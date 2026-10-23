# WSA and WSL2 graphics route selection

Research date: 2026-10-23 (America/Los_Angeles). This document records source-backed feasibility and proposed tests. It does **not** establish that Android hardware rendering works on this NVIDIA N1X machine. Runtime probe output must establish that separately.

## Selected direction

The first experiment qualifies the existing **ARM64 WSA binary** before a custom WSL kernel and Android graphics bridge. Its Windows app/window integration supports the independent app-window objective. The QEMU/Redroid runtime and data remain separate. At the time of this research, WSA GPU acceleration, ARM64 system compatibility and 120 FPS were unverified on NVIDIA N1X; subsequent Android 13 results are recorded in [WSA runtime status](WSA-ANDROID13.md).

Keep the WSL2 ARM64 backend as the source-oriented Android 16 route and fallback. Redroid reuses the current Android image and launcher. If WSA does not meet the target, first qualify Linux GPU rendering in WSL, then use a renderer process in the Linux distribution, where Microsoft's D3D12 libraries can execute, and an Android graphics command transport into that process.

The leading experimental GLES path is:

`Android Mesa / virpipe → Unix socket → WSL virglrenderer → Mesa D3D12 → /dev/dxg → NVIDIA GPU`

This changes the backend from the earlier QEMU virtio-gpu → Windows ANGLE experiment. It still requires Android EGL/gralloc integration and real pixel validation. A renderer name alone is insufficient: the earlier experiment identified NVIDIA but produced black Android frames.

## What WSA provides today

Microsoft's WSA developer repository says Store availability ended on March 5, 2025; GitHub marks the repository archived on May 20, 2025. Its stated purpose is developer issues, feature requests and documentation. The public WSA Linux kernel is useful reference code, but these repositories do not provide a complete rebuildable Windows host, Android vendor graphics stack and window integration product. [Microsoft WSA repository](https://github.com/microsoft/WSA), [retirement announcement](https://github.com/microsoft/WSA/discussions/536), [WSA Linux kernel](https://github.com/microsoft/WSA-Linux-Kernel).

