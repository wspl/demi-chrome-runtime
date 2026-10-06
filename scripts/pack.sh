#!/bin/bash
# Packs entries of a directory into a .tar.zst the same way every time:
# sorted, with fixed times and owners, compressed with zstd -19.
#
# Usage: pack.sh <dir> <archive> <entry>...
set -euo pipefail

dir=$1
archive=$2
shift 2
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -C "$dir" -cf - "$@" \
  | zstd -19 -T0 -q -f -o "$archive"
