module C = Configurator.V1

(* C++ standard required to compile webview_stubs.cpp, on every platform. *)
let std_flags = [ "-std=c++17" ]

(* macOS: WebKit/Cocoa are system frameworks, no pkg-config needed. *)
let macos_link_flags =
  [ "-lc++"; "-lobjc"; "-framework"; "WebKit"; "-framework"; "Cocoa" ]

(* Linux: prefer GTK 4/WebKitGTK 6.0, with explicit GTK 3 fallbacks. *)
let linux_candidates =
  [
    ("gtk4-webkitgtk-6.0", [ "gtk4"; "webkitgtk-6.0" ], "OWV_WEBKITGTK_6_0");
    ( "gtk3-webkit2gtk-4.1",
      [ "gtk+-3.0"; "webkit2gtk-4.1" ],
      "OWV_WEBKITGTK_4_1" );
    ( "gtk3-webkit2gtk-4.0",
      [ "gtk+-3.0"; "webkit2gtk-4.0" ],
      "OWV_WEBKITGTK_4_0" );
  ]

(* Query pkg-config for each package and merge the results. Returns None if
   pkg-config is unavailable or any package is missing. *)
let query_packages pc packages =
  let results =
    List.map (fun package -> C.Pkg_config.query pc ~package) packages
  in
  if List.mem None results then None
  else
    let configurations =
      List.map
        (function Some configuration -> configuration | None -> assert false)
        results
    in
    Some
      ( List.concat
          (List.map
             (fun (configuration : C.Pkg_config.package_conf) ->
               configuration.cflags)
             configurations),
        List.concat
          (List.map
             (fun (configuration : C.Pkg_config.package_conf) ->
               configuration.libs)
             configurations) )

let linux_flags c =
  match C.Pkg_config.get c with
  | None -> None
  | Some pc ->
      List.find_map
        (fun (_name, packages, define) ->
          Option.map
            (fun (cflags, libraries) ->
              (("-D" ^ define ^ "=1") :: cflags, libraries))
            (query_packages pc packages))
        linux_candidates

let () =
  C.main ~name:"webview" (fun c ->
      let system =
        match C.ocaml_config_var c "system" with Some s -> s | None -> ""
      in
      let cflags, link_flags =
        match system with
        | "macosx" ->
            ( [ "-DOWV_BACKEND_COCOA=1"; "-fblocks" ] @ std_flags,
              macos_link_flags )
        | "win32" | "mingw" | "mingw64" | "cygwin" ->
            ( "-DOWV_BACKEND_WEBVIEW2=1" :: std_flags,
              [
                "-lstdc++";
                "-lole32";
                "-ladvapi32";
                "-lshell32";
                "-lshlwapi";
                "-lversion";
              ] )
        | "linux" -> (
            match linux_flags c with
            | Some (cflags, libs) -> (std_flags @ cflags, "-lstdc++" :: libs)
            | None ->
                C.die
                  "could not detect a supported Linux WebKit backend via \
                   pkg-config (tried gtk4/webkitgtk-6.0, \
                   gtk+-3.0/webkit2gtk-4.1, and gtk+-3.0/webkit2gtk-4.0)")
        | other -> C.die "unsupported operating-system target: %s" other
      in
      C.Flags.write_sexp "c_flags.sexp" cflags;
      C.Flags.write_sexp "c_library_flags.sexp" link_flags)
