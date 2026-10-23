using System.Runtime.InteropServices;
using System.Text.Json;

namespace SparkDroid.Launcher;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Contains("--probe-runtime", StringComparer.OrdinalIgnoreCase))
        {
            try
            {
                var options = StartupOptions.Parse(args.Where(x => !x.Equals("--probe-runtime", StringComparison.OrdinalIgnoreCase)).ToArray());
                var root = RuntimeClient.FindProjectRoot(options.ProjectRoot);
                var result = new RuntimeClient(root).ExecuteAsync("Status").GetAwaiter().GetResult();
                Console.WriteLine(result.Output.Trim());
                if (result.Error.Length != 0) Console.Error.WriteLine(result.Error.Trim());
                return result.ExitCode;
            }
            catch (Exception ex) { Console.Error.WriteLine(ex.Message); return 1; }
        }
        if (args.Contains("--smoke-test", StringComparer.OrdinalIgnoreCase))
        {
            ApplicationConfiguration.Initialize();
            using var form = new MainForm(AppContext.BaseDirectory, new StartupOptions(null, null, []), persistLog: false, performStartupActions: false);
            _ = form.Handle;
            var screenshotOption = Array.FindIndex(args, value => value.Equals("--screenshot", StringComparison.OrdinalIgnoreCase));
            string? screenshot = null;
            if (screenshotOption >= 0)
            {
                if (screenshotOption + 1 >= args.Length) throw new ArgumentException("--screenshot requires a file path.");
                screenshot = Path.GetFullPath(args[screenshotOption + 1]);
                form.StartPosition = FormStartPosition.Manual;
                form.Location = new Point(-32000, -32000);
                form.ShowInTaskbar = false;
                form.Show();
                Application.DoEvents();
                form.PerformLayout();
                using var bitmap = new Bitmap(form.Width, form.Height);
                form.DrawToBitmap(bitmap, new Rectangle(Point.Empty, bitmap.Size));
                bitmap.Save(screenshot, System.Drawing.Imaging.ImageFormat.Png);
                form.Hide();
            }
            if (RuntimeClient.IsPackageId("com.example.app;calc.exe") ||
                !RuntimeClient.IsPackageId("com.example.app") ||
                RuntimeClient.ParsePackages("package:com.example.app\ncom.example.app\ninvalid").Count != 1)
                throw new InvalidOperationException("Launcher package validation self-check failed.");
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                application = "SPARKDROID Launcher", version = "0.1.0",
                architecture = RuntimeInformation.ProcessArchitecture.ToString(),
                framework = RuntimeInformation.FrameworkDescription,
                windows = OperatingSystem.IsWindows(),
                uiConstructed = form.IsHandleCreated,
                screenshotFile = screenshot,
                runtimeBootValidated = false, gpuValidated = false,
                note = "Launcher process smoke test only; no Android runtime is started."
            }));
            return OperatingSystem.IsWindows() && RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? 0 : 2;
        }

        ApplicationConfiguration.Initialize();
        try
        {
            var options = StartupOptions.Parse(args);
            var root = RuntimeClient.FindProjectRoot(options.ProjectRoot);
            if (options.ExportShortcuts)
            {
                var result = new RuntimeClient(root).ExecuteAsync("Apps").GetAwaiter().GetResult();
                if (!result.Success) throw new InvalidOperationException(result.Combined);
                var packages = RuntimeClient.ParsePackages(result.Output);
                foreach (var package in packages) NativeIntegration.CreateAppShortcuts(package, root);
                Console.WriteLine(JsonSerializer.Serialize(new { shortcutsCreated = packages, desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory) }));
                return 0;
            }
            if (options.Package is not null && options.Apks.Count == 0)
            {
                using var appLaunch = new AppLaunchForm(root, options.Package);
                Application.Run(appLaunch);
                return appLaunch.ExitCode;
            }
            Application.Run(new MainForm(root, options));
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "SPARKDROID", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}

internal sealed record StartupOptions(string? ProjectRoot, string? Package, IReadOnlyList<string> Apks, bool ExportShortcuts = false)
{
    public static StartupOptions Parse(string[] args)
    {
        string? project = null, package = null;
        var exportShortcuts = false;
        var apks = new List<string>();
        for (var i = 0; i < args.Length; i++)
        {
            switch (args[i].ToLowerInvariant())
            {
                case "--project": project = Value(args, ref i); break;
                case "--package": package = Value(args, ref i); break;
                case "--export-shortcuts": exportShortcuts = true; break;
                case "--apk": apks.Add(Value(args, ref i)); break;
                default:
                    if (args[i].EndsWith(".apk", StringComparison.OrdinalIgnoreCase)) apks.Add(args[i]);
                    else throw new ArgumentException($"Unknown argument: {args[i]}");
                    break;
            }
        }
        if (package is not null && !RuntimeClient.IsPackageId(package))
            throw new ArgumentException("The Android package identifier is invalid.");
        return new(project, package, apks, exportShortcuts);
    }

    private static string Value(string[] args, ref int index)
    {
        if (++index >= args.Length) throw new ArgumentException("A command-line option is missing its value.");
        return args[index];
    }
}
