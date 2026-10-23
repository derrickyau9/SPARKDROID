using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;

namespace SparkDroid.Launcher;

internal sealed record CommandResult(int ExitCode, string Output, string Error)
{
    public bool Success => ExitCode == 0;
    public string Combined => string.Join(Environment.NewLine, new[] { Output.Trim(), Error.Trim() }.Where(x => x.Length != 0));
}

internal sealed class RuntimeClient(string projectRoot)
{
    public string ProjectRoot { get; } = projectRoot;
    public string ScriptPath => Path.Combine(ProjectRoot, "scripts", "SparkDroid.ps1");

    public async Task<CommandResult> ExecuteAsync(string action, string? profile = null, string? apk = null,
        string? package = null, Action<string>? output = null, string? displayMode = null)
    {
        if (!File.Exists(ScriptPath)) throw new FileNotFoundException("Runtime control script was not found. Build or extract the complete SPARKDROID project.", ScriptPath);
        if (package is not null && !IsPackageId(package)) throw new ArgumentException("Invalid Android package identifier.");
        var start = CreatePowerShellStartInfo();
        Add(start, "-NoProfile", "-NonInteractive", "-File", ScriptPath, "-Action", action);
        if (profile is not null) Add(start, "-Profile", profile);
        if (apk is not null) Add(start, "-Apk", Path.GetFullPath(apk));
        if (package is not null) Add(start, "-Package", package);
        if (displayMode is not null) Add(start, "-DisplayMode", displayMode);
        using var process = new Process { StartInfo = start };
        if (!process.Start()) throw new InvalidOperationException("PowerShell could not be started.");
        // Read both pipes concurrently so large ADB/diagnostic output cannot deadlock.
        using var drain = new CancellationTokenSource();
        var stdout = ReadAsync(process.StandardOutput, output, drain.Token);
        var stderr = ReadAsync(process.StandardError, output, drain.Token);
        await process.WaitForExitAsync();
        // A booted VM can inherit a pipe handle after PowerShell exits.
        // Drain its final lines, then release this transient launcher.
        drain.CancelAfter(TimeSpan.FromSeconds(1));
        return new(process.ExitCode, await stdout, await stderr);
    }

    public ProcessStartInfo CreatePowerShellStartInfo() => new(FindPowerShell())
    {
        WorkingDirectory = ProjectRoot, UseShellExecute = false,
        CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
        StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
    };

    public string FindPowerShell()
    {
        var bundled = Path.Combine(ProjectRoot, "tools", "powershell", "pwsh.exe");
        if (File.Exists(bundled)) return bundled;
        var conventional = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PowerShell", "7", "pwsh.exe");
        if (File.Exists(conventional)) return conventional;
        foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
        {
            try
            {
                var path = Path.Combine(directory.Trim('"'), "pwsh.exe");
                if (File.Exists(path)) return path;
            }
            catch (ArgumentException) { }
        }
        throw new FileNotFoundException("PowerShell 7 (pwsh.exe) is required. Put it in tools\\powershell or add it to PATH.");
    }

    public static string FindProjectRoot(string? specified)
    {
        if (specified is not null)
        {
            var full = Path.GetFullPath(specified);
            if (!File.Exists(Path.Combine(full, "scripts", "SparkDroid.ps1")))
                throw new DirectoryNotFoundException($"No scripts\\SparkDroid.ps1 in {full}");
            return full;
        }
        foreach (var location in new[] { AppContext.BaseDirectory, Environment.CurrentDirectory })
        {
            for (var dir = new DirectoryInfo(location); dir is not null; dir = dir.Parent)
                if (File.Exists(Path.Combine(dir.FullName, "scripts", "SparkDroid.ps1"))) return dir.FullName;
        }
        throw new DirectoryNotFoundException("Cannot locate scripts\\SparkDroid.ps1. Keep the launcher inside the complete project, or pass --project <project directory>.");
    }

    public static bool IsPackageId(string value) => Regex.IsMatch(value, @"\A[a-zA-Z][a-zA-Z0-9_]*(?:\.[a-zA-Z][a-zA-Z0-9_]*)+\z", RegexOptions.CultureInvariant);

    public static IReadOnlyList<string> ParsePackages(string text)
    {
        // Accept `pm list packages` lines and plain package identifiers only.
        return text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries)
            .Select(x => x.Trim()).Select(x => x.StartsWith("package:", StringComparison.Ordinal) ? x[8..] : x)
            .Where(IsPackageId).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray();
    }

    private static void Add(ProcessStartInfo start, params string[] arguments)
    {
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
    }

    private static async Task<string> ReadAsync(StreamReader reader, Action<string>? output, CancellationToken cancellationToken)
    {
        var result = new StringBuilder();
        while (true)
        {
            string? line;
            try { line = await reader.ReadLineAsync(cancellationToken); }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { break; }
            if (line is null) break;
            result.AppendLine(line);
            output?.Invoke(line);
        }
        return result.ToString();
    }
}
