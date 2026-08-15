#!/bin/sh
set -eu

LC_ALL=C
export LC_ALL

version=${1:-}
case "$version" in
  ''|*[!A-Za-z0-9._+~-]*)
    echo "usage: $0 VERSION" >&2
    echo "example: $0 0.1.0~rc1" >&2
    exit 2
    ;;
esac

root=$(git rev-parse --show-toplevel)
cd "$root"

if [ "${OWEBVIEW_REQUIRE_CLEAN:-0}" = 1 ] && [ -n "$(git status --porcelain)" ]; then
  echo "refusing to package a dirty worktree (OWEBVIEW_REQUIRE_CLEAN=1)" >&2
  exit 1
fi

base=_build/local-release
name=owebview-$version
out=$base/$name
case "$out" in
  _build/local-release/owebview-*) ;;
  *) echo "invalid release output path" >&2; exit 1 ;;
esac

if [ -e "$out" ]; then
  rm -rf "$out"
fi
mkdir -p "$out"

stage=$(mktemp -d "$root/$base/.stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
source_root=$stage/$name
mkdir -p "$source_root"

git ls-files --cached --others --exclude-standard | LC_ALL=C sort |
while IFS= read -r path; do
  case "$path" in
    _build/*|.git/*) continue ;;
  esac
  # A tracked path may be intentionally deleted in a dirty local branch. The
  # candidate represents the working tree, not the index's stale pathname.
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    continue
  fi
  destination=$source_root/$path
  mkdir -p "$(dirname "$destination")"
  cp -pP "$path" "$destination"
done

# Normalize source mtimes and archive ownership. The sorted file list avoids
# filesystem traversal order affecting the archive.
find "$source_root" -exec touch -h -t 200001010000 {} +
file_list=$stage/files.txt
(cd "$stage" && find "$name" \( -type f -o -type l \) -print | LC_ALL=C sort) > "$file_list"

archive=$out/$name.tar.gz
COPYFILE_DISABLE=1
export COPYFILE_DISABLE
uncompressed=$stage/$name.tar
(cd "$stage" && tar -cf "$uncompressed" --uid 0 --gid 0 \
  --uname root --gname root -T "$file_list")
# -n omits the gzip filename and timestamp header, making repeated packaging of
# identical source bytes produce the same archive checksum.
gzip -n -9 -c "$uncompressed" > "$archive"

checksum=$(shasum -a 256 "$archive" | awk '{ print $1 }')
printf '%s  %s\n' "$checksum" "$name.tar.gz" > "$archive.sha256"

opam_dir=$out/opam-repository/packages/owebview/owebview.$version
mkdir -p "$opam_dir"
cp owebview.opam "$opam_dir/opam"
cat >> "$opam_dir/opam" <<EOF
url {
  src: "file://$root/$archive"
  checksum: "sha256=$checksum"
}
EOF

dirty=no
if [ -n "$(git status --porcelain)" ]; then dirty=yes; fi
file_count=$(wc -l < "$file_list" | tr -d ' ')
cat > "$out/MANIFEST.txt" <<EOF
package=owebview
version=$version
commit=$(git rev-parse HEAD)
worktree_dirty=$dirty
source_files=$file_count
archive_sha256=$checksum
host=$(uname -s)-$(uname -m)
ocaml=$(ocamlc -version)
dune=$(dune --version)
opam=$(opam --version)
created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
publication=prohibited-local-candidate-only
EOF

opam lint "$opam_dir/opam"
echo "created local release candidate: $out"
