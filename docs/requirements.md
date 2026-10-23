# SPARKDROID engineering requirements

SPARKDROID targets Android applications running inside Windows 11 ARM64 on
NVIDIA RTX Spark (N1X), with individual Windows app windows and persistent data.
The requirements below describe project goals. Verified behavior and remaining
limitations are recorded in [the project overview](../README.md),
[runtime results](RESULTS.md) and [WSA Android 13 status](WSA-ANDROID13.md).

## Execution and architecture

- Native ARM64 application execution through hardware virtualization where available.
- Windows remains the host operating system, with its installation and data preserved.
- Architecture selection accounts for Android compatibility, graphics support,
  memory use, startup latency, power consumption and maintenance cost.
- Runtime configuration identifies the Android version, kernel, supported ABIs,
  hypervisor and rendering backend.
- Builds and packages use pinned dependencies, automated scripts and recorded provenance.

## Graphics and performance

- Hardware-backed Android rendering through supported Windows ARM64 GPU interfaces.
- Explicit reporting of software rendering and graphics compatibility failures.
- Low frame latency, consistent pacing and a 120 Hz presentation target on capable displays.
- Separate measurements of Android draw callbacks, guest display modes and Windows presentation.
- Reduced memory duplication, background wakeups and idle CPU/GPU activity.
- Performance, Balanced and Ultra Efficient profiles, with measured resource and power behavior.
- Standard Android API compatibility retained during optimization.

## Applications and Windows integration

- APK and split APK installation, ABI checks, ADB access and application management.
- Independent, resizable app windows and per-app desktop shortcuts.
- Runtime start, stop, suspend and resume controls with persistent application data.
- Keyboard, mouse, touch, clipboard and shared-file integration.
- Networking, audio, microphone, camera and location support where the host interfaces permit.
- Android permissions, notifications, deep links and background services.
- Chinese fonts, input methods and application compatibility documented per tested version.
- Proprietary services, device attestation and unsupported ABIs recorded as compatibility limits.

## Validation and deliverables

Acceptance requires repeatable Android boot and clean shutdown, a working ARM64
application, persistent data, and verified networking, audio and input. Graphics
acceleration requires evidence from the Android-to-Windows rendering path;
hardware availability alone is insufficient.

Measurements cover boot and application startup time, CPU and memory use, frame
rate and latency, background wakeups, idle and active power, and battery impact.
Each result records the configuration, workload and observation limits. Untested
features remain explicitly marked as unverified.

Deliverables include the Windows ARM64 launcher, runtime setup and build scripts,
APK installation workflow, compatibility matrix, performance and power reports,
and documentation of remaining limitations. Third-party images and binaries are
handled according to their own distribution terms.

Engineering priorities: ARM64 execution, application compatibility, GPU
acceleration, energy efficiency, then Windows integration.
