#!/usr/bin/env python3
"""Local-only ARM64 minidump metadata, FP chain, and bounded diagnostic scan.

Only opens the specified dump and local binaries read-only. A frame-pointer
chain is explicitly reported as such, not as a full unwind with debug symbols.
"""
import argparse
from bisect import bisect_right
import json
from pathlib import Path
import re
import struct
import uuid

def u32(b, n=0): return struct.unpack_from('<I', b, n)[0]
def u64(b, n=0): return struct.unpack_from('<Q', b, n)[0]

class Dump:
    def __init__(self, path):
        self.data = Path(path).read_bytes()
        if self.data[:4] != b'MDMP': raise ValueError('Not a Windows minidump')
        count, directory = u32(self.data, 8), u32(self.data, 12)
        self.streams = {}
        for i in range(count):
            kind, size, rva = struct.unpack_from('<III', self.data, directory + 12*i)
            self.streams[kind] = (size, rva)
        self.modules = []
        if 4 in self.streams:
            _, rva = self.streams[4]
            for i in range(u32(self.data, rva)):
                entry = self.data[rva + 4 + 108*i:rva + 112 + 108*i]
                item = {'base': u64(entry), 'size': u32(entry, 8), 'timestamp': u32(entry, 16), 'name': self.string(u32(entry, 20))}
                cv_size, cv_rva = u32(entry, 76), u32(entry, 80)
                cv = self.data[cv_rva:cv_rva + cv_size]
                if cv[:4] == b'RSDS':
                    item['pdb'] = {'guid': str(uuid.UUID(bytes_le=cv[4:20])), 'age': u32(cv, 20), 'name': cv[24:].split(b'\0', 1)[0].decode('utf-8', 'replace')}
                self.modules.append(item)
        self.modules.sort(key=lambda m: m['base'])
        self.memories = []
        if 9 in self.streams:
            _, rva = self.streams[9]
            count, start = u64(self.data, rva), u64(self.data, rva + 8)
            for i in range(count):
                address, size = struct.unpack_from('<QQ', self.data, rva + 16 + 16*i)
                self.memories.append((address, size, start))
                start += size
        if 5 in self.streams:
            _, rva = self.streams[5]
            for i in range(u32(self.data, rva)):
                address, size, start = struct.unpack_from('<QII', self.data, rva + 4 + 16*i)
                self.memories.append((address, size, start))
        self.threads = []
        if 3 in self.streams:
            _, rva = self.streams[3]
            for i in range(u32(self.data, rva)):
                entry = self.data[rva + 4 + 48*i:rva + 52 + 48*i]
                stack_addr, stack_size, stack_rva = u64(entry, 24), u32(entry, 32), u32(entry, 36)
                self.memories.append((stack_addr, stack_size, stack_rva))
                self.threads.append({'id': u32(entry), 'teb': u64(entry, 16), 'stack': (stack_addr, stack_size),
                                     'context': self.context(u32(entry, 44), u32(entry, 40))})
        self.memories.sort()
        self.starts = [r[0] for r in self.memories]

    def string(self, rva):
        length = u32(self.data, rva)
        return self.data[rva + 4:rva + 4 + length].decode('utf-16-le', 'replace')

    def context(self, rva, size):
        data = self.data[rva:rva + size]
        if len(data) < 272: return {'error': 'context too small'}
        flags = u32(data)
        if not flags & 0x400000: return {'error': f'not ARM64 context: {flags:#x}'}
        return {'flags': flags, 'cpsr': u32(data, 4), 'x': list(struct.unpack_from('<31Q', data, 8)), 'sp': u64(data, 256), 'pc': u64(data, 264)}

    def read(self, address, size):
        idx = bisect_right(self.starts, address) - 1
        for i in range(idx, max(-1, idx-3), -1):
            begin, length, offset = self.memories[i]
            if begin <= address and address + size <= begin + length:
                return self.data[offset + address-begin:offset + address-begin + size]
        raise ValueError(f'Address not captured: {address:#x}+{size:#x}')

    def location(self, address):
        for module in self.modules:
            if module['base'] <= address < module['base'] + module['size']:
                return f'{Path(module["name"]).name}+{address-module["base"]:#x}'
        return hex(address)

    def exception(self):
        _, rva = self.streams[6]
        data = self.data[rva:rva+168]
        return {'threadId': u32(data), 'code': hex(u32(data, 8)), 'flags': u32(data, 12), 'address': hex(u64(data, 24)),
                'location': self.location(u64(data, 24)), 'parameters': list(struct.unpack_from('<15Q', data, 40))[:u32(data, 32)],
                'context': self.context(u32(data, 164), u32(data, 160))}

    def fp_chain(self, context):
        fp, sp, pc = context['x'][29], context['sp'], context['pc']
        chain = [{'pc': hex(pc), 'location': self.location(pc), 'sp': hex(sp), 'fp': hex(fp), 'source': 'exception context'}]
        lr = context['x'][30]
        chain.append({'pc': hex(lr), 'location': self.location(lr), 'source': 'context LR; may be stale'})
        visited = set()
        for i in range(64):
            if fp in visited or fp < sp or fp % 16: break
            visited.add(fp)
            try: previous, ret = struct.unpack('<QQ', self.read(fp, 16))
            except ValueError: break
            chain.append({'fp': hex(fp), 'previousFp': hex(previous), 'pc': hex(ret), 'location': self.location(ret), 'source': 'frame-pointer record'})
            if previous <= fp or previous - fp > 1024*1024: break
            fp = previous
        return chain


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('dump', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    dump = Dump(args.dump)
    exception = dump.exception()
    fault_thread = next(t for t in dump.threads if t['id'] == exception['threadId'])
    context = exception['context']
    stack_start, stack_size = fault_thread['stack']
    stack_candidates = []
    for address in range(context['sp'], min(stack_start + stack_size, context['sp'] + 16384), 8):
        try: pointer = u64(dump.read(address, 8))
        except ValueError: continue
        location = dump.location(pointer)
        if '+' in location:
            stack_candidates.append({'slot': hex(address), 'pointer': hex(pointer), 'location': location})
    diagnostics = []
    pattern = re.compile(rb'[\x20-\x7e]{16,1000}')
    keywords = re.compile(r'failed|failure|fatal|assert|abort|exception|HRESULT|error [0-9]|ErrorCode|\.cpp\(|\.cpp:|\.h\(', re.I)
    for begin, size, offset in dump.memories:
        # Module static string tables are not runtime error evidence.
        if any(m['base'] <= begin < m['base'] + m['size'] for m in dump.modules): continue
        for match in pattern.finditer(dump.data, offset, offset + size):
            value = match.group().decode('ascii')
            if keywords.search(value):
                diagnostics.append({'address': hex(begin + match.start() - offset), 'text': value})
        data = dump.data[offset:offset + size]
        for match in re.finditer(rb'(?:[\x20-\x7e]\x00){16,1000}', data):
            value = match.group().decode('utf-16-le')
            if keywords.search(value):
                diagnostics.append({'address': hex(begin + match.start()), 'text': value, 'encoding': 'utf16'})
    output = {'dump': str(args.dump), 'localOnly': True, 'streams': dump.streams, 'exception': exception,
              'framePointerChain': dump.fp_chain(context), 'stackCodePointerCandidates': stack_candidates,
              'modules': dump.modules, 'heapDiagnosticCandidates': diagnostics[:300],
              'limits': ['No debug symbols or full unwind; stack pointer candidates are not necessarily return addresses',
                         'Heap strings can be stale or unrelated and require correlation with the fault stack']}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'exception': {k: v for k, v in exception.items() if k != 'context'}, 'framePointerChain': output['framePointerChain'],
                      'heapDiagnosticCandidates': diagnostics[:50], 'moduleCount': len(dump.modules), 'threadCount': len(dump.threads)}, indent=2))

if __name__ == '__main__': main()
