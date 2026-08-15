#!/bin/sh
set -eu

root=$(git rev-parse --show-toplevel)
cd "$root"

stage=$(mktemp -d "${TMPDIR:-/tmp}/owebview-install.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM

dune build --profile release @install
dune install --profile release --prefix /usr/local --destdir "$stage" owebview

if ! find "$stage" -path '*/owebview/META' -print -quit | grep -q .; then
  echo "staged package does not contain owebview/META" >&2
  exit 1
fi

if ! find "$stage" -name 'owebview_protocol.cmi' -print -quit | grep -q .; then
  echo "staged package does not contain the protocol interface" >&2
  exit 1
fi
