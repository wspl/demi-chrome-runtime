#!/bin/bash
# Downloads and unpacks a Chrome for Testing version for one Linux
# architecture, and prints the directory that holds the chrome executable.
#
# Usage: chrome.sh <version> <x86_64|aarch64> <dir>
set -euo pipefail

version=$1
arch=$2
dir=$3

case "$arch" in
  x86_64) platform=linux64 ;;
  aarch64) platform=linux-arm64 ;;
  *) echo "unknown architecture $arch" >&2; exit 1 ;;
esac

mkdir -p "$dir"
curl -fsSL -o "$dir/chrome.zip" \
  "https://storage.googleapis.com/chrome-for-testing-public/$version/$platform/chrome-$platform.zip"
unzip -q -o "$dir/chrome.zip" -d "$dir"
rm "$dir/chrome.zip"
echo "$dir/chrome-$platform"
