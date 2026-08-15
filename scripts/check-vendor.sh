#!/bin/sh
set -eu

root=$(git rev-parse --show-toplevel)
cd "$root"

header=vendor/webview.h

for marker in \
  'Copyright (c) 2017 Serge Zaitsev' \
  'Copyright (c) 2022 Steffen André Langnes' \
  '#define WEBVIEW_VERSION_MAJOR 0' \
  '#define WEBVIEW_VERSION_MINOR 12' \
  '#define WEBVIEW_VERSION_PATCH 0'
do
  if ! grep -Fq "$marker" "$header"; then
    echo "vendored webview marker missing: $marker" >&2
    exit 1
  fi
done

test -f LICENSE
test -f VENDORING.md
