namespace SparkDroid.Launcher;

// Shortcuts open this small startup indicator, then leave only the app window.
internal sealed class AppLaunchForm : Form
{
    private readonly Label _status = new() { Dock = DockStyle.Fill, AutoEllipsis = true, Padding = new Padding(16), TextAlign = ContentAlignment.MiddleLeft };
    private readonly RuntimeClient _runtime;
    private readonly string _package;
    private bool _finished;
    public int ExitCode { get; private set; } = 1;

    public AppLaunchForm(string root, string package)
    {
        _runtime = new(root); _package = package;
        Text = NativeIntegration.AppName(package);
        Size = new Size(440, 145); StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog; ControlBox = false;
        ShowInTaskbar = false; Font = new Font("Segoe UI", 10);
        Controls.Add(_status);
        Controls.Add(new ProgressBar { Dock = DockStyle.Bottom, Height = 7, Style = ProgressBarStyle.Marquee });
        _status.Text = $"正在启动 {NativeIntegration.AppName(package)}…\nAndroid 未运行时会自动启动。";
        Shown += Launch;
        FormClosing += (_, e) => { if (!_finished) e.Cancel = true; };
    }

    private async void Launch(object? sender, EventArgs e)
    {
        try
        {
            var result = await _runtime.ExecuteAsync("Launch", package: _package, output: line =>
            {
                if (IsHandleCreated && !IsDisposed) BeginInvoke(() => _status.Text = line);
            });
            ExitCode = result.ExitCode;
            if (!result.Success) MessageBox.Show(this, result.Combined, "Android app could not start", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        catch (Exception error) { MessageBox.Show(this, error.Message, "SPARKDROID", MessageBoxButtons.OK, MessageBoxIcon.Error); }
        finally { _finished = true; Close(); }
    }
}
