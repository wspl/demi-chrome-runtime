#!/bin/bash
# Collects the shared libraries Chrome for Testing needs beyond glibc, inside a
# container of the base distribution (AlmaLinux 8, whose glibc 2.28 is the
# oldest the runtime runs on).
#
# It installs the packages Chrome links and loads, copies the ldd closure of
# Chrome's executable and of the NSS modules into /out/lib under their sonames,
# leaving out glibc, the loader, glibc's libnss_* modules and libgcc_s, which
# every Host has. It fails if any object needs a glibc newer than 2.28.
#
# Inputs:  /chrome  the unpacked Chrome for Testing archive (read only)
# Outputs: /out/lib/            the objects, the NSS modules, empty gio/modules
#          /out/MANIFEST        lib/<file>, package, version (tab separated)
#          /out/licenses/<package>/  each package's license texts
#          /out/sources/        the source RPM of every package
#          /out/BASE            the distribution and architecture
set -euo pipefail

readonly GLIBC_MAX=GLIBC_2.28

# The libraries glibc itself provides, and libgcc_s, which glibc loads itself:
# these always come from the Host.
readonly HOST_ONLY='^(ld-linux[^/]*|ld64\.so\.[0-9]+|libc|libm|libdl|libpthread|librt|libresolv|libutil|libanl|libBrokenLocale|libmvec|libnss_[a-z0-9_]+|libthread_db|libc_malloc_debug|libgcc_s)\.so(\.[0-9.]+)?$'

# Chrome's NEEDED libraries and the NSS modules it loads at run time.
readonly PACKAGES=(
  alsa-lib at-spi2-atk atk at-spi2-core cairo cups-libs dbus-libs expat
  mesa-libgbm glib2 nspr nss nss-util nss-softokn nss-softokn-freebl pango
  systemd-libs libX11 libxcb libXcomposite libXdamage libXext libXfixes
  libxkbcommon libXrandr
)

# The NSS modules: NSS opens softokn and freebl by path beside libnss3, and
# Chrome opens libnssckbi.so by name.
readonly NSS_MODULES=(libsoftokn3.so libfreeblpriv3.so libfreebl3.so libnssckbi.so libnssdbm3.so)

# License files in a source archive, for packages whose binary RPMs carry none.
readonly SOURCE_NOTICE='^[^/]+/((COPYING|LICENSE|LICENCE|COPYRIGHT)[^/]*|docs/license\.rst|copyright\.html)$'
# Source packages with no license file at all, by the header that states it.
declare -A NOTICE_HEADERS=([libdrm]='xf86drm\.h')

dnf upgrade -y -q > /dev/null
dnf install -y -q --setopt=install_weak_deps=False \
  "${PACKAGES[@]}" binutils bzip2 cpio unzip dnf-plugins-core > /dev/null

owner() {
  rpm -qf --qf '%{NAME}\n' "$1" | head -1
}

version() {
  rpm -q --qf '%{VERSION}-%{RELEASE}' "$1"
}

source_rpm() {
  rpm -q --qf '%{SOURCERPM}' "$1"
}

