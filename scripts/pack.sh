#!/bin/bash
# Packs entries of a directory into an archive the same way every time:
# sorted, with fixed times and owners. A .tar.zst is compressed with zstd -19;
# a .tar holds files that are already compressed and stays as it is.
#
# Usage: pack.sh <dir> <archive> <entry>...
set -euo pipefail

dir=$1
archive=$2
shift 2
tar_files=(tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -C "$dir" -cf -)
case "$archive" in
  *.tar.zst) "${tar_files[@]}" "$@" | zstd -19 -T0 -q -f -o "$archive" ;;
  *.tar) "${tar_files[@]}" "$@" > "$archive" ;;
  *) echo "unknown archive type: $archive" >&2; exit 1 ;;
esac
