This native Windows ARM64 helper opens only the default **render** endpoint with WASAPI loopback. It never enumerates or opens microphone endpoints. Capture has a hard ten-second maximum. Local WAV artifacts are private test evidence; they may contain any other sound playing on that endpoint during the bounded interval.

`scripts/Test-Audio.ps1 -PrepareOnly` compiles the helper and creates a deterministic PCM tone without recording or touching Android. Run the script without that flag only when the runtime is ready for its audio test. The script plays the tone in Android VLC and checks its alternating 440/880 Hz sequence in Windows output loopback. Success establishes digital playback routing, not physical speaker audibility or microphone integration.

The analyzer also accepts `analyze --input WAV --report JSON` for testing against generated signal and silence fixtures without opening an audio device.

Sources: [NAudio loopback API](https://github.com/naudio/NAudio/blob/release/2.x/Docs/WasapiLoopbackCapture.md), [NAudio 2.x loopback implementation](https://github.com/naudio/NAudio/blob/release/2.x/NAudio.Wasapi/WasapiLoopbackCapture.cs), [scrcpy audio forwarding](https://github.com/Genymobile/scrcpy/blob/master/doc/audio.md). Exact NuGet dependency versions and hashes are stored in `packages.lock.json`.
