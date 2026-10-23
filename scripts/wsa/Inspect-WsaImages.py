#!/usr/bin/env python3
"""Read-only inspection of clean, non-differencing VHDX/ext4 WSA images.

Uses the documented VHDX BAT and ext4 extent/directory structures. Does not
mount, boot, install, modify an image, or create a raw virtual disk copy.
Unsupported structures fail explicitly. Targeted extracted files go to an
ignored local analysis directory; the report contains metadata and summaries.
"""
from __future__ import annotations

import argparse
from collections import Counter
from functools import lru_cache
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import struct
import sys
import uuid
from datetime import datetime, timezone


def u16(data, offset): return struct.unpack_from('<H', data, offset)[0]
def u32(data, offset): return struct.unpack_from('<I', data, offset)[0]
def u64(data, offset): return struct.unpack_from('<Q', data, offset)[0]


def crc32c(data):
    crc = 0xffffffff
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ (0x82f63b78 if crc & 1 else 0)
    return crc ^ 0xffffffff


def valid_crc(data, checksum_offset=4):
    expected = u32(data, checksum_offset)
    cleared = data[:checksum_offset] + b'\0' * 4 + data[checksum_offset + 4:]
    return expected == crc32c(cleared)


class Vhdx:
    BAT = '2dc27766-f623-4200-9d64-115e9bfd4a08'
    META = '8b7ca206-4790-4b9a-b8fe-575f050f886e'
    PARAMETERS = 'caa16737-fa36-4d43-b3b6-33f0aa44e76b'
    SIZE = '2fa54224-cd1b-4876-b211-5dbed83bf4b8'
    SECTOR = '8141bf1d-a96f-4709-ba47-f233a8faab5f'

    def __init__(self, path):
        self.path = Path(path)
        self.file = self.path.open('rb')
        self.file_size = self.path.stat().st_size
        if self.physical(0, 8) != b'vhdxfile':
            raise ValueError('Not a VHDX file')
        headers = [self.physical(offset, 4096) for offset in (65536, 131072)]
        headers = [h for h in headers if h[:4] == b'head' and valid_crc(h)]
        if not headers:
            raise ValueError('No valid VHDX header checksum')
        self.header = max(headers, key=lambda h: u64(h, 8))
        if u16(self.header, 66) != 1:
            raise ValueError('Unsupported VHDX version')
        if self.header[48:64] != b'\0' * 16:
            raise ValueError('VHDX has a nonempty log GUID; replay would require a separate supported reader')
        regions = None
        for offset in (196608, 262144):
            table = self.physical(offset, 65536)
            if table[:4] == b'regi' and valid_crc(table):
                count = u32(table, 8)
                if count > 2047:
                    raise ValueError('Invalid VHDX region count')
                regions = {}
                for i in range(count):
                    entry = table[16 + 32*i:48 + 32*i]
                    guid = str(uuid.UUID(bytes_le=entry[:16]))
                    regions[guid] = (u64(entry, 16), u32(entry, 24))
                break
        if regions is None:
            raise ValueError('No valid VHDX region table checksum')
        metadata_offset, metadata_length = regions[self.META]
        metadata = self.physical(metadata_offset, min(metadata_length, 65536))
        if metadata[:8] != b'metadata':
            raise ValueError('VHDX metadata signature is invalid')
        items = {}
        for i in range(u16(metadata, 10)):
            entry = metadata[32 + 32*i:64 + 32*i]
            guid = str(uuid.UUID(bytes_le=entry[:16]))
            offset, length = u32(entry, 16), u32(entry, 20)
            if offset + length > metadata_length:
                raise ValueError('Metadata item outside its region')
            items[guid] = self.physical(metadata_offset + offset, length)
        self.block_size, flags = struct.unpack('<II', items[self.PARAMETERS])
        if flags & 2:
            raise ValueError('Differencing VHDX is unsupported; source was not modified')
        self.size = u64(items[self.SIZE], 0)
        self.sector_size = u32(items[self.SECTOR], 0)
        if self.sector_size not in (512, 4096) or self.block_size < 1048576 or self.block_size & (self.block_size - 1):
            raise ValueError('Invalid VHDX block/sector geometry')
        self.chunk_ratio = ((1 << 23) * self.sector_size) // self.block_size
        bat_offset, bat_length = regions[self.BAT]
        self.bat = self.physical(bat_offset, bat_length)

    def physical(self, offset, length):
        if offset < 0 or length < 0 or offset + length > self.file_size:
            raise ValueError('VHDX physical read outside source file')
        self.file.seek(offset)
        data = self.file.read(length)
        if len(data) != length:
            raise ValueError('Short VHDX read')
        return data

    def read(self, offset, length):
        if offset < 0 or length < 0 or offset + length > self.size:
            raise ValueError('Virtual disk read outside bounds')
        pieces = []
        while length:
            block, within = divmod(offset, self.block_size)
            bat_index = block + block // self.chunk_ratio
            entry = u64(self.bat, bat_index * 8)
            state = entry & 7
            take = min(length, self.block_size - within)
            if state == 6:
                pieces.append(self.physical((entry & 0xfffffffffff00000) + within, take))
            elif state in (0, 1, 2, 3):
                pieces.append(b'\0' * take)
            else:
                raise ValueError(f'Unsupported BAT state {state}')
            offset += take
            length -= take
        return b''.join(pieces)

    def close(self):
        self.file.close()


