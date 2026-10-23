using System.Diagnostics;
using System.Text.Json;
using NAudio.CoreAudioApi;
using NAudio.Wave;

static class Program
{
    static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    static async Task<int> Main(string[] args)
    {
        string? reportPath = null;
        try
        {
            if (args.Length == 0)
                throw new ArgumentException("Commands: capture --output WAV --report JSON --ready-file FILE --seconds 10; analyze --input WAV --report JSON");
            var options = new Dictionary<string, string>();
            for (int i = 1; i < args.Length; i += 2)
            {
                if (i + 1 >= args.Length) throw new ArgumentException("Option value missing");
                options.Add(args[i], args[i + 1]);
            }
            reportPath = options["--report"];
            if (args[0] == "analyze")
            {
                var analysis = Analyze(options["--input"]);
                Save(reportPath, analysis);
                return analysis.Passed ? 0 : 2;
            }
            if (args[0] != "capture") throw new ArgumentException("Unknown command");
            int seconds = int.Parse(options.GetValueOrDefault("--seconds", "10"));
            if (seconds is < 1 or > 10) throw new ArgumentException("Output loopback capture is limited to 1–10 seconds");
            string outputPath = options["--output"];
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outputPath))!);
            // Select Render explicitly: microphone/capture endpoints are never opened.
            using var enumerator = new MMDeviceEnumerator();
            using var endpoint = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            using var capture = new WasapiLoopbackCapture(endpoint);
            using var writer = new WaveFileWriter(outputPath, capture.WaveFormat);
            var stopped = new TaskCompletionSource<Exception?>(TaskCreationOptions.RunContinuationsAsynchronously);
            long packets = 0, bytes = 0;
            capture.DataAvailable += (_, e) =>
            {
                writer.Write(e.Buffer, 0, e.BytesRecorded);
                Interlocked.Increment(ref packets);
                Interlocked.Add(ref bytes, e.BytesRecorded);
            };
            capture.RecordingStopped += (_, e) => stopped.TrySetResult(e.Exception);
            var startedUtc = DateTimeOffset.UtcNow;
            var timer = Stopwatch.StartNew();
            capture.StartRecording();
            if (options.TryGetValue("--ready-file", out var ready))
                File.WriteAllText(ready, startedUtc.ToString("O"));
            Console.WriteLine("Windows render-endpoint loopback ready; bounded capture started.");
            await Task.Delay(TimeSpan.FromSeconds(seconds));
            capture.StopRecording();
            var error = await stopped.Task.WaitAsync(TimeSpan.FromSeconds(3));
            timer.Stop();
            writer.Dispose();
            if (error != null) throw new InvalidOperationException("WASAPI output loopback failed", error);
            var signal = Analyze(outputPath);
            Save(reportPath, new
            {
                Passed = signal.Passed,
                Scope = "Digital default Windows playback endpoint; no microphone opened; physical audibility untested",
                ProcessArchitecture = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString(),
                StartedUtc = startedUtc,
                CaptureWallSeconds = timer.Elapsed.TotalSeconds,
                RequestedCaptureSeconds = seconds,
                Device = endpoint.FriendlyName,
                DeviceId = endpoint.ID,
                DeviceMuted = endpoint.AudioEndpointVolume.Mute,
                DeviceVolumeScalar = endpoint.AudioEndpointVolume.MasterVolumeLevelScalar,
                Format = capture.WaveFormat.ToString(),
                Packets = packets,
                CapturedBytes = bytes,
                Signal = signal,
                Dependencies = "NAudio.Core 2.4.0; NAudio.Wasapi 2.4.0",
                Reference = "https://github.com/naudio/NAudio/blob/release/2.x/Docs/WasapiLoopbackCapture.md"
            });
            return signal.Passed ? 0 : 2;
        }
        catch (Exception e)
        {
            if (reportPath != null) Save(reportPath, new { Passed = false, Error = e.ToString() });
            Console.Error.WriteLine(e.Message);
            return 1;
        }
    }

    static void Save(string path, object value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        string json = JsonSerializer.Serialize(value, JsonOptions);
        File.WriteAllText(path, json + Environment.NewLine);
        Console.WriteLine(json);
    }

    sealed record SignalWindow(double StartSeconds, double Rms, double Amplitude440, double Amplitude880, double ControlAmplitude, int DetectedFrequency);
    sealed record SignalResult(bool Passed, double SampleSeconds, int SampleRate, int Channels, int Windows440, int Windows880, int Alternations, string Criterion, List<SignalWindow> Windows);

    static SignalResult Analyze(string path)
    {
        using var reader = new WaveFileReader(path);
        var sampleProvider = reader.ToSampleProvider();
        int channels = sampleProvider.WaveFormat.Channels;
        int rate = sampleProvider.WaveFormat.SampleRate;
        // Files are locally generated/captured and bounded, but cap reads independently.
        var data = new List<double>(rate * 11);
        var buffer = new float[channels * 4096];
        int read;
        while ((read = sampleProvider.Read(buffer, 0, buffer.Length)) > 0)
        {
            for (int i = 0; i + channels <= read; i += channels)
            {
                double mono = 0;
                for (int c = 0; c < channels; c++) mono += buffer[i + c];
                data.Add(mono / channels);
            }
            if (data.Count > rate * 30) throw new InvalidOperationException("Analysis input exceeds 30 seconds");
        }
        int windowSamples = rate / 5;
        var windows = new List<SignalWindow>();
        int hits440 = 0, hits880 = 0, lastTone = 0, alternations = 0;
        for (int start = 0; start + windowSamples <= data.Count; start += windowSamples)
        {
            double rms = Math.Sqrt(data.GetRange(start, windowSamples).Average(v => v * v));
            double f440 = Amplitude(data, start, windowSamples, 440, rate);
            double f880 = Amplitude(data, start, windowSamples, 880, rate);
            double control = new[] { 200, 1200, 3700 }.Max(f => Amplitude(data, start, windowSamples, f, rate));
            int tone = 0;
            // Windows/Android gain and endpoint processing attenuate frequencies
            // differently. Require spectral dominance, with only a -80 dBFS
            // peak floor, rather than assuming a particular output volume.
            if (rms > .00005 && f440 > .0001 && f440 > f880 * 4 && f440 > control * 8) { tone = 440; hits440++; }
            else if (rms > .00005 && f880 > .0001 && f880 > f440 * 4 && f880 > control * 8) { tone = 880; hits880++; }
            if (tone != 0)
            {
                if (lastTone != 0 && lastTone != tone) alternations++;
                lastTone = tone;
            }
            windows.Add(new(start / (double)rate, rms, f440, f880, control, tone));
        }
        return new(hits440 >= 3 && hits880 >= 3 && alternations >= 3, data.Count / (double)rate, rate, channels,
            hits440, hits880, alternations,
            "Both 440/880 Hz present in >=3 separate 200ms windows each, peak amplitude >0.0001 (-80dBFS), >4x other tone, >8x controls; >=3 alternations", windows);
    }

    static double Amplitude(List<double> samples, int start, int count, int frequency, int rate)
    {
        double real = 0, imaginary = 0, weightSum = 0;
        for (int i = 0; i < count; i++)
        {
            double weight = .5 - .5 * Math.Cos(2 * Math.PI * i / (count - 1));
            double angle = 2 * Math.PI * frequency * i / rate;
            real += samples[start + i] * weight * Math.Cos(angle);
            imaginary += samples[start + i] * weight * Math.Sin(angle);
            weightSum += weight;
        }
        return 2 * Math.Sqrt(real * real + imaginary * imaginary) / weightSum;
    }
}
