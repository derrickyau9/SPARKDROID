# Component attribution

The MIT license at the repository root applies to original SPARKDROID source.
Third-party source, packages and dependencies retain their own licenses and
notices. Microsoft WSA and Android components are developed by their respective
upstream projects.

| Component / project | Use in SPARKDROID |
|---|---|
| Microsoft Windows Subsystem for Android; [WSA Linux kernel source](https://github.com/microsoft/WSA-Linux-Kernel) | Existing Windows host, kernel and Android integration. The full WSA stack has not been rebuilt from source by this project. |
| [MustardChef/WSABuilds](https://github.com/MustardChef/WSABuilds) | ARM64 Android 13 LTS8 base package, pinned in [the package record](upstream/wsabuilds-arm64.lock.json). |
| [snickler/WSA-Patched 0.0.2](https://github.com/snickler/WSA-Patched/releases/tag/0.0.2) | One inspected ARM64 audio-service executable, with local hashes and provenance in [the component record](upstream/wsa-audio-arm64.lock.json). The other patched partitions and bundled applications were not installed. No reproducible source-build or publisher-signature verification is claimed. |
| [Android Open Source Project](https://source.android.com/) | Android platform and architectural references. Component-specific AOSP licenses apply to any separately acquired sources. |
| [Redroid](https://github.com/remote-android/redroid-doc) | Prebuilt Android container used by the QEMU backend and planned WSL backend. Vendored module sources retain their notices and [license](upstream/redroid-modules/LICENSE). |
| [QEMU](https://www.qemu.org/) and Microsoft Windows Hypervisor Platform | ARM64 VM process and hardware virtualization used by the QEMU backend. |
| [scrcpy](https://github.com/Genymobile/scrcpy) | Individual app display/control client for the QEMU backend. |
| [Ubuntu](https://ubuntu.com/) and [Microsoft WSL](https://github.com/microsoft/WSL) | Linux guest/tool environments; WSL was also used for offline WSA ext4 checks. |

Source/version locks and setup scripts under `upstream/` and `scripts/` identify
additional dependencies. Downloaded binaries, Android APKs, WSA VHDX images,
user data, credentials and raw runtime diagnostics remain outside Git.
Published evidence reports contain observations and hashes, not redistributed
third-party executables or system images.

This is a community experiment developed and tested on NVIDIA RTX Spark N1X.
The project name describes the target hardware; it does not imply Microsoft,
NVIDIA, Google or the upstream maintainers endorse this work.
