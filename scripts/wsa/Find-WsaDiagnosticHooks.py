#!/usr/bin/env python3
"""Read-only static diagnostic configuration string inventory of WSA binaries."""
import argparse
import json
from pathlib import Path
import re
import struct

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--package',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    args=p.parse_args()
    pattern=re.compile(r'debugconsole|debug.?shell|console|serial|kernelcommand|kernel.command|mini_init|logcat|dmesg|bootconfig|diagnostic|KernelDebug|DebugLog|TraceLogging|vm\.log|hvsocket|HyperVSocket|ttyS|androidboot|WsaSettings|Software\\Microsoft\\.*(WSA|Android|Windows Subsystem)',re.I)
    files=['WsaClient/WsaClient.exe','WsaService/WsaService.exe','wslcore.dll','lxutil.dll','wsldevicehost.dll','wslrelay.exe','Tools/initrd.img']
    results=[]
    for name in files:
        path=args.package/name
        if not path.is_file():continue
        data=path.read_bytes()
        sections=[]
        if data[:2]==b'MZ':
            pe=struct.unpack_from('<I',data,60)[0]
            optsize=struct.unpack_from('<H',data,pe+20)[0]
            start=pe+24+optsize
            for i in range(struct.unpack_from('<H',data,pe+6)[0]):
                e=data[start+i*40:start+(i+1)*40]
                sections.append((struct.unpack_from('<I',e,20)[0],struct.unpack_from('<I',e,16)[0],struct.unpack_from('<I',e,12)[0]))
        found=[]
        for expr,encoding in [(rb'[\x20-\x7e]{6,1000}','ascii'),(rb'(?:[\x20-\x7e]\x00){6,1000}','utf-16-le')]:
            for match in re.finditer(expr,data):
                text=match.group().decode(encoding)
                if pattern.search(text):
                    offset=match.start()
                    rva=next((hex(v+offset-f) for f,l,v in sections if f<=offset<f+l),None)
                    found.append({'fileOffset':hex(offset),'rva':rva,'text':text,'encoding':encoding})
        results.append({'file':name,'strings':found})
        print(name)
        for row in found: print(f'  {row["rva"] or row["fileOffset"]} {row["text"]}')
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps({'method':'Static string inventory only; no hooks enabled or host settings changed','files':results},indent=2)+'\n')

if __name__=='__main__':main()
