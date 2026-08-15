#!/bin/sh
set -eu

LC_ALL=C
export LC_ALL

version=${1:-}
case "$version" in
  ''|*[!A-Za-z0-9._+~-]*)
    echo "usage: $0 VERSION" >&2
    exit 2
    ;;
esac

root=$(git rev-parse --show-toplevel)
cd "$root"

ODOC_WARN_ERROR=true
export ODOC_WARN_ERROR

name=owebview-$version
candidate=_build/local-release/$name
archive=$candidate/$name.tar.gz
checksum_file=$archive.sha256
opam_file=$candidate/opam-repository/packages/owebview/owebview.$version/opam

test -f "$archive"
test -f "$checksum_file"
test -f "$opam_file"

expected=$(awk 'NR == 1 { print $1 }' "$checksum_file")
actual=$(shasum -a 256 "$archive" | awk '{ print $1 }')
if [ "$expected" != "$actual" ]; then
  echo "archive checksum mismatch" >&2
  exit 1
fi

stage=$(mktemp -d "${TMPDIR:-/tmp}/owebview-release-verify.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
tar -xzf "$archive" -C "$stage"
source_root=$stage/$name
test -f "$source_root/dune-project"
test -f "$source_root/COMPATIBILITY.md"
test -f "$source_root/SECURITY.md"
test -f "$source_root/LICENSE"
test -f "$source_root/vendor/webview.h"

cd "$source_root"
dune build @fmt
dune build @all @runtest @doc
if [ "${OWEBVIEW_SKIP_INTEGRATION:-0}" != 1 ]; then
  dune build @integration
fi
dune build --profile release @install @runtest @doc
opam lint owebview.opam
opam lint "$root/$opam_file"

install_stage=$stage/install
mkdir -p "$install_stage"
dune install --profile release --prefix /usr/local \
  --destdir "$install_stage" owebview
find "$install_stage" -path '*/owebview/META' -print -quit | grep -q .

echo "verified local release candidate: $candidate"
