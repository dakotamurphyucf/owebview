#!/bin/sh
set -eu

LC_ALL=C
export LC_ALL

destination=${1:-}
if [ -z "$destination" ]; then
  echo "usage: $0 ABSOLUTE_DESTINATION_OUTSIDE_REPOSITORY" >&2
  exit 2
fi

root=$(git rev-parse --show-toplevel)
case "$destination" in
  /*) ;;
  *) echo "backup destination must be an absolute path" >&2; exit 2 ;;
esac

mkdir -p "$destination"
resolved=$(realpath "$destination")
case "$resolved/" in
  "$root"/*)
    echo "backup destination must be outside the repository" >&2
    exit 1
    ;;
esac

stamp=$(date -u +%Y%m%dT%H%M%SZ)
prefix=$resolved/owebview-$stamp

git -C "$root" bundle create "$prefix.bundle" --all

untracked_list=$(mktemp "${TMPDIR:-/tmp}/owebview-untracked.XXXXXX")
trap 'rm -f "$untracked_list"' EXIT HUP INT TERM
git -C "$root" ls-files --others --exclude-standard -z > "$untracked_list"
if [ -s "$untracked_list" ]; then
  COPYFILE_DISABLE=1
  export COPYFILE_DISABLE
  (cd "$root" && tar -czf "$prefix-untracked.tar.gz" --null -T "$untracked_list")
fi

shasum -a 256 "$prefix.bundle" > "$prefix.bundle.sha256"
if [ -f "$prefix-untracked.tar.gz" ]; then
  shasum -a 256 "$prefix-untracked.tar.gz" > "$prefix-untracked.tar.gz.sha256"
fi

echo "created local backup set: $prefix.*"
