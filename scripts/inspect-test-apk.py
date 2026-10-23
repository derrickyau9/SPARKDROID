"""Inspect an APK without executing it or requiring an Android SDK installation."""
import argparse
import hashlib
import json
import struct
import zipfile
from pathlib import Path


def pool_strings(data, offset):
    _, header_size, chunk_size = struct.unpack_from("<HHI", data, offset)
    count, _, flags, strings_offset, _ = struct.unpack_from("<IIIII", data, offset + 8)
    result = []

    def length8(pos):
        first = data[pos]
        return (((first & 127) << 8) | data[pos + 1], pos + 2) if first & 128 else (first, pos + 1)

    def length16(pos):
        first = struct.unpack_from("<H", data, pos)[0]
        return (((first & 32767) << 16) | struct.unpack_from("<H", data, pos + 2)[0], pos + 4) if first & 32768 else (first, pos + 2)

    for i in range(count):
        relative = struct.unpack_from("<I", data, offset + header_size + 4 * i)[0]
        pos = offset + strings_offset + relative
        if flags & 256:
            _, pos = length8(pos)
            length, pos = length8(pos)
            result.append(data[pos:pos + length].decode("utf-8"))
        else:
            length, pos = length16(pos)
            result.append(data[pos:pos + 2 * length].decode("utf-16-le"))
    return result, chunk_size


def inspect_manifest(data):
    strings = []
    elements = []
    offset = struct.unpack_from("<H", data, 2)[0]
    while offset < len(data):
        kind, _, chunk_size = struct.unpack_from("<HHI", data, offset)
        if chunk_size < 8 or offset + chunk_size > len(data):
            raise ValueError("Invalid Android binary XML chunk")
        if kind == 1:
            strings, _ = pool_strings(data, offset)
        elif kind == 0x102:
            name_index = struct.unpack_from("<I", data, offset + 20)[0]
            attr_start, attr_size, attr_count = struct.unpack_from("<HHH", data, offset + 24)
            attrs = {}
            for i in range(attr_count):
                pos = offset + 16 + attr_start + i * attr_size
                _, name, raw = struct.unpack_from("<III", data, pos)
                value_type = data[pos + 15]
                value = struct.unpack_from("<I", data, pos + 16)[0]
                if raw != 0xFFFFFFFF:
                    value = strings[raw]
                elif value_type == 3:
                    value = strings[value]
                attrs[strings[name]] = value
            elements.append({"name": strings[name_index], "attributes": attrs})
        offset += chunk_size
    manifest = next(e["attributes"] for e in elements if e["name"] == "manifest")
    sdk = next((e["attributes"] for e in elements if e["name"] == "uses-sdk"), {})
    return {"package": manifest.get("package"), "version_name": manifest.get("versionName"),
            "version_code": manifest.get("versionCode"), "min_sdk": sdk.get("minSdkVersion"),
            "target_sdk": sdk.get("targetSdkVersion")}


def inspect_signature_blocks(data):
    eocd = data.rfind(b"PK\x05\x06", max(0, len(data) - 65557))
    if eocd < 0:
        raise ValueError("No ZIP end record")
    central = struct.unpack_from("<I", data, eocd + 16)[0]
    if data[central - 16:central] != b"APK Sig Block 42":
        return []
    size = struct.unpack_from("<Q", data, central - 24)[0]
    pos = central - size
    end = central - 24
    identifiers = {0x7109871A: "APK Signature Scheme v2", 0xF05368C0: "APK Signature Scheme v3",
                   0x1B93AD61: "APK Signature Scheme v3.1", 0x42726577: "Verity padding"}
    result = []
    while pos < end:
        length, identifier = struct.unpack_from("<QI", data, pos)
        result.append({"id": f"0x{identifier:08x}", "type": identifiers.get(identifier, "Other block")})
        pos += 8 + length
    return result


def inspect(path):
    data = path.read_bytes()
    with zipfile.ZipFile(path) as archive:
        libs = []
        for entry in archive.infolist():
            if entry.filename.startswith("lib/") and entry.filename.endswith(".so"):
                payload = archive.read(entry)
                if payload[:4] != b"\x7fELF":
                    raise ValueError(f"Not an ELF library: {entry.filename}")
                libs.append({"path": entry.filename, "bytes": len(payload), "elf_class": payload[4],
                             "elf_machine": struct.unpack_from("<H", payload, 18)[0],
                             "sha256": hashlib.sha256(payload).hexdigest()})
        result = {"file": path.as_posix(), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                  **inspect_manifest(archive.read("AndroidManifest.xml")), "native_libraries": libs,
                  "signature_blocks": inspect_signature_blocks(data),
                  "signature_verification": "Presence inspected; Android package-manager cryptographic verification pending install"}
        if not libs or any(lib["elf_class"] != 2 or lib["elf_machine"] != 183 for lib in libs):
            raise ValueError("APK contains no native libraries or non-AArch64 native libraries")
        return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("apk", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    rendered = json.dumps(inspect(args.apk), indent=2)
    if args.output:
        args.output.write_text(rendered + "\n", encoding="utf-8")
    print(rendered)
