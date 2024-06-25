open Config
open Def
open Gwdb
open Util

let file_copy input_name output_name =
  let fd_in = Unix.openfile input_name [ O_RDONLY ] 0 in
  let fd_out = Unix.openfile output_name [ O_WRONLY; O_CREAT; O_TRUNC ] 0o666 in
  let buffer_size = 8192 in
  let buffer = Bytes.create buffer_size in
  let rec copy_loop () =
    match Unix.read fd_in buffer 0 buffer_size with
    | 0 -> ()
    | r ->
        ignore (Unix.write fd_out buffer 0 r);
        copy_loop ()
  in
  copy_loop ();
  Unix.close fd_in;
  Unix.close fd_out

let cp = file_copy

let rn fname s =
  try if Sys.file_exists fname then Sys.rename fname s
  with Failure _ ->
    Printf.eprintf "Rn failed: %s to %s\n" fname s;
    flush stderr

type image_type = JPEG | GIF | PNG

let extension_of_type = function
  | JPEG -> ".jpg"
  | GIF -> ".gif"
  | PNG -> ".png"

let image_types = [ JPEG; GIF; PNG ]
let raise_modErr s = raise @@ Update.ModErr (Update.UERR s)

let incorrect conf str =
  Hutil.incorrect_request conf ~comment:str;
  failwith (__FILE__ ^ " (" ^ str ^ ")" :> string)

let incorrect_content_type conf base p s =
  let title _ =
    Output.print_sstring conf (Utf8.capitalize (Util.transl conf "error"))
  in
  Hutil.header conf title;
  Output.print_sstring conf "<p>\n<em style=\"font-size:smaller\">";
  Output.printf conf "Error: incorrect image content type: %s" s;
  Output.printf conf "</em>\n</p>\n<ul>\n<li>\n%s</li>\n</ul>\n"
    (Util.referenced_person_title_text conf base p :> string);
  Hutil.trailer conf;
  failwith (__FILE__ ^ " " ^ string_of_int __LINE__ :> string)

let error_too_big_image conf base p len max_len =
  let title _ =
    Output.print_sstring conf (Utf8.capitalize (Util.transl conf "error"))
  in
  Hutil.header ~error:true conf title;
  Output.print_sstring conf "<p><em style=\"font-size:smaller\">";
  Output.printf conf "Error: this image is too big: %d bytes<br>\n" len;
  Output.printf conf "Maximum authorized in this database: %d bytes<br>\n"
    max_len;
  Output.printf conf "</em></p>\n<ul>\n<li>\n%s</li>\n</ul>\n"
    (Util.referenced_person_title_text conf base p :> string);
  Hutil.trailer conf;
  failwith (__FILE__ ^ " " ^ string_of_int __LINE__ :> string)

let raw_get conf key =
  try List.assoc key conf.env
  with Not_found -> incorrect conf ("raw_get" ^ key)

let insert_saved fname =
  let l = String.split_on_char Filename.dir_sep.[0] fname |> List.rev in
  let l = List.rev @@ match l with h :: t -> h :: "saved" :: t | _ -> l in
  String.concat Filename.dir_sep l

let write_file fname content =
  let oc = Secure.open_out_bin fname in
  output_string oc content;
  flush oc;
  close_out oc

let move_file_to_save dir file =
  try
    (* FIXME attention, le basename détruit les sous dossiers *)
    let save_dir = Filename.concat dir "saved" in
    if not (Sys.file_exists save_dir) then Mutil.mkdir_p save_dir;
    let fname = Filename.basename file in
    let orig_file = Filename.concat dir fname in
    let saved_file = Filename.concat save_dir fname in
    (* TODO handle rn errors *)
    rn orig_file saved_file;
    let orig_file_t = Filename.remove_extension orig_file ^ ".txt" in
    let saved_file_t = Filename.remove_extension saved_file ^ ".txt" in
    if Sys.file_exists orig_file_t then rn orig_file_t saved_file_t;
    let orig_file_s = Filename.remove_extension orig_file ^ ".src" in
    let saved_file_s = Filename.remove_extension saved_file ^ ".src" in
    if Sys.file_exists orig_file_s then rn orig_file_s saved_file_s;
    1
  with _ -> 0

let create_blason_stop conf base p =
  let blason_dir = Image.get_dir_name "blasons" conf.bname in
  let blason_stop =
    String.concat Filename.dir_sep
      [ blason_dir; Image.default_image_filename "blasons" base p ^ ".stop" ]
  in
  let oc = open_out blason_stop in
  close_out oc;
  blason_stop

let move_blason_file conf base src dst =
  let blason_dir = Image.get_dir_name "blasons" conf.bname in
  let blason_src =
    String.concat Filename.dir_sep
      [ blason_dir; Image.get_blason_name conf base src ]
  in
  if
    Image.has_blason conf base src true
    && Sys.file_exists blason_src
    && not (Image.has_blason conf base dst true)
  then (
    let blason_dst =
      String.concat Filename.dir_sep
        [
          blason_dir;
          Image.default_image_filename "blasons" base dst
          ^ Filename.extension blason_src;
        ]
    in
    rn blason_src blason_dst;
    blason_dst)
  else ""

