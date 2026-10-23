#!/usr/bin/env python3
"""Read-only, local ARM64 code inspection with an explicitly provided Capstone path."""
import argparse
import importlib
from pathlib import Path
import re
import struct
import sys

def u16(b,n=0):return struct.unpack_from('<H',b,n)[0]
def u32(b,n=0):return struct.unpack_from('<I',b,n)[0]
def u64(b,n=0):return struct.unpack_from('<Q',b,n)[0]

class PE:
    def __init__(self,path):
        self.data=Path(path).read_bytes()
        self.pe=u32(self.data,0x3c)
        self.machine=u16(self.data,self.pe+4)
        self.opt=self.pe+24
        self.imagebase=u64(self.data,self.opt+24)
        self.sections=[]
        start=self.opt+u16(self.data,self.pe+20)
        for i in range(u16(self.data,self.pe+6)):
            entry=self.data[start+i*40:start+(i+1)*40]
            self.sections.append((entry[:8].rstrip(b'\0').decode(),u32(entry,12),u32(entry,8),u32(entry,20),u32(entry,16)))
        self.imports={}
        directory=u32(self.data,self.opt+112+8)
        if directory:
            while True:
                d=self.read(directory,20)
                if not any(d):break
                original,first=u32(d),u32(d,16)
                dll=self.string(u32(d,12))
                index=0
                while True:
                    thunk=u64(self.read((original or first)+index*8,8))
                    if not thunk:break
                    name=f'ordinal{thunk&0xffff}' if thunk>>63 else self.string(thunk+2)
                    self.imports[first+index*8]=f'{dll}!{name}'
                    index+=1
                directory+=20

    def read(self,rva,size):
        for name,start,vsize,offset,rawsize in self.sections:
            if start<=rva and rva+size<=start+rawsize:
                return self.data[offset+rva-start:offset+rva-start+size]
        raise ValueError(f'Unmapped RVA {rva:#x}')

    def string(self,rva,wide=False):
        remaining=next((start+rawsize-rva for name,start,vsize,offset,rawsize in self.sections if start<=rva<start+rawsize),0)
        data=self.read(rva,min(256,remaining))
        if wide:
            end=next((i for i in range(0,len(data)-1,2) if data[i:i+2]==b'\0\0'),len(data))
            return data[:end].decode('utf16','replace')
        return data.split(b'\0',1)[0].decode('ascii','replace')

    def label(self,rva):
        if rva in self.imports:return self.imports[rva]
        try:
            for wide in (False,True):
                s=self.string(rva,wide)
                if len(s)>=5 and all(32<=ord(c)<127 or c in '\r\n\t' for c in s):return repr(s)
        except ValueError:pass
        return ''

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('binary',type=Path)
    p.add_argument('--capstone-path',type=Path,required=True)
    p.add_argument('--range',action='append',default=[],help='hex start:end RVA')
    p.add_argument('--xref',action='append',default=[],help='hex RVA to locate via adjacent ADRP/ADD instructions')
    args=p.parse_args()
    sys.path.insert(0,str(args.capstone_path.resolve()))
    cs=importlib.import_module('capstone')
    pe=PE(args.binary)
    print(f'Machine={pe.machine:#x}, imagebase={pe.imagebase:#x}')
    decoder=cs.Cs(cs.CS_ARCH_ARM64,cs.CS_MODE_ARM)
    if args.xref:
        decoder.skipdata=True
        targets={int(n,16) for n in args.xref}
        for section,start,vsize,offset,rawsize in pe.sections:
            if section!='.text':continue
            regs={}
            for ins in decoder.disasm(pe.read(start,rawsize),start):
                regs={key:value for key,value in regs.items() if ins.address-value[1]<=48}
                match=re.fullmatch(r'(x\d+), #0x([0-9a-f]+)',ins.op_str)
                if ins.mnemonic in ('adrp','adr') and match:regs[match[1]]=(int(match[2],16),ins.address)
                match=re.fullmatch(r'(x\d+), (x\d+), #0x([0-9a-f]+)',ins.op_str)
                if ins.mnemonic=='add' and match and match[2] in regs:
                    target=regs[match[2]][0]+int(match[3],16)
                    if target in targets:print(f'XREF {ins.address:#x} -> {target:#x}: {ins.mnemonic} {ins.op_str} {pe.label(target)}')
        decoder.skipdata=False
    for span in args.range:
        start,end=(int(n,16) for n in span.split(':'))
        print(f'\nRVA {start:#x}..{end:#x}')
        registers={}
        for ins in decoder.disasm(pe.read(start,end-start),start):
            note=''
            match=re.fullmatch(r'(x\d+), #0x([0-9a-f]+)',ins.op_str)
            if ins.mnemonic in ('adrp','adr') and match:
                registers[match[1]]=int(match[2],16)
            match=re.fullmatch(r'(x\d+), (x\d+), #0x([0-9a-f]+)',ins.op_str)
            if ins.mnemonic=='add' and match and match[2] in registers:
                registers[match[1]]=registers[match[2]]+int(match[3],16)
                note=pe.label(registers[match[1]])
            match=re.fullmatch(r'(x\d+), \[(x\d+)(?:, #0x([0-9a-f]+))?\]',ins.op_str)
            if ins.mnemonic=='ldr' and match and match[2] in registers:
                rva=registers[match[2]]+int(match[3] or '0',16)
                note=pe.label(rva)
            print(f'{ins.address:08x}  {ins.mnemonic:<8} {ins.op_str:<45} {note}')

if __name__=='__main__':main()
