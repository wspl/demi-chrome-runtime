#!/bin/bash
# Assembles a release's assets from the build jobs' outputs: the libraries'
# and fonts' archives, licenses.tar.zst with every package's license texts
# and the MANIFEST, sources.tar with every source archive under sources/, and
# SHA256SUMS.
#
# Usage: assemble.sh <artifacts dir> <assets dir>
#   <artifacts dir> holds libs-x86_64/, libs-aarch64/ and fonts/, each with its
#   archive, MANIFEST, licenses/ and sources/.
set -euo pipefail

in=$1
out=$2
readonly parts=(libs-x86_64 libs-aarch64 fonts)

mkdir -p "$out" "$out.licenses/licenses"

# One license directory per package. Both architectures install the same
# package versions, so their license texts must agree.
for part in "${parts[@]}"; do
  cp "$in/$part/$part.tar.zst" "$out/"
  for dir in "$in/$part/licenses"/*/; do
    package=$(basename "$dir")
    if [[ -d "$out.licenses/licenses/$package" ]]; then
      diff -r "$dir" "$out.licenses/licenses/$package"
    else
      cp -R "$dir" "$out.licenses/licenses/$package"
    fi
  done
done

{
  printf 'archive\tfile\tpackage\tversion\n'
  for part in "${parts[@]}"; do
    awk -v archive="$part.tar.zst" '{ print archive "\t" $0 }' "$in/$part/MANIFEST"
  done
} > "$out.licenses/MANIFEST"
"$(dirname "$0")/pack.sh" "$out.licenses" "$out/licenses.tar.zst" MANIFEST licenses
rm -rf "$out.licenses"

# Source archives, once each; a name both architectures carry is the same file.
mkdir -p "$out.sources/sources"
for part in "${parts[@]}"; do
  for file in "$in/$part/sources"/*; do
    name=$(basename "$file")
    if [[ -f "$out.sources/sources/$name" ]]; then
      cmp "$file" "$out.sources/sources/$name"
    else
      cp "$file" "$out.sources/sources/"
    fi
  done
done
"$(dirname "$0")/pack.sh" "$out.sources" "$out/sources.tar" sources
rm -rf "$out.sources"

(cd "$out" && sha256sum -- * > SHA256SUMS)
