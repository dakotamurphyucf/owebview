(lang dune 3.0)

(generate_opam_files true)

(name owebview)
(source
 (github dakotamurphyucf/owebview-runtime))
(license MIT)
(authors "Frédéric Lang" "Dakota Murphy")
(maintainers "Dakota Murphy <dakotamurphyucf@gmail.com>")

(package
 (name owebview)
 (synopsis "OCaml 5 and Eio desktop application runtime")
 (description
  "An opinionated OCaml 5 desktop application runtime built on the system WebView. It provides managed native handles, an Eio lifecycle, a shared native/js_of_ocaml protocol, typed RPC, bounded realtime streams, secure application assets, multiple windows, and durable shared sessions.\n\nOn macOS the native dependencies are provided by Cocoa/WebKit. Linux discovery prefers GTK4/WebKitGTK 6.0 and falls back to GTK3/WebKitGTK 4.1 or 4.0. Windows targets use the upstream WebView2 backend but remain unvalidated.")
 (depends
  (ocaml
   (>= 5.3))
  (eio
   (>= 1.3))
  (eio_main
   (>= 1.3))
  (cohttp-eio
   (>= 6.0))
  (magic-mime
   (>= 1.3))
  (uri
   (>= 4.4))
  (yojson
   (>= 3.0))
  (js_of_ocaml
   (>= 6.4))
  (dune-configurator
   (and
   (>= 3.0)
   :build))))
