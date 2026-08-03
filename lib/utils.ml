(* Filesystem helpers for locating on-disk assets relative to the running
   executable, independently of the current working directory. *)

(* Absolute path to the directory containing the running executable. *)
let exe_dir () =
  let dir = Filename.dirname Sys.executable_name in
  if Filename.is_relative dir then Filename.concat (Sys.getcwd ()) dir else dir

(* Directory to resolve on-disk assets against, independently of the cwd.

   When launched via [dune exec], the executable lives under
   [<root>/_build/<context>/...] but the source assets are not copied there.
   We map such a path back to the matching source directory so the assets are
   found. When run from an installed location (no [_build] segment) the
   executable directory is used as-is. *)
let asset_dir () =
  let rec strip = function
    | "_build" :: _context :: rest -> rest (* drop "_build/<context>/" *)
    | x :: rest -> x :: strip rest
    | [] -> []
  in
  String.concat Filename.dir_sep
    (strip (String.split_on_char '/' (exe_dir ())))

(* Locate the directory holding the web assets (index.html + style.css +
   app.js), independently of the current working directory.

   We prefer [asset_dir/web] so that, in dev, the {b live source} tree is used
   (assets added there are picked up without a rebuild). [asset_dir] maps a
   [_build/<context>/...] path back to the source; when run from an installed
   location or a bundle it equals [exe_dir], so [asset_dir/web] is then the
   directory next to the binary. [exe_dir/web] is only a fallback (e.g. a build
   tree copied elsewhere, where no [_build] segment remains yet the assets sit
   beside the binary). *)
let web_dir () =
  let has_index dir = Sys.file_exists (Filename.concat dir "index.html") in
  let source = Filename.concat (asset_dir ()) "web" in
  if has_index source then source else Filename.concat (exe_dir ()) "web"