let normal_image_type s =
  if String.length s > 10 && Char.code s.[0] = 0xff && Char.code s.[1] = 0xd8
  then Some JPEG
  else if String.length s > 4 && String.sub s 0 4 = "\137PNG" then Some PNG
  else if String.length s > 4 && String.sub s 0 4 = "GIF8" then Some GIF
  else None

let string_search s v =
  let rec loop i j =
    if j = String.length v then Some (i - String.length v)
    else if i = String.length s then None
    else if s.[i] = v.[j] then loop (i + 1) (j + 1)
    else loop (i + 1) 0
  in
  loop 0 0

(* get the image type, possibly removing spurious header *)

let image_type s =
  match normal_image_type s with
  | Some t -> Some (t, s)
  | None -> (
      match string_search s "JFIF" with
      | Some i when i > 6 ->
          let s = String.sub s (i - 6) (String.length s - i + 6) in
          Some (JPEG, s)
      | _ -> (
          match string_search s "\137PNG" with
          | Some i ->
              let s = String.sub s i (String.length s - i) in
              Some (PNG, s)
          | _ -> (
              match string_search s "GIF8" with
              | Some i ->
                  let s = String.sub s i (String.length s - i) in
                  Some (GIF, s)
              | None -> None)))

let dump_bad_image conf s =
  match List.assoc_opt "dump_bad_images" conf.base_env with
  | Some "yes" -> (
      try
        (* Where will "bad-image"end up? *)
        let oc = Secure.open_out_bin "bad-image" in
        output_string oc s;
        flush oc;
        close_out oc
      with Sys_error _ -> ())
  | _ -> ()

(* swap files between new and old folder *)
(* [| ".jpg"; ".jpeg"; ".png"; ".gif" |] *)

let swap_files_aux dir file ext old_ext =
  (* FIXME basename !!*)
  let old_file =
    String.concat Filename.dir_sep [ dir; "saved"; Filename.basename file ]
  in
  let tmp_file = String.concat Filename.dir_sep [ dir; "tempfile.tmp" ] in
  if ext <> old_ext then (
    if Sys.file_exists file then rn file (Filename.chop_extension old_file ^ ext);
    if Sys.file_exists old_file then
      rn old_file (Filename.chop_extension file ^ old_ext))
  else (
    if Sys.file_exists file then rn file tmp_file;
    if Sys.file_exists old_file then rn old_file file;
    if Sys.file_exists tmp_file then rn tmp_file old_file)

let swap_files file ext old_ext =
  let dir = Filename.dirname file in
  (* FIXME basename *)
  let fname = Filename.basename file in
  swap_files_aux dir file ext old_ext;
  let txt_file =
    String.concat Filename.dir_sep
      [ dir; Filename.chop_extension fname ^ ".txt" ]
  in
  swap_files_aux dir txt_file ext old_ext;
  let src_file =
    String.concat Filename.dir_sep
      [ dir; Filename.chop_extension fname ^ ".src" ]
  in
  swap_files_aux dir src_file ext old_ext

let clean_saved_portrait file =
  let file = Filename.remove_extension file in
  Array.iter (fun ext -> Mutil.rm (file ^ ext)) Image.ext_list_1

(* TODO merge with Image.file_without_extension *)
let get_extension conf saved fname =
  let f =
    if saved then
      String.concat Filename.dir_sep
        [ Util.base_path [ "images" ] conf.bname; "saved"; fname ]
    else
      String.concat Filename.dir_sep
        [ Util.base_path [ "images" ] conf.bname; fname ]
  in
  if Sys.file_exists (f ^ ".jpg") then ".jpg"
  else if Sys.file_exists (f ^ ".jpeg") then ".jpeg"
  else if Sys.file_exists (f ^ ".png") then ".png"
  else if Sys.file_exists (f ^ ".gif") then ".gif"
  else if Sys.file_exists (f ^ ".url") then ".url"
  else if Sys.file_exists (f ^ ".stop") then ".stop"
  else "."

let print_confirm_c conf base save_m report =
  match Util.p_getint conf.env "i" with
  | Some ip ->
      let p = poi base (Gwdb.iper_of_string (string_of_int ip)) in
      let digest = Image.default_image_filename "portraits" base p in
      let new_env =
        List.fold_left
          (fun accu (k, v) ->
            if k = "m" then ("m", Adef.encoded "REFRESH") :: accu
            else if k = "idigest" || k = "" || k = "file" then accu
            else (k, v) :: accu)
          [] conf.env
      in
      let new_env =
        if save_m = "REFRESH" then new_env
        else ("em", Adef.encoded save_m) :: new_env
      in
      let new_env =
        ("idigest", Adef.encoded digest)
        :: ("report", Adef.encoded report)
        :: new_env
      in
      let conf = { conf with env = new_env } in
      Perso.interp_templ "carrousel" conf base p
  | None -> Hutil.incorrect_request conf

