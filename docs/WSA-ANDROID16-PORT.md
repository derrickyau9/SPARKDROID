# Android 16 on the WSA ARM64 host

Status: **Research only; implementation deferred.** Android 13 is the currently verified WSA version; see [runtime status](WSA-ANDROID13.md).

Research date: 2026-10-23. This proposal targets **an Android 16 guest using the existing native ARM64 WSA Windows host**, including its app-window and hardware graphics integration. The first milestone would be Android 16 boot plus ADB; individual app windows, GPU frames, media and 120 Hz presentation would follow as separate acceptance milestones. An Android 16 WSA boot has not been verified.

## Chosen architecture

Retain the packaged WSA Windows service/client and its initial VM/graphics transport. Build Android 16 system components, then port the WSA guest-specific integration across the framework boundary. This starts from the host that already implements Windows app integration, rather than rebuilding the Windows UI and graphics bridge first.

```text
WsaService.exe + packaged WSL VM support
  └─ existing WSA ARM64 kernel + mini_init handoff
       └─ Android 16 init / framework / ART / system services
            ├─ ported WSA guest integration and HALs
            ├─ guest graphics client → existing gfxstream host
            └─ app surfaces → WsaClient.exe → Windows composition
```

Microsoft's kernel-team presentation describes WsaService as the VM manager and WsaClient as the adapter that presents Android surfaces as Win32 HWNDs through Windows.UI.Composition and D3D. It also describes minimizing changes to the AOSP framework. This supports retaining the original host as the first porting boundary; it does not establish that its guest interfaces are stable across Android versions. [Microsoft WSA architecture presentation, pages 2 and 4](https://static.sched.com/hosted_files/ossna2023/bb/WSA%20and%20WSL%20presentation.pdf).

## Verified inputs

