# SPARKDROID upstream feasibility

Research date: 2026-10-22 (America/Los_Angeles). Upstream support and measured host capability are separate evidence. No Android boot or GPU result is inferred from documentation.

Implementation addendum: Android 16 subsequently reached `sys.boot_completed=1` in the native WHPX Ubuntu ARM64 VM. Its initial SurfaceFlinger crash was repaired by compiling and loading the small ARM64 ashmem kernel module described below. This establishes a working software-rendered framework; graphics experiments and APK acceptance are recorded separately by the main implementation work.

## Decision

Use a native Windows ARM64 QEMU 11 virtual machine with WHPX, initially hosting Ubuntu ARM64 and an ARM64 Redroid Android container. This is one hardware virtual machine plus a Linux container; it needs no nested hypervisor. It preserves native ARM64 CPU execution if the WHPX guest boot succeeds. Use explicit software graphics until a complete accelerated guest-to-Windows pipeline passes validation. A direct AOSP guest remains the longer-term path.

The native ARM64 WHP probe in `artifacts/host/whp-probe.json` returned `HypervisorPresent=1`, successful `WHvGetCapability`, and successful `WHvCreatePartition`. These effective API results supersede conflicting optional-feature inventory. They establish partition creation, not a successful virtual processor or guest boot. No host features were enabled by this research.

## Architecture matrix

| Approach | Upstream basis | Main integration work or blocker | Assessment |
|---|---|---|---|
| AOSP ARM64 hardware VM | WHP supports ARM64; QEMU 11 supports ARM64 WHPX | Build a compatible kernel, vendor HALs, boot storage, graphics transport and host services | Strong long-term architecture; guest port required |
| WSA-derived runtime | Public WSA Linux kernel source includes ARM64 configurations | Public issue tracker and kernel source do not provide a complete rebuildable Windows integration layer | Do not depend on unavailable proprietary WSA binaries |
| Android container in an ARM64 Linux VM | Redroid supports ARM64 Android 16; Linux supplies Binder and memfd | Linux guest provision, ADB/display transport, graphics integration | Closest practical prebuilt fallback |
| Custom minimal guest/VMM | Direct WHP API provides partitions and vCPUs | Implement device model, GIC, timers, storage, network, Android vendor/HAL integration | Higher maintenance than QEMU; no performance claim |
| Google Android Emulator | Google supplies Windows x64 emulator archive | Official Windows ARM CPU support is absent; Goldfish/Ranchu images require its device model | Not a supported native Windows ARM64 solution |
| Native Windows container/compatibility layer | Android needs Linux kernel interfaces | Linux Binder/syscall ABI is not supplied by an ordinary Windows process container | No demonstrated native Windows implementation |

## Native Windows ARM64 virtualization