# A package's %license files, and for packages that predate %license, its
# COPYING-like documents.
notices() {
  local file
  while IFS= read -r file; do
    if [[ "$file" == /* && -f "$file" ]]; then
      echo "$file"
    fi
  done < <(
    rpm -q --licensefiles "$1"
    rpm -qd "$1" | grep -iE '/(copying|license|licence|copyright|lgpl|gpl|notice)[^/]*$'
  ) | sort -u
}

nss_paths=()
for name in "${NSS_MODULES[@]}"; do
  nss_paths+=("/usr/lib64/$name")
done

# The closure, by soname.
declare -A closure=()
for root in /chrome/chrome "${nss_paths[@]}"; do
  while read -r name path; do
    if [[ "$name" =~ $HOST_ONLY ]]; then
      continue
    fi
    if [[ "$path" == "not" ]]; then
      echo "unresolved: $name (needed by $root)" >&2
      exit 1
    fi
    closure[$name]=$path
  done < <(ldd "$root" | awk '$2 == "=>" { print $1, $3 }')
done

mkdir -p /out/lib/gio/modules /out/licenses /out/sources
: > /out/MANIFEST
declare -A packages=()

# Records a copied file in the manifest under the package that owns $2.
record() {
  local file=$1
  local package
  package=$(owner "$(readlink -f "$2")")
  packages[$package]=1
  printf '%s\t%s\t%s\n' "$file" "$package" "$(version "$package")" >> /out/MANIFEST
}

for name in "${!closure[@]}"; do
  cp -L "${closure[$name]}" "/out/lib/$name"
  record "lib/$name" "${closure[$name]}"
done
for path in "${nss_paths[@]}"; do
  name=$(basename "$path")
  cp -L "$path" "/out/lib/$name"
  record "lib/$name" "$path"
  # freebl and softokn check themselves against these signatures.
  if [[ -e "${path%.so}.chk" ]]; then
    cp -L "${path%.so}.chk" /out/lib/
    record "lib/$(basename "${path%.so}.chk")" "${path%.so}.chk"
  fi
done
sort -o /out/MANIFEST /out/MANIFEST

# Every object must run on glibc 2.28 and use no glibc-private symbols.
newest=$(objdump -T /out/lib/*.so* | grep -o 'GLIBC_[0-9][0-9.]*' | sort -uV | tail -1)
echo "newest glibc symbol version: $newest"
if [[ "$(printf '%s\n' "$GLIBC_MAX" "$newest" | sort -V | tail -1)" != "$GLIBC_MAX" ]]; then
  for file in /out/lib/*.so*; do
    if objdump -T "$file" | grep -q "$newest"; then
      echo "$(basename "$file") needs $newest, newer than $GLIBC_MAX" >&2
    fi
  done
  exit 1
fi
if objdump -T /out/lib/*.so* | grep -q GLIBC_PRIVATE; then
  echo "an object uses GLIBC_PRIVATE symbols" >&2
  exit 1
fi

# Container images install packages without their documentation, license
# texts included; install them again with it.
dnf reinstall -y -q --setopt=tsflags= "${!packages[@]}" > /dev/null

# The source RPM of every package.
nevras=()
for package in "${!packages[@]}"; do
  nevras+=("$(rpm -q "$package")")
done
dnf download -q --source --destdir /out/sources "${nevras[@]}"
for package in "${!packages[@]}"; do
  if [[ ! -f "/out/sources/$(source_rpm "$package")" ]]; then
    echo "no source RPM for $package: $(source_rpm "$package")" >&2
    exit 1
  fi
done

# Lists the members of archive $1, or with $2, writes that member to stdout.
archive() {
  case "$1" in
    *.zip)
      if [[ $# -eq 1 ]]; then unzip -Z1 "$1"; else unzip -p "$1" "$2"; fi
      ;;
    *.tar.bz2)
      if [[ $# -eq 1 ]]; then tar -I bzip2 -tf "$1"; else tar -I bzip2 -xOf "$1" "$2"; fi
      ;;
    *)
      if [[ $# -eq 1 ]]; then tar -tf "$1"; else tar -xOf "$1" "$2"; fi
      ;;
  esac
}

# Copies the license files in the upstream archives of source RPM $2 (those
# named after its source package, not tools bundled beside them) into $1's
# licenses. A project with no license file states it in a header comment.
source_notices() {
  local package=$1
  local srpm=$2
  local work name file member
  work=$(mktemp -d)
  name=$(rpm -qp --qf '%{NAME}' "$srpm")
  (cd "$work" && rpm2cpio "$srpm" | cpio -idm --quiet)
  for file in "$work/$name"-*.tar.* "$work/$name"-*.zip; do
    if [[ ! -f "$file" ]]; then
      continue
    fi
    while IFS= read -r member; do
      archive "$file" "$member" > "/out/licenses/$package/$(basename "$member")"
    done < <(archive "$file" | grep -E "$SOURCE_NOTICE")
    if [[ -n "${NOTICE_HEADERS[$name]:-}" ]]; then
      member=$(archive "$file" | grep -E "^[^/]+/${NOTICE_HEADERS[$name]}\$")
      archive "$file" "$member" | awk '/Copyright/ { on = 1 } on && !done { print } on && /\*\// { done = 1 }' \
        > "/out/licenses/$package/$(basename "$member").notice"
    fi
  done
  rm -rf "$work"
}

# License texts: the package's own; else those of another installed package
# built from the same source RPM; else those in the source archives.
for package in "${!packages[@]}"; do
  mkdir -p "/out/licenses/$package"
  files=$(notices "$package")
  if [[ -z "$files" ]]; then
    srpm=$(source_rpm "$package")
    for sibling in $(rpm -qa --qf '%{NAME} %{SOURCERPM}\n' | awk -v s="$srpm" '$2 == s { print $1 }'); do
      files=$(notices "$sibling")
      if [[ -n "$files" ]]; then
        echo "$package: license texts of $sibling, built from the same $srpm"
        break
      fi
    done
  fi
  if [[ -n "$files" ]]; then
    while IFS= read -r file; do
      cp "$file" "/out/licenses/$package/"
    done <<< "$files"
  else
    echo "$package: license texts from the sources in $(source_rpm "$package")"
    source_notices "$package" "/out/sources/$(source_rpm "$package")"
  fi
  if [[ -z "$(ls -A "/out/licenses/$package")" ]]; then
    echo "no license text for $package" >&2
    exit 1
  fi
done

. /etc/os-release
echo "$PRETTY_NAME $(uname -m)" > /out/BASE
echo "$(find /out/lib -type f | wc -l) files, $(du -sh /out/lib | cut -f1), from $(cat /out/BASE)"
