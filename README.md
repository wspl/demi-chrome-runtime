# Demi Chrome runtime

The shared libraries and fonts that run
[Chrome for Testing](https://developer.chrome.com/docs/automation-and-testing/chrome-for-testing)
on any Linux with glibc 2.28 or newer, x86_64 or aarch64, without installing
anything into the system. [Demi](https://github.com/wspl/demi)'s
`demi browser install` downloads a release of it beside Chrome and starts
Chrome with it.

The design, what goes in and how Chrome finds it, is Demi's:
[Browser distribution](https://github.com/wspl/demi/blob/feat/demi-next/docs/browser/browser.md#browser-distribution)
and [Chrome runtime](https://github.com/wspl/demi/blob/feat/demi-next/docs/delivery/builds-and-releases.md#chrome-runtime).

## A release

| Asset | Content |
| --- | --- |
| `libs-x86_64.tar.zst`, `libs-aarch64.tar.zst` | `lib/`: the shared objects Chrome needs beyond glibc and `libgcc_s`, from AlmaLinux 8 |
| `fonts.tar.zst` | `fonts/`: the Noto family and Liberation; `fontconfig/fonts.conf` |
| `licenses.tar.zst` | Each package's license texts, and a `MANIFEST` naming every file with its package and version |
| `sources.tar` | The source packages of every library and font in the release |
| `SHA256SUMS` | The digest of every other asset |

Releases are numbered `1`, `2`, …, and change only when a Chrome version
needs a library the runtime lacks, or a package gets a fix.

## Using it without Demi

Unpack the libraries and fonts into one directory, then start Chrome with
these variables set for Chrome's process only. Set in a shell, the libraries
break the system's own programs.

```sh
LD_LIBRARY_PATH="$RUNTIME/lib" \
FONTCONFIG_FILE="$RUNTIME/fontconfig/fonts.conf" \
NSS_IGNORE_SYSTEM_POLICY=1 \
GIO_MODULE_DIR="$RUNTIME/lib/gio/modules" \
  chrome-linux64/chrome --headless --no-sandbox --disable-audio-output …
```

## Licenses

The scripts in this repository are MIT. Each library and font keeps its own
license, which `licenses.tar.zst` carries and `MANIFEST` names; the libraries
are LGPL, MPL, MIT, BSD and similar, the fonts SIL OFL 1.1. Every release
publishes the source packages it was built from.