class Ext4:
    def __init__(self, disk):
        self.disk = disk
        self.offset = self.find_offset()
        self.super = disk.read(self.offset + 1024, 1024)
        self.block_size = 1024 << u32(self.super, 24)
        self.inodes_per_group = u32(self.super, 40)
        self.inode_size = u16(self.super, 88) or 128
        self.incompat = u32(self.super, 96)
        if self.incompat & 0x10:
            raise ValueError('ext4 META_BG descriptor layout is unsupported')
        self.desc_size = max(32, u16(self.super, 254)) if self.incompat & 0x80 else 32
        self.desc_offset = (u32(self.super, 20) + 1) * self.block_size
        self.label = self.super[120:136].split(b'\0', 1)[0].decode('utf-8', 'replace')
        self.uuid = str(uuid.UUID(bytes=self.super[104:120]))
        self.inode_count = u32(self.super, 0)
        if self.block_size not in (1024, 2048, 4096, 8192, 16384, 32768, 65536) or self.inode_size < 128 or not self.inodes_per_group:
            raise ValueError('Invalid ext4 geometry')

    def find_offset(self):
        if u16(self.disk.read(1024, 1024), 56) == 0xef53:
            return 0
        mbr = self.disk.read(0, 512)
        candidates = []
        if mbr[510:512] == b'\x55\xaa':
            for i in range(4):
                entry = mbr[446 + 16*i:462 + 16*i]
                if entry[4] and entry[4] != 0xee:
                    candidates.append(u32(entry, 8) * self.disk.sector_size)
        gpt = self.disk.read(self.disk.sector_size, self.disk.sector_size)
        if gpt[:8] == b'EFI PART':
            start, count, stride = u64(gpt, 72), u32(gpt, 80), u32(gpt, 84)
            if count > 4096 or stride < 128 or stride > 4096:
                raise ValueError('Invalid GPT partition entry table')
            for i in range(count):
                entry = self.disk.read(start*self.disk.sector_size + i*stride, stride)
                if entry[:16] != b'\0'*16:
                    candidates.append(u64(entry, 32)*self.disk.sector_size)
        matches = [offset for offset in candidates if offset + 2048 <= self.disk.size and u16(self.disk.read(offset + 1024, 1024), 56) == 0xef53]
        if len(matches) != 1:
            raise ValueError(f'Expected one ext4 partition, found {len(matches)}')
        return matches[0]

    @lru_cache(maxsize=4096)
    def block(self, index):
        return self.disk.read(self.offset + index*self.block_size, self.block_size)

    @lru_cache(maxsize=32768)
    def inode(self, number):
        if not 1 <= number <= self.inode_count:
            raise ValueError(f'Invalid inode {number}')
        group, index = divmod(number - 1, self.inodes_per_group)
        descriptor = self.disk.read(self.offset + self.desc_offset + group*self.desc_size, self.desc_size)
        table = u32(descriptor, 8)
        if self.desc_size >= 64:
            table |= u32(descriptor, 40) << 32
        data = self.disk.read(self.offset + table*self.block_size + index*self.inode_size, self.inode_size)
        return {'number': number, 'mode': u16(data, 0), 'size': u32(data, 4) | (u32(data, 108) << 32),
                'flags': u32(data, 32), 'blocks512': u32(data, 28), 'mapping': data[40:100]}

    def extents(self, tree, expected_depth=None):
        if u16(tree, 0) != 0xf30a:
            raise ValueError('Bad ext4 extent header')
        entries, maximum, depth = u16(tree, 2), u16(tree, 4), u16(tree, 6)
        if depth > 5 or entries > maximum or 12 + entries*12 > len(tree) or (expected_depth is not None and depth != expected_depth):
            raise ValueError('Invalid ext4 extent tree bounds/depth')
        for i in range(entries):
            entry = tree[12 + i*12:24 + i*12]
            logical = u32(entry, 0)
            if depth:
                child = u32(entry, 4) | (u16(entry, 8) << 32)
                yield from self.extents(self.block(child), depth - 1)
            else:
                raw_length = u16(entry, 4)
                length = raw_length - 32768 if raw_length > 32768 else raw_length
                physical = u32(entry, 8) | (u16(entry, 6) << 32)
                yield logical, length, physical, raw_length > 32768

    def legacy_blocks(self, mapping, count):
        def indirect(index, depth):
            if not index:
                yield from [0] * ((self.block_size//4)**depth)
                return
            pointers = struct.unpack('<' + 'I'*(self.block_size//4), self.block(index))
            for pointer in pointers:
                if depth == 1: yield pointer
                else: yield from indirect(pointer, depth - 1)
        emitted = 0
        pointers = struct.unpack('<15I', mapping)
        for pointer in pointers[:12]:
            if emitted >= count: return
            yield pointer
            emitted += 1
        for depth, pointer in enumerate(pointers[12:], 1):
            for block in indirect(pointer, depth):
                if emitted >= count: return
                yield block
                emitted += 1

    def contents(self, inode, max_size=8*1024*1024):
        size = inode['size']
        if size > max_size:
            raise ValueError(f'Inode {inode["number"]} exceeds read limit ({size})')
        if inode['flags'] & 0x10000000:
            raise ValueError('Inline-data ext4 inode is unsupported')
        kind = inode['mode'] & 0xf000
        if kind == 0xa000 and size <= 60 and not inode['blocks512']:
            return inode['mapping'][:size]
        data = bytearray(size)
        if inode['flags'] & 0x80000:
            for logical, length, physical, unwritten in self.extents(inode['mapping']):
                start = logical*self.block_size
                take = min(length*self.block_size, size - start)
                if take > 0 and not unwritten:
                    data[start:start + take] = self.disk.read(self.offset + physical*self.block_size, take)
        else:
            for i, physical in enumerate(self.legacy_blocks(inode['mapping'], (size + self.block_size - 1)//self.block_size)):
                take = min(self.block_size, size - i*self.block_size)
                if physical:
                    data[i*self.block_size:i*self.block_size + take] = self.block(physical)[:take]
        return bytes(data)

    def directory(self, inode):
        data = self.contents(inode)
        cursor = 0
        while cursor + 8 <= len(data):
            child, stride, name_length, kind = struct.unpack_from('<IHBB', data, cursor)
            if stride < 8 or stride % 4 or cursor + stride > len(data) or name_length > stride - 8:
                raise ValueError(f'Invalid ext4 directory entry at inode {inode["number"]}, offset {cursor}')
            name = data[cursor + 8:cursor + 8 + name_length].decode('utf-8', 'surrogateescape')
            if child and name not in ('.', '..'):
                if '/' in name or '\x00' in name:
                    raise ValueError('Invalid directory component')
                yield name, child
            cursor += stride

    def walk(self):
        todo = [('', 2)]
        visited = set()
        count = 0
        while todo:
            path, number = todo.pop()
            inode = self.inode(number)
            kind = inode['mode'] & 0xf000
            yield path or '/', inode
            count += 1
            if count > 300000:
                raise ValueError('Filesystem traversal exceeded safety limit')
            if kind == 0x4000 and number not in visited:
                visited.add(number)
                for name, child in self.directory(inode):
                    todo.append((path + '/' + name, child))


def selected_config(path):
    p = PurePosixPath(path)
    name = p.name.lower()
    return name in ('build.prop', 'prop.default', 'default.prop', 'kernel_cmdline', 'kernelcmdline', 'ueventd.rc') or name.startswith('fstab') or \
        (name.endswith('.rc') and ('init' in name or '/etc/init/' in path)) or \
        ('/vintf/' in path and name.endswith('.xml')) or \
        (name.endswith(('.json', '.xml', '.conf', '.cfg', '.prop')) and re.search(r'wsa|windows|microsoft|virtio|gfxstream|goldfish|ranchu', path, re.I))


def prop_map(text):
    return {key.strip(): value.strip() for line in text.splitlines() if line.strip() and not line.lstrip().startswith('#') and '=' in line for key, value in [line.split('=', 1)]}


def image_report(path, extract_dir):
    before = path.stat()
    disk = Vhdx(path)
    try:
        fs = Ext4(disk)
        result = {'image': path.name, 'physicalBytes': disk.file_size, 'virtualBytes': disk.size, 'vhdxBlockBytes': disk.block_size,
                  'sourceReadOnly': True, 'vhdxHeaderAndRegionChecksumsValid': True, 'vhdxLogReplayRequired': False,
                  'filesystem': {'type': 'ext4', 'offset': fs.offset, 'blockBytes': fs.block_size, 'label': fs.label, 'uuid': fs.uuid,
                                 'incompatFeatures': hex(fs.incompat), 'state': u16(fs.super, 58)},
                  'files': [], 'extractedConfigs': [], 'properties': {}, 'services': [], 'wsaRelatedPaths': [], 'warnings': []}
        kinds = Counter()
        for path_in_image, inode in fs.walk():
            kind = inode['mode'] & 0xf000
            kind_name = {0x4000: 'directory', 0x8000: 'file', 0xa000: 'symlink'}.get(kind, hex(kind))
            kinds[kind_name] += 1
            entry = {'path': path_in_image, 'kind': kind_name, 'size': inode['size'], 'inode': inode['number']}
            if kind == 0xa000:
                try: entry['target'] = fs.contents(inode).decode('utf-8', 'replace')
                except ValueError as error: entry['readError'] = str(error)
            result['files'].append(entry)
            if re.search(r'wsa|microsoft|windows|gfxstream|goldfish|ranchu|d3d12|directx|dxg|hvsocket|virtio', path_in_image, re.I):
                result['wsaRelatedPaths'].append(path_in_image)
            if kind == 0x8000 and selected_config(path_in_image):
                try:
                    data = fs.contents(inode, max_size=2*1024*1024)
                    text = data.decode('utf-8', 'replace')
                    destination = extract_dir / path.stem / path_in_image.lstrip('/')
                    if not destination.resolve().is_relative_to(extract_dir.resolve()):
                        raise ValueError('Unsafe extraction path')
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.write_bytes(data)
                    result['extractedConfigs'].append({'path': path_in_image, 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest(), 'localPath': str(destination.resolve())})
                    if PurePosixPath(path_in_image).name in ('build.prop', 'prop.default', 'default.prop'):
                        result['properties'][path_in_image] = prop_map(text)
                    if path_in_image.endswith('.rc'):
                        for line in text.splitlines():
                            if line.startswith('service '):
                                result['services'].append({'config': path_in_image, 'declaration': line})
                except (ValueError, OSError) as error:
                    result['warnings'].append({'path': path_in_image, 'error': str(error)})
        result['entryCounts'] = dict(kinds)
        result['files'].sort(key=lambda e: e['path'])
        result['wsaRelatedPaths'].sort()
        result['extractedConfigs'].sort(key=lambda e: e['path'])
        after = path.stat()
        result['sourceMetadataUnchanged'] = before.st_size == after.st_size and before.st_mtime_ns == after.st_mtime_ns
        return result
    finally:
        disk.close()


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, default=root/'tools/wsabuilds/LTS8-arm64/WSA_2407.40000.4.0_arm64')
    parser.add_argument('--extract', type=Path, default=root/'tools/wsabuilds/inspection/extracted')
    parser.add_argument('--report', type=Path, default=root/'artifacts/wsa/image-inspection.json')
    args = parser.parse_args()
    package = args.package.resolve()
    extract = args.extract.resolve()
    if extract == package or extract.is_relative_to(package):
        raise SystemExit('Extraction must not modify the source package directory')
    reports = []
    for path in sorted(package.glob('*.vhdx')):
        print(f'Inspecting {path.name} read-only...', flush=True)
        try:
            report = image_report(path, extract)
            print(f'  {report["entryCounts"]}; extracted {len(report["extractedConfigs"])} configs', flush=True)
            reports.append(report)
        except (ValueError, OSError, struct.error, KeyError) as error:
            reports.append({'image': path.name, 'error': str(error), 'sourceReadOnly': True})
            print(f'  ERROR: {error}', flush=True)
    if not reports:
        raise SystemExit('No VHDX images found')
    output = {'schemaVersion': 1, 'recordedUtc': datetime.now(timezone.utc).isoformat(), 'package': str(package),
              'method': 'Read-only Python VHDX BAT and ext4 inode/extent traversal; no mounting, source writes or raw disk copies',
              'limitations': ['Not a filesystem repair or full consistency checker', 'Does not verify ext4 metadata CRCs or replay journals',
                              'Fails on VHDX differencing/active logs and ext4 META_BG/inline-data', 'Static image inspection does not validate boot or hardware graphics'],
              'formatReferences': ['https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-vhdx/af7334e6-ad2c-4378-9b81-afc1334a6ee7',
                                   'https://www.kernel.org/doc/html/latest/filesystems/ext4/index.html'],
              'images': reports}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(output, indent=2, ensure_ascii=True) + '\n', encoding='utf-8')
    print(f'Report: {args.report.resolve()}')
    return int(any('error' in report for report in reports))


if __name__ == '__main__':
    sys.exit(main())
