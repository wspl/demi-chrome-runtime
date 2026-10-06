#!/bin/bash
# Checks the runtime on one Linux distribution: a fresh container of <image>
# gets Chrome and the runtime (both read only) and the probe, and runs
# run.sh as an ordinary user. Results land in <out dir>.
#
# Usage: host.sh <image> <runtime dir> <chrome dir> <probe> <out dir>
set -euo pipefail

image=$1
runtime=$(cd "$2" && pwd)
chrome=$(cd "$3" && pwd)
probe=$(cd "$(dirname "$4")" && pwd)/$(basename "$4")
out=$5
here=$(cd "$(dirname "$0")" && pwd)

mkdir -p "$out"
out=$(cd "$out" && pwd)
# The container's user writes the results.
chmod 777 "$out"

docker run --rm --user 1000:1000 \
  -v "$chrome:/opt/chrome:ro" -v "$runtime:/opt/runtime:ro" \
  -v "$here:/test:ro" -v "$here/../fonts/fonts.json:/fonts.json:ro" \
  -v "$probe:/probe:ro" -v "$out:/out" \
  "$image" bash /test/run.sh
