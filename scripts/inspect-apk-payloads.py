"""Inventory ELF and opaque APK library payloads without executing or unpacking protection."""
import argparse
import hashlib
import importlib.util
import json
import struct
import sys
import zipfile
from pathlib import Path

sys.dont_write_bytecode = True
module_spec = importlib.util.spec_from_file_location(
    "sparkdroid_apk_metadata", Path(__file__).with_name("inspect-test-apk.py")
)
metadata = importlib.util.module_from_spec(module_spec)
module_spec.loader.exec_module(metadata)


def inspect(path):
    data = path.read_bytes()
    payloads = []
    with zipfile.ZipFile(path) as archive:
        manifest = metadata.inspect_manifest(archive.read("AndroidManifest.xml"))
        for entry in archive.infolist():
            if not entry.filename.startswith("lib/") or not entry.filename.endswith(".so"):
                continue
            payload = archive.read(entry)
            is_elf = len(payload) >= 20 and payload[:4] == b"\x7fELF"
            payloads.append({
                "path": entry.filename, "bytes": len(payload),
                "sha256": hashlib.sha256(payload).hexdigest(), "is_elf": is_elf,
                "elf_class": payload[4] if is_elf else None,
                "elf_machine": struct.unpack_from("<H" if payload[5] == 1 else ">H", payload, 18)[0] if is_elf else None,
                "inspection": "ELF header only" if is_elf else "Opaque non-ELF payload; architecture and runtime behavior unverified",
            })
    elf = [entry for entry in payloads if entry["is_elf"]]
    return {
        "file": path.as_posix(), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
        **manifest, "library_payload_count": len(payloads), "elf_library_count": len(elf),
        "opaque_library_payload_count": len(payloads) - len(elf),
        "all_inspected_elf_libraries_aarch64": bool(elf) and all(entry["elf_class"] == 2 and entry["elf_machine"] == 183 for entry in elf),
        "library_payloads": payloads, "signature_blocks": metadata.inspect_signature_blocks(data),
        "signature_verification": "Signature block presence inspected; Android package-manager verification pending installation",
        "limitations": "No protected payloads decrypted or executed. ELF architecture evidence does not establish whole-app compatibility.",
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("apk", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = inspect(args.apk)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: value for key, value in report.items() if key != "library_payloads"}, indent=2))
