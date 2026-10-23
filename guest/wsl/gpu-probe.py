#!/usr/bin/env python3
"""Verify Linux GLES rendering through WSL D3D12; this does not verify Android.

Usage: python3 gpu-probe.py [--output report.json] [--timeout 30]
Dependencies: python3, libegl1, libegl-mesa0, libgles2, libgl1-mesa-dri, libx11-6.
The parent isolates each EGL attempt so a driver crash or hang becomes evidence.
"""
import argparse
import ctypes as c
import datetime
import json
import os
from pathlib import Path
import platform
import stat
import subprocess
import sys


def fn(lib, name, result, *arguments):
    entry = getattr(lib, name)
    entry.restype = result
    entry.argtypes = list(arguments)
    return entry


def elf_info(path):
    result = {"path": str(path), "exists": path.exists()}
    try:
        with path.open("rb") as handle:
            header = handle.read(20)
        if len(header) != 20 or header[:4] != b"\x7fELF":
            raise ValueError("Not an ELF library")
        machine = int.from_bytes(header[18:20], "little" if header[5] == 1 else "big")
        result.update(resolvedPath=str(path.resolve()), elfClass=header[4],
                      machine=machine, arm64=header[4] == 2 and machine == 183)
    except (OSError, ValueError) as error:
        result.update(arm64=False, error=str(error))
    return result


def host_info():
    dxg = Path("/dev/dxg")
    try:
        dxg_info = {"present": True, "characterDevice": stat.S_ISCHR(dxg.stat().st_mode),
                    "readWriteAccessible": os.access(dxg, os.R_OK | os.W_OK)}
        descriptor = os.open(dxg, os.O_RDWR)
        os.close(descriptor)
        dxg_info["openedReadWrite"] = True
    except OSError as error:
        dxg_info = {"present": dxg.exists(), "characterDevice": dxg.is_char_device(),
                    "readWriteAccessible": False, "openedReadWrite": False, "error": str(error)}
    libraries = {name: elf_info(Path("/usr/lib/wsl/lib") / name)
                 for name in ("libd3d12.so", "libd3d12core.so", "libdxcore.so")}
    return {"system": platform.system(), "machine": platform.machine(),
            "kernel": platform.release(), "dxg": dxg_info, "libraries": libraries,
            "environment": {key: os.environ.get(key) for key in (
                "DISPLAY", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "EGL_PLATFORM",
                "MESA_D3D12_DEFAULT_ADAPTER_NAME", "GALLIUM_DRIVER",
                "LIBGL_ALWAYS_SOFTWARE", "MESA_LOADER_DRIVER_OVERRIDE")}}