WSABuilds is actively maintaining packages. The checked ARM64 release is `Windows_11_2407.40000.4.0_LTS_8_arm64`, published September 4, 2026. Its changelog explicitly identifies **Android 13**, and it has an unrooted NoGApps/NoAmazon asset suitable for the initial app/GPU test. The release is a hotfix for the ARM translation-layer issue; that description is not evidence that every ARM64 host boot problem is fixed. [ARM64 LTS8 release and assets](https://github.com/MustardChef/WSABuilds/releases/tag/Windows_11_2407.40000.4.0_LTS_8_arm64).

The public packaging scripts download Microsoft's WSA MSIX bundle and extract the selected architecture before patching/repacking. They do not build the complete Windows host and Android integration from source. Separately, on October 5, 2026 the maintainer said the Android 14 device tree and associated components would remain closed source. Thus WSABuilds is useful as a binary runtime candidate, but is not a fully open/rebuildable WSA replacement or an available source port of WSA graphics into WSL. [Bundle acquisition](https://github.com/MustardChef/WSABuilds/blob/master/MagiskOnWSA/scripts/generateWSALinks.py), [extraction](https://github.com/MustardChef/WSABuilds/blob/master/MagiskOnWSA/scripts/extractWSA.py), [build script](https://github.com/MustardChef/WSABuilds/blob/master/MagiskOnWSA/scripts/build.sh), [maintainer source-availability statement](https://github.com/MustardChef/WSABuilds/issues/700#issuecomment-6000598148).

### ARM64 and graphics qualification

Issue #325 tracks WSA boot failures on newer ARM64 PCs, including failures linked to remaining ARM32 guest components. A separate community patch replaces guest images; its own release notes warn of broken video. These reports justify inspecting the actual package's ELF/PE architectures and boot logs, rather than assuming an `arm64` archive proves that every system service can execute on a 64-bit-only CPU. They do not establish an N1X failure. [ARM64 issue](https://github.com/MustardChef/WSABuilds/issues/325), [patch author's component replacement](https://github.com/MustardChef/WSABuilds/issues/325#issuecomment-2246488353), [patch release limitations](https://github.com/snickler/WSA-Patched/releases/tag/0.0.2).

The Android 14 effort lists subsystem GLES, ANGLE, system Vulkan and Mesa Dozen paths. The maintainer reported testing on a Surface Laptop 12 with Snapdragon X Plus, with bugs remaining; that is not an NVIDIA N1X qualification. Issue #593 concerns app crashes after Windows updates, originally on x64; it must not be treated as proof that native ARM64 has the same cause or that the ARM64 package has every fix. [Android 14 progress](https://github.com/MustardChef/WSABuilds/issues/700), [limited ARM64 testing](https://github.com/MustardChef/WSABuilds/issues/700#issuecomment-4429909473), [Windows-update app crashes](https://github.com/MustardChef/WSABuilds/issues/593).

After the required Windows reboot, test WSA in this order: subsystem boot and ADB; actual guest Android version/ABIs; an app in its own Windows window; nonblack GLES/Vulkan output and reported hardware adapter; video playback; measured rendered/presented cadence at the display's 120 Hz mode. A software adapter or a 120 Hz mode alone is not a hardware-rendering or 120 FPS result. Do not replace guest images or extract WSA's graphics libraries into Redroid before establishing a working baseline.

### Can WSA use Android 16?

There is no verified public ARM64 WSA Android 16 package in the releases checked on October 23, 2026. The shipped LTS8 package is Android 13. Issue #700 tracks the Android 14/LineageOS 21 port and remains open; its progress checklist is not a release. The Android 16 request is also open, and the maintainer explicitly plans incremental upgrades rather than a direct 13-to-16 jump. In September the maintainer described later Android upgrades as substantial work rather than fundamentally impossible. [Android 16 request and response](https://github.com/MustardChef/WSABuilds/issues/688#issuecomment-3735179384), [later-version feasibility response](https://github.com/MustardChef/WSABuilds/issues/700#issuecomment-5600369411).

An Android 16 WSA port would need the WSA device/vendor integration to work with the newer framework: graphics and buffer/HWC interfaces, media, guest-host services, init/SELinux and matching VINTF/HAL/kernel requirements. AOSP checks framework/vendor compatibility at build, boot and update time. Replacing `system.vhdx` with a generic Android 16 image is therefore an experiment requiring integration and validation, not a supported upgrade procedure. This is an engineering inference from the architecture and source boundary, not proof that the port cannot be done. [AOSP VINTF architecture](https://source.android.com/docs/core/architecture/vintf), [compatibility matching rules](https://source.android.com/docs/core/architecture/vintf/match-rules).

SPARKDROID's existing Redroid runtime already booted Android 16 ARM64 successfully; see `artifacts/acceptance/runtime-checks.json` and `docs/RESULTS.md`. Keeping that runtime and the WSL/Redroid 16 route preserves the Android 16 option. It does not supply WSA's Windows integration or prove hardware graphics in either runtime.

## Why WSL GPU access is a different route

WSL exposes GPU paravirtualization through `/dev/dxg`. Microsoft's `libd3d12.so` and `libdxcore.so` run in a glibc Linux environment, with vendor user-mode driver components supplied by the Windows driver. `/dev/dri/renderD128` is not a prerequisite for this D3D12 route. Conversely, seeing `/dev/dxg` proves only device exposure, not a usable NVIDIA driver or successful rendering. Android uses Bionic, so copying those Linux libraries into Android is not by itself a working driver port. Keeping the host renderer in WSL avoids that ABI mismatch. [Microsoft GPU architecture](https://devblogs.microsoft.com/directx/directx-heart-linux/).

Mesa's D3D12 Gallium driver translates OpenGL into D3D12. WSLg documents that the Linux distribution must ship that driver and that compatible host graphics drivers are required. `MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA` can request the NVIDIA adapter; an actual renderer/device result must confirm the selection. [Mesa D3D12 documentation](https://docs.mesa3d.org/drivers/d3d12.html), [WSLg project](https://github.com/microsoft/wslg), [Microsoft GUI prerequisites](https://learn.microsoft.com/en-us/windows/wsl/tutorials/gui-apps).

## Candidate comparison

| Route | Useful property | Remaining blocker | Priority |
|---|---|---|---|
| Redroid on WSL, existing SwiftShader/scrcpy | Reuses current Android image, apps and launcher protocol | Does not fix rendering or video encoding costs | Establish backend separately |
| Android Mesa virpipe → WSL virglrenderer → D3D12 | No QEMU graphics device or Android access to Microsoft's glibc libraries needed | Android Mesa build, gralloc buffer import/readback, SurfaceFlinger correctness; GLES feature compatibility | First graphics prototype after WSL GL passes |
| Android ANGLE → Venus vtest → WSL Dozen → D3D12 | Vulkan transport can cross the Bionic/glibc boundary through a socket | More layers; Dozen device creation and shared-memory semantics; Android buffer handling | Secondary prototype after native WSL Vulkan passes |
| Waydroid multiwindow → WSLg | Android HWC/Wayland window integration may replace Android H.264 capture | Waydroid's default Android GPU path still needs suitable drivers; its documented unsupported-GPU fallback is SwiftShader | Presentation experiment, not automatic GPU fix |
| Gfxstream → WSL or Windows renderer | Designed for graphics API streaming, including IPC | Custom guest transport/HALs; Windows recipe targets x64, not verified Windows ARM64 | Longer-term alternative |
| Current WSABuilds ARM64 LTS8 | Existing Windows app/window integration and graphics paths | Android 13; N1X boot/GPU compatibility untested; host/vendor stack not fully rebuildable | First binary qualification before custom WSL kernel work |

Waydroid's upstream VM guidance explicitly provides SwiftShader overrides for unsupported GPUs, including NVIDIA. Its issue tracker records Android EGL/DRM integration obstacles with virpipe. Those reports explain integration risks, not a universal impossibility claim. [Waydroid VM guidance](https://docs.waydro.id/faq/get-waydroid-to-work-through-a-vm), [Waydroid virpipe discussion](https://github.com/waydroid/waydroid/issues/564).

## Concrete source details for the prototypes

Mesa revision `d15e4274f6268c33fbddd1021779ad1cd85c1156` was inspected through Chromium's upstream Mesa mirror using Gitiles `?format=TEXT`:

- Android EGL has `MESA_ANDROID_NO_KMS_SWRAST` and a `pure_swrast` initialization route without opening a DRM device. This makes old statements that Android Mesa can never initialize without DRM too broad. Whether that path successfully hosts virpipe and compatible Android buffers remains an experiment.
- Dozen advertises `KHR_external_memory_fd` on non-Windows builds and handles opaque FD exports/imports. This satisfies an advertised extension check, not every memory-mapping behavior required by Venus.
- VirGL's Android CI entry uses Cuttlefish `drm_virgl`. It is not evidence of a container/vtest Android deployment.

[Android EGL source](https://chromium.googlesource.com/external/gitlab.freedesktop.org/mesa/mesa/+/d15e4274f6268c33fbddd1021779ad1cd85c1156/src/egl/drivers/dri2/platform_android.c?format=TEXT), [Dozen source](https://chromium.googlesource.com/external/gitlab.freedesktop.org/mesa/mesa/+/d15e4274f6268c33fbddd1021779ad1cd85c1156/src/microsoft/vulkan/dzn_device.c?format=TEXT), [VirGL CI source](https://chromium.googlesource.com/external/gitlab.freedesktop.org/mesa/mesa/+/d15e4274f6268c33fbddd1021779ad1cd85c1156/src/gallium/drivers/virgl/ci/gitlab-ci.yml?format=TEXT).

Mesa documents a Venus vtest server and client path that does not require virtio-gpu kernel transport. A Linux host needs Vulkan 1.1 and `VK_KHR_external_memory_fd`, but Mesa warns that driver memory behavior can still prevent operation. Dozen is not in the documented tested-host list. [Venus requirements and vtest](https://docs.mesa3d.org/drivers/venus.html).

ANGLE's Android backends are GLES and Vulkan; its D3D11 backend is a Windows backend. It supplies API translation, not the cross-container transport or Hardware Composer. Gfxstream does supply API transport, including IPC, but its published Windows build recipe uses `-A x64`; a native ARM64 port remains work. [ANGLE platform matrix](https://github.com/google/angle), [Gfxstream build and transport](https://github.com/google/gfxstream).

A recent upstream WSLg issue reports NVIDIA Dozen crashing during `vkCreateDevice` on a different RTX GPU/driver combination. This is a reason to run the Vulkan gate early, not evidence that N1X will fail. [Upstream report #1492](https://github.com/microsoft/wslg/issues/1492).

## Required gates and evidence

1. **WSL installation and ARM64 execution:** record WSL/WSLg versions, `uname -m`, kernel version, `/dev/dxg`, `/usr/lib/wsl/lib`, and the architecture of D3D12/DXCore/vendor libraries. A working WSL boot is independent of Android boot.
2. **Linux GPU rendering:** install distribution Mesa utilities and check `glxinfo -B` plus EGL information. Run a colored offscreen render/readback or visible test. Reject `llvmpipe`, `softpipe`, WARP and software-only adapters as hardware success. Record renderer, version and pixel result.
3. **Linux transport prototype:** run virglrenderer against the verified D3D12 backend, then a Linux virpipe GLES test through its socket. This isolates transport/backend errors before replacing Android libraries. For the secondary route, first run native Dozen `vulkaninfo` and a rendering test, then Venus vtest.
4. **Android GPU integration:** build ARM64 Android Mesa with the relevant driver using a pinned revision, install into a separate experimental Android container/image, validate an EGL colored-buffer test, then boot SurfaceFlinger and inspect nonblack frames. Preserve the stable container and data. Mesa documents Android cross builds; a Linux shared object is not interchangeable with an Android library. [Mesa Android build procedure](https://docs.mesa3d.org/android.html).
5. **Display and power:** measure actual rendered/presented frames, p95 frame time, CPU use and whole-machine power on identical app workloads. Record refresh mode separately from stream FPS. Keep single-window and multiwindow results separate.

Redroid's WSL recipe requires Binder/BinderFS and other kernel features and currently shows old 5.10/5.15 x86 build examples. The ARM64 WSL kernel must be configured and built against its actual version instead of copying the x86 boot-image path. The recipe establishes a deployment direction, not hardware graphics. [Redroid WSL recipe](https://github.com/remote-android/redroid-doc/blob/master/deploy/wsl.md).

## Presentation work after rendering

The existing scrcpy transport still performs Android video encoding even if its Windows decoder uses the GPU. Hardware GLES alone will not remove that encoding bottleneck. Waydroid's Wayland/multiwindow route is worth prototyping for this separate reason. WSLg's VAIL path uses shared memory across the VM boundary, so it can avoid an Android H.264 stream, although it does not promise zero-copy scanout or 120 FPS on this host. [WSLg architecture](https://devblogs.microsoft.com/commandline/wslg-architecture/).

The acceptance target is a complete app-to-screen path with measured cadence and lower resource cost. Neither an installed WSL backend, a 120 Hz virtual display, nor a GPU renderer string alone satisfies that target.

## Installed WSL 3.0.3 kernel prerequisites: offline verification

The installed version report identifies WSL `3.0.3.0`, kernel package `6.18.54.1-1`, and WSLg `1.0.79`. The matching official kernel tag `linux-msft-wsl-6.18.54.1` resolves to commit `d504d40ab83839cb61942a812a99d183c42227b9`. WSL 3.0.3's release notes identify that kernel update. [WSL release](https://github.com/microsoft/WSL/releases/tag/3.0.3), [kernel release](https://github.com/microsoft/WSL2-Linux-Kernel/releases/tag/linux-msft-wsl-6.18.54.1).

The actual installed `C:\Program Files\WSL\tools\kernel` was read without booting or mounting anything. Its SHA256 is `3d2881b97ad864ceeacaa4acd3637da61bf92152a9188623ef0ffb133da9dbbd`. Decompressing its embedded `IKCFG_ST`/`IKCFG_ED` configuration confirmed:

| Setting | Installed value | Consequence |
|---|---|---|
| `CONFIG_ANDROID_BINDER_IPC` | unset | Binder is absent from the stock kernel |
| `CONFIG_DXGKRNL` | `y` | WSL GPU kernel bridge is compiled in; driver/rendering still need testing |
| `CONFIG_DMABUF_HEAPS`, `CONFIG_DMABUF_HEAPS_SYSTEM` | `y` | System DMA-buffer heap support is compiled in |
| `CONFIG_MEMFD_CREATE`, `CONFIG_SHMEM` | `y` | memfd/shared-memory primitives are available |
| `CONFIG_MODULES` | `y` | External modules can be supported |
| `CONFIG_MODVERSIONS` | `y` | Matching symbol CRCs are required |
| `CONFIG_MODULE_SIG` | unset | Kernel config does not enforce signed modules |
| `CONFIG_KPROBES`, `CONFIG_KALLSYMS` | `y` | Prerequisites for the existing ashmem source's symbol resolver are compiled in |
| `CONFIG_IKHEADERS` | `m` | Header archive is packaged as `kheaders.ko` |

These settings also match the [official ARM64 configuration at the pinned revision](https://github.com/microsoft/WSL2-Linux-Kernel/blob/d504d40ab83839cb61942a812a99d183c42227b9/arch/arm64/configs/config-wsl-arm64).

Read-only parsing of the installed `tools\artifacts.vhd` ext4 contents confirmed no Binder or ashmem module. Its directory is `6.18.54.1-microsoft-standard-WSL2`, which is the kernel release name expected after boot; the package's `-1` is not part of that directory name. The packaged `linux-headers` tree contains userspace headers, not a complete Kbuild tree. `kheaders.ko` embeds generated headers, including `autoconf.h`, but neither package tree contains `Module.symvers`, a Kbuild Makefile or `scripts/mod/modpost`. Thus it is not enough to point the existing ashmem Makefile at this header directory. Linux's build documentation also explains that `modules_prepare` does not generate symbol CRCs when module versioning is enabled. [External module build requirements](https://docs.kernel.org/kbuild/modules.html).

### Binder is the larger kernel blocker

In this exact kernel, `ANDROID_BINDER_IPC` is a **boolean**, not a tristate. The upstream Android Makefile builds Binder's component objects directly; it does not expose the old ordinary `binder_linux.ko` target. Therefore, enabling `CONFIG_ANDROID_BINDER_IPC=m` is not a supported module-only fix on this revision. A custom ARM64 WSL kernel with Binder/BinderFS enabled is the direct source-supported route. Retaining the stock kernel requires a separately maintained and validated external Binder port/backport, including exported-symbol and initialization compatibility. That has not been implemented or tested here. [Pinned Binder Kconfig](https://github.com/microsoft/WSL2-Linux-Kernel/blob/d504d40ab83839cb61942a812a99d183c42227b9/drivers/android/Kconfig), [pinned Binder Makefile](https://github.com/microsoft/WSL2-Linux-Kernel/blob/d504d40ab83839cb61942a812a99d183c42227b9/drivers/android/Makefile).

### Smallest ashmem route without replacing the kernel

The project's existing ashmem source lock pins `remote-android/redroid-modules` revision `f55e1e7515a6dd5f8e0f9569ea79148c08f60816`; its Makefile builds an external `ashmem_linux.ko`. The upstream proposal includes modern shrinker/VMA API fixes and a kprobe-based resolver, and reports tests on Linux 6.17. The project previously built it successfully for Ubuntu ARM64 6.8. That existing binary is **not** compatible evidence for WSL 6.18.54.1. [Source Makefile](https://github.com/remote-android/redroid-modules/blob/f55e1e7515a6dd5f8e0f9569ea79148c08f60816/ashmem/Makefile), [upstream compatibility proposal](https://github.com/remote-android/redroid-modules/pull/23).

The minimum module-only attempt is to obtain a prepared build tree and `Module.symvers` matching the stock ARM64 WSL kernel, build only this external ashmem module, and load it inside WSL. If matching build artifacts cannot be obtained, reproducing the official kernel build can generate them without deploying the rebuilt kernel. Do not force-load the old module or bypass version checks. This avoids changing `.wslconfig` for ashmem, but does not solve the independent Binder blocker.

The pinned Android 16 Redroid image still requires `/dev/ashmem` for its software gralloc despite `androidboot.use_memfd=1`; that is established by this project's earlier boot failure/recovery and the corresponding upstream diagnosis. Replacing the software allocator with a verified memfd/DMA-buffer implementation could remove this image dependency, but is additional Android work, not a boot argument. [Redroid gralloc diagnosis](https://github.com/remote-android/redroid-doc/issues/934).

No WSL boot, module loading, custom kernel build or global WSL configuration change was performed by this offline audit. First startup remains pending the host reboot reported by the implementation workflow.
