#!/usr/bin/env python3
"""Read-only ELF dependency and ext4 metadata plan; never executes guest code."""
from __future__ import annotations

import base64
from datetime import datetime, timezone
import hashlib
import importlib.util
import io
import json
from pathlib import Path, PurePosixPath
import posixpath
import struct
import sys
import zipfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('wsa_images', Path(__file__).with_name('Inspect-WsaImages.py'))
images = importlib.util.module_from_spec(spec)
spec.loader.exec_module(images)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def elf(data):
    if data[:4] != b'\x7fELF':
        return None
    if data[5] != 1 or data[4] not in (1, 2):
        raise ValueError('Unsupported ELF encoding')
    bits = 64 if data[4] == 2 else 32
    shoff = struct.unpack_from('<Q' if bits == 64 else '<I', data, 40 if bits == 64 else 32)[0]
    stride, count, _ = struct.unpack_from('<HHH', data, 58 if bits == 64 else 46)
    fmt = '<IIQQQQIIQQ' if bits == 64 else '<IIIIIIIIII'
    if stride < struct.calcsize(fmt) or shoff + count * stride > len(data):
        raise ValueError('ELF section bounds invalid')
    sections = [struct.unpack_from(fmt, data, shoff + i * stride) for i in range(count)]
    needed = []
    for section in sections:
        if section[1] != 6:
            continue
        strings = sections[section[6]]
        table = data[strings[4]:strings[4] + strings[5]]
        for offset in range(section[4], section[4] + section[5], section[9] or (16 if bits == 64 else 8)):
            tag, value = struct.unpack_from('<qQ' if bits == 64 else '<iI', data, offset)
            if tag == 1:
                end = table.find(b'\0', value)
                if end < 0:
                    raise ValueError('ELF DT_NEEDED string unterminated')
                needed.append(table[value:end].decode('ascii'))
    return {'bits': bits, 'machine': images.u16(data, 18), 'needed': needed}


def inode_raw(fs, number):
    group, index = divmod(number - 1, fs.inodes_per_group)
    desc = fs.disk.read(fs.offset + fs.desc_offset + group * fs.desc_size, fs.desc_size)
    table = images.u32(desc, 8) | ((images.u32(desc, 40) << 32) if fs.desc_size >= 64 else 0)
    return fs.disk.read(fs.offset + table * fs.block_size + index * fs.inode_size, fs.inode_size)


def attrs(data, entry_start, value_base):
    result = {}
    cursor = entry_start
    prefixes = {0: '', 1: 'user.', 2: 'system.posix_acl_access', 3: 'system.posix_acl_default',
                4: 'trusted.', 6: 'security.', 7: 'system.', 8: 'system.richacl'}
    while cursor + 4 <= len(data) and data[cursor:cursor + 4] != b'\0' * 4:
        if cursor + 16 > len(data):
            raise ValueError('Truncated ext4 xattr entry')
        name_len, name_index = data[cursor], data[cursor + 1]
        value_offset = images.u16(data, cursor + 2)
        value_inode, value_size = images.u32(data, cursor + 4), images.u32(data, cursor + 8)
        if value_inode:
            raise ValueError('External EA_INODE value unsupported')
        if cursor + 16 + name_len > len(data) or value_base + value_offset + value_size > len(data):
            raise ValueError('Ext4 xattr bounds invalid')
        name = prefixes[name_index] + data[cursor + 16:cursor + 16 + name_len].decode('ascii')
        value = data[value_base + value_offset:value_base + value_offset + value_size]
        result[name] = base64.b64encode(value).decode('ascii')
        cursor += (16 + name_len + 3) & ~3
    return result


class View:
    def __init__(self, path):
        self.path = path
        self.disk = images.Vhdx(path)
        self.fs = images.Ext4(self.disk)
        self.files = dict(self.fs.walk())
        self.cache = {}

    def contents(self, path):
        return self.fs.contents(self.files[path], max_size=128 * 1024 * 1024)

    def detail(self, path):
        if path in self.cache:
            return self.cache[path]
        inode = self.files[path]
        raw = inode_raw(self.fs, inode['number'])
        xattrs = {}
        if len(raw) > 128:
            start = 128 + images.u16(raw, 128)
            if start + 4 <= len(raw) and images.u32(raw, start) == 0xea020000:
                xattrs.update(attrs(raw, start + 4, start + 4))
        external = images.u32(raw, 104) | ((images.u16(raw, 118) << 32) if self.fs.incompat & 0x80 else 0)
        if external:
            block = self.fs.block(external)
            if images.u32(block, 0) != 0xea020000:
                raise ValueError('Bad external ext4 xattr header')
            xattrs.update(attrs(block, 32, 0))
        kind = inode['mode'] & 0xf000
        data = self.contents(path)
        item = {'path': path, 'bytes': len(data), 'sha256': digest(data),
                'mode': oct(inode['mode'] & 0o7777), 'uid': images.u16(raw, 2) | (images.u16(raw, 120) << 16),
                'gid': images.u16(raw, 24) | (images.u16(raw, 122) << 16), 'links': images.u16(raw, 26),
                'xattrsBase64': xattrs, 'kind': 'symlink' if kind == 0xa000 else 'file'}
        if 'security.selinux' in xattrs:
            item['selinux'] = base64.b64decode(xattrs['security.selinux']).rstrip(b'\0').decode('ascii')
        if kind == 0xa000:
            item['target'] = data.decode('utf-8')
        else:
            info = elf(data)
            if info:
                item['elf'] = info
        self.cache[path] = item
        return item

    def close(self):
        self.disk.close()