def render_attempt(surface_platform):
    result = {"platform": surface_platform, "renderSucceeded": False,
              "nvidiaD3D12Renderer": False, "pixelsValidated": False}
    egl = gl = x11 = None
    display = context = surface = native_display = None
    ptr, integer, uint = c.c_void_p, c.c_int, c.c_uint
    try:
        egl = c.CDLL("libEGL.so.1")
        gl = c.CDLL("libGLESv2.so.2")
        egl_error = fn(egl, "eglGetError", uint)

        def require(value, operation):
            if not value:
                raise RuntimeError(f"{operation} failed: EGL error 0x{egl_error():04x}")

        get_display = fn(egl, "eglGetPlatformDisplay", ptr, uint, ptr, c.POINTER(c.c_ssize_t))
        if surface_platform == "x11":
            x11 = c.CDLL("libX11.so.6")
            native_display = fn(x11, "XOpenDisplay", ptr, c.c_char_p)(None)
            if not native_display:
                raise RuntimeError(f"XOpenDisplay failed for DISPLAY={os.environ.get('DISPLAY')!r}")
            display = get_display(0x31D5, native_display, None)  # EGL_PLATFORM_X11_KHR
        else:
            display = get_display(0x31DD, None, None)  # EGL_PLATFORM_SURFACELESS_MESA
        require(display, "eglGetPlatformDisplay")
        major, minor = integer(), integer()
        require(fn(egl, "eglInitialize", uint, ptr, c.POINTER(integer), c.POINTER(integer))(
            display, c.byref(major), c.byref(minor)), "eglInitialize")
        query = fn(egl, "eglQueryString", c.c_char_p, ptr, integer)
        result.update(eglVersion=f"{major.value}.{minor.value}",
                      eglVendor=(query(display, 0x3053) or b"").decode(errors="replace"))
        attrs = (integer * 13)(0x3033, 1, 0x3040, 4, 0x3024, 8, 0x3023, 8,
                               0x3022, 8, 0x3021, 8, 0x3038)
        config, count = ptr(), integer()
        require(fn(egl, "eglChooseConfig", uint, ptr, c.POINTER(integer),
                   c.POINTER(ptr), integer, c.POINTER(integer))(
                       display, attrs, c.byref(config), 1, c.byref(count)), "eglChooseConfig")
        if count.value < 1:
            raise RuntimeError("No RGBA8 ES2 pbuffer configuration")
        require(fn(egl, "eglBindAPI", uint, uint)(0x30A0), "eglBindAPI(ES)")
        context_attrs = (integer * 3)(0x3098, 2, 0x3038)
        context = fn(egl, "eglCreateContext", ptr, ptr, ptr, ptr, c.POINTER(integer))(
            display, config, None, context_attrs)
        require(context, "eglCreateContext")
        surface_attrs = (integer * 5)(0x3057, 16, 0x3056, 16, 0x3038)
        surface = fn(egl, "eglCreatePbufferSurface", ptr, ptr, ptr, c.POINTER(integer))(
            display, config, surface_attrs)
        require(surface, "eglCreatePbufferSurface")
        require(fn(egl, "eglMakeCurrent", uint, ptr, ptr, ptr, ptr)(
            display, surface, surface, context), "eglMakeCurrent")
        get_string = fn(gl, "glGetString", c.c_char_p, uint)
        renderer = (get_string(0x1F01) or b"").decode(errors="replace")
        renderer_lower = renderer.lower()
        result.update(glVendor=(get_string(0x1F00) or b"").decode(errors="replace"),
                      glRenderer=renderer,
                      glVersion=(get_string(0x1F02) or b"").decode(errors="replace"),
                      nvidiaD3D12Renderer=("d3d12" in renderer_lower and "nvidia" in renderer_lower
                          and not any(word in renderer_lower for word in
                                      ("llvmpipe", "softpipe", "swiftshader", "warp", "microsoft basic"))))
        try:
            mapped_paths = set()
            for line in Path("/proc/self/maps").read_text().splitlines():
                fields = line.split(maxsplit=5)
                if len(fields) == 6 and any(name in fields[5].lower() for name in ("libd3d12", "libdxcore")):
                    mapped_paths.add(fields[5])
            result["mappedD3D12Libraries"] = [elf_info(Path(path)) for path in sorted(mapped_paths)]
        except OSError as error:
            result["mappedD3D12LibrariesError"] = str(error)
        get_error = fn(gl, "glGetError", uint)
        shader_source = fn(gl, "glShaderSource", None, uint, integer,
                           c.POINTER(c.c_char_p), c.POINTER(integer))
        shader_status = fn(gl, "glGetShaderiv", None, uint, uint, c.POINTER(integer))
        shader_log = fn(gl, "glGetShaderInfoLog", None, uint, integer, c.POINTER(integer), ptr)

        def compile_shader(kind, source):
            shader = fn(gl, "glCreateShader", uint, uint)(kind)
            text = c.c_char_p(source)
            shader_source(shader, 1, c.byref(text), None)
            fn(gl, "glCompileShader", None, uint)(shader)
            ok = integer()
            shader_status(shader, 0x8B81, c.byref(ok))
            if not ok.value:
                log = c.create_string_buffer(8192)
                shader_log(shader, len(log), None, log)
                raise RuntimeError("Shader compilation failed: " + log.value.decode(errors="replace"))
            return shader

        vertex = compile_shader(0x8B31,
            b"attribute vec2 position; void main(){gl_Position=vec4(position,0.0,1.0);}")
        fragment = compile_shader(0x8B30,
            b"precision mediump float; void main(){gl_FragColor=vec4(gl_FragCoord.xy/16.0,0.6,1.0);}")
        program = fn(gl, "glCreateProgram", uint)()
        attach = fn(gl, "glAttachShader", None, uint, uint)
        attach(program, vertex)
        attach(program, fragment)
        fn(gl, "glBindAttribLocation", None, uint, uint, c.c_char_p)(program, 0, b"position")
        fn(gl, "glLinkProgram", None, uint)(program)
        linked = integer()
        fn(gl, "glGetProgramiv", None, uint, uint, c.POINTER(integer))(program, 0x8B82, c.byref(linked))
        if not linked.value:
            log = c.create_string_buffer(8192)
            fn(gl, "glGetProgramInfoLog", None, uint, integer, c.POINTER(integer), ptr)(
                program, len(log), None, log)
            raise RuntimeError("Program linking failed: " + log.value.decode(errors="replace"))
        fn(gl, "glUseProgram", None, uint)(program)
        vertices = (c.c_float * 6)(-1, -1, 3, -1, -1, 3)
        buffer = uint()
        fn(gl, "glGenBuffers", None, integer, c.POINTER(uint))(1, c.byref(buffer))
        fn(gl, "glBindBuffer", None, uint, uint)(0x8892, buffer.value)
        fn(gl, "glBufferData", None, uint, c.c_ssize_t, ptr, uint)(
            0x8892, c.sizeof(vertices), vertices, 0x88E4)
        fn(gl, "glVertexAttribPointer", None, uint, integer, uint, c.c_ubyte, integer, ptr)(
            0, 2, 0x1406, 0, 0, None)
        fn(gl, "glEnableVertexAttribArray", None, uint)(0)
        fn(gl, "glViewport", None, integer, integer, integer, integer)(0, 0, 16, 16)
        fn(gl, "glClearColor", None, c.c_float, c.c_float, c.c_float, c.c_float)(0, 0, 0, 1)
        fn(gl, "glClear", None, uint)(0x4000)
        fn(gl, "glDrawArrays", None, uint, integer, integer)(4, 0, 3)
        fn(gl, "glFinish", None)()
        pixels = (c.c_ubyte * (16 * 16 * 4))()
        fn(gl, "glReadPixels", None, integer, integer, integer, integer, uint, uint, ptr)(
            0, 0, 16, 16, 0x1908, 0x1401, pixels)
        samples = []
        for x, y in ((0, 0), (15, 0), (8, 8), (0, 15), (15, 15)):
            offset = (y * 16 + x) * 4
            actual = list(pixels[offset:offset + 4])
            expected = [round((x + 0.5) / 16 * 255), round((y + 0.5) / 16 * 255), 153, 255]
            samples.append({"xy": [x, y], "rgba": actual, "expected": expected,
                            "matches": all(abs(a - b) <= 2 for a, b in zip(actual, expected))})
        error = get_error()
        valid = all(sample["matches"] for sample in samples)
        result.update(shaderDraw=True, samples=samples, pixelsValidated=valid,
                      glError=f"0x{error:04x}", renderSucceeded=valid and error == 0)
        if error or not valid:
            result["error"] = "Shader draw/readback failed pixel validation or generated a GL error"
    except Exception as error:
        result["error"] = f"{type(error).__name__}: {error}"
    finally:
        if egl and display:
            fn(egl, "eglMakeCurrent", uint, ptr, ptr, ptr, ptr)(display, None, None, None)
            if surface:
                fn(egl, "eglDestroySurface", uint, ptr, ptr)(display, surface)
            if context:
                fn(egl, "eglDestroyContext", uint, ptr, ptr)(display, context)
            fn(egl, "eglTerminate", uint, ptr)(display)
        if x11 and native_display:
            fn(x11, "XCloseDisplay", integer, ptr)(native_display)
    return result