Microsoft documents ARM64 `WHvCreatePartition` from Windows 11 24H2 build 26100.3915. QEMU documents ARM64 WHPX on the April/May 2025 Windows updates or newer, with `-M virt -accel whpx -cpu host`. The host build reported by discovery is newer, and the probe above succeeded. QEMU must itself be native ARM64; a QEMU executable running through Windows x64 translation is not evidence of native ARM64 virtualization. [Microsoft API requirements](https://learn.microsoft.com/en-us/virtualization/api/hypervisor-platform/funcs/whvcreatepartition), [QEMU WHPX documentation](https://www.qemu.org/docs/master/system/whpx.html).

Pinned upstream source: `https://github.com/qemu/qemu.git`, tag `v11.0.0`, peeled commit `98b060da3a4f92b2a994ead5b16a87e783baf77c`, resolved with `git ls-remote`. ARM64 WHPX implementation exists at `target/arm/whpx/whpx-all.c` in this revision. Do not assume older Windows QEMU packages contain that backend. [Pinned WHPX source](https://github.com/qemu/qemu/blob/98b060da3a4f92b2a994ead5b16a87e783baf77c/target/arm/whpx/whpx-all.c), [versioned QEMU 11 documentation](https://qemu.readthedocs.io/en/v11.0.0/system/whpx.html).

## Android image acquisition and build paths

### Practical prebuilt fallback

Ubuntu publishes a bootable ARM64 QCOW2/GPT image, `noble-server-cloudimg-arm64.img`, and SHA256SUMS at its [official cloud image directory](https://cloud-images.ubuntu.com/noble/current/). Copy or overlay the image inside the workspace, expand the guest disk to at least 16 GiB (32 GiB preferred), supply a NoCloud seed, and boot with ARM64 UEFI. Preserve the base image and its verified hash.

`guest/provision-redroid.sh` installs Docker and the running Ubuntu kernel's Binder module, starts a persistent Android container, explicitly selects memfd and software rendering, and records boot status. Official Redroid supports both ARM64 and AMD64, Android 16, persistent `/data`, ADB, and a guest software-rendering mode. [Redroid upstream](https://github.com/remote-android/redroid-doc), [Ubuntu deployment recipe](https://github.com/remote-android/redroid-doc/blob/master/deploy/ubuntu.md).

Actual Ubuntu 6.8 behavior required mounting BinderFS before the Binder nodes appeared. The provisioning script now installs a boot service for that mount. Android 16's software gralloc also requires `/dev/ashmem` despite the memfd option: without it, SurfaceFlinger repeatedly aborted with `output buffer not gpu writeable`. The upstream issue's eventual diagnosis matches this observation. [Redroid issue 934](https://github.com/remote-android/redroid-doc/issues/934).

SPARKDROID compiled `ashmem_linux.ko` for `6.8.0-147-generic aarch64`, using pinned Redroid module PR 23 revision `f55e1e7515a6dd5f8e0f9569ea79148c08f60816`. This is an open upstream-proposed kernel compatibility change, not a merged release. Loading it restored SurfaceFlinger and framework boot without any Android binary patch. The source, archive hash, compiled module hash and evidence are retained in `upstream/redroid-modules.lock.json` and `artifacts/guest/`. The module is installed only in the disposable Linux guest. [Module compatibility change](https://github.com/remote-android/redroid-modules/pull/23).

`guest/set-graphics.sh` can explicitly switch `guest`/`host` graphics by recreating only the named Android container while preserving its bind-mounted data. A requested host mode fails before stopping Android if the specified DRM render device is absent. There is no automatic graphics fallback.

Registry metadata was resolved directly from Docker Hub on this research date:

| Artifact | Digest |
|---|---|
| `redroid/redroid:16.0.0_64only-latest` multiarch index | `sha256:7b1e389bd15f37af3bcd06138f5b2ffa7cfba4332bd5ef54c53e99c2f160a15b` |
| Android 16 Linux ARM64 image manifest, used by provisioning | `sha256:e194edc99aa364358d1f8c214acb18b6d006c74fa0561f39259a20173ec30b66` |
| Android 16 image configuration, reports `architecture=arm64` | `sha256:59300630a8ac2cb4ad2105703ce92e92eb7a001eaac5f12624424e610199759f` |
| Android 16 compressed root layer (733,630,886 bytes) | `sha256:efbc1c6b9440932189927a386ba3fc991f8a6b88bb8f56f1fd9b26ee8d7475b6` |
| Android 15 fallback ARM64 manifest | `sha256:dc2024a999dd0acb1112a23cddc9537ec8cb60a0dbe5a87ce9fbd75a2f5e94d2` |

The Docker registry API endpoint is `https://registry-1.docker.io/v2/redroid/redroid/manifests/<tag-or-digest>`; public pull authorization uses `https://auth.docker.io/token?service=registry.docker.io&scope=repository:redroid/redroid:pull`. No credentials or access tokens are saved in this document. Pinning a prebuilt Redroid image does not mean SPARKDROID has compiled AOSP.

### Direct AOSP/Cuttlefish development

The supported AOSP build environment is x86-64 Linux with approximately 400 GB free space and at least 64 GB RAM. Building ARM64 targets does not mean Google's entire host build-tool set supports ARM64 Windows. Use a suitably provisioned Linux build machine for a reproducible custom image. Resolve a branch to a manifest revision and save `repo manifest -r` after sync. [AOSP build requirements](https://source.android.com/docs/setup/start/requirements).

Cuttlefish publishes ARM64 images at [Android CI](https://ci.android.com/) for `aosp_cf_arm64_only_phone-userdebug`; images and `cvd-host_package.tar.gz` must come from the same build. Its documented hosts are Linux x86 and ARM64 with KVM. [Cuttlefish quick start](https://source.android.com/docs/devices/cuttlefish/get-started), [Cuttlefish overview](https://source.android.com/docs/devices/cuttlefish).

These are not standalone generic QEMU disks. Android 16's QEMU manager selects `virt`, an assembled boot disk, U-Boot, ordered virtio consoles, and host Keymaster/Gatekeeper/KeyMint services. The code only selects KVM on Linux or HVF on Apple hosts, with a compile-time error otherwise. Porting it to Windows requires those services and storage/boot assembly, in addition to selecting WHPX. Google Emulator images similarly depend on Goldfish/Ranchu devices absent from plain upstream QEMU. [AOSP QEMU device setup](https://android.googlesource.com/device/google/cuttlefish/+/refs/heads/android16-release/host/libs/vm_manager/qemu_manager.cpp), [dynamic-partition fstab](https://android.googlesource.com/device/google/cuttlefish/+/refs/heads/android16-release/shared/config/fstab.in).

Resolved manifest branch heads: `android-latest-release` = `ad156f32caaa06dae91c02d443f6a8fe210eaa54`, `android16-release` = `0a0240e222ce92dbf782219f3fc473137b3dd59c`, `android17-release` = `29ace668ae756c7b8917c57abb440f6518844b0c`. The similarly named `aosp-android-latest-release` is a CI branch label in documentation and did not resolve as a manifest Git branch in this check. Source acquisition must resolve actual available refs instead of assuming label equivalence.

For a custom Redroid build, `guest/build-android.sh` uses AOSP tag `android-16.0.0_r2` (manifest commit `6650f1e0458a5450156c0348fe0dc96acb958eb8`) plus the pinned component revisions in `upstream/aosp/sparkdroid-redroid16.xml` and acquired Android 16 Redroid patches. The exact product declaration supports `redroid_arm64_only-bp2a-userdebug`. This custom-source baseline was acquired as metadata/patches; the full AOSP tree was not synced or compiled, and it is not claimed to reproduce the prebuilt image byte-for-byte. [Redroid product definitions](https://github.com/remote-android/device_redroid/blob/f12358e83fef301eee116d7e1d3d4f54e75ec237/AndroidProducts.mk), [upstream build procedure](https://github.com/remote-android/redroid-doc/tree/master/android-builder-docker).

## Graphics pipelines and limits

| Pipeline | What upstream provides | SPARKDROID status |
|---|---|---|
| QEMU virtio-gpu 2D | Display controller; guest must render 3D in software | Explicit fallback candidate; not GPU acceleration |
| VirGL | Guest GL command serialization through host virglrenderer | Linux guest EGL test reported success through Windows ANGLE; Android graphics integration must be validated separately |
| Venus | Vulkan transport using virtio-gpu, host Vulkan and external-memory features | Mesa's current renderer requirements describe Linux/Android hosts, not Windows; not a drop-in DirectX bridge |
| Gfxstream + ANGLE | Guest GLES/Vulkan streaming, potential host API translation | Plausible custom Windows development path; end-to-end ARM64 composition/transport remains unproven |
| NVIDIA passthrough/GPU partitioning | Requires a compatible host assignment API and Android/Linux driver stack | No applicable working guest path demonstrated |
| WSLg | Linux GUI forwarding and vGPU driver path | Does not itself supply Android HALs, Binder or a validated nested Android GPU transport |

QEMU distinguishes its default software 2D backend from VirGL and rutabaga accelerators, including experimental Android Gfxstream capability sets. [QEMU virtio-gpu](https://www.qemu.org/docs/master/system/devices/virtio/virtio-gpu.html). Mesa documents Venus host external-memory requirements and guest kernel requirements; its NVIDIA version references concern the Linux driver and do not prove Windows support. [Mesa Venus requirements](https://docs.mesa3d.org/drivers/venus.html).

Google's Gfxstream repository includes a Windows build recipe explicitly selecting `-A x64`; that is useful source, not evidence that Windows ARM64 runs this pipeline unchanged. [Gfxstream source and Windows recipe](https://github.com/google/gfxstream). Cuttlefish's accelerated modes require suitable EGL/GLES/Vulkan host drivers; its SwiftShader mode is software. [Cuttlefish graphics](https://source.android.com/docs/devices/cuttlefish/gpu). WSLg also requires a compatible vGPU driver. [Microsoft WSL GUI support](https://learn.microsoft.com/en-us/windows/wsl/tutorials/gui-apps).

ANGLE translates graphics APIs; it does not provide a guest-to-host transport, Android Hardware Composer, shared DMA buffer import, or GPU assignment by itself. Scrcpy decodes a rendered Android video stream on Windows; host video decode/presentation activity does not demonstrate Android GPU rendering.

## WSA and official emulator availability

Microsoft removed WSA/Amazon Appstore availability from its Store on March 5, 2025. Its [WSA repository](https://github.com/microsoft/WSA) is an archived issue/documentation repository. Public [WSA Linux kernel source](https://github.com/microsoft/WSA-Linux-Kernel) includes ARM64 build configurations, but is only the kernel component. These facts do not establish rights to redistribute a proprietary WSA host package or constitute a complete open-source replacement. [Microsoft retirement notice](https://support.microsoft.com/en-us/windows/privacy/privacy-with-windows-subsystem-for-android-and-amazon-appstore).

Google's current Windows installation page explicitly excludes ARM-based CPUs. The SDK repository XML supplied stable Android Emulator 37.2.12, build 16428233, with a Windows x64 archive and no Windows ARM64 archive. [Official supported hosts](https://developer.android.com/studio/install), [official SDK package metadata](https://dl.google.com/android/repository/repository2-3.xml).

## Integration, audio and validation

Use QEMU user networking with `hostfwd=tcp:127.0.0.1:5555-:5555`; Android's Docker port is reachable on the guest NIC. Do not bind the Windows ADB listener to external interfaces. Scrcpy can provide keyboard/mouse control, clipboard, output audio and resizable app windows, but these features still require runtime validation.

Scrcpy supports audio capture on Android 11+ and documents Android 12+ as working without the Android 11 unlock workaround. Use `--require-audio` during acceptance so audio failure is visible. `--audio-source=mic` captures the guest microphone toward Windows; it does not inject the Windows microphone into Android. [Scrcpy audio documentation](https://github.com/Genymobile/scrcpy/blob/master/doc/audio.md). `--new-display=1280x720 --start-app=<package>` can launch an application in its own virtual-display window on supported guests. [Scrcpy app/display controls](https://github.com/Genymobile/scrcpy/blob/master/doc/device.md).

Waydroid also requires Binder and ashmem or memfd support; it cannot run as an ordinary Windows process. Its VM guidance documents software-rendering overrides for unsupported GPUs and virtio-gpu acceleration prerequisites. [Kernel requirements](https://docs.waydro.id/debugging/getting-essential-information), [Waydroid VM guidance](https://docs.waydro.id/faq/get-waydroid-to-work-through-a-vm).

Acceptance must record actual WHPX guest execution, `sys.boot_completed=1`, `arm64-v8a`, an ARM64 native-library APK launch, Android network reachability, audible output, input interaction, renderer evidence, persistence after restart and clean guest shutdown. CPU speed, power, audio latency, memory sharing, suspend behavior, app compatibility and graphics acceleration have no measured result in this research document. Read the later experiment logs for their actual state.