(* ************************************************************************ *)
(*  send, delete, reset and print functions                                 *)
(*                                                                          *)
(* ************************************************************************ *)

(* we need print_link_delete_image in the send function *)
let print_link_delete_image conf base p =
  if Option.is_some @@ Image.get_portrait conf base p then (
    Output.print_sstring conf {|<div><a class="btn btn-danger mt-3" href="|};
    Output.print_string conf (commd conf);
    Output.print_sstring conf "m=DEL_IMAGE&i=";
    Output.print_string conf (get_iper p |> string_of_iper |> Mutil.encode);
    Output.print_sstring conf {|">|};
    transl conf "delete" |> Utf8.capitalize_fst |> Output.print_sstring conf;
    Output.print_sstring conf {| |};
    transl_nth conf "image/images" 0 |> Output.print_sstring conf;
    Output.print_sstring conf "</a></div>")

let print_send_image conf base p =
  let title h =
    if Option.is_some @@ Image.get_portrait conf base p then
      transl_nth conf "image/images" 0
      |> transl_decline conf "modify"
      |> Utf8.capitalize_fst |> Output.print_sstring conf
    else
      transl_nth conf "image/images" 0
      |> transl_decline conf "add" |> Utf8.capitalize_fst
      |> Output.print_sstring conf;
    if not h then (
      Output.print_sstring conf (transl conf ":");
      Output.print_sstring conf " ";
      Output.print_string conf (Util.escape_html (p_first_name base p));
      Output.print_sstring conf (Format.sprintf ".%d " (get_occ p));
      Output.print_string conf (Util.escape_html (p_surname base p)))
  in
  let digest = Image.default_image_filename "portraits" base p in
  Hutil.header conf title;
  Output.printf conf
    "<form method=\"post\" action=\"%s\" enctype=\"multipart/form-data\">\n"
    conf.command;
  Output.print_sstring conf
    "<div class=\"d-inline-flex align-items-center mt-2\">\n";
  Util.hidden_env conf;
  Util.hidden_input conf "m" (Adef.encoded "SND_IMAGE_C_OK");
  Util.hidden_input conf "i" (get_iper p |> string_of_iper |> Mutil.encode);
  Util.hidden_input conf "idigest" (Mutil.encode digest);
  Output.print_sstring conf (Utf8.capitalize_fst (transl conf "file"));
  Output.print_sstring conf (Util.transl conf ":");
  Output.print_sstring conf " ";
  Output.print_sstring conf
    {|<input type="file" class="form-control-file ml-1" name="file" accept="image/*">|};
  (match
     Option.map int_of_string @@ List.assoc_opt "max_images_size" conf.base_env
   with
  | Some len ->
      Output.print_sstring conf "<p>(maximum authorized size = ";
      Output.print_sstring conf (string_of_int len);
      Output.print_sstring conf " bytes)</p>"
  | None -> ());
  Output.print_sstring conf
    {|<span>></span><button type="submit" class="btn btn-primary ml-3">|};
  transl_nth conf "validate/delete" 0
  |> Utf8.capitalize_fst |> Output.print_sstring conf;
  Output.print_sstring conf "</button></div></form>";
  print_link_delete_image conf base p;
  Hutil.trailer conf

let print_send_blason conf base p =
  let title h =
    if Option.is_some @@ Image.get_blason conf base p true then
      transl_nth conf "image/images" 0
      |> transl_decline conf "modify"
      |> Utf8.capitalize_fst |> Output.print_sstring conf
    else
      transl_nth conf "image/images" 0
      |> transl_decline conf "add" |> Utf8.capitalize_fst
      |> Output.print_sstring conf;
    if not h then (
      Output.print_sstring conf (transl conf ": ");
      Output.print_sstring conf (transl_nth conf "family/families" 0);
      Output.print_sstring conf " ";
      Output.print_string conf (Util.escape_html (p_surname base p)))
  in
  let digest = Update.digest_person (UpdateInd.string_person_of base p) in
  Perso.interp_notempl_with_menu title "perso_header" conf base p;
  Output.print_sstring conf "<h2>\n";
  title false;
  Output.print_sstring conf "</h2>\n";
  Output.printf conf
    "<form method=\"post\" action=\"%s\" enctype=\"multipart/form-data\">\n"
    conf.command;
  Output.print_sstring conf "<p>\n";
  Util.hidden_env conf;
  Util.hidden_input conf "m" (Adef.encoded "SND_FIMAGE_OK");
  Util.hidden_input conf "i" (get_iper p |> string_of_iper |> Mutil.encode);
  Util.hidden_input conf "digest" (Mutil.encode digest);
  Output.print_sstring conf (Utf8.capitalize_fst (transl conf "file"));
  Output.print_sstring conf (Util.transl conf ":");
  Output.print_sstring conf " ";
  Output.print_sstring conf
    {| <input type="file" class="form-control-file" name="file" accept="image/*"></p>|};
  (match
     Option.map int_of_string @@ List.assoc_opt "max_images_size" conf.base_env
   with
  | Some len ->
      Output.print_sstring conf "<p>(maximum authorized size = ";
      Output.print_sstring conf (string_of_int len);
      Output.print_sstring conf " bytes)</p>"
  | None -> ());
  Output.print_sstring conf
    {|<button type="submit" class="btn btn-primary mt-2">|};
  transl_nth conf "validate/delete" 0
  |> Utf8.capitalize_fst |> Output.print_sstring conf;
  Output.print_sstring conf "</button></form>";
  print_link_delete_image conf base p;
  Hutil.trailer conf

let print_sent conf base p =
  let title _ =
    transl conf "image received"
    |> Utf8.capitalize_fst |> Output.print_sstring conf
  in
  Hutil.header conf title;
  Output.print_sstring conf "<ul><li>";
  Output.print_string conf (referenced_person_text conf base p);
  Output.print_sstring conf "</li></ul>";
  Hutil.trailer conf

let effective_send_ok conf base p file =
  let mode =
    try (List.assoc "mode" conf.env :> string) with Not_found -> "portraits"
  in
  let strm = Stream.of_string file in
  let request, content = Wserver.get_request_and_content strm in
  let content =
    let s =
      let rec loop len (strm__ : _ Stream.t) =
        match Stream.peek strm__ with
        | Some x ->
            Stream.junk strm__;
            loop (Buff.store len x) strm
        | _ -> Buff.get len
      in
      loop 0 strm
    in
    (content :> string) ^ s
  in
  let typ, content =
    match image_type content with
    | None ->
        dump_bad_image conf content;
        Mutil.extract_param "content-type: " '\n' request
        |> incorrect_content_type conf base p
    | Some (typ, content) -> (
        match
          Option.map int_of_string
          @@ List.assoc_opt "max_images_size" conf.base_env
        with
        | Some len when String.length content > len ->
            error_too_big_image conf base p (String.length content) len
        | _ -> (typ, content))
  in
  let fname = Image.default_image_filename "portraits" base p in
  let dir = Util.base_path [ "images" ] conf.bname in
  if not (Sys.file_exists dir) then Mutil.mkdir_p dir;
  let fname =
    Filename.concat dir
      (if mode = "portraits" then fname ^ extension_of_type typ else fname)
  in
  let _moved = move_file_to_save dir fname in
  write_file fname content;
  let changed =
    U_Send_image (Util.string_gen_person base (gen_person_of_person p))
  in
  History.record conf base changed "si";
  print_sent conf base p

let effective_blason_send_ok conf base p file =
  let mode =
    try (List.assoc "mode" conf.env :> string) with Not_found -> "portraits"
  in
  let strm = Stream.of_string file in
  let request, content = Wserver.get_request_and_content strm in
  let content =
    let s =
      let rec loop len (strm__ : _ Stream.t) =
        match Stream.peek strm__ with
        | Some x ->
            Stream.junk strm__;
            loop (Buff.store len x) strm
        | _ -> Buff.get len
      in
      loop 0 strm
    in
    (content :> string) ^ s
  in
  let typ, content =
    match image_type content with
    | None ->
        dump_bad_image conf content;
        Mutil.extract_param "content-type: " '\n' request
        |> incorrect_content_type conf base p
    | Some (typ, content) -> (
        match
          Option.map int_of_string
          @@ List.assoc_opt "max_images_size" conf.base_env
        with
        | Some len when String.length content > len ->
            error_too_big_image conf base p (String.length content) len
        | _ -> (typ, content))
  in
  let fname = Image.default_image_filename "blasons" base p in
  let dir = Util.base_path [ "images" ] conf.bname in
  if not (Sys.file_exists dir) then Mutil.mkdir_p dir;
  let fname =
    Filename.concat dir
      (if mode = "portraits" then fname ^ extension_of_type typ else fname)
  in
  let _moved = move_file_to_save dir fname in
  write_file fname content;
  let changed =
    U_Send_image (Util.string_gen_person base (gen_person_of_person p))
  in
  History.record conf base changed "si";
  print_sent conf base p

let print_send_ok conf base =
  let ip =
    try raw_get conf "i" |> Mutil.decode |> iper_of_string
    with Failure _ -> incorrect conf "print send ok"
  in
  let p = poi base ip in
  let digest = Image.default_image_filename "portraits" base p in
  if (digest :> string) = Mutil.decode (raw_get conf "idigest") then
    raw_get conf "file" |> Adef.as_string |> effective_send_ok conf base p
  else Update.error_digest conf

let print_blason_send_ok conf base =
  let ip =
    try raw_get conf "i" |> Mutil.decode |> iper_of_string
    with Failure _ -> incorrect conf "print family send ok"
  in
  let p = poi base ip in
  let digest = Update.digest_person (UpdateInd.string_person_of base p) in
  if (digest :> string) = Mutil.decode (raw_get conf "digest") then
    raw_get conf "file" |> Adef.as_string
    |> effective_blason_send_ok conf base p
  else Update.error_digest conf

(* carrousel *)
let effective_send_c_ok ?(portrait = true) conf base p file file_name =
  let mode =
    try (List.assoc "mode" conf.env :> string) with Not_found -> "portraits"
  in
  let image_url =
    try (List.assoc "image_url" conf.env :> string) with Not_found -> ""
  in
  let image_name =
    try (List.assoc "image_name" conf.env :> string) with Not_found -> ""
  in
  let image_name =
    if image_name = "" then
      let f =
        if String.length image_url > 7 then
          String.sub image_url 7 (String.length image_url - 7)
        else image_url
      in
      (* FIXME basename *)
      Filename.basename f
    else image_name
  in
  let note =
    match Util.p_getenv conf.env "note" with
    | Some v ->
        Util.safe_html
          (Util.only_printable_or_nl (Mutil.strip_all_trailing_spaces v))
    | None -> Adef.safe ""
  in
  let source =
    match Util.p_getenv conf.env "source" with
    | Some v ->
        Util.safe_html
          (Util.only_printable_or_nl (Mutil.strip_all_trailing_spaces v))
    | None -> Adef.safe ""
  in
  let strm = Stream.of_string file in
  let request, content = Wserver.get_request_and_content strm in
  let content =
    if mode = "note" || mode = "source" || image_url <> "" then ""
    else
      let s =
        let rec loop len (strm__ : _ Stream.t) =
          match Stream.peek strm__ with
          | Some x ->
              Stream.junk strm__;
              loop (Buff.store len x) strm
          | _ -> Buff.get len
        in
        loop 0 strm
      in
      (content :> string) ^ s
  in
  let typ, content =
    if content <> "" then
      match image_type content with
      | None ->
          let ct = Mutil.extract_param "Content-Type: " '\n' request in
          dump_bad_image conf content;
          incorrect_content_type conf base p ct
      | Some (typ, content) -> (
          match List.assoc_opt "max_images_size" conf.base_env with
          | Some len when String.length content > int_of_string len ->
              error_too_big_image conf base p (String.length content)
                (int_of_string len)
          | _ -> (typ, content))
    else (GIF, content (* we dont care which type, content = "" *))
  in
  let fname =
    if portrait then Image.default_image_filename "portraits" base p
    else Image.default_image_filename "blasons" base p
  in
  let dir =
    if mode = "portraits" then
      String.concat Filename.dir_sep [ Util.base_path [ "images" ] conf.bname ]
    else
      String.concat Filename.dir_sep
        [ Util.base_path [ "src" ] conf.bname; "images"; fname ]
  in
  if not (Sys.file_exists dir) then Mutil.mkdir_p dir;
  let fname =
    Filename.concat dir
      (if mode = "portraits" then fname ^ extension_of_type typ else file_name)
  in
  if mode = "portraits" then
    match
      if portrait then Image.get_portrait conf base p
      else Image.get_blason conf base p true
    with
    | Some (`Path portrait) ->
        if move_file_to_save dir portrait = 0 then
          incorrect conf "effective send (portrait)"
    | Some (`Url url) -> (
        let fname =
          if portrait then Image.default_image_filename "portraits" base p
          else Image.default_image_filename "blasons" base p
        in
        let dir = Filename.concat dir "saved" in
        if not (Sys.file_exists dir) then Mutil.mkdir_p dir;
        let fname = Filename.concat dir fname ^ ".url" in
        try write_file fname url
        with _ ->
          incorrect conf
            (Printf.sprintf "effective send (effective send url portrait %s)"
               fname)
        (* TODO update person to supress url image *))
    | _ -> ()
  else if content <> "" then
    if Sys.file_exists fname then
      if move_file_to_save dir fname = 0 then
        incorrect conf "effective send (image)";
  let fname =
    if image_url <> "" then Filename.concat dir image_name ^ ".url" else fname
  in
  if content <> "" then
    try write_file fname content
    with _ ->
      incorrect conf
        (Printf.sprintf "effective send (writing content file %s)" fname)
  else if image_url <> "" then
    try write_file fname image_url
    with _ ->
      incorrect conf
        (Printf.sprintf "effective send (writing .url file %s)" fname)
  else ();
  if note <> Adef.safe "" then
    let fname = Filename.remove_extension fname ^ ".txt" in
    try write_file fname (note :> string)
    with _ ->
      incorrect conf
        (Printf.sprintf "effective send (writing .txt file %s)" fname)
  else ();
  if source <> Adef.safe "" then
    let fname = Filename.remove_extension fname ^ ".src" in
    try write_file fname (source :> string)
    with _ ->
      incorrect conf
        (Printf.sprintf "effective send (writing .txt file %s)" fname)
  else ();
  let changed =
    U_Send_image (Util.string_gen_person base (gen_person_of_person p))
  in
  History.record conf base changed
    (match mode with
    | "portraits" -> "sp"
    | "blasons" -> "sb"
    | "carrousel" ->
        if file_name <> "" && note <> Adef.safe "" && source <> Adef.safe ""
        then "s3"
        else if file_name <> "" then "sf"
        else if note <> Adef.safe "" then "so"
        else if source <> Adef.safe "" then "ss"
        else "sx"
    | _ -> "s?");
  file_name

(* Delete *)
let print_delete_image conf base p =
  let title h =
    transl_nth conf "image/images" 0
    |> transl_decline conf "delete"
    |> Utf8.capitalize_fst |> Output.print_sstring conf;
    if not h then (
      let fn = p_first_name base p in
      let sn = p_surname base p in
      let occ = get_occ p in
      Output.print_sstring conf (Util.transl conf ":");
      Output.print_sstring conf " ";
      Output.print_string conf (Util.escape_html fn);
      Output.print_sstring conf ".";
      Output.print_sstring conf (string_of_int occ);
      Output.print_sstring conf " ";
      Output.print_string conf (Util.escape_html sn))
  in
  Hutil.header conf title;
  Output.printf conf "<form method=\"post\" action=\"%s\">" conf.command;
  Util.hidden_env conf;
  Util.hidden_input conf "m" (Adef.encoded "DEL_IMAGE_OK");
  Util.hidden_input conf "i" (get_iper p |> string_of_iper |> Mutil.encode);
  Output.print_sstring conf
    {|<div class="mt-3"><button type="submit" class="btn btn-danger">|};
  transl_nth conf "validate/delete" 1
  |> Utf8.capitalize_fst |> Output.print_sstring conf;
  Output.print_sstring conf {|</button></div></form>|};
  Hutil.trailer conf

let print_deleted conf base p =
  let title _ =
    transl conf "image deleted"
    |> Utf8.capitalize_fst |> Output.print_sstring conf
  in
  Hutil.header conf title;
  Output.print_sstring conf "<ul><li>";
  Output.print_string conf (referenced_person_text conf base p);
  Output.print_sstring conf "</li></ul>";
  Hutil.trailer conf

let effective_delete_ok conf base p =
  let fname = Image.default_image_filename "portraits" base p in
  let ext = get_extension conf false fname in
  let dir = Util.base_path [ "images" ] conf.bname in
  if move_file_to_save dir (fname ^ ext) = 0 then
    incorrect conf "effective delete";
  let changed =
    U_Delete_image (Util.string_gen_person base (gen_person_of_person p))
  in
  History.record conf base changed "di";
  print_deleted conf base p

let print_del_ok conf base =
  match p_getenv conf.env "i" with
  | Some ip ->
      let p = poi base (iper_of_string ip) in
      effective_delete_ok conf base p
  | None -> incorrect conf "print del ok"

let print_del conf base =
  match p_getenv conf.env "i" with
  | None -> Hutil.incorrect_request conf
  | Some ip -> (
      let p = poi base (iper_of_string ip) in
      match Image.get_portrait conf base p with
      | Some _ -> print_delete_image conf base p
      | None -> Hutil.incorrect_request conf)

(*carrousel *)
(* removes portrait or other image and saves it into old folder *)
(* if delete=on permanently deletes the file in old folder *)

let effective_delete_c_ok conf base ?(f_name = "") p =
  let mode =
    try (List.assoc "mode" conf.env :> string) with Not_found -> "portraits"
  in
  let delete =
    try List.assoc "delete" conf.env = Adef.encoded "on"
    with Not_found -> false
  in
  let keydir = Image.default_image_filename "portraits" base p in
  let fname =
    if f_name = "" then
      try (List.assoc "file_name" conf.env :> string) with Not_found -> ""
    else f_name
  in
  let dir =
    if mode = "portraits" || mode = "blasons" then
      Util.base_path [ "images" ] conf.bname
    else
      String.concat Filename.dir_sep
        [ Util.base_path [ "src" ] conf.bname; "images"; keydir ]
  in
  if not (Sys.file_exists dir) then Mutil.mkdir_p dir;
  (* TODO verify we dont destroy a saved image
      having the same name as portrait! *)
  let orig_file =
    if delete then String.concat Filename.dir_sep [ dir; "saved"; fname ]
    else Filename.concat dir fname
  in
  let orig_file = Image.find_file_without_ext orig_file in
  (* FIXME basename *)
  let file = Filename.basename orig_file in
  if orig_file = "" then incorrect conf "empty file name"
    (* if delete is on, we are talking about saved files *)
  else if delete then Mutil.rm orig_file (* is it needed ?, move should do it *)
  else if move_file_to_save dir file = 0 then incorrect conf "effective delete";
  let changed =
    U_Delete_image (Util.string_gen_person base (gen_person_of_person p))
  in
  History.record conf base changed
    (match mode with
    | "portraits" -> "dq"
    | "blasons" -> "db"
    | "carrousel" -> "dc"
    | _ -> "d?");
  fname

let effective_copy_portrait_to_blason conf base p =
  let create_url_file keydir url =
    let fname = Util.base_path [ "images"; conf.bname ] keydir ^ ".url" in
    let oc = Secure.open_out_bin fname in
    output_string oc url;
    flush oc;
    close_out oc;
    fname
  in
  let dir = Util.base_path [ "images" ] conf.bname in
  let fname, url =
    match Image.src_of_string conf (sou base (get_image p)) with
    | `Url u ->
        ( create_url_file (Image.default_image_filename "portraits" base p) u,
          true )
    | _ -> (Image.default_image_filename "portraits" base p, false)
  in
  let ext = if url then ".url" else get_extension conf false fname in
  let portrait_filename =
    String.concat Filename.dir_sep
      [ dir; Image.default_image_filename "portrait" base p ^ ext ]
  in
  let blason_filename =
    String.concat Filename.dir_sep
      [ dir; Image.default_image_filename "blasons" base p ^ ext ]
  in
  let has_blason_self = Image.has_blason conf base p true in
  (* attention, xxx.url has to be removed too *)
  let _deleted =
    (if has_blason_self then
     effective_delete_c_ok conf base
       ~f_name:(Filename.basename blason_filename)
       p
    else "OK")
    <> ""
  in
  cp portrait_filename blason_filename;
  History.record conf base
    (U_Send_image (Util.string_gen_person base (gen_person_of_person p)))
    "cb";
  blason_filename

let effective_copy_image_to_blason conf base p =
  let fname =
    try (List.assoc "file_name" conf.env :> string) with Not_found -> ""
  in
  let keydir = Image.default_image_filename "portraits" base p in
  let ext = Filename.extension fname in
  let blason_filename =
    String.concat Filename.dir_sep
      [
        Image.portrait_folder conf;
        Image.default_image_filename "blasons" base p ^ ext;
      ]
  in
  let has_blason_self = Image.has_blason conf base p true in
  let _deleted =
    (if has_blason_self then
     effective_delete_c_ok conf base
       ~f_name:(Filename.basename blason_filename)
       p
    else "OK")
    <> ""
  in
  (* la fonction image_to_blason part des images sauvegardées *)
  let fname =
    String.concat Filename.dir_sep
      [ Image.carrousel_folder conf; keydir; "saved"; fname ]
  in
  cp fname blason_filename;
  History.record conf base
    (U_Send_image (Util.string_gen_person base (gen_person_of_person p)))
    "cd";
  blason_filename

(* carrousel *)
(* reset portrait or image from old folder to portrait or others *)

let effective_reset_c_ok ?(portrait = true) conf base p =
  (* WARNING: when saved portrait is an url, we should update the person record
     when doing a reset  idem for delete *)
  let _ = portrait in
  let mode =
    try (List.assoc "mode" conf.env :> string) with Not_found -> "portraits"
  in
  let keydir = Image.default_image_filename "portraits" base p in
  let file_name =
    match mode with
    | "portraits" -> Image.default_image_filename "portraits" base p
    | "blasons" -> Image.default_image_filename "blasons" base p
    | "carrousel" -> (
        try (List.assoc "file_name" conf.env :> string) with Not_found -> "")
    | _ -> "xx"
  in
  let ext = get_extension conf false file_name in
  let old_ext = get_extension conf true file_name in
  let ext =
    match Image.get_portrait conf base p with
    | Some src -> if Image.is_url (Image.src_to_string src) then ".url" else ext
    | _ -> ext
  in
  let file_in_new =
    if mode = "portraits" || mode = "blasons" then
      String.concat Filename.dir_sep
        [ Util.base_path [ "images" ] conf.bname; file_name ^ old_ext ]
    else
      String.concat Filename.dir_sep
        [ Util.base_path [ "src" ] conf.bname; "images"; keydir; file_name ]
  in
  swap_files file_in_new ext old_ext;
  let changed =
    U_Send_image (Util.string_gen_person base (gen_person_of_person p))
  in
  History.record conf base changed
    (match mode with
    | "portraits" -> "rp"
    | "blasons" -> "rb"
    | "carrousel" -> "rc"
    | _ -> "r?");
  file_name

(* ************************************************************************** *)
(*  [Fonc] print : Config.config -> Gwdb.base -> unit                         *)
(* ************************************************************************** *)

(* most functions in GeneWeb end with a COMMAND_OK confirmation step *)
(* for carrousel, we have chosen to ignore this step and refresh *)
(* the updated page directly *)
(* if em="" this is the first pass, do it *)

let print_main_c conf base =
  match Util.p_getenv conf.env "em" with
  | None -> (
      match Util.p_getenv conf.env "m" with
      | Some m -> (
          let save_m = m in
          match Util.p_getenv conf.env "i" with
          | Some ip -> (
              let p = poi base (Gwdb.iper_of_string ip) in
              let digest = Image.default_image_filename "portraits" base p in
              let conf, report =
                match m with
                | "SND_IMAGE_C_OK" ->
                    let mode =
                      try (List.assoc "mode" conf.env :> string)
                      with Not_found -> "portraits"
                    in
                    let file_name =
                      try (List.assoc "file_name" conf.env :> string)
                      with Not_found -> ""
                    in
                    let file_name =
                      if file_name = "" then
                        try (List.assoc "file_name_2" conf.env :> string)
                        with Not_found -> ""
                      else file_name
                    in
                    let file_name =
                      (Mutil.decode (Adef.encoded file_name) :> string)
                    in
                    let file_name_2 = Filename.remove_extension file_name in
                    let new_env =
                      List.fold_left
                        (fun accu (k, v) ->
                          if k = "file_name_2" then
                            (k, Adef.encoded file_name_2) :: accu
                          else (k, v) :: accu)
                        [] conf.env
                    in
                    let conf = { conf with env = new_env } in
                    let file =
                      if mode = "note" || mode = "source" then "file_name"
                      else (raw_get conf "file" :> string)
                    in
                    let idigest =
                      try (List.assoc "idigest" conf.env :> string)
                      with Not_found -> ""
                    in
                    let fdigest =
                      try (List.assoc "fdigest" conf.env :> string)
                      with Not_found -> ""
                    in
                    if digest = idigest then
                      ( conf,
                        effective_send_c_ok
                          ~portrait:(if idigest = fdigest then false else true)
                          conf base p file file_name )
                    else (conf, "idigest error")
                | "DEL_IMAGE_C_OK" ->
                    let idigest =
                      try (List.assoc "idigest" conf.env :> string)
                      with Not_found -> ""
                    in
                    let fdigest =
                      try (List.assoc "fdigest" conf.env :> string)
                      with Not_found -> ""
                    in
                    if digest = idigest then
                      (conf, effective_delete_c_ok conf base p)
                    else if fdigest != "" then
                      (conf, effective_delete_c_ok conf base p)
                    else (conf, "idigest error")
                | "RESET_IMAGE_C_OK" ->
                    let idigest =
                      try (List.assoc "idigest" conf.env :> string)
                      with Not_found -> ""
                    in
                    let fdigest =
                      try (List.assoc "fdigest" conf.env :> string)
                      with Not_found -> ""
                    in
                    if digest = idigest then
                      (conf, effective_reset_c_ok conf base p)
                    else if fdigest != "" then
                      (conf, effective_reset_c_ok ~portrait:false conf base p)
                    else (conf, "idigest error")
                | "BLASON_MOVE_TO_ANC" ->
                    if Image.has_blason conf base p true then
                      match Util.p_getenv conf.env "ia" with
                      | Some ia ->
                          let fa = poi base (Gwdb.iper_of_string ia) in
                          (conf, move_blason_file conf base p fa)
                      | None -> (conf, "")
                    else (conf, "")
                | "PORTRAIT_TO_BLASON" ->
                    (conf, effective_copy_portrait_to_blason conf base p)
                | "IMAGE_TO_BLASON" ->
                    (conf, effective_copy_image_to_blason conf base p)
                | "BLASON_STOP" ->
                    let has_blason_self = Image.has_blason conf base p true in
                    let has_blason = Image.has_blason conf base p false in
                    if has_blason && not has_blason_self then
                      (conf, create_blason_stop conf base p)
                    else (conf, "idigest error")
                | "IMAGE_C" -> (conf, "image")
                | _ -> (conf, "incorrect request")
              in
              match report with
              | "idigest error" ->
                  failwith
                    (__FILE__ ^ " idigest error, line " ^ string_of_int __LINE__
                      :> string)
              | "incorrect request" -> Hutil.incorrect_request conf
              | _ -> print_confirm_c conf base save_m report)
          | None -> Hutil.incorrect_request conf)
      | None -> Hutil.incorrect_request conf)
  (* em!="" second pass, ignore *)
  | Some _ -> print_confirm_c conf base "REFRESH" ""

let print conf base =
  match p_getenv conf.env "i" with
  | None -> Hutil.incorrect_request conf
  | Some ip ->
      let p = poi base (iper_of_string ip) in
      let fn = p_first_name base p in
      let sn = p_surname base p in
      if fn = "?" || sn = "?" then Hutil.incorrect_request conf
      else print_send_image conf base p

let print_family conf base =
  match p_getenv conf.env "i" with
  | None -> Hutil.incorrect_request conf
  | Some ip ->
      let p = poi base (iper_of_string ip) in
      let sn = p_surname base p in
      if sn = "?" then Hutil.incorrect_request conf
      else print_send_blason conf base p

(* carrousel *)
let print_c ?(saved = false) ?(portrait = true) conf base =
  let mode = if portrait then "portraits" else "blasons" in
  match (Util.p_getenv conf.env "s", Util.find_person_in_env conf base "") with
  | Some f, Some p ->
      let k = Image.default_image_filename mode base p in
      let f = Filename.concat k f in
      ImageDisplay.print_source conf (if saved then insert_saved f else f)
  | Some f, _ -> ImageDisplay.print_source conf f
  | _, Some p -> (
      match
        if saved then Image.get_old_portrait_or_blason conf base "portraits" p
        else if mode = "portraits" then Image.get_portrait conf base p
        else Image.get_blason conf base p false
      with
      | Some (`Path f) ->
          Result.fold ~ok:ignore
            ~error:(fun _ -> Hutil.incorrect_request conf)
            (ImageDisplay.print_image_file conf f)
      | _ -> Hutil.incorrect_request conf)
  | _, _ -> Hutil.incorrect_request conf
