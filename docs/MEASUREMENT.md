# Reproducible observations

Use PowerShell 7 from the project root. The measurement script observes the running managed QEMU process; it does not start, stop, or reconfigure the VM.

```powershell
# The label describes the workload you have actually arranged.
./scripts/Measure-Runtime.ps1 -Seconds 60 -Label 'Android home screen, no foreground apps'

# Optional three process-cold launch trials follow the observation window.
./scripts/Measure-Runtime.ps1 -Seconds 30 -Package com.example.app -Label 'home screen before launch trials'

# Stop the runtime first. Baseline refuses to run if its QEMU binary is active.
./scripts/Measure-Runtime.ps1 -Mode Baseline -Seconds 60 -Label 'runtime stopped, host workload unchanged'
```

Each run creates a timestamped directory in `artifacts/benchmarks` containing `measurement.json`, `host-samples.csv`, GPU and battery CSV files when available, and raw command output. The JSON records the caller's workload label, actual elapsed observation time, architecture, VM process identity, configured profile, Android readiness, diagnostics, optional launch trials and limitations. A label does not prove the workload was idle.

Run `./scripts/Test-Measurement.ps1 -ReportPath <path/to/measurement.json>` to verify sample/CSV consistency, CPU normalization, elapsed intervals, raw evidence presence and honest power/launch status fields. Baseline reports are marked invalid if the configured QEMU executable appears during a sampled interval.

QEMU CPU usage uses differences in process CPU seconds divided by actual wall time. `vmCpuPercentOneCore` can exceed 100%; 100% means one fully occupied core. `vmCpuPercentWholeMachine` divides that value by the host's detected logical processor count. `windowAverageVmCpuPercent*` uses the entire observation window. Working set and private bytes are host process metrics, not a direct measure of guest Android memory. Host CPU uses Windows `GetSystemTimes`; measurements above 64 logical processors require checking processor-group accounting before interpreting the result. No process CPU value proves near-native Android performance.

`nvidia-smi` sensor readings are recorded per device, including device names. Device Watts measure the sensor's device domain; they do not measure whole-system idle power or isolate Android's share. The script can perturb the very power and wakeup behavior under observation. Compare matched runs, allow thermal and provisioning activity to settle, preserve brightness/network/power conditions, and use an external calibrated power meter for system idle/active power. `systemPowerWatts` remains null. WMI raw battery discharge rate remains null on AC or while charging; it is not converted to Watts because Windows permits relative-capacity battery reporting and that capability has not been independently verified here. See [Microsoft's battery status specification](https://learn.microsoft.com/en-us/windows/win32/power/battery-status-str) and [NVIDIA's sensor documentation](https://docs.nvidia.com/deploy/nvidia-smi/).

Android diagnostics are bounded captures of `getprop`, `uname`, `dumpsys meminfo`, `dumpsys cpuinfo`, `dumpsys SurfaceFlinger`, and app `gfxinfo framestats` when a package is supplied. Renderer evidence remains raw; the script does not declare GPU acceleration from a device name or configuration flag. A VM observation made while Android is unready is explicitly marked as such. Raw framestats are preserved without inventing FPS, latency or wakeup estimates.

The optional three launch trials resolve the package's launchable activity, force-stop the application, and run `am start -W`. They preserve application data and host/guest caches. `LaunchState`, `ThisTime`, `TotalTime`, `WaitTime`, command exit status and ADB wall time are recorded as available; these are process-cold launch observations, not a claim that disk/ART caches were cold. Trials and diagnostics run outside the host sample window. Benchmarking an application can alter its visible UI and foreground state.

For useful comparisons, run a stopped-runtime baseline and each configured profile with the same workload and duration, repeat trials, and retain all raw evidence. Boot reliability, networking/audio/input, application compatibility, battery drain, frame pacing, whole-system power and background wakeups require their own controlled acceptance tests. Successful instrumentation alone does not satisfy those acceptance criteria.
