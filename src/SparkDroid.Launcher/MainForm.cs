using System.Diagnostics;
using System.Text.Json;

namespace SparkDroid.Launcher;

internal sealed class MainForm : Form
{
    private readonly RuntimeClient _runtime;
    private readonly StartupOptions _startup;
    private readonly List<Control> _operationControls = [];
    private readonly ListBox _apps = new() { Dock = DockStyle.Fill, IntegralHeight = false, Font = new Font("Segoe UI", 11) };
    private readonly TextBox _filter = new() { Dock = DockStyle.Fill, PlaceholderText = "Filter Android package identifiers" };
    private readonly TextBox _diagnostics = OutputBox();
    private readonly TextBox _activity = OutputBox();
    private readonly Label _status = new() { AutoSize = false, Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft, Padding = new Padding(12, 0, 0, 0) };
    private readonly ComboBox _profile = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 160 };
    private readonly Button _launch = new() { Text = "Launch app window", AutoSize = true };
    private readonly Button _shortcut = new() { Text = "Desktop shortcut", AutoSize = true };
    private readonly Button _uninstall = new() { Text = "Uninstall app", AutoSize = true };
    private readonly TabControl _tabs = new() { Dock = DockStyle.Fill };
    private readonly ToolTip _tips = new() { AutoPopDelay = 12000, InitialDelay = 300, ReshowDelay = 100 };
    private IReadOnlyList<string> _allPackages = [];
    private StreamWriter? _sessionLog;
    private bool _busy;

    public MainForm(string root, StartupOptions startup, bool persistLog = true, bool performStartupActions = true)
    {
        SuspendLayout();
        _runtime = new(root);
        _startup = startup;
        if (persistLog)
        {
            try
            {
                var logDirectory = Path.Combine(root, "artifacts", "launcher", "logs");
                Directory.CreateDirectory(logDirectory);
                _sessionLog = new StreamWriter(Path.Combine(logDirectory, $"launcher-{DateTime.Now:yyyyMMdd-HHmmss}-{Environment.ProcessId}.log"), append: false) { AutoFlush = true };
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
        }
        Text = "SPARKDROID · Android runtime controls";
        Size = new Size(1180, 820);
        MinimumSize = new Size(960, 660);
        StartPosition = FormStartPosition.CenterScreen;
        AutoScaleDimensions = new SizeF(96, 96);
        AutoScaleMode = AutoScaleMode.Dpi;
        Font = new Font("Segoe UI", 10);
        BackColor = Color.FromArgb(246, 248, 250);
        AllowDrop = true;

        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 5, Padding = new Padding(16), BackColor = BackColor };
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 84));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 49));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 110));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
        Controls.Add(layout);

        var header = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 2, ColumnCount = 1 };
        header.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));
        header.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        header.Controls.Add(new Label { Text = "SPARKDROID", Font = new Font("Segoe UI Semibold", 23), AutoSize = true, ForeColor = Color.FromArgb(21, 46, 63) }, 0, 0);
        header.Controls.Add(new Label { Text = "ARM64 Android controls · Boot, app compatibility and GPU acceleration require runtime validation.\nExplicit refresh only; the launcher does not poll in the background.", AutoSize = true, ForeColor = Color.FromArgb(65, 78, 91) }, 0, 1);
        layout.Controls.Add(header, 0, 0);

        var primary = Flow();
        primary.Controls.Add(new Label { Text = "Profile", AutoSize = true, Padding = new Padding(0, 6, 2, 0) });
        _profile.Items.AddRange(["Performance", "Balanced", "UltraEfficient"]);
        _profile.SelectedIndex = 1;
        primary.Controls.Add(_profile);
        _operationControls.Add(_profile);
        primary.Controls.Add(ActionButton("Start", async () => await RunAsync("Start", profile: Profile)));
        primary.Controls.Add(ActionButton("Stop", async () => await RunAsync("Stop")));
        primary.Controls.Add(ActionButton("Suspend", async () => await RunAsync("Suspend")));
        primary.Controls.Add(ActionButton("Resume", async () => await RunAsync("Resume")));
        primary.Controls.Add(ActionButton("Refresh status", RefreshStatusAsync));
        primary.Controls.Add(ActionButton("Benchmark", async () => { _tabs.SelectedIndex = 1; await RunAsync("Benchmark", profile: Profile); }));
        layout.Controls.Add(primary, 0, 1);

        var secondary = Flow();
        secondary.WrapContents = true;
        secondary.AutoScroll = false;
        secondary.Controls.Add(ActionButton("Smooth 60 Hz", async () => await RunAsync("SetDisplay", displayMode: "Smooth")));
        secondary.Controls.Add(ActionButton("120 Hz (experimental)", async () => await RunAsync("SetDisplay", displayMode: "HighRefresh")));
        secondary.Controls.Add(ActionButton("Install APK…", PickApksAsync));
        secondary.Controls.Add(ActionButton("Install splits…", PickSplitApksAsync));
        secondary.Controls.Add(ActionButton("Refresh apps", RefreshAppsAsync));
        secondary.Controls.Add(ActionButton("ADB console", OpenAdbConsoleAsync));
        secondary.Controls.Add(ActionButton("APK Open with…", RegisterApkAsync));
        secondary.Controls.Add(ActionButton("Project folder", () => LocalActionAsync(() => NativeIntegration.OpenPath(root))));
        var sharedFolder = ActionButton("Shared folder", () => LocalActionAsync(() => NativeIntegration.OpenPath(Path.Combine(root, "shared"))));
        _tips.SetToolTip(sharedFolder, "Open the Windows shared folder. Android receives files only through an explicit Send shared files transfer.");
        secondary.Controls.Add(sharedFolder);
        var sendShared = ActionButton("Send shared files", async () => await RunAsync("PushShared"));
        _tips.SetToolTip(sendShared, "Manually copy Windows shared files to Android /sdcard/Download/SPARKDROID. This is an explicit transfer, not a mounted or continuously synchronized folder.");
        secondary.Controls.Add(sendShared);
        var fetchShared = ActionButton("Fetch shared files", async () => await RunAsync("PullShared"));
        _tips.SetToolTip(fetchShared, "Manually copy files from Android /sdcard/Download/SPARKDROID to the host shared folder. This is an explicit transfer, not live folder synchronization.");
        secondary.Controls.Add(fetchShared);
        secondary.Controls.Add(ActionButton("Save diagnostics…", SaveDiagnosticsAsync));
        layout.Controls.Add(secondary, 0, 2);

        var appsTab = new TabPage("Applications") { Padding = new Padding(12), BackColor = Color.White };
        var appLayout = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 4, ColumnCount = 1 };
        appLayout.RowStyles.Add(new RowStyle(SizeType.Absolute, 32));
        appLayout.RowStyles.Add(new RowStyle(SizeType.Absolute, 39));
        appLayout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        appLayout.RowStyles.Add(new RowStyle(SizeType.Absolute, 60));
        appLayout.Controls.Add(new Label { Text = "Drop APKs to install separately. For a base APK and its splits, choose Install splits. Refresh apps after boot.", AutoSize = true }, 0, 0);
        appLayout.Controls.Add(_filter, 0, 1);
        appLayout.Controls.Add(_apps, 0, 2);
        var appActions = Flow();
        foreach (var control in new[] { _launch, _shortcut, _uninstall })
        {
            appActions.Controls.Add(control);
            _operationControls.Add(control);
        }
        appLayout.Controls.Add(appActions, 0, 3);
        appsTab.Controls.Add(appLayout);
        _tabs.TabPages.Add(appsTab);
        var diagnosticsTab = new TabPage("Runtime diagnostics") { Padding = new Padding(8), BackColor = Color.White };
        diagnosticsTab.Controls.Add(_diagnostics);
        _diagnostics.Text = "No runtime validation has been performed by this launcher.\r\nUse Refresh status to inspect the configured runtime.\r\n\r\nProject: " + root;
        _tabs.TabPages.Add(diagnosticsTab);
        var activityTab = new TabPage("Activity log") { Padding = new Padding(8), BackColor = Color.White };
        activityTab.Controls.Add(_activity);
        _tabs.TabPages.Add(activityTab);
        layout.Controls.Add(_tabs, 0, 3);
        layout.Controls.Add(_status, 0, 4);
        SetStatus("Ready. Runtime boot and GPU acceleration are unverified.");

        _filter.TextChanged += (_, _) => ApplyFilter();
        _apps.SelectedIndexChanged += (_, _) => UpdateAppControls();
        _apps.DoubleClick += async (_, _) => await LaunchSelectedAsync();
        _launch.Click += async (_, _) => await LaunchSelectedAsync();
        _shortcut.Click += async (_, _) => await CreateShortcutAsync();
        _uninstall.Click += async (_, _) => await UninstallSelectedAsync();
        EnableApkDrop(this);
        if (performStartupActions) Shown += OnShown;
        FormClosing += (_, e) =>
        {
            if (_busy)
            {
                e.Cancel = true;
                SetStatus("Wait for the current operation to finish before closing the launcher.", true);
            }
        };
        FormClosed += (_, _) => { _sessionLog?.Dispose(); _tips.Dispose(); };
        Log($"SPARKDROID Launcher 0.1.0. Project: {root}");
        UpdateAppControls();
        ResumeLayout(performLayout: true);
    }

    private string Profile => (string)(_profile.SelectedItem ?? "Balanced");
    private string? SelectedPackage => _apps.SelectedItem as string;

    private async void OnShown(object? sender, EventArgs args)
    {
        try
        {
            await RefreshStatusAsync();
            await RefreshAppsAsync();
            if (_startup.Apks.Count > 0) await InstallApksAsync(_startup.Apks);
            if (_startup.Package is { } package) await RunAsync("Launch", package: package);
        }
        catch (Exception ex) { ReportError(ex); }
    }

    private Button ActionButton(string text, Func<Task> action)
    {
        var button = new Button { Text = text, AutoSize = true, MinimumSize = new Size(74, 32), Padding = new Padding(4, 0, 4, 0) };
        button.Click += async (_, _) =>
        {
            try { await action(); }
            catch (Exception ex) { ReportError(ex); }
        };
        _operationControls.Add(button);
        return button;
    }

    private async Task<CommandResult?> RunAsync(string action, string? profile = null, string? apk = null, string? package = null, string? displayMode = null)
    {
        if (_busy) return null;
        SetBusy(true);
        SetStatus($"{action} in progress…");
        Log($"> {action}" + (package is null ? "" : $" {package}") + (apk is null ? "" : $" {apk}") + (profile is null ? "" : $" [{profile}]"));
        var stopwatch = Stopwatch.StartNew();
        try
        {
            var result = await _runtime.ExecuteAsync(action, profile, apk, package, line =>
            {
                if (!IsDisposed && IsHandleCreated) BeginInvoke(() => Log(line));
            }, displayMode: displayMode);
            Log($"< {action}: exit {result.ExitCode}, {stopwatch.Elapsed.TotalSeconds:F2} s");
            if (action is "Status" or "Benchmark") _diagnostics.Text = result.Combined.Length == 0 ? $"{action} returned no output." : result.Combined;
            SetStatus(result.Success ? $"{action} completed. See Activity log for details." : $"{action} failed (exit {result.ExitCode}). See Activity log for the reported blocker.", !result.Success);
            if (!result.Success) _tabs.SelectedIndex = action is "Status" or "Benchmark" ? 1 : 2;
            return result;
        }
        catch (Exception ex)
        {
            ReportError(ex);
            if (action == "Status") _diagnostics.Text = ex.Message;
            return null;
        }
        finally { SetBusy(false); }
    }

    private async Task RefreshStatusAsync()
    {
        var result = await RunAsync("Status");
        if (result is not { Success: true }) return;
        try
        {
            using var document = JsonDocument.Parse(result.Output);
            if (document.RootElement.TryGetProperty("profile", out var profile) && _profile.Items.Contains(profile.GetString())) _profile.SelectedItem = profile.GetString();
            if (document.RootElement.TryGetProperty("requestedDisplayHz", out var hz)) SetStatus($"Requested display: {hz.GetInt32()} Hz. Actual FPS depends on the app; use Activity log for measured client FPS.");
        }
        catch (JsonException) { }
    }

    private async Task RefreshAppsAsync()
    {
        var result = await RunAsync("Apps");
        if (result is not { Success: true }) return;
        _allPackages = RuntimeClient.ParsePackages(result.Output);
        ApplyFilter();
        _tabs.SelectedIndex = 0;
        SetStatus($"{_allPackages.Count} installed packages reported by Android.");
    }

    private Task LaunchSelectedAsync() => SelectedPackage is { } package ? RunAsync("Launch", package: package) : Task.CompletedTask;

    private async Task UninstallSelectedAsync()
    {
        if (SelectedPackage is not { } package) return;
        if (MessageBox.Show(this, $"Uninstall {package}? Android will delete this application's data.", "Uninstall Android application", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
        var result = await RunAsync("Uninstall", package: package);
        if (result is { Success: true }) await RefreshAppsAsync();
    }

    private Task CreateShortcutAsync() => LocalActionAsync(() =>
    {
        if (SelectedPackage is not { } package) return;
        NativeIntegration.CreateDesktopShortcut(package, _runtime.ProjectRoot);
        SetStatus($"Created desktop and Start menu shortcuts for {package}; shortcuts open the app directly.");
    });

    private async Task PickApksAsync()
    {
        using var dialog = new OpenFileDialog { Title = "Install Android APK files", Filter = "Android packages (*.apk)|*.apk", Multiselect = true, CheckFileExists = true };
        if (dialog.ShowDialog(this) == DialogResult.OK) await InstallApksAsync(dialog.FileNames);
    }

    private async Task InstallApksAsync(IEnumerable<string> paths)
    {
        if (_busy) return;
        var installed = false;
        foreach (var value in paths)
        {
            var path = Path.GetFullPath(value);
            if (!File.Exists(path) || !Path.GetExtension(path).Equals(".apk", StringComparison.OrdinalIgnoreCase))
            {
                ReportError(new FileNotFoundException("Installation requires an existing .apk file.", path));
                continue;
            }
            var result = await RunAsync("Install", apk: path);
            installed |= result is { Success: true };
        }
        if (installed) await RefreshAppsAsync();
    }

    private async Task PickSplitApksAsync()
    {
        using var dialog = new OpenFileDialog { Title = "Select base APK and all split APKs for one application", Filter = "Android packages (*.apk)|*.apk", Multiselect = true, CheckFileExists = true };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        if (dialog.FileNames.Length < 2)
        {
            SetStatus("Select the base APK and at least one split APK for session installation.", true);
            return;
        }
        var manifestDirectory = Path.Combine(_runtime.ProjectRoot, "artifacts", "launcher");
        Directory.CreateDirectory(manifestDirectory);
        var manifest = Path.Combine(manifestDirectory, $"install-split-{Guid.NewGuid():N}.json");
        try
        {
            File.WriteAllText(manifest, JsonSerializer.Serialize(dialog.FileNames.Select(Path.GetFullPath).ToArray()));
            var result = await RunAsync("InstallSplit", apk: manifest);
            if (result is { Success: true }) await RefreshAppsAsync();
        }
        finally { File.Delete(manifest); }
    }

    private Task OpenAdbConsoleAsync() => LocalActionAsync(() =>
    {
        var start = new ProcessStartInfo(_runtime.FindPowerShell()) { WorkingDirectory = _runtime.ProjectRoot, UseShellExecute = true };
        foreach (var arg in new[] { "-NoProfile", "-NoExit", "-File", _runtime.ScriptPath, "-Action", "AdbShell" }) start.ArgumentList.Add(arg);
        Process.Start(start);
        SetStatus("Opened interactive ADB console. Android must be reachable.");
    });

    private Task RegisterApkAsync() => LocalActionAsync(() =>
    {
        NativeIntegration.RegisterApkOpenWith(_runtime.ProjectRoot);
        MessageBox.Show(this, "Registered SPARKDROID in this Windows user's APK Open with choices.\n\nRight-click an APK, select Open with, choose SPARKDROID and select Always to enable double-click installation. Windows controls the default application selection.", "APK installation", MessageBoxButtons.OK, MessageBoxIcon.Information);
        SetStatus("APK Open with registration completed for the current Windows user.");
    });

    private Task SaveDiagnosticsAsync() => LocalActionAsync(() =>
    {
        using var dialog = new SaveFileDialog { Title = "Save SPARKDROID diagnostics", Filter = "Text file (*.txt)|*.txt", FileName = $"sparkdroid-diagnostics-{DateTime.Now:yyyyMMdd-HHmmss}.txt" };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        File.WriteAllText(dialog.FileName, $"SPARKDROID Launcher 0.1.0\r\nProject: {_runtime.ProjectRoot}\r\n\r\n{_diagnostics.Text}\r\n\r\nACTIVITY LOG\r\n{_activity.Text}");
        SetStatus($"Saved diagnostics to {dialog.FileName}");
    });

    private void OnDragEnter(object? sender, DragEventArgs args)
    {
        args.Effect = !_busy && args.Data?.GetData(DataFormats.FileDrop) is string[] paths && paths.Length > 0 && paths.All(x => Path.GetExtension(x).Equals(".apk", StringComparison.OrdinalIgnoreCase)) ? DragDropEffects.Copy : DragDropEffects.None;
    }

    private async void OnDragDrop(object? sender, DragEventArgs args)
    {
        try
        {
            if (args.Data?.GetData(DataFormats.FileDrop) is string[] paths) await InstallApksAsync(paths);
        }
        catch (Exception ex) { ReportError(ex); }
    }

    private void EnableApkDrop(Control control)
    {
        control.AllowDrop = true;
        control.DragEnter += OnDragEnter;
        control.DragDrop += OnDragDrop;
        foreach (Control child in control.Controls) EnableApkDrop(child);
    }

    private void ApplyFilter()
    {
        var selected = SelectedPackage;
        _apps.BeginUpdate();
        _apps.Items.Clear();
        foreach (var package in _allPackages.Where(x => x.Contains(_filter.Text, StringComparison.OrdinalIgnoreCase))) _apps.Items.Add(package);
        if (selected is not null && _apps.Items.Contains(selected)) _apps.SelectedItem = selected;
        _apps.EndUpdate();
        UpdateAppControls();
    }

    private void SetBusy(bool busy)
    {
        _busy = busy;
        UseWaitCursor = busy;
        foreach (var control in _operationControls) control.Enabled = !busy;
        UpdateAppControls();
    }

    private void UpdateAppControls()
    {
        foreach (var button in new[] { _launch, _shortcut, _uninstall }) button.Enabled = !_busy && SelectedPackage is not null;
    }

    private void SetStatus(string message, bool error = false)
    {
        _status.Text = message;
        _status.ForeColor = error ? Color.FromArgb(168, 31, 31) : Color.FromArgb(27, 65, 78);
    }

    private void Log(string message)
    {
        // Keep the visible buffer bounded during large diagnostic commands.
        if (_activity.TextLength > 500_000) _activity.Text = _activity.Text[^250_000..];
        var line = $"[{DateTime.Now:HH:mm:ss}] {message}";
        _activity.AppendText(line + "\r\n");
        try { _sessionLog?.WriteLine(line); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            _sessionLog?.Dispose();
            _sessionLog = null;
            _activity.AppendText("[Launcher log could not be written; the visible log remains available.]\r\n");
        }
    }

    private void ReportError(Exception error)
    {
        Log($"ERROR: {error.Message}");
        SetStatus(error.Message, true);
        _tabs.SelectedIndex = 2;
    }

    private Task LocalActionAsync(Action action)
    {
        try { action(); }
        catch (Exception ex) { ReportError(ex); }
        return Task.CompletedTask;
    }

    private static FlowLayoutPanel Flow() => new() { Dock = DockStyle.Fill, FlowDirection = FlowDirection.LeftToRight, WrapContents = false, AutoScroll = true, Padding = new Padding(0, 4, 0, 0) };

    private static TextBox OutputBox() => new() { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Both, WordWrap = false, Font = new Font("Consolas", 10), BackColor = Color.FromArgb(249, 250, 251), BorderStyle = BorderStyle.FixedSingle };
}