class MemoryDisk:
    def __init__(self, data):
        self.data, self.size, self.sector_size = data, len(data), 512

    def read(self, offset, length):
        if offset < 0 or length < 0 or offset + length > self.size:
            raise ValueError('APEX payload read outside bounds')
        return self.data[offset:offset + length]


def apex_libraries(view, path):
    """Inspect the APEX zip and ext4 payload in memory, without executing/mounting."""
    data = view.contents(path)
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        payload = archive.read('apex_payload.img')
    fs = images.Ext4(MemoryDisk(payload))
    found = {}
    for child, inode in fs.walk():
        if child.startswith('/lib64/') and child.endswith('.so') and inode['mode'] & 0xf000 == 0x8000:
            content = fs.contents(inode, max_size=64 * 1024 * 1024)
            found[PurePosixPath(child).name] = {'apex': path, 'path': child, 'sha256': digest(content), 'elf': elf(content)}
    return {'sha256': digest(data), 'payloadSha256': digest(payload), 'libraries': found}


def main():
    locations = {
        'baseline': ROOT / 'tools/wsabuilds/arm64-only-candidate',
        'community': ROOT / 'tools/wsabuilds/snickler-0.0.2',
    }
    views = {label: {part: View(folder / (part + '.vhdx')) for part in ('system', 'vendor')}
             for label, folder in locations.items()}
    try:
        report = {'schemaVersion': 1, 'recordedUtc': datetime.now(timezone.utc).isoformat(),
                  'scope': 'Read-only minimal static media dependency plan. No guest code executed, images mounted, candidate built, or installed file modified.',
                  'limitations': ['DT_NEEDED closure does not establish linker namespace visibility, dlopen behavior, runtime compatibility or source-to-binary trust.',
                                  'VNDK and i18n APEX contents are inspected; other APEX symlink targets are recorded without parsing.',
                                  'The community package contains unrelated modifications and is not suitable for whole-package deployment.',
                                  'These are possible later candidates; their necessity depends on boot evidence after the isolated audio repair.'],
                  'sources': {}, 'services': {}}
        for label, parts in views.items():
            report['sources'][label] = {}
            for part, view in parts.items():
                with view.path.open('rb') as stream:
                    sha = hashlib.file_digest(stream, 'sha256').hexdigest()
                report['sources'][label][part] = {'relativePath': view.path.relative_to(ROOT).as_posix(), 'sha256': sha}

        apex = {name: apex_libraries(views['baseline']['system'], path) for name, path in {
            'vndk': '/system/apex/com.android.vndk.current.apex',
            'i18n': '/system/apex/com.android.i18n.apex',
        }.items()}
        report['inspectedApex'] = {name: {key: value for key, value in item.items() if key != 'libraries'} for name, item in apex.items()}

        def resolve(part, soname):
            # Partition-local vendor variants take precedence over same-name platform
            # libraries. Actual namespace exports still require runtime verification.
            prefix = '/lib64/' if part == 'vendor' else '/system/lib64/'
            for label in ('baseline', 'community'):
                if prefix + soname in views[label][part].files:
                    return label, part, prefix + soname, None
            apex_name = 'vndk' if part == 'vendor' else 'i18n'
            if soname in apex[apex_name]['libraries']:
                return 'baseline-apex', 'system', None, apex[apex_name]['libraries'][soname]
            if part == 'vendor' and '/system/lib64/' + soname in views['baseline']['system'].files:
                return 'baseline', 'system', '/system/lib64/' + soname, None
            return 'unresolved', part, None, None

        services = {
            'mediaserver': ('system', '/system/bin/mediaserver', '/system/etc/init/mediaserver.rc'),
            'drmserver': ('system', '/system/bin/drmserver', '/system/etc/init/drmserver.rc'),
            'cas': ('vendor', '/bin/hw/android.hardware.cas@1.2-service', '/etc/init/android.hardware.cas@1.2-service.rc'),
        }
        for name, (part, binary, rc) in services.items():
            baseline = views['baseline'][part]
            community = views['community'][part]
            entry = {'binary': {'baseline': baseline.detail(binary), 'community': community.detail(binary)},
                     'requiredReplacements': [{'partition': part, **community.detail(binary)}],
                     'requiredAdditions': [], 'existingDependencyCount': 0, 'dependencyEdges': [],
                     'apexSymlinks': {}, 'apexDependencies': {}, 'unresolvedNames': [], 'rc': {}}
            entry['binaryMetadataIdentical'] = all(entry['binary']['baseline'][key] == entry['binary']['community'][key]
                                                   for key in ('mode', 'uid', 'gid', 'xattrsBase64'))
            if rc in baseline.files and rc in community.files:
                entry['rc'] = {'path': rc, 'identical': baseline.contents(rc) == community.contents(rc),
                               'baseline': baseline.detail(rc), 'community': community.detail(rc),
                               'text': baseline.contents(rc).decode('utf-8')}
            else:
                entry['rc'] = {'requestedPath': rc, 'matches': [p for p in community.files if p.endswith('.rc') and name in p]}
            queue = [(part, binary, 'community')]
            visited = set()
            additions = set()
            existing = set()
            while queue:
                owner, path, label = queue.pop()
                if (owner, path, label) in visited:
                    continue
                visited.add((owner, path, label))
                item = views[label][owner].detail(path)
                if item['kind'] == 'symlink':
                    target = item['target']
                    if target.startswith('/apex/'):
                        entry['apexSymlinks'][owner + ':' + path] = target
                    else:
                        target = posixpath.normpath(posixpath.join(str(PurePosixPath(path).parent), target))
                        if target in views[label][owner].files:
                            queue.append((owner, target, label))
                        else:
                            entry['unresolvedNames'].append(owner + ':' + path + ' -> ' + target)
                    continue
                info = item.get('elf')
                if not info:
                    raise ValueError('Expected ELF or symlink: ' + path)
                if info['bits'] != 64 or info['machine'] != 183:
                    raise ValueError('Dependency is not ELF64 AArch64: ' + path)
                for needed in info['needed']:
                    source, dep_owner, dep_path, apex_item = resolve(owner, needed)
                    edge = {'from': owner + ':' + path, 'soname': needed, 'source': source}
                    if source == 'unresolved':
                        entry['unresolvedNames'].append(needed)
                    elif source == 'baseline-apex':
                        entry['apexDependencies'][needed] = apex_item
                        edge['to'] = apex_item['apex'] + ':' + apex_item['path']
                    else:
                        edge['to'] = dep_owner + ':' + dep_path
                        if owner == 'vendor' and dep_owner == 'system':
                            edge['namespaceCaveat'] = 'Platform path availability only; vendor namespace export not proven by this report.'
                        queue.append((dep_owner, dep_path, source))
                        if source == 'community':
                            additions.add((dep_owner, dep_path))
                        else:
                            existing.add((dep_owner, dep_path))
                    entry['dependencyEdges'].append(edge)
            entry['requiredAdditions'] = [{'partition': owner, **views['community'][owner].detail(path)} for owner, path in sorted(additions)]
            entry['existingDependencyCount'] = len(existing)
            entry['unresolvedNames'] = sorted(set(entry['unresolvedNames']))
            entry['knownDynamicPlugins'] = []
            prefixes = ('/lib64/mediacas/', '/lib64/mediadrm/') if name == 'cas' else (('/system/lib64/drm/',) if name == 'drmserver' else ())
            for path in sorted(baseline.files):
                if any(path.startswith(prefix) for prefix in prefixes) and path.endswith('.so'):
                    a = baseline.detail(path)
                    b = community.detail(path) if path in community.files else None
                    entry['knownDynamicPlugins'].append({'baseline': a, 'communityIdenticalContent': b is not None and a['sha256'] == b['sha256'],
                                                         'note': 'Present ELF64 plugin; actual dynamic selection remains runtime-dependent.'})
            report['services'][name] = entry

        comparison = json.loads((ROOT / 'artifacts/wsa/snickler-partitions-comparison.json').read_text(encoding='utf-8'))
        vendor = comparison['partitions']['vendor']
        report['omx'] = {
            'status': 'No one-for-one ELF64 OMX replacement supplied by community image; out of minimal replacement scope.',
            'originalExecutable': '/vendor/bin/hw/android.hardware.media.omx@1.0-service',
            'removedFiles': [p for p in vendor['removed'] if 'omx' in p.lower()],
            'codec2AddedFiles': [p for p in vendor['added'] if 'c2' in p.lower() or 'codec2' in p.lower()],
            'manifestDiffs': {p: d for p, d in vendor['configDiffs'].items() if '/vintf/' in p},
            'policyChanges': [p for p in vendor['changed'] if 'selinux' in p],
        }
        output = ROOT / 'artifacts/wsa/media-arm64-dependency-plan.json'
        output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
        print(json.dumps({'output': str(output), 'services': {name: {
            'replacements': len(item['requiredReplacements']),
            'additions': [x['partition'] + ':' + x['path'] for x in item['requiredAdditions']],
            'unresolvedNames': item['unresolvedNames'], 'existingDependencies': item['existingDependencyCount'],
            'rcIdentical': item['rc'].get('identical')
        } for name, item in report['services'].items()}}, indent=2))
    finally:
        for parts in views.values():
            for view in parts.values():
                view.close()


if __name__ == '__main__':
    main()
