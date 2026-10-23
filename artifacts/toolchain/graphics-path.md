# SPARKDROID graphics validation

The NVIDIA D3D11 → ANGLE → VirGL → VirtIO → ARM64 Linux guest path rendered a pixel successfully. A subsequent Android hardware-mode trial booted its framework but produced black frames with an incomplete multisample framebuffer. The working Android configuration therefore uses explicit software graphics. No GPU passthrough, zero-copy guest memory sharing, or Android Vulkan support is established.

## Tested components and results

- Native Windows ARM64 QEMU 11.1.2-1 from the official MSYS2 CLANGARM64 repository, PE machine `0xAA64`. The executable SHA256 is `0479d85fbb1e730ebf491e373bd43bfaac9efb97817e0f213078f1c9e9720ba3`.
- Packaged VirGLrenderer 1.3.0 and ANGLE 2.1.25748 (`890b5d8fa298`). All dependencies are local under `tools/qemu-arm64/clangarm64`.
- The native host EGL test reports NVIDIA RTX Spark N1X, D3D11 driver `32.0.16.1721`, OpenGL ES 3.0. It clears a framebuffer and reads `[51,102,153,255]` with no GL error. See `angle-renderer.json`.
- A separate Ubuntu 24.04 ARM64 diagnostic VM boots with WHPX, 2 vCPUs and 2048 MiB. Linux kernel `6.8.0-147-generic` exposes `/dev/dri/renderD128`. Mesa 25.2.8 reports `virgl (ANGLE (NVIDIA, NVIDIA RTX Spark N1X (6144-core Black...)` on GBM, surfaceless, and its first EGL device. The separate second EGL device is explicitly llvmpipe; its results are not counted as acceleration.
- `guest-egl-probe.py` opens **renderD128 explicitly through GBM**, creates a GLES context and texture framebuffer, clears it, and reads the expected pixel with `glError=0`. See `linux-virgl-render.json` and `linux-virgl-validation.txt`.
- The guest exposes OpenGL 2.1 and OpenGL ES 2.0 through this path. This limitation may prevent modern Android components from using hardware rendering. No version overrides were applied.
- An isolated host attempt with `ANGLE_DEFAULT_PLATFORM=vulkan` crashes natively at `eglInitialize` with `0xC0000005`. It is not a working Vulkan path; see `angle-renderer-vulkan.json`.
- Linux kernel logs contain two early framebuffer scanout errors (`response 0x1203`, command `0x103`). Offscreen rendering nevertheless succeeds. Guest scanout presentation, Android composition, and frame pacing require separate testing.

## Exact host device configuration

Add these arguments to an ARM64 `virt` machine using `-accel whpx -cpu host`:

```text
-display egl-headless -device virtio-gpu-gl-pci
```

No environment override is needed for the validated D3D11 path. Keep the packaged DLLs adjacent to the QEMU executable. Host blob memory and Venus are not enabled or validated.

The reproducible isolated diagnostic VM script is `scripts/toolchain/Start-GpuProbeVm.ps1`. It uses its own overlay, seed, SSH22223 and QMP14445. It shares only the read-only Ubuntu backing image and existing public SSH key. Its cloud-init installs `mesa-utils`, `libegl1`, `libgles2`, and `libgl1-mesa-dri`. The successful diagnostic VM was shut down cleanly after validation.

To rerun the pixel test while that diagnostic VM is running:

```powershell
Get-Content scripts/toolchain/guest-egl-probe.py -Raw | ssh.exe -p 22223 -i state/ssh_key -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=state/gpu-probe-known_hosts spark@127.0.0.1 'sudo python3 -'
```

## Android integration candidate

The current Redroid image contains Mesa EGL/GLES libraries, `virtio_gpu_dri.so`, GBM gralloc, and the Redroid hardware composer. See `redroid-graphics-libraries.txt`. A Linux VM launched with the GPU arguments above can expose the render node to a privileged Android container. Its candidate boot arguments are:

```text
androidboot.redroid_gpu_mode=host
androidboot.redroid_gpu_node=/dev/dri/renderD128
```

Require `dumpsys SurfaceFlinger` and an actual app render result naming VirGL/NVIDIA before selecting this as a validated Android graphics mode. The Vulkan VirtIO HAL is present in the image but its presence does not demonstrate a functioning host Vulkan pipeline. Check HWUI renderer selection and any GLES3 requirements explicitly. Keep the software mode identified separately if hardware mode fails.

The actual Android trial is recorded in `artifacts/acceptance/graphics.json`: framework boot completed and SurfaceFlinger reported Mesa/VirGL/NVIDIA, but the captured frame was black. Host logs reported framebuffer status `0x8d56`, GL error `1286`, and a rejected CLEAR command. Android hardware frames are **not validated**. See `android-virgl-diagnosis.md` for bounded source-level findings.

## Upstream references

- [QEMU VirtIO GPU documentation](https://www.qemu.org/docs/master/system/devices/virtio/virtio-gpu.html)
- [QEMU 11.1.2 Win32 EGL source](https://github.com/qemu/qemu/blob/v11.1.2/ui/egl-helpers.c)
- [QEMU 11.1.2 VirGL device source](https://github.com/qemu/qemu/blob/v11.1.2/hw/display/virtio-gpu-virgl.c)
- [MSYS2 VirGLrenderer packaging](https://github.com/msys2/MINGW-packages/blob/master/mingw-w64-virglrenderer/PKGBUILD)
- [Redroid GPU configuration source](https://github.com/remote-android/vendor_redroid/blob/master/gpu_config.sh)
- [ANGLE backend selection source](https://chromium.googlesource.com/angle/angle/+/HEAD/src/libANGLE/Display.cpp)

The exact downloaded source excerpts are retained in `artifacts/toolchain/sources`. Repository package SHA256 digests are pinned in `upstream/qemu-arm64.lock.json`. Detached package PGP signatures were not independently verified.
