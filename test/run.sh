#!/bin/bash
# Runs inside a fresh container of a Linux distribution with nothing
# Chrome-related installed, as an ordinary user (see host.sh). Starts Chrome
# from /opt/chrome with the runtime at /opt/runtime, runs the probe against
# it, and fails if a check fails or if Chrome loaded any library from the
# Host beyond glibc and libgcc_s.
#
# Mounts: /opt/chrome, /opt/runtime, /test (this directory), /fonts.json,
# /probe (the compiled probe), /out (writable).
set -uo pipefail

readonly runtime=/opt/runtime
readonly out=/out
export HOME=/tmp/home
mkdir -p "$HOME" "$out/ld"

# The runtime's recipe, given to Chrome alone: exported to this shell,
# LD_LIBRARY_PATH would break the Host's own programs.
#   NSS_IGNORE_SYSTEM_POLICY: the EL8 NSS otherwise reads the Host's crypto
#     policy, which on Fedora loads the Host's p11-kit-proxy.so into Chrome.
#   GIO_MODULE_DIR: an empty directory, so GLib loads none of the Host's
#     GIO modules.
#   --disable-audio-output (below): no libpulse or ALSA plugins from the Host.
chrome_env=(
  env
  LD_LIBRARY_PATH="$runtime/lib"
  FONTCONFIG_FILE="$runtime/fontconfig/fonts.conf"
  NSS_IGNORE_SYSTEM_POLICY=1
  GIO_MODULE_DIR="$runtime/lib/gio/modules"
)

{
  . /etc/os-release
  echo "os: $PRETTY_NAME"
  echo "glibc: $(getconf GNU_LIBC_VERSION 2> /dev/null || echo unknown)"
  echo "kernel: $(uname -r) $(uname -m)"
} | tee "$out/host.txt"

# Demi's switches, plus remote debugging, the probe extension, and autoplay
# so the audio check can start without a click.
flags=(
  --headless --no-sandbox --disable-audio-output
  --disable-background-networking --disable-background-timer-throttling
  --disable-backgrounding-occluded-windows --disable-breakpad
  --disable-client-side-phishing-detection
  --disable-component-extensions-with-background-pages --disable-default-apps
  --disable-dev-shm-usage --disable-hang-monitor --disable-ipc-flooding-protection
  --disable-popup-blocking --disable-prompt-on-repost --disable-renderer-backgrounding
  --disable-sync --metrics-recording-only --no-first-run --use-mock-keychain
  --mute-audio
  --enable-features=NetworkService,NetworkServiceInProcess
  --disable-features=TranslateUI,InitialWebUI,WebUIToolbarProcessOverheadExperiment,PreloadTopChromeWebUI,WebUIOmniboxPopup,WebUIOmniboxAimPopup,ExtensionDisableUnsupportedDeveloper
  --force-color-profile=srgb --password-store=basic
  --disable-blink-features=AutomationControlled
  --user-data-dir="$HOME/profile" --remote-debugging-port=9222
  --autoplay-policy=no-user-gesture-required --load-extension=/test/ext
)

"${chrome_env[@]}" LD_DEBUG=libs LD_DEBUG_OUTPUT="$out/ld/run" /opt/chrome/chrome "${flags[@]}" \
  about:blank > "$out/chrome.log" 2>&1 &
pid=$!
/probe 9222 /fonts.json file:///test/page.html "$out"
status=$?
for _ in $(seq 100); do
  if ! kill -0 "$pid" 2> /dev/null; then
    break
  fi
  sleep 0.1
done
kill "$pid" 2> /dev/null

# Every object the loader initialized, and those that came from the Host.
readonly host_only='/(ld-linux[^/]*|ld64\.so\.[0-9]+|libc|libm|libdl|libpthread|librt|libresolv|libutil|libanl|libmvec|libnss_[a-z0-9_]+|libgcc_s)\.so(\.[0-9.]+)?$'
grep -h "calling init:" "$out"/ld/run.* | awk '{print $NF}' | sort -u > "$out/loaded.txt"
grep -v "^$runtime/\|^/opt/chrome/" "$out/loaded.txt" > "$out/loaded-from-host.txt"
rm -rf "$out/ld"
if grep -vE "$host_only" "$out/loaded-from-host.txt" > "$out/unexpected.txt"; then
  echo "FAILED: Chrome loaded from the Host: $(tr '\n' ' ' < "$out/unexpected.txt")"
  status=1
fi
echo "loaded from the Host: $(tr '\n' ' ' < "$out/loaded-from-host.txt")"
exit "$status"
