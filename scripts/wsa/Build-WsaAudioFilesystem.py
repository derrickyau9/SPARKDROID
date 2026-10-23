#!/usr/bin/env python3
"""Linux-only builder for an isolated vendor raw-image candidate.

Invoked by Build-WsaAudioCandidate.ps1 in the owned SPARKDROID-Tools distro.
All mounts are nodev,nosuid,noexec. The replacement is read as data, never run.
Source VHDX images and the installed Android runtime are not opened here.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import stat
import struct
import subprocess
import tempfile

NEW_HASH = 'c7a830d4f62c5643c3a7303d442892dcf4d1899741261fa775eeabeb86805e22'
OLD_HASH = '192af147e754b0ad9908f511bf3b56777e7eba01a583b1dbb6fc8da99e5579a0'
TARGET = 'bin/hw/android.hardware.audio.service'


def require(value, message):
    if not value:
        raise RuntimeError(message)


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def attributes(path):
    info = path.lstat()
    return {'mode': stat.S_IMODE(info.st_mode), 'type': stat.S_IFMT(info.st_mode),
            'uid': info.st_uid, 'gid': info.st_gid,
            'xattrs': {key: base64.b64encode(os.getxattr(path, key, follow_symlinks=False)).decode()
                       for key in sorted(os.listxattr(path, follow_symlinks=False))}}


def inventory(root):
    result = {}
    for parent, directories, files in os.walk(root, followlinks=False):
        for name in ['.'] + directories + files:
            path = Path(parent) if name == '.' else Path(parent) / name
            relative = str(path.relative_to(root))
            if relative in result:
                continue
            info = attributes(path)
            if info['type'] == stat.S_IFREG:
                info['sha256'] = digest(path)
                info['size'] = path.stat().st_size
            elif info['type'] == stat.S_IFLNK:
                info['link'] = os.readlink(path)
            result[relative] = info
    return result


def feature_bits(raw):
    with raw.open('rb') as stream:
        stream.seek(1024)
        block = stream.read(1024)
    require(struct.unpack_from('<H', block, 56)[0] == 0xef53, 'Expected raw ext4 at offset zero')
    return struct.unpack_from('<III', block, 92)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--replacement', type=Path, required=True)
    parser.add_argument('--token', required=True)
    args = parser.parse_args()
    require(os.geteuid() == 0, 'The tools distro must run this builder as root')
    directory, replacement = args.directory.resolve(), args.replacement.resolve()
    request = json.loads((directory / 'build-request.json').read_text())
    require(request['token'] == args.token and request['allowInactiveAvbExperiment'] is True, 'Invalid candidate build receipt')
    require(request['toolsDistro'] == 'SPARKDROID-Tools' and request['distroOwnershipVerifiedByRegistry'] is True,
            'Wrapper must verify that the dedicated tools distro BasePath belongs to this workspace')
    raw = directory / 'vendor.raw'
    require(raw.is_file() and raw.stat().st_nlink == 1, 'Expected an independent raw image copy')
    require(digest(raw) == request['rawSha256'], 'Raw-copy hash mismatch')
    data = replacement.read_bytes()
    require(len(data) == 19472 and hashlib.sha256(data).hexdigest() == NEW_HASH, 'Replacement hash/length mismatch')
    require(data[:5] == b'\x7fELF\x02' and struct.unpack_from('<H', data, 18)[0] == 183, 'Replacement is not ELF64/AArch64')
    report = {'success': False, 'commands': [], 'replacementExecuted': False, 'runtimeInstalledOrStarted': False}

    def run(name, argv, accepted=(0,)):
        completed = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        (directory / (name + '.txt')).write_text(completed.stdout)
        report['commands'].append({'stage': name, 'exitCode': completed.returncode})
        require(completed.returncode in accepted, f'{name} failed with exit {completed.returncode}; see {name}.txt')
        return completed.stdout.strip()

    loop, mounted = None, False
    mountpoint = Path(tempfile.mkdtemp(prefix='sparkdroid-audio-'))

    def mount_image(readonly):
        nonlocal loop, mounted
        argv = ['/usr/sbin/losetup', '--find', '--show']
        if readonly:
            argv += ['--read-only']
        loop = run('loop-ro' if readonly else 'loop-rw', argv + [str(raw)])
        require(loop.startswith('/dev/loop') and loop[9:].isdigit(), 'Unexpected allocated loop-device name')
        options = 'ro,noload,nodev,nosuid,noexec' if readonly else 'rw,nodev,nosuid,noexec'
        run('mount-ro' if readonly else 'mount-rw', ['/usr/bin/mount', '-t', 'ext4', '-o', options, loop, str(mountpoint)])
        mounted = True

    def unmount_image(stage):
        nonlocal loop, mounted
        if mounted:
            run('unmount-' + stage, ['/usr/bin/umount', str(mountpoint)])
            mounted = False
        if loop:
            run('detach-' + stage, ['/usr/sbin/losetup', '--detach', loop])
            loop = None

    try:
        run('original-fsck', ['/usr/sbin/e2fsck', '-fn', str(raw)])
        mount_image(True)
        before = inventory(mountpoint)
        require(before[TARGET]['sha256'] == OLD_HASH and before[TARGET]['size'] == 10804, 'Original audio file precondition mismatch')
        (directory / 'inventory-before.json').write_text(json.dumps(before, indent=2) + '\n')
        unmount_image('original')
        report['originalFilesystemFeatures'] = [hex(value) for value in feature_bits(raw)]
        with raw.open('r+b') as stream:
            stream.truncate(256 * 1024 * 1024)
            stream.flush()
            os.fsync(stream.fileno())
        run('resize', ['/usr/sbin/resize2fs', str(raw), '256M'])
        run('unshare', ['/usr/sbin/e2fsck', '-fy', '-E', 'unshare_blocks', str(raw)], (0, 1))
        require(not feature_bits(raw)[2] & 0x4000, 'Shared-blocks feature still present; refusing read-write mount')
        run('unshared-fsck', ['/usr/sbin/e2fsck', '-fn', str(raw)])
        mount_image(False)
        original = mountpoint / TARGET
        require(original.is_file() and not original.is_symlink(), 'Audio target is not a regular file')
        require(original.stat().st_nlink == 1 and digest(original) == OLD_HASH, 'Audio target changed or has hard links')
        metadata = attributes(original)
        inode_before = original.stat().st_ino
        with original.open('r+b') as stream:
            stream.seek(0)
            require(stream.write(data) == len(data), 'Short audio write')
            stream.truncate(len(data))
            stream.flush()
            os.fsync(stream.fileno())
        # Writes can clear capability xattrs. Restore exactly the prior metadata.
        os.chown(original, metadata['uid'], metadata['gid'])
        os.chmod(original, metadata['mode'])
        current_xattrs = attributes(original)['xattrs']
        for key, encoded in metadata['xattrs'].items():
            if current_xattrs.get(key) != encoded:
                os.setxattr(original, key, base64.b64decode(encoded))
        require(original.stat().st_ino == inode_before and attributes(original) == metadata, 'Target inode/metadata changed')
        after = inventory(mountpoint)
        expected = dict(before)
        expected[TARGET] = dict(before[TARGET], sha256=NEW_HASH, size=len(data))
        require(after == expected, 'Whole-tree audit found a change outside the single approved audio binary')
        (directory / 'inventory-after.json').write_text(json.dumps(after, indent=2) + '\n')
        unmount_image('candidate')
        run('candidate-fsck', ['/usr/sbin/e2fsck', '-fn', str(raw)])
        report.update(success=True, rawSha256=digest(raw), filesystemBytes=raw.stat().st_size,
                      fileTreeEntriesChecked=len(before), changedFiles=[TARGET],
                      targetMetadataPreserved=True, targetInodePreserved=True,
                      finalFilesystemFeatures=[hex(value) for value in feature_bits(raw)],
                      inactiveAvbExperiment=True,
                      avbNotice='Filesystem growth reuses the former AVB/hash-tree trailer area. Candidate is not AVB-valid. No runtime verification setting was changed; original input VHDX is preserved for rollback.')
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        try:
            unmount_image('cleanup')
            mountpoint.rmdir()
        except Exception as error:
            report['cleanupError'] = str(error)
            report['success'] = False
            raise
        finally:
            (directory / 'filesystem-build.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'success': report['success'], 'fileTreeEntriesChecked': report['fileTreeEntriesChecked'],
                      'changedFiles': report['changedFiles']}, indent=2))


if __name__ == '__main__':
    main()
