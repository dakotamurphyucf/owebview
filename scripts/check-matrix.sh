#!/bin/sh
set -eu

root=$(git rev-parse --show-toplevel)
cd "$root"

list_cells() {
  cat <<'EOF'
macos-arm64-ocaml-5.3,cocoa,validated-locally
macos-arm64-ocaml-5.4,cocoa,prepared
macos-arm64-ocaml-5.5,cocoa,prepared
linux-ocaml-5.3-gtk4,webkitgtk-6.0,prepared
linux-ocaml-5.4-gtk4,webkitgtk-6.0,prepared
linux-ocaml-5.5-gtk4,webkitgtk-6.0,prepared
linux-ocaml-5.3-gtk3,webkit2gtk-4.1,prepared
linux-ocaml-5.4-gtk3,webkit2gtk-4.1,prepared
linux-ocaml-5.5-gtk3,webkit2gtk-4.1,prepared
windows-ocaml-5.x-webview2,webview2,target-only
EOF
}

current_cell() {
  system=$(uname -s)
  machine=$(uname -m)
  ocaml_minor=$(ocamlc -version | awk -F. '{ print $1 "." $2 }')
  case "$system:$machine" in
    Darwin:arm64) echo "macos-arm64-ocaml-$ocaml_minor" ;;
    Linux:*)
      backend=$(dune exec lib/config/discover.exe 2>&1 || true)
      case "$backend" in
        *webkitgtk-6.0*) suffix=gtk4 ;;
        *) suffix=gtk3 ;;
      esac
      echo "linux-ocaml-$ocaml_minor-$suffix"
      ;;
    MINGW*:*|MSYS*:*|CYGWIN*:*) echo "windows-ocaml-$ocaml_minor-webview2" ;;
    *) echo "unsupported-$system-$machine-ocaml-$ocaml_minor" ;;
  esac
}

run_current() {
  cell=$(current_cell)
  if ! list_cells | cut -d, -f1 | grep -Fxq "$cell"; then
    echo "current machine/switch is not a prepared matrix cell: $cell" >&2
    exit 1
  fi

  results=_build/validation
  mkdir -p "$results"
  log="$results/$cell.log"
  {
    echo "cell=$cell"
    echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "commit=$(git rev-parse HEAD)"
    echo "ocaml=$(ocamlc -version)"
    echo "dune=$(dune --version)"
    echo "opam=$(opam --version)"
    scripts/check-local.sh
    scripts/check-sanitizers.sh
    echo "result=passed"
  } 2>&1 | tee "$log"
}

case "${1:-}" in
  list) list_cells ;;
  identify) current_cell ;;
  current) run_current ;;
  cell)
    requested=${2:-}
    actual=$(current_cell)
    if [ -z "$requested" ] || [ "$requested" != "$actual" ]; then
      echo "requested cell '$requested' does not match current cell '$actual'" >&2
      exit 1
    fi
    run_current
    ;;
  *)
    echo "usage: $0 {list|identify|current|cell CELL}" >&2
    exit 2
    ;;
esac
