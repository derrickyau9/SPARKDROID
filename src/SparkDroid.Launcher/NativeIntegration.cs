using System.Diagnostics;
using Microsoft.Win32;

namespace SparkDroid.Launcher;

internal static class NativeIntegration
{
    [System.Runtime.InteropServices.DllImport("shell32.dll")]
    private static extern void SHChangeNotify(uint eventId, uint flags, IntPtr item1, IntPtr item2);

    public static void CreateDesktopShortcut(string package, string projectRoot)
        => CreateAppShortcuts(package, projectRoot);

    public static string AppName(string package) => package switch
    {
        "com.tencent.mm" => "WeChat",
        "org.videolan.vlc" => "VLC",
        _ => package
    };

    public static void CreateAppShortcuts(string package, string projectRoot)
    {
        if (!RuntimeClient.IsPackageId(package)) throw new ArgumentException("Invalid Android package identifier.");
        var executable = ExecutablePath();
        var type = Type.GetTypeFromProgID("WScript.Shell") ?? throw new InvalidOperationException("Windows Script Host is unavailable.");
        dynamic shell = Activator.CreateInstance(type)!;
        try
        {
            foreach (var folder in new[] {
                Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "SPARKDROID") })
            {
                Directory.CreateDirectory(folder);
                dynamic shortcut = shell.CreateShortcut(Path.Combine(folder, $"{AppName(package)} (Android - SPARKDROID).lnk"));
                try
                {
                    shortcut.TargetPath = executable;
                    shortcut.Arguments = $"--project {Quote(projectRoot)} --package {Quote(package)}";
                    shortcut.WorkingDirectory = projectRoot;
                    shortcut.Description = $"Open {AppName(package)} as an individual Android window; starts Android automatically.";
                    shortcut.IconLocation = executable;
                    shortcut.Save();
                }
                finally { System.Runtime.InteropServices.Marshal.FinalReleaseComObject(shortcut); }
            }
        }
        finally
        {
            System.Runtime.InteropServices.Marshal.FinalReleaseComObject(shell);
        }
    }

    public static void RegisterApkOpenWith(string projectRoot)
    {
        var executable = ExecutablePath();
        using (var kind = Registry.CurrentUser.CreateSubKey(@"Software\Classes\SparkDroid.Apk"))
        {
            kind.SetValue("", "Android application package (SPARKDROID)");
            using var icon = kind.CreateSubKey("DefaultIcon");
            icon.SetValue("", $"{Quote(executable)},0");
            using var command = kind.CreateSubKey(@"shell\open\command");
            command.SetValue("", $"{Quote(executable)} --project {Quote(projectRoot)} --apk \"%1\"");
        }
        using var extensions = Registry.CurrentUser.CreateSubKey(@"Software\Classes\.apk\OpenWithProgids");
        extensions.SetValue("SparkDroid.Apk", Array.Empty<byte>(), RegistryValueKind.None);
        SHChangeNotify(0x08000000, 0, IntPtr.Zero, IntPtr.Zero);
        // UserChoice/default association is deliberately selected in Windows' Open With UI.
    }

    public static void OpenPath(string path)
    {
        if (!Directory.Exists(path) && !File.Exists(path)) throw new FileNotFoundException("Path does not exist yet.", path);
        Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
    }

    private static string ExecutablePath()
    {
        var path = Environment.ProcessPath ?? throw new InvalidOperationException("Launcher executable path is unavailable.");
        if (Path.GetFileNameWithoutExtension(path).Equals("dotnet", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Use the published SparkDroid.exe to create shortcuts or register APK handling.");
        return path;
    }

    // Windows CommandLineToArgvW quoting, including trailing backslashes in folder paths.
    internal static string Quote(string value)
    {
        var builder = new System.Text.StringBuilder("\"");
        var backslashes = 0;
        foreach (var character in value)
        {
            if (character == '\\') { backslashes++; continue; }
            if (character == '"') builder.Append('\\', backslashes * 2 + 1).Append('"');
            else builder.Append('\\', backslashes).Append(character);
            backslashes = 0;
        }
        return builder.Append('\\', backslashes * 2).Append('"').ToString();
    }
}