def run_isolated(surface_platform, timeout):
    command = [sys.executable, str(Path(__file__).resolve()), "--attempt", surface_platform]
    try:
        completed = subprocess.run(command, capture_output=True, text=True,
                                   errors="replace", timeout=timeout, check=False)
        # Driver diagnostics may precede JSON on stdout. The child emits JSON last.
        lines = completed.stdout.splitlines()
        result = json.loads(lines[-1]) if lines else {}
        if not isinstance(result, dict):
            raise ValueError("Attempt did not return a JSON object")
        result.update(exitCode=completed.returncode, stderr=completed.stderr)
        if len(lines) > 1:
            result["driverStdout"] = "\n".join(lines[:-1])
        if completed.returncode:
            result["renderSucceeded"] = False
            result.setdefault("error", "Probe process failed; check exit code and driver output")
        return result
    except subprocess.TimeoutExpired as error:
        return {"platform": surface_platform, "renderSucceeded": False,
                "error": f"Driver probe exceeded {timeout} seconds",
                "stderr": (error.stderr or b"").decode(errors="replace")}
    except (ValueError, IndexError) as error:
        return {"platform": surface_platform, "renderSucceeded": False,
                "error": f"Invalid driver probe result: {error}",
                "exitCode": completed.returncode, "stdout": completed.stdout,
                "stderr": completed.stderr}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--timeout", type=int, default=30)
    parser.add_argument("--attempt", choices=("x11", "surfaceless"), help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.timeout < 1 or args.timeout > 120:
        parser.error("--timeout must be 1..120 seconds")
    # Explicit D3D12/NVIDIA selection; retain other inherited settings in evidence.
    os.environ["MESA_D3D12_DEFAULT_ADAPTER_NAME"] = "NVIDIA"
    os.environ["GALLIUM_DRIVER"] = "d3d12"
    if args.attempt:
        print(json.dumps(render_attempt(args.attempt)))
        return 0
    host = host_info()
    candidates = (["x11"] if os.environ.get("DISPLAY") else []) + ["surfaceless"]
    attempts = [run_isolated(candidate, args.timeout) for candidate in candidates]
    linux_arm64 = host["system"] == "Linux" and host["machine"].lower() in ("aarch64", "arm64")
    required_libraries = all(host["libraries"][name]["arm64"]
                             for name in ("libd3d12.so", "libdxcore.so"))
    device_usable = (host["dxg"]["characterDevice"] and host["dxg"]["readWriteAccessible"]
                     and host["dxg"]["openedReadWrite"])
    passing = [attempt for attempt in attempts if attempt.get("renderSucceeded")
               and attempt.get("nvidiaD3D12Renderer") and attempt.get("pixelsValidated")]
    verified = bool(linux_arm64 and required_libraries and device_usable and passing)
    report = {"schemaVersion": 1, "timestampUtc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "success": verified, "hardwareRenderingVerified": verified,
              "androidHardwareRenderingVerified": False, "host": host, "attempts": attempts,
              "selectedPlatform": passing[0]["platform"] if passing else None,
              "scope": "Linux GLES shader rendering and pixel readback on NVIDIA via WSL D3D12. "
                       "Does not establish Android rendering, window presentation, encoding, FPS or power consumption.",
              "sources": ["https://github.com/microsoft/wslg/wiki/GPU-selection-in-WSLg",
                          "https://docs.mesa3d.org/drivers/d3d12.html"]}
    output = json.dumps(report, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(output + "\n", encoding="utf-8")
    print(output)
    return 0 if verified else 1


if __name__ == "__main__":
    raise SystemExit(main())