The local baseline is `tools/wsabuilds/LTS8-arm64/WSA_2407.40000.4.0_arm64`, from ARM64 LTS8 published September 4, 2026. The release explicitly identifies Android 13. Keep that baseline intact and build experimental images separately. [Release](https://github.com/MustardChef/WSABuilds/releases/tag/Windows_11_2407.40000.4.0_LTS_8_arm64).

Read-only inspection of the extracted package found:

| Component | Observed fact | Porting implication |
|---|---|---|
| `WsaService/WsaService.exe`, `WsaClient/WsaClient.exe` | PE machine `0xaa64` | Native ARM64 host binaries are available |
| `gfxstream_backend.dll`, `libEGL.dll`, `libGLESv2.dll`, `vulkan_dzn.dll`, `vulkan-1.dll` | All PE machine `0xaa64` | Both the host GLES/ANGLE and Dozen/Vulkan libraries have ARM64 builds |
| `libGLESv2.dll` | File version `2.1.9690 git hash: 60c4b8810bdc` | Record this original graphics dependency, rather than silently updating it |
| `Tools/initrd.img` | Plain `newc` CPIO; one ELF64 `/init` of 1,950,240 bytes plus trailer | This is not a conventional AOSP ramdisk to replace wholesale |
| `/init` strings | `mini_init`, `InitEntryUtilityVm`, `/system/init`, `/systemvhd`, WSL message names | Preserve the original host/mini-init handoff while investigating the Android init entry point |
| Disk layout | Separate `system`, `system_ext`, `product`, `vendor`, `metadata`, `userdata` VHDX files | Image contents and mount semantics must be mapped before assembling a replacement |

The implementation workflow separately reports a successful Windows ANGLE D3D11 colored-pixel test on N1X. That establishes a useful host-rendering prerequisite; it does not establish a working Android graphics command stream, SurfaceFlinger or app window.

## Public source map

| Source | Reuse | Boundary to respect |
|---|---|---|
| [AOSP Android 16 r2 `aosp_arm64.mk`](https://android.googlesource.com/platform/build/+/android-16.0.0_r2/target/product/aosp_arm64.mk) | ARM64 system-as-root/GSI baseline with 64-bit Binder | Generic product, not a WSA device tree |
| [AOSP Android 16 r2 `generic_system_arm64.mk`](https://android.googlesource.com/platform/build/+/android-16.0.0_r2/target/product/generic_system_arm64.mk) | System-only bring-up artifact; explicitly disables vendor/product/system_ext/ramdisk image generation | Retaining the Android 13 extensions is a test, not a compatibility guarantee |
| [Microsoft WSA Linux kernel](https://github.com/microsoft/WSA-Linux-Kernel) | Kernel source, WSA device support and configuration reference | Match the packaged kernel/config before rebuilding; latest public branch need not reproduce the packaged kernel |
| [Microsoft WSL mini_init documentation](https://github.com/microsoft/WSL/blob/master/doc/docs/technical-documentation/mini_init.md), [message definitions](https://github.com/microsoft/WSL/blob/master/src/shared/inc/lxinitshared.h), [launch code](https://github.com/microsoft/WSL/blob/master/src/linux/init/main.cpp) | Public reference for host hvsockets, disk mounting and `LxMiniInitMessageLaunchInit` | Current public WSL is a protocol reference, not proof of binary compatibility with the packaged WSA host |
| [LSPosed MagiskOnWSALocal build script](https://github.com/LSPosed/MagiskOnWSALocal/blob/main/scripts/build.sh) | Demonstrates preserving the WSA mini-init while adding a boot-time layer; its Magisk path renames `/init` to `/wsainit` and chains another entry point | Packaging/initrd modification, not an Android framework/device-tree port; repository includes prebuilt `lspinit` |
| [AOSP Android 16 Gfxstream](https://android.googlesource.com/platform/hardware/google/gfxstream/+/refs/tags/android-16.0.0_r2) | Public guest/host graphics streaming implementation and transports; pinned tag resolves to commit `fc0dca02291e1d5ba1d2dad1d0b58b4f2ef255d0` | Do not assume the current guest protocol is compatible with WSA's older/custom host DLL |
| [Snickler ARM64 guest-image patch](https://github.com/snickler/WSA-Patched/releases/tag/0.0.2), [author's component notes](https://github.com/MustardChef/WSABuilds/issues/325#issuecomment-2246488353) | Evidence that replacing ARM32 guest components with ARM64 variants can advance WSA boot on newer CPUs | Android 13 experiment with reported media failures; not a reusable Android 16 device tree |

The checked public repositories do not provide a complete WSA Android device tree. WSABuilds' Android 14 port is relevant evidence that guest modernization is possible, but its maintainer states that the device tree and associated components remain closed source. Its Android 16 request calls for incremental upgrades. This means the missing guest integration needs to be reconstructed or replaced in this project, not that an Android 16 port is impossible. [Android 14 work](https://github.com/MustardChef/WSABuilds/issues/700), [source-availability statement](https://github.com/MustardChef/WSABuilds/issues/700#issuecomment-6000598148), [Android 16 request](https://github.com/MustardChef/WSABuilds/issues/688#issuecomment-3735179384).

## Interfaces to extract and preserve

The image inventory should produce a machine-readable record of each candidate blob, partition/path, architecture, hash, imported libraries and service/interface identity. This avoids treating the entire Android 13 root filesystem as an indivisible dependency.

| Boundary | Required inventory | First validation |
|---|---|---|
| Host → guest boot | Mini-init arguments/messages; `/system/init`; fstab; actual disk order/labels; init imports; uevent rules; boot properties | Android 16 init logs and stable ADB connection |
| Framework ↔ vendor | Vendor and framework VINTF manifests/matrices, HAL versions, vendor API/VNDK level, linker namespaces, ELF `DT_NEEDED` | HALs register; no unresolved native symbols or manifest incompatibilities |
| Framework ↔ WSA extensions | `system_ext` framework JAR/APK/native libraries, bootclasspath/system-server additions, permissions, overlays, Binder service descriptors | Zygote and system_server remain alive; Windows bridge services connect |
| Graphics transport | EGL/GLES/Vulkan guest modules, gralloc/allocator/mapper/composer services, gfxstream feature/protocol negotiation, device nodes and virtio channels | Colored pixels through the guest path, then a nonblack Android app window |
| Security policy | `plat`, `vendor`, `system_ext`, `product` CIL; mapping files; file/property/service contexts | Policy compiles and required services start with intended labels |
| ARM64-only execution | Every executable started by init and every library in its dependency closure | No required ARM32 executable/library is left on the 64-bit-only path |
| Media and peripherals | Codec/OMX/Codec2, audio, input, camera, clipboard/files/network bridge services | Playback, input and clipboard tested independently after boot |

These are investigation targets, not claims that every interface already has a known failure.

## The system_ext compatibility trap

Treble's vendor boundary does not make old `system_ext` code universally compatible with a new framework. AOSP explicitly permits private calls between `system` and `system_ext`; these partitions are intended to upgrade together. A generic GSI may also omit the OEM `system_ext`/`product` partitions, which could remove the Windows integration being preserved. Therefore the system-only Android 16 build is the **first boot experiment**. The eventual device product needs its own Android 16-compatible WSA extensions or deliberate compatibility shims for the retained components. [AOSP shared-system-image design](https://source.android.com/docs/core/architecture/partitions/shared-system-image), [GSI and partition policy caveat](https://source.android.com/docs/security/features/selinux/customize).

VINTF checks framework/vendor capabilities and requirements at build, boot and update time. SELinux has separate platform/vendor and OEM extension mapping obligations. Keep the compatibility data explicit; do not confuse suppressing a check with establishing a working interface. [VINTF match rules](https://source.android.com/docs/core/architecture/vintf/match-rules), [SELinux compatibility](https://source.android.com/docs/security/features/selinux/compatibility).

## Build and bring-up sequence

1. Preserve and hash the ARM64 WSA baseline. Extract disk contents offline and record the interfaces above. Keep the original kernel, mini-init and Windows graphics libraries for the first attempt.
2. Produce a pinned Android 16 ARM64 system image on the supported Linux build host. Verify the image's Android version, ELF architecture and init layout. A successful source build is not a successful WSA boot.
3. Assemble a separate experimental VHDX with the Android 16 system and the required WSA boot entry point. Preserve mount/partition semantics and use separate test userdata. Port only the integration required for init, storage, ADB, Binder and framework startup first.
4. Boot through the original WSA host after any required Windows reboot. Capture host diagnostics, kernel/init log, logcat and tombstones. Milestone one requires working ADB, Android 16 properties, ARM64 execution, stable zygote/system_server and `sys.boot_completed=1`.
5. Bring up the native app-window bridge and guest graphics transport. Keep failures separated into transport, gralloc/HWC, renderer and Windows presentation. Prove a nonblack hardware-rendered Android window before changing refresh settings.
6. Add audio/video and other integration, then measure app-to-screen cadence at 120 Hz. Retain the earlier working image after each completed milestone.

This proposal is based on source, metadata and binary inspection. A full AOSP build and an Android 16 WSA boot remain unverified.
