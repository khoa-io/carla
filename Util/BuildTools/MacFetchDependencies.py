#!/usr/bin/env python3

import argparse
import collections
import concurrent.futures
import gzip
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import sys
import urllib.request
import xml.etree.ElementTree as ET


def sha1_file(path):
    digest = hashlib.sha1()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def safe_destination(root, name):
    relative = PurePosixPath(name)
    if relative.is_absolute() or '..' in relative.parts or '\\' in name:
        raise ValueError('Unsafe manifest path: ' + name)
    destination = root.joinpath(*relative.parts).resolve()
    if root not in destination.parents:
        raise ValueError('Manifest path escapes engine root: ' + name)
    return destination


def verify_pack(path, pack):
    digest = hashlib.sha1()
    total = 0
    with gzip.open(path, 'rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
            total += len(chunk)
    if digest.hexdigest() != pack['Hash'] or total != int(pack['Size']):
        raise ValueError('Pack integrity check failed: ' + str(path))


def ensure_pack(cache, pack, base_url):
    path = cache / (pack['Hash'] + '.pack')
    if not path.exists():
        url = base_url.rstrip('/') + '/' + pack['RemotePath'].strip('/') + '/' + pack['Hash']
        if not url.startswith('https://'):
            raise ValueError('Dependency downloads require HTTPS: ' + url)
        partial = path.with_suffix('.part')
        try:
            with urllib.request.urlopen(url, timeout=60) as response, partial.open('wb') as target:
                shutil.copyfileobj(response, target, 1024 * 1024)
            verify_pack(partial, pack)
            partial.replace(path)
        finally:
            partial.unlink(missing_ok=True)
    else:
        verify_pack(path, pack)
    return path


def extract_pack(path, blobs, files_by_hash, root):
    installed = 0
    with gzip.open(path, 'rb') as source:
        position = 0
        for blob in sorted(blobs, key=lambda item: int(item['PackOffset'])):
            offset = int(blob['PackOffset'])
            if offset < position:
                raise ValueError('Overlapping dependency blobs in ' + str(path))
            while position < offset:
                chunk = source.read(min(1024 * 1024, offset - position))
                if not chunk:
                    raise ValueError('Truncated pack: ' + str(path))
                position += len(chunk)
            targets = files_by_hash[blob['Hash']]
            first = safe_destination(root, targets[0]['Name'])
            first.parent.mkdir(parents=True, exist_ok=True)
            partial = first.with_name(first.name + '.gitdeps-part')
            digest = hashlib.sha1()
            remaining = int(blob['Size'])
            try:
                with partial.open('wb') as target:
                    while remaining:
                        chunk = source.read(min(1024 * 1024, remaining))
                        if not chunk:
                            raise ValueError('Truncated blob: ' + blob['Hash'])
                        target.write(chunk)
                        digest.update(chunk)
                        remaining -= len(chunk)
                        position += len(chunk)
                if digest.hexdigest() != blob['Hash']:
                    raise ValueError('Blob integrity check failed: ' + blob['Hash'])
                for entry in targets[1:]:
                    destination = safe_destination(root, entry['Name'])
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    duplicate = destination.with_name(destination.name + '.gitdeps-part')
                    try:
                        shutil.copyfile(partial, duplicate)
                        duplicate.chmod(0o755 if entry.get('IsExecutable', '').lower() == 'true' else 0o644)
                        duplicate.replace(destination)
                    finally:
                        duplicate.unlink(missing_ok=True)
                partial.chmod(0o755 if targets[0].get('IsExecutable', '').lower() == 'true' else 0o644)
                partial.replace(first)
                installed += len(targets)
            finally:
                partial.unlink(missing_ok=True)
    return installed


def fetch(engine, manifest, cache, prefixes=(), excludes=(), suffixes=(), dry_run=False,
          max_download_gb=16, max_output_gb=64, force=False, jobs=4):
    engine = Path(engine).resolve()
    tree = ET.parse(manifest).getroot()
    base_url = tree.get('BaseUrl', 'https://cdn.unrealengine.com/dependencies').replace('http://', 'https://', 1)
    all_blobs = {entry.attrib['Hash']: entry.attrib for entry in tree.findall('./Blobs/Blob')}
    all_packs = {entry.attrib['Hash']: entry.attrib for entry in tree.findall('./Packs/Pack')}
    files_by_hash = collections.defaultdict(list)
    selected = []
    excluded = {component.casefold() for component in excludes}
    for node in tree.findall('./Files/File'):
        entry = node.attrib
        name = entry['Name']
        if prefixes and not any(name.startswith(prefix) for prefix in prefixes):
            continue
        if excluded.intersection(component.casefold() for component in PurePosixPath(name).parts):
            continue
        if suffixes and not any(name.endswith(suffix) for suffix in suffixes):
            continue
        destination = safe_destination(engine, name)
        blob = all_blobs[entry['Hash']]
        selected.append((entry, blob))
        if destination.is_file() and sha1_file(destination) == entry['Hash']:
            continue
        if destination.exists() and not force:
            raise ValueError('Existing dependency differs from manifest; review it before using --force: ' + str(destination))
        files_by_hash[entry['Hash']].append(entry)
    grouped = collections.defaultdict(list)
    for blob_hash in files_by_hash:
        blob = all_blobs[blob_hash]
        grouped[blob['PackHash']].append(blob)
    cache = Path(cache).resolve()
    download_bytes = sum(int(all_packs[pack_hash]['CompressedSize']) for pack_hash in grouped
                         if not (cache / (pack_hash + '.pack')).exists())
    output_bytes = sum(int(blob['Size']) for entry, blob in selected)
    summary = dict(selected_files=len(selected), pending_files=sum(map(len, files_by_hash.values())),
                   packs=len(grouped), download_bytes=download_bytes, selected_output_bytes=output_bytes)
    print(json.dumps(summary, sort_keys=True), flush=True)
    if dry_run:
        return summary
    if download_bytes > max_download_gb * 1024 ** 3 or output_bytes > max_output_gb * 1024 ** 3:
        raise ValueError('Dependency selection exceeds download/output budget; narrow prefixes or set explicit limits')
    if shutil.disk_usage(engine).free < download_bytes + output_bytes + 2 * 1024 ** 3:
        raise ValueError('Insufficient disk space for selected dependencies and download cache')
    cache.mkdir(parents=True, exist_ok=True)
    if jobs < 1:
        raise ValueError('jobs must be positive')
    def process_pack(item):
        pack_hash, blobs = item
        pack = all_packs[pack_hash]
        print('Fetching pack ' + pack_hash + ' (' + str(len(blobs)) + ' blobs)', flush=True)
        path = ensure_pack(cache, pack, base_url)
        return extract_pack(path, blobs, files_by_hash, engine)
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as executor:
        installed = sum(executor.map(process_pack, grouped.items()))
    summary['installed_files'] = installed
    print(json.dumps(summary, sort_keys=True), flush=True)
    return summary


def main():
    parser = argparse.ArgumentParser(description='Fetch pinned Unreal GitDependencies without Intel Mono')
    parser.add_argument('--engine', required=True, type=Path)
    parser.add_argument('--manifest', type=Path)
    parser.add_argument('--cache', type=Path)
    parser.add_argument('--prefix', action='append', default=[])
    parser.add_argument('--exclude-component', action='append', default=[])
    parser.add_argument('--suffix', action='append', default=[])
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--max-download-gb', type=float, default=16)
    parser.add_argument('--max-output-gb', type=float, default=64)
    parser.add_argument('--force', action='store_true')
    parser.add_argument('--jobs', type=int, default=4)
    args = parser.parse_args()
    manifest = args.manifest or args.engine / 'Engine/Build/Commit.gitdeps.xml'
    cache = args.cache or args.engine.parent / 'gitdeps/packs'
    try:
        fetch(args.engine, manifest, cache, args.prefix, args.exclude_component, args.suffix,
              args.dry_run, args.max_download_gb, args.max_output_gb, args.force, args.jobs)
    except (OSError, ValueError, ET.ParseError, KeyError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
