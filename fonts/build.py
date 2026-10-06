#!/usr/bin/env python3
"""Builds the runtime's fonts from the upstream releases fonts.json pins.

Downloads each release (kept in --cache between runs), checks its size and
SHA-256, and writes into --out:

  fonts/                 the font files fonts.json names
  fontconfig/fonts.conf  fonts.conf.in with the generic families and the
                         language rules filled in from fonts.json
  licenses/<name>/       each release's license
  MANIFEST               fonts/<file> or fontconfig/fonts.conf, package, version
  sources/               the archives the fonts came from, and the upstream
                         source archives fonts.json names

Usage: build.py --out DIR --cache DIR --version RELEASE
"""

import argparse
import hashlib
import io
import json
import os
import shutil
import sys
import tarfile
import urllib.request
import zipfile
from xml.sax.saxutils import escape

HERE = os.path.dirname(os.path.abspath(__file__))


def download(entry, cache):
    """Returns the bytes of entry['url'] after checking its size and SHA-256."""
    path = os.path.join(cache, entry['sha256'])
    if not os.path.exists(path):
        with urllib.request.urlopen(entry['url']) as response, open(path + '.part', 'wb') as out:
            shutil.copyfileobj(response, out)
        os.replace(path + '.part', path)
    with open(path, 'rb') as file:
        data = file.read()
    digest = hashlib.sha256(data).hexdigest()
    if len(data) != entry['size'] or digest != entry['sha256']:
        os.remove(path)
        sys.exit(f"{entry['url']}: got {len(data)} bytes, SHA-256 {digest}; "
                 f"fonts.json pins {entry['size']} bytes, SHA-256 {entry['sha256']}")
    return data


def open_archive(url, data):
    """Returns a function reading one member of the archive, or None for a plain file."""
    if url.endswith('.zip'):
        archive = zipfile.ZipFile(io.BytesIO(data))
        return archive.read
    if url.endswith(('.tar.gz', '.tgz', '.tar.xz', '.tar.bz2')):
        archive = tarfile.open(fileobj=io.BytesIO(data))
        return lambda name: archive.extractfile(name).read()
    return None


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as file:
        file.write(data)


def fonts_conf(fonts):
    """fonts.conf.in with the generic family lists and language rules filled in."""
    families = [family for font in fonts for family in font['families']]
    generic = '\n'.join(
        f'      <family>{escape(family["name"])}</family>'
        for family in families if family['generic'])
    rules = []
    for family in families:
        for lang in family['langs']:
            for generic_family in ('sans-serif', 'serif'):
                rules.append(
                    '  <match target="pattern">\n'
                    f'    <test name="lang"><string>{escape(lang)}</string></test>\n'
                    f'    <test name="family"><string>{generic_family}</string></test>\n'
                    f'    <edit name="family" mode="prepend"><string>{escape(family["name"])}</string></edit>\n'
                    '  </match>')
    with open(os.path.join(HERE, 'fonts.conf.in')) as file:
        template = file.read()
    return template.replace('@GENERIC@', generic).replace('@LANGUAGES@', '\n'.join(rules))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', required=True)
    parser.add_argument('--cache', required=True)
    parser.add_argument('--version', required=True, help='the runtime release, for the MANIFEST')
    args = parser.parse_args()

    with open(os.path.join(HERE, 'fonts.json')) as file:
        fonts = json.load(file)['fonts']
    os.makedirs(args.cache, exist_ok=True)
    if os.path.exists(args.out):
        shutil.rmtree(args.out)

    manifest = []
    for font in fonts:
        data = download(font, args.cache)
        read = open_archive(font['url'], data)
        for member in font['files']:
            name = os.path.basename(member)
            path = os.path.join(args.out, 'fonts', name)
            if os.path.exists(path):
                sys.exit(f'two fonts are named {name}')
            write(path, read(member) if read else data)
            manifest.append(f"fonts/{name}\t{font['name']}\t{font['version']}")
        license = font['license']
        if isinstance(license, dict):
            license_name = os.path.basename(license['url'])
            license_data = download(license, args.cache)
        else:
            license_name = os.path.basename(license)
            license_data = read(license)
        write(os.path.join(args.out, 'licenses', font['name'], license_name), license_data)
        # The archive the fonts came from; a plain font file is already in fonts/.
        if read:
            write(os.path.join(args.out, 'sources', os.path.basename(font['url'])), data)
        if 'source' in font:
            write(os.path.join(args.out, 'sources', os.path.basename(font['source']['url'])),
                  download(font['source'], args.cache))

    write(os.path.join(args.out, 'fontconfig', 'fonts.conf'), fonts_conf(fonts).encode())
    manifest.append(f'fontconfig/fonts.conf\tdemi-chrome-runtime\t{args.version}')
    write(os.path.join(args.out, 'MANIFEST'), ('\n'.join(sorted(manifest)) + '\n').encode())


if __name__ == '__main__':
    main()
