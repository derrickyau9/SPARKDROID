#!/usr/bin/env python3
"""Build new ARM64-only WSA image copies; never write the source package.

Default is a dry run. --apply creates a previously nonexistent candidate
directory. Only seven fixed-length property values and the VHDX write identity
headers may differ. This is an offline, pinned-image experiment, not a general
ext4/VHDX repair utility. Independently check candidates before installation.
"""
from __future__ import annotations

import argparse
from collections import defaultdict
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import shutil
import struct
import sys
import uuid

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
spec = importlib.util.spec_from_file_location('wsa_images', HERE / 'Inspect-WsaImages.py')
images = importlib.util.module_from_spec(spec)
spec.loader.exec_module(images)
u16, u32, u64 = images.u16, images.u32, images.u64

EXPECTED = {
    'system.vhdx': '049f3b18364cd10210185fb28362e6ea5685beaf150bd79c2384a063f09709a4',
    'vendor.vhdx': '9b52110b952a81d2e7d6c7f39a8f00aa2331c7a454584cd9052275e7d62a1831',
}
ABI = 'arm64-v8a,armeabi-v7a,armeabi'
ABI32 = 'armeabi-v7a,armeabi'
CHANGES = {
    'system.vhdx': {
        '/system/build.prop': [
            ('ro.system.product.cpu.abilist', ABI, 'arm64-v8a'),
            ('ro.system.product.cpu.abilist32', ABI32, ''),
        ],
    },
    'vendor.vhdx': {
        '/build.prop': [
            ('ro.vendor.product.cpu.abilist', ABI, 'arm64-v8a'),
            ('ro.vendor.product.cpu.abilist32', ABI32, ''),
            ('ro.zygote', 'zygote64_32', 'zygote64'),
        ],
        '/odm/etc/build.prop': [
            ('ro.odm.product.cpu.abilist', ABI, 'arm64-v8a'),
            ('ro.odm.product.cpu.abilist32', ABI32, ''),
        ],
    },
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def avb_footer(disk):
    footer = disk.read(disk.size - 64, 64)
    if footer[:4] != b'AVBf':
        return {'present': False}
    major, minor, original, offset, length = struct.unpack_from('>IIQQQ', footer, 4)
    header = disk.read(offset, 256)
    require(header[:4] == b'AVB0', 'Invalid AVB metadata header')
    return {'present': True, 'footerVersion': [major, minor], 'originalImageBytes': original,
            'vbmetaOffset': offset, 'vbmetaBytes': length,
            'algorithm': struct.unpack_from('>I', header, 28)[0],
            'flags': struct.unpack_from('>I', header, 120)[0],
            'existingHashtreeWillBeStale': True, 'avbBytesModified': False,
            'limitation': 'This experimental candidate retains the original AVB descriptors and hash tree unchanged. Their digest no longer matches modified filesystem data. No boot verification setting is changed and no AVB validation success is claimed.'}


def group_descriptors(fs):
    blocks = u32(fs.super, 4) | (u32(fs.super, 336) << 32)
    first, per_group = u32(fs.super, 20), u32(fs.super, 32)
    count = math.ceil((blocks - first) / per_group)
    for group in range(count):
        data = fs.disk.read(fs.offset + fs.desc_offset + group * fs.desc_size, fs.desc_size)
        block_bitmap, inode_bitmap, table = struct.unpack_from('<III', data)
        if fs.desc_size >= 64:
            block_bitmap |= u32(data, 32) << 32
            inode_bitmap |= u32(data, 36) << 32
            table |= u32(data, 40) << 32
        yield group, block_bitmap, inode_bitmap, table


def inode_raw(fs, number, descriptors):
    group, index = divmod(number - 1, fs.inodes_per_group)
    table = descriptors[group][3]
    return fs.disk.read(fs.offset + table * fs.block_size + index * fs.inode_size, fs.inode_size)


def extent_maps(fs, tree, nodes, depth=None):
    require(u16(tree, 0) == 0xf30a, 'Bad extent magic')
    count, maximum, current = u16(tree, 2), u16(tree, 4), u16(tree, 6)
    require(current <= 5 and count <= maximum and 12 + count * 12 <= len(tree), 'Bad extent bounds')
    require(depth is None or depth == current, 'Bad extent depth')
    for index in range(count):
        entry = tree[12 + index * 12:24 + index * 12]
        logical = u32(entry, 0)
        if current:
            child = u32(entry, 4) | (u16(entry, 8) << 32)
            require(child not in nodes, 'Repeated extent-tree node')
            nodes.add(child)
            yield from extent_maps(fs, fs.block(child), nodes, current - 1)
        else:
            raw_length = u16(entry, 4)
            length = raw_length - 32768 if raw_length > 32768 else raw_length
            physical = u32(entry, 8) | (u16(entry, 6) << 32)
            require(length > 0, 'Empty extent')
            yield logical, length, physical, raw_length > 32768


def inode_maps(fs, raw):
    flags, mode = u32(raw, 32), u16(raw, 0) & 0xf000
    size = u32(raw, 4) | (u32(raw, 108) << 32)
    nodes = set()
    if not u32(raw, 28) and (mode != 0x8000 or not size):
        return [], nodes  # Includes fast symlinks and empty reserved inodes.
    if flags & 0x10000000:
        return [], nodes  # Inline inodes cannot reference a target data block.
    if flags & 0x80000:
        return list(extent_maps(fs, raw[40:100], nodes)), nodes
    # All indirect pointers are traversed, including resize/journal inode maps.
    mappings = []
    pointers = struct.unpack('<15I', raw[40:100])
    for logical, physical in enumerate(pointers[:12]):
        if physical:
            mappings.append((logical, 1, physical, False))
    fanout = fs.block_size // 4

    def indirect(physical, depth, logical):
        if not physical:
            return
        require(physical not in nodes, 'Repeated indirect mapping node')
        nodes.add(physical)
        values = struct.unpack('<' + 'I' * fanout, fs.block(physical))
        for index, block in enumerate(values):
            if not block:
                continue
            at = logical + index * fanout ** (depth - 1)
            if depth == 1:
                mappings.append((at, 1, block, False))
            else:
                indirect(block, depth - 1, at)

    logical = 12
    for depth, pointer in enumerate(pointers[12:], 1):
        indirect(pointer, depth, logical)
        logical += fanout ** depth
    return mappings, nodes


def physical_segments(disk, virtual_offset, length):
    require(0 <= virtual_offset < disk.size and virtual_offset + length <= disk.size, 'Out-of-range virtual patch')
    while length:
        block, within = divmod(virtual_offset, disk.block_size)
        entry = u64(disk.bat, 8 * (block + block // disk.chunk_ratio))
        require(entry & 7 == 6, 'Patch requires a fully-present VHDX payload block')
        take = min(length, disk.block_size - within)
        physical = (entry & 0xfffffffffff00000) + within
        require(physical >= 1024 * 1024 and physical + take <= disk.file_size, 'Invalid payload location')
        yield physical, take
        virtual_offset += take
        length -= take


def value_edits(content, changes):
    edits = []
    for key, before, after in changes:
        key, old, new = key.encode(), before.encode(), after.encode()
        require(len(new) <= len(old), 'Replacement would expand a property')
        target = key + b'=' + old
        lines = content.splitlines(keepends=True)
        found, offset = [], 0
        for line in lines:
            if line.rstrip(b'\r\n') == target:
                found.append(offset + len(key) + 1)
            offset += len(line)
        require(len(found) == 1, f'Expected exactly one original property: {key.decode()}')
        edits.append({'key': key.decode(), 'before': before, 'after': after,
                      'offset': found[0], 'old': old, 'new': new.ljust(len(old), b' ')})
    return edits


def audit_ownership(fs, targets, descriptors):
    target_blocks = {block for target in targets for block in target['blocks']}
    require(sum(len(t['blocks']) for t in targets) == len(target_blocks), 'Target files share data blocks')
    references = defaultdict(list)
    blocks_per_group, first = u32(fs.super, 32), u32(fs.super, 20)
    descriptor_blocks = math.ceil(len(descriptors) * fs.desc_size / fs.block_size)
    inode_table_blocks = math.ceil(fs.inodes_per_group * fs.inode_size / fs.block_size)
    reserved_gdt = u16(fs.super, 206)
    ro_features = u32(fs.super, 100)
    require(not u32(fs.super, 92) & 0x200, 'sparse_super2 is unsupported')

    def metadata(start, length, kind):
        require(not any(start <= block < start + length for block in target_blocks), f'Target intersects {kind}')

    def power_of(group, base):
        while group > 1 and group % base == 0:
            group //= base
        return group == 1

    allocated_count = 0
    for group, bitmap, inode_bitmap, table in descriptors:
        metadata(bitmap, 1, 'block bitmap')
        metadata(inode_bitmap, 1, 'inode bitmap')
        metadata(table, inode_table_blocks, 'inode table')
        has_super = not ro_features & 1 or group in (0, 1) or any(power_of(group, n) for n in (3, 5, 7))
        if has_super:
            metadata(first + group * blocks_per_group, 1 + descriptor_blocks + reserved_gdt, 'superblock/GDT/reserved GDT')
        bits = fs.block(inode_bitmap)
        table_bytes = fs.disk.read(fs.offset + table * fs.block_size, fs.inodes_per_group * fs.inode_size)
        for index in range(fs.inodes_per_group):
            number = group * fs.inodes_per_group + index + 1
            if number > fs.inode_count or not bits[index // 8] & (1 << (index % 8)):
                continue
            allocated_count += 1
            raw = table_bytes[index * fs.inode_size:(index + 1) * fs.inode_size]
            # Extended attributes can live in a separate metadata block, including
            # on fast-symlink/inline inodes that have no regular data mappings.
            external_xattr = u32(raw, 104) | (u16(raw, 118) << 32)
            if external_xattr:
                metadata(external_xattr, 1, f'external xattr block of inode {number}')
            mappings, nodes = inode_maps(fs, raw)
            require(not target_blocks & nodes, f'Target intersects extent/indirect metadata of inode {number}')
            for logical, length, physical, unwritten in mappings:
                for block in target_blocks:
                    if physical <= block < physical + length:
                        references[block].append({'inode': number, 'logicalBlock': logical + block - physical,
                                                  'unwritten': unwritten})
    for target in targets:
        for block, logical in target['blocks'].items():
            require(references[block] == [{'inode': target['inode'], 'logicalBlock': logical, 'unwritten': False}],
                    f'Block {block} is shared, unwritten, or has inconsistent ownership: {references[block]}')
            group, index = divmod(block - first, blocks_per_group)
            bitmap = fs.block(descriptors[group][1])
            require(bitmap[index // 8] & (1 << (index % 8)), f'Target block {block} is not allocated')
    return {'allocatedInodesScanned': allocated_count, 'targetBlocksProvenExclusive': sorted(target_blocks),
            'filesystemHasSharedBlocksFeature': bool(ro_features & 0x4000), 'metadataIntersections': 0}


def plan_image(source):
    actual_hash = sha256(source)
    require(actual_hash == EXPECTED[source.name], f'Pinned source SHA256 mismatch: {source.name}')
    disk = images.Vhdx(source)
    try:
        fs = images.Ext4(disk)
        require(u16(fs.super, 58) == 1 and not fs.incompat & 4, 'Filesystem is not clean / requires recovery')
        require(fs.incompat == 0x42 and u32(fs.super, 92) == 0x28 and u32(fs.super, 100) == 0x407b,
                'Unexpected filesystem feature set; only pinned image layout is supported')
        avb = avb_footer(disk)
        descriptors = list(group_descriptors(fs))
        nodes = dict(fs.walk())
        targets, patches, summaries = [], [], []
        for path, changes in CHANGES[source.name].items():
            inode = nodes.get(path)
            require(inode is not None, f'Missing target: {path}')
            raw = inode_raw(fs, inode['number'], descriptors)
            require(inode['mode'] & 0xf000 == 0x8000, 'Target must be a regular file')
            require(u16(raw, 26) == 1, 'Target has hard links')
            require(not inode['flags'] & (0x10000000 | 0x800 | 0x100000 | 0x4), 'Inline/encrypted/verity/compressed target forbidden')
            require(inode['flags'] == 0x80000, 'Unexpected target inode flags')
            mappings, _ = inode_maps(fs, raw)
            content = fs.contents(inode)
            blocks = {}
            for logical, length, physical, unwritten in mappings:
                require(not unwritten, 'Target has unwritten extents')
                for offset in range(length):
                    require(physical + offset not in blocks, 'Target aliases its own data block')
                    blocks[physical + offset] = logical + offset
            targets.append({'inode': inode['number'], 'blocks': blocks})
            edits = value_edits(content, changes)
            changed = bytearray(content)
            for edit in edits:
                begin, remaining = edit['offset'], len(edit['new'])
                changed[begin:begin + remaining] = edit['new']
                used = 0
                while remaining:
                    logical, within = divmod(begin + used, fs.block_size)
                    owners = [physical for physical, at in blocks.items() if at == logical]
                    require(len(owners) == 1, 'Target file has a sparse or duplicate logical block')
                    take = min(remaining, fs.block_size - within)
                    virtual = fs.offset + owners[0] * fs.block_size + within
                    consumed = 0
                    for physical, length in physical_segments(disk, virtual, take):
                        before = edit['old'][used + consumed:used + consumed + length]
                        after = edit['new'][used + consumed:used + consumed + length]
                        require(disk.physical(physical, length) == before, 'Payload precondition mismatch')
                        patches.append({'offset': physical, 'old': before, 'new': after, 'kind': 'property', 'key': edit['key']})
                        consumed += length
                    used += take
                    remaining -= take
            require(len(changed) == len(content), 'Target file length changed')
            summaries.append({'path': path, 'inode': inode['number'], 'fileBytes': len(content),
                              'beforeSha256': hashlib.sha256(content).hexdigest(),
                              'afterSha256': hashlib.sha256(changed).hexdigest(),
                              'properties': [{key: edit[key] for key in ('key', 'before', 'after')} for edit in edits]})
        ownership = audit_ownership(fs, targets, descriptors)
        # A VHDX physical payload block must not alias another virtual block or metadata.
        referenced = defaultdict(list)
        for block in range(math.ceil(disk.size / disk.block_size)):
            entry = u64(disk.bat, 8 * (block + block // disk.chunk_ratio))
            if entry & 7 == 6:
                base = entry & 0xfffffffffff00000
                for patch in patches:
                    if base <= patch['offset'] < base + disk.block_size:
                        referenced[patch['offset']].append(block)
        require(all(len(referenced[p['offset']]) == 1 for p in patches), 'VHDX payload is aliased')
        table = disk.physical(196608, 65536)
        require(images.valid_crc(table), 'Primary VHDX region CRC invalid')
        regions = [(0, 1024 * 1024)]
        for index in range(u32(table, 8)):
            region = table[16 + 32 * index:48 + 32 * index]
            regions.append((u64(region, 16), u32(region, 24)))
        regions.append((u64(disk.header, 72), u32(disk.header, 68)))
        require(all(not (start < p['offset'] + len(p['new']) and p['offset'] < start + length)
                    for p in patches for start, length in regions), 'Patch intersects VHDX metadata/log')
        headers = [(offset, disk.physical(offset, 4096)) for offset in (65536, 131072)]
        require(all(h[:4] == b'head' and images.valid_crc(h) for _, h in headers), 'Both source headers must be valid')
        require(headers[0][1][48:] == headers[1][1][48:], 'Unexpected source header layout/log mismatch')
        require(u64(headers[0][1], 8) != u64(headers[1][1], 8), 'Ambiguous current VHDX header')
        return {'image': source.name, 'sourceSha256': actual_hash, 'sourceBytes': disk.file_size,
                'ownershipAudit': ownership, 'avb': avb, 'files': summaries,
                'payloadPatchRanges': [{'offset': p['offset'], 'bytes': len(p['new']), 'property': p['key']} for p in patches]}, patches, headers
    finally:
        disk.close()


def header_patches(headers):
    ordered = sorted(headers, key=lambda entry: u64(entry[1], 8))
    current = ordered[-1][1]
    require(u64(current, 8) <= (1 << 64) - 3, 'VHDX sequence overflow')
    file_guid, data_guid = uuid.uuid4().bytes_le, uuid.uuid4().bytes_le
    result = []
    for increment, (offset, previous) in enumerate(ordered, 1):
        updated = bytearray(current)
        struct.pack_into('<Q', updated, 8, u64(current, 8) + increment)
        updated[16:32], updated[32:48] = file_guid, data_guid
        updated[4:8] = b'\0' * 4
        struct.pack_into('<I', updated, 4, images.crc32c(updated))
        require(images.valid_crc(updated), 'Generated header CRC invalid')
        # All other bytes remain exactly those of this header slot.
        require(updated[:4] == previous[:4] and updated[48:] == previous[48:], 'Header layout would change')
        result.append({'offset': offset, 'old': previous, 'new': bytes(updated), 'kind': 'header'})
    return result


def verify_diff(source, candidate, patches):
    expected = {}
    for patch in patches:
        for index, (before, after) in enumerate(zip(patch['old'], patch['new'])):
            if before != after:
                position = patch['offset'] + index
                require(position not in expected, 'Overlapping patch bytes')
                expected[position] = (before, after)
    found = set()
    with source.open('rb') as original, candidate.open('rb') as modified:
        offset = 0
        while True:
            a, b = original.read(4 * 1024 * 1024), modified.read(4 * 1024 * 1024)
            require(len(a) == len(b), 'Candidate image length changed')
            if not a:
                break
            if a != b:
                for index, (before, after) in enumerate(zip(a, b)):
                    if before != after:
                        at = offset + index
                        require(expected.get(at) == (before, after), f'Unexpected global byte difference at {at}')
                        found.add(at)
            offset += len(a)
    require(found == set(expected), 'A planned byte difference was not applied')
    return {'entireFileCompared': True, 'changedBytes': len(found), 'unexpectedChangedBytes': 0,
            'allowedChanges': 'Seven property values across two images; VHDX header CRC/sequence/FileWriteGuid/DataWriteGuid only'}


def apply_image(source, destination, plan, patches, headers):
    # Exclusive creation prevents overwriting either an existing candidate or source.
    with source.open('rb') as original, destination.open('xb') as candidate:
        shutil.copyfileobj(original, candidate, 4 * 1024 * 1024)
        candidate.flush()
        os.fsync(candidate.fileno())
    require(sha256(destination) == plan['sourceSha256'], 'Copy SHA256 mismatch')
    header_edits = header_patches(headers)
    with destination.open('r+b') as candidate:
        # Update older header, flush, then other header, flush, before data writes.
        for patch in header_edits + patches:
            candidate.seek(patch['offset'])
            require(candidate.read(len(patch['old'])) == patch['old'], 'Candidate patch precondition failed')
            candidate.seek(patch['offset'])
            require(candidate.write(patch['new']) == len(patch['new']), 'Short candidate write')
            if patch['kind'] == 'header':
                candidate.flush()
                os.fsync(candidate.fileno())
        candidate.flush()
        os.fsync(candidate.fileno())
    difference = verify_diff(source, destination, header_edits + patches)
    disk = images.Vhdx(destination)
    try:
        fs = images.Ext4(disk)
        nodes = dict(fs.walk())
        for target in plan['files']:
            content = fs.contents(nodes[target['path']])
            require(len(content) == target['fileBytes'], 'Read-back file length mismatch')
            require(hashlib.sha256(content).hexdigest() == target['afterSha256'], 'Read-back file hash mismatch')
            parsed = images.prop_map(content.decode('ascii'))
            for prop in target['properties']:
                require(parsed[prop['key']] == prop['after'], 'Read-back property value mismatch')
        for offset in (65536, 131072):
            require(images.valid_crc(disk.physical(offset, 4096)), 'Read-back header CRC mismatch')
    finally:
        disk.close()
    require(sha256(source) == plan['sourceSha256'], 'Source changed during candidate creation')
    return {'candidateSha256': sha256(destination), 'readBackVerified': True, 'sourceSha256Unchanged': True,
            'globalDiff': difference, 'vhdxWriteGuidsUpdated': True, 'ext4MetadataUnchanged': True,
            'independentFilesystemCheck': 'Required before installation; this tool does not replace e2fsck'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=ROOT / 'tools/wsabuilds/LTS8-arm64/WSA_2407.40000.4.0_arm64')
    parser.add_argument('--output', type=Path, default=ROOT / 'tools/wsabuilds/arm64-only-candidate')
    parser.add_argument('--report', type=Path, default=ROOT / 'artifacts/wsa/arm64-only-patch-plan.json')
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--allow-inactive-avb-for-experiment', action='store_true',
                        help='Explicitly accept the unchanged AVB hash tree becoming stale in an experimental candidate; no verification setting is modified')
    args = parser.parse_args()
    source, output, report = args.source.resolve(), args.output.resolve(), args.report.resolve()
    require(not output.exists(), 'Output directory must not exist; refusing to reuse or overwrite candidates')
    require(output != source and not output.is_relative_to(source), 'Output must be outside the source package')
    require(not report.is_relative_to(source), 'Report must be outside the source package')
    require(not report.exists(), 'Report must not already exist; choose a new report path')
    plans = []
    for name in CHANGES:
        print(f'Checking pinned {name} and target block ownership...', flush=True)
        plan, patches, headers = plan_image(source / name)
        plans.append((plan, patches, headers))
    result = {'schemaVersion': 1, 'mode': 'candidate' if args.apply else 'dry-run',
              'sourcePackage': source.name, 'images': [entry[0] for entry in plans],
              'cryptoSelfTestServicesUnchanged': True,
              'headerPolicy': 'Before payload writes, update FileWriteGuid/DataWriteGuid and both headers sequence/CRC, older slot first with flush; all ext4 metadata and all VHDX BAT/region/metadata/log bytes remain unchanged.',
              'specification': 'https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-vhdx/39d641c2-093c-4d4a-8c9d-bd4b9fc2ff31',
              'runtimeInstalledOrStarted': False}
    if args.apply:
        require(args.allow_inactive_avb_for_experiment or not any(plan['avb']['present'] for plan, _, _ in plans),
                'Existing AVB footer detected. Applying this experimental data-only candidate requires --allow-inactive-avb-for-experiment; no AVB enforcement setting will be changed')
        output.mkdir(parents=True, exist_ok=False)
        for plan, patches, headers in plans:
            print(f'Creating and verifying new {plan["image"]} candidate...', flush=True)
            plan['result'] = apply_image(source / plan['image'], output / plan['image'], plan, patches, headers)
    for name in CHANGES:
        require(sha256(source / name) == EXPECTED[name], f'Source hash changed: {name}')
    result['sourceHashesVerifiedAfterOperation'] = True
    report.parent.mkdir(parents=True, exist_ok=True)
    with report.open('x', encoding='utf-8') as stream:
        json.dump(result, stream, indent=2)
        stream.write('\n')
    print(f'{result["mode"]} verified. Report: {report}', flush=True)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, struct.error) as error:
        print(f'REFUSED: {error}', file=sys.stderr)
        sys.exit(1)
