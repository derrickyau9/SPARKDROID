# Application compatibility evidence

This matrix distinguishes installation and initial launch from usable account workflows. A welcome screen does not validate messaging, payments, maps, push notifications, camera, microphone, DRM, device attestation or background reliability. No account login, registration, payment, or acceptance of application legal terms is part of these tests.

| Application | APK/version acquired | Installation / initial launch evidence | Remaining scope |
|---|---|---|---|
| VLC for Android | Official VideoLAN ARM64 3.7.1 | Installed; three successful `am start -W` process-cold trials reported `COLD`, TotalTime 399 / 472 / 464 ms. Separate native scrcpy app window opened. Generated 440/880 Hz audio played through Android, scrcpy and Windows output; digital loopback verified both frequencies. | Physical audibility unverified because the Windows output endpoint is muted at volume zero. Audio quality, latency, microphone and broader media formats remain untested. |
| WeChat / Weixin | Official Tencent ARM64 8.0.79, version code 3200 | Android package manager accepted installation. `com.tencent.mm/.ui.LauncherUI` reported `COLD`, TotalTime 430 ms; process remained alive and screenshot shows welcome screen with Log In / Sign Up and Chinese language control. | No button pressed. Login, messaging, calls, payments, mini programs, push and permission workflows untested. |
| QQ | Not acquired | Untested | No compatibility claim. |
| Alipay | Not acquired | Untested | Authentication, payments and attestation untested. |
| Taobao | Not acquired | Untested | No compatibility claim. |
| JD | Not acquired | Untested | No compatibility claim. |
| Douyin | Not acquired | Untested | Playback, capture, codecs and account workflows untested. |
| Bilibili | Not acquired | Untested | Playback, codecs, DRM and account workflows untested. |
| Xiaohongshu | Not acquired | Untested | No compatibility claim. |
| Meituan | Not acquired | Untested | Location, notifications and account workflows untested. |
| Amap | Not acquired | Untested | GPS/location bridge and map rendering untested. |
| Baidu Maps | Not acquired | Untested | GPS/location bridge and map rendering untested. |
| Chinese banking applications | No specific bank application selected | Untested | Device integrity, authentication, biometrics and financial workflows untested; no bypass attempted. |

The VLC launch evidence is in `artifacts/benchmarks/20261023T065252669Z-runtime-28fa02/measurement.json` and its raw trial output. These trials retain application data and filesystem/ART caches. Host observations include other development work and the opening of a scrcpy display; they are not a controlled speed comparison or idle-power test. SurfaceFlinger reported ANGLE with a SwiftShader Vulkan device, confirming software rendering for that observation.

## Tencent APK provenance

The [official Weixin website](https://weixin.qq.com/) was fetched over HTTPS and its embedded Android ARM64 download link was extracted directly. The selected [Tencent CDN APK](https://dldir1v6.qq.com/weixin/android/weixin8079android3200_0x28004f30_arm64_1.apk) downloaded with HTTP 200, successful TLS verification and no redirects. This records the exact official artifact observed during acquisition; it does not claim that a version remains current indefinitely.

- Local file: `artifacts/apks/WeChat-arm64.apk`, 285,284,760 bytes.
- SHA-256: `f2a725bc04302ad218a563533ae79356e66b64aa711b275bc919a8d432f7e15d`.
- Manifest: `com.tencent.mm`, version name 8.0.79, version code 3200, minimum SDK 24, target SDK 34.
- Native payload inventory: 194 actual ELF libraries all have ELF64/AArch64 headers; 15 `.so`-named payloads are opaque non-ELF data. Their architecture and protected behavior are unverified; no protection unpacking was attempted.
- APK Signature Scheme v2 block was observed and Android's package manager accepted installation. Signer identity has not been independently pinned beyond the official HTTPS source and matching acquisition hash.

Reproduction/provenance evidence: `artifacts/apks/weixin-official-source.json`, saved official-page HTML, transfer metadata/headers, `wechat.lock.json`, `wechat-inspection.json`, and `scripts/inspect-apk-payloads.py`. The inspector reads metadata and payload headers without executing the APK. The ordinary strict `inspect-test-apk.py` intentionally rejects opaque `.so` payloads; its rejection of this packed APK is not evidence that Android cannot install it.

The observed WeChat welcome screen and launch evidence are saved in `artifacts/compatibility/wechat-20261023T070739171Z/screen.png` and `result.json`. `scripts/Test-WeChatLaunch.ps1` reproduces the pinned-APK install and launch observation without sending input. Initial installation took 9.091 seconds; `am start -W` reported `Status: ok`, `LaunchState: COLD`, TotalTime 430 ms and WaitTime 434 ms (ADB wall time 509.868 ms). The main process was alive after the five-second wait. This is one launch observation with caches retained, not a statistical performance claim. UIAutomator could not obtain an idle state and produced no XML; the visible welcome-screen finding comes from the screenshot. The screenshot also shows Chinese text rendered in the language control; a Chinese keyboard/input workflow was not tested.

## Framework and integration scope

The selected runtime executes ARM64 guests using Windows hardware virtualization. Matching APK ELF headers and a booted ARM64 guest demonstrate an available instruction-set path; they do not establish every application's native code, anti-tamper framework or vendor dependency will work. No CPU speedup or universal compatibility is inferred.

Google Play Integrity, proprietary push transports, vendor frameworks, Widevine/DRM, hardware-backed keys and device attestation must be tested through supported application flows. This prototype does not provide attestations or modify applications to bypass those checks. Account-dependent functionality remains untested without an authorized account workflow.

Split APK sessions are supported by the install CLI and launcher workflow but have not yet been validated with a real split application. Chinese text is visible on the WeChat welcome screen and NotoSansCJK-Regular.ttc is present. A Chinese input method has not been exercised. Manual host/Android shared-file copies passed a SHA256 round trip; they are not a live shared mount. Android DNS/ICMP connectivity and ADB HOME-key injection passed. Touchscreen behavior, camera/microphone forwarding, real location providers, clipboard interoperability, deep links, Windows notifications and sustained background behavior remain unvalidated.

The installed WebView is com.android.webview 133.0.6943.137 and reports a valid/enabled provider. The guest reports security patch 2025-06-05, userdebug, ro.debuggable=1 and disabled SELinux. These are limitations of this experimental image. See `artifacts/acceptance/platform-details.txt`, `webview.txt`, `file-bridge.json`, `runtime-checks.json` and `audio-acceptance.json` for the actual evidence.
