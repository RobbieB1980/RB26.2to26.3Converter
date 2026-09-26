using System.Diagnostics;
using System.Text;

namespace RB.RB262To263Converter;

public sealed class MainForm : Form
{
    private readonly TextBox _input = NewTextBox();
    private readonly TextBox _output = NewTextBox();
    private readonly TextBox _neo = NewTextBox("neoforge-26.3.0.7-beta");
    private readonly RichTextBox _log = new() { Multiline = true, ReadOnly = true, ScrollBars = RichTextBoxScrollBars.Vertical, Dock = DockStyle.Fill };
    private readonly Button _run = NewButton("Convert", 150);
    private readonly Button _openOutput = NewButton("Open output", 130);
    private readonly Button _clearLog = NewButton("Clear log", 110);
    private readonly CheckBox _build = NewCheck("Compile after convert (build must succeed)", true);
    private readonly ProgressBar _progress = new() { Style = ProgressBarStyle.Continuous, Height = 22, Dock = DockStyle.Fill };
    private readonly Label _status = new() { Text = "Experimental. Original input is never modified.", AutoSize = true, ForeColor = Color.FromArgb(140, 200, 140) };

    public MainForm()
    {
        Text = "RB 26.2 → 26.3 Converter";
        Width = 980;
        Height = 760;
        MinimumSize = new Size(840, 640);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.FromArgb(32, 34, 40);
        ForeColor = Color.Gainsboro;
        Font = new Font("Segoe UI", 9.5f);
        Padding = new Padding(12);
        _log.BackColor = Color.FromArgb(24, 26, 31);
        _log.ForeColor = Color.Gainsboro;
        _log.BorderStyle = BorderStyle.FixedSingle;
        _build.ForeColor = Color.Gainsboro;
        _run.BackColor = Color.FromArgb(46, 120, 80);
        _run.FlatAppearance.BorderColor = Color.FromArgb(70, 160, 100);
        _run.Font = new Font("Segoe UI Semibold", 10f);
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(0), ColumnCount = 4, RowCount = 10 };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 140));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 82));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 82));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 40));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 40));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 40));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 32));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        var header = new Label { Text = "RB 26.2 → 26.3 Converter", Font = new Font("Segoe UI Semibold", 12f), ForeColor = Color.White, AutoSize = true, Anchor = AnchorStyles.Left };
        layout.Controls.Add(header, 0, 0); layout.SetColumnSpan(header, 4);
        layout.Controls.Add(new Label { Text = "Input project or .jar", AutoSize = true, Anchor = AnchorStyles.Left }, 0, 1);
        layout.Controls.Add(_input, 1, 1); layout.Controls.Add(CreateFolderBrowse(_input), 2, 1); layout.Controls.Add(CreateJarBrowse(_input), 3, 1);
        layout.Controls.Add(new Label { Text = "Output 26.3 project", AutoSize = true, Anchor = AnchorStyles.Left }, 0, 2);
        layout.Controls.Add(_output, 1, 2); layout.SetColumnSpan(_output, 2); layout.Controls.Add(CreateFolderBrowse(_output), 3, 2);
        layout.Controls.Add(new Label { Text = "NeoForge 26.3 pin", AutoSize = true, Anchor = AnchorStyles.Left }, 0, 3);
        layout.Controls.Add(_neo, 1, 3); layout.SetColumnSpan(_neo, 2);
        layout.SetColumnSpan(_status, 4); layout.Controls.Add(_status, 0, 4);
        layout.SetColumnSpan(_run, 2); layout.Controls.Add(_run, 0, 5); layout.Controls.Add(_openOutput, 2, 5); layout.Controls.Add(_clearLog, 3, 5);
        layout.SetColumnSpan(_build, 4); layout.Controls.Add(_build, 0, 6);
        layout.SetColumnSpan(_progress, 4); layout.Controls.Add(_progress, 0, 7);
        layout.SetColumnSpan(_log, 4); layout.Controls.Add(_log, 0, 9);
        Controls.Add(layout);
        _run.Click += async (_, _) => await RunConversionAsync();
        _openOutput.Click += (_, _) => { if (Directory.Exists(_output.Text)) Process.Start(new ProcessStartInfo("explorer.exe", _output.Text) { UseShellExecute = true }); };
        _clearLog.Click += (_, _) => _log.Clear();
    }

    private Button CreateFolderBrowse(TextBox target)
    {
        var button = new Button { Text = "Folder…", Dock = DockStyle.Fill };
        button.Click += (_, _) => { using var dialog = new FolderBrowserDialog(); if (dialog.ShowDialog() == DialogResult.OK) { target.Text = dialog.SelectedPath; if (ReferenceEquals(target, _input)) SuggestOutput(dialog.SelectedPath); } };
        return button;
    }

    private Button CreateJarBrowse(TextBox target)
    {
        var button = new Button { Text = "JAR…", Dock = DockStyle.Fill };
        button.Click += (_, _) => { using var dialog = new OpenFileDialog { Filter = "Java mod JAR (*.jar)|*.jar|All files (*.*)|*.*", CheckFileExists = true }; if (dialog.ShowDialog() == DialogResult.OK) { target.Text = dialog.FileName; if (ReferenceEquals(target, _input)) SuggestOutput(dialog.FileName); } };
        return button;
    }

    private void SuggestOutput(string input)
    {
        try
        {
            var full = Path.GetFullPath(input);
            var name = File.Exists(full) ? Path.GetFileNameWithoutExtension(full) : new DirectoryInfo(full).Name;
            var parent = Directory.GetParent(full)?.FullName ?? full;
            var candidate = Path.Combine(parent, $"RB-{name}-26.3");
            var i = 2;
            while (Directory.Exists(candidate)) { candidate = Path.Combine(parent, $"RB-{name}-26.3-{i}"); i++; }
            _output.Text = candidate;
        }
        catch { }
    }

    private async Task RunConversionAsync()
    {
        if (string.IsNullOrWhiteSpace(_input.Text) || string.IsNullOrWhiteSpace(_neo.Text))
        { MessageBox.Show(this, "Choose an input and an official NeoForge 26.3 version.", "Missing input", MessageBoxButtons.OK, MessageBoxIcon.Warning); return; }
        _run.Enabled = false; _log.Clear(); _status.Text = "Running deterministic 26.2 → 26.3 preview passes…";
        try
        {
            var script = Path.Combine(AppContext.BaseDirectory, "tools", "rb-26.2-to-26.3", "Convert-RB262To263.ps1");
            var shell = OperatingSystem.IsWindows() && File.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PowerShell", "7", "pwsh.exe")) ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PowerShell", "7", "pwsh.exe") : "powershell.exe";
            var psi = new ProcessStartInfo(shell) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
            psi.ArgumentList.Add("-NoProfile"); psi.ArgumentList.Add("-ExecutionPolicy"); psi.ArgumentList.Add("Bypass"); psi.ArgumentList.Add("-File"); psi.ArgumentList.Add(script);
            psi.ArgumentList.Add("-InputPath"); psi.ArgumentList.Add(_input.Text); psi.ArgumentList.Add("-OutputPath"); psi.ArgumentList.Add(_output.Text); psi.ArgumentList.Add("-NeoVersion"); psi.ArgumentList.Add(_neo.Text);
            using var process = Process.Start(psi) ?? throw new InvalidOperationException("Could not start PowerShell.");
            var (stdout, stderr) = await CaptureProcessOutputAsync(process, line => AppendLogLine(line));
            if (process.ExitCode != 0)
            {
                _status.Text = $"Conversion failed with exit code {process.ExitCode}.";
                return;
            }

            if (!Directory.Exists(_output.Text))
            {
                var reason = ExtractRejectionReason(stdout);
                _status.Text = string.IsNullOrWhiteSpace(reason)
                    ? "Conversion did not create the requested output folder; build was not started."
                    : "Input rejected: " + reason;
                _log.AppendText(Environment.NewLine + Environment.NewLine + (string.IsNullOrWhiteSpace(reason)
                    ? "The target returned without producing an output project."
                    : "Rejection reason: " + reason));
                return;
            }

            if (_build.Checked)
            {
                _status.Text = "Conversion completed; running Gradle build…";
                AppendLogLine("");
                AppendLogLine("===== GRADLE BUILD =====");
                var buildResult = await RunGradleBuildAsync(_output.Text, line => AppendLogLine(line));
                _status.Text = buildResult.ExitCode == 0
                    ? "Conversion and Gradle build completed; inspect MIGRATION_EVIDENCE.md."
                    : buildResult.ExitCode == 2
                        ? "Conversion completed; Gradle build was unavailable for this input."
                        : $"Conversion completed, but Gradle build failed with exit code {buildResult.ExitCode}.";
            }
            else
            {
                _status.Text = "Preview conversion completed; build was skipped.";
            }
        }
        catch (Exception ex) { _log.Text = ex.ToString(); _status.Text = "Conversion failed."; }
        finally { _run.Enabled = true; }
    }

    private async Task<(int ExitCode, string Output, string Error)> RunGradleBuildAsync(string outputPath, Action<string> writeLine)
    {
        if (!Directory.Exists(outputPath))
            return (-2, $"Build not started: output directory does not exist: {outputPath}", "");
        var buildScript = Path.Combine(AppContext.BaseDirectory, "tools", "rb-26.2-to-26.3", "Build-WithDestinationJava.ps1");
        if (!File.Exists(buildScript))
            return (-2, "Build not started: the packaged destination-Java build helper is missing.", "");
        var psi = new ProcessStartInfo("powershell.exe")
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = outputPath
        };
        psi.ArgumentList.Add("-NoProfile");
        psi.ArgumentList.Add("-ExecutionPolicy");
        psi.ArgumentList.Add("Bypass");
        psi.ArgumentList.Add("-File");
        psi.ArgumentList.Add(buildScript);
        psi.ArgumentList.Add("-ProjectRoot");
        psi.ArgumentList.Add(outputPath);
        using var process = Process.Start(psi) ?? throw new InvalidOperationException("Could not start Gradle wrapper.");
        var (output, error) = await CaptureProcessOutputAsync(process, writeLine);
        return (process.ExitCode, output, error);
    }

    private static async Task<(string Output, string Error)> CaptureProcessOutputAsync(Process process, Action<string> writeLine)
    {
        var stdout = new StringBuilder();
        var stderr = new StringBuilder();
        async Task ReadLinesAsync(StreamReader reader, StringBuilder capture, bool isError)
        {
            while (await reader.ReadLineAsync() is { } line)
            {
                capture.AppendLine(line);
                writeLine(isError ? "[stderr] " + line : line);
            }
        }

        await Task.WhenAll(
            ReadLinesAsync(process.StandardOutput, stdout, false),
            ReadLinesAsync(process.StandardError, stderr, true));
        await process.WaitForExitAsync();
        return (stdout.ToString(), stderr.ToString());
    }

    private void AppendLogLine(string line)
    {
        if (InvokeRequired)
        {
            BeginInvoke(() => AppendLogLine(line));
            return;
        }
        _log.AppendText(line + Environment.NewLine);
        _log.SelectionStart = _log.TextLength;
        _log.ScrollToCaret();
    }

    private static TextBox NewTextBox(string text = "") => new()
    {
        Text = text,
        BackColor = Color.FromArgb(45, 48, 56),
        ForeColor = Color.White,
        BorderStyle = BorderStyle.FixedSingle,
        Dock = DockStyle.Fill
    };

    private static CheckBox NewCheck(string text, bool isChecked) => new()
    {
        Text = text,
        Checked = isChecked,
        AutoSize = true,
        ForeColor = Color.Gainsboro
    };

    private static Button NewButton(string text, int minWidth) => new()
    {
        Text = text,
        FlatStyle = FlatStyle.Flat,
        BackColor = Color.FromArgb(60, 64, 78),
        ForeColor = Color.White,
        MinimumSize = new Size(minWidth, 32),
        Height = 32,
        Dock = DockStyle.Fill,
        Cursor = Cursors.Hand,
        FlatAppearance = { BorderColor = Color.FromArgb(90, 96, 112) }
    };

    private static string? ExtractRejectionReason(string output)
    {
        var match = System.Text.RegularExpressions.Regex.Match(output ?? "", "\\\"Reason\\\"\\s*:\\s*\\\"(?<reason>[^\\\"]+)\\\"");
        return match.Success ? match.Groups["reason"].Value : null;
    }

}
