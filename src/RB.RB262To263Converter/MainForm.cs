using System.Diagnostics;
using System.Text;

namespace RB.RB262To263Converter;

public sealed class MainForm : Form
{
    private readonly TextBox _input = new() { Dock = DockStyle.Fill };
    private readonly TextBox _output = new() { Dock = DockStyle.Fill };
    private readonly TextBox _neo = new() { Text = "neoforge-26.3.0.7-beta", Dock = DockStyle.Fill };
    private readonly TextBox _log = new() { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill };
    private readonly Button _run = new() { Text = "Convert 26.2 → 26.3", AutoSize = true };
    private readonly Label _status = new() { Text = "Preview target: exact NeoForge 26.2 input → NeoForge 26.3 output", AutoSize = true, ForeColor = Color.DarkGoldenrod };

    public MainForm()
    {
        Text = "RB 26.2 → 26.3 Converter Preview";
        Width = 920;
        Height = 650;
        StartPosition = FormStartPosition.CenterScreen;
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(14), ColumnCount = 4, RowCount = 7 };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 140));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 82));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 82));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 52));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 32));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.Controls.Add(new Label { Text = "Input 26.2 project", AutoSize = true, Anchor = AnchorStyles.Left }, 0, 0);
        layout.Controls.Add(_input, 1, 0); layout.Controls.Add(CreateFolderBrowse(_input), 2, 0); layout.Controls.Add(CreateJarBrowse(_input), 3, 0);
        layout.Controls.Add(new Label { Text = "Output 26.3 project", AutoSize = true, Anchor = AnchorStyles.Left }, 0, 1);
        layout.Controls.Add(_output, 1, 1); layout.SetColumnSpan(_output, 2); layout.Controls.Add(CreateFolderBrowse(_output), 3, 1);
        layout.Controls.Add(new Label { Text = "NeoForge 26.3 pin", AutoSize = true, Anchor = AnchorStyles.Left }, 0, 2);
        layout.Controls.Add(_neo, 1, 2);
        layout.Controls.Add(new Label { Text = "Required until the official stable 26.3 artifact is pinned.", AutoSize = true, ForeColor = Color.DimGray, Anchor = AnchorStyles.Left }, 1, 3);
        layout.SetColumnSpan(_status, 4); layout.Controls.Add(_status, 0, 3);
        layout.SetColumnSpan(_run, 4); layout.Controls.Add(_run, 0, 4);
        layout.SetColumnSpan(_log, 4); layout.Controls.Add(_log, 0, 6);
        Controls.Add(layout);
        _run.Click += async (_, _) => await RunConversionAsync();
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
            var stdout = await process.StandardOutput.ReadToEndAsync(); var stderr = await process.StandardError.ReadToEndAsync(); await process.WaitForExitAsync();
            _log.Text = stdout + (string.IsNullOrWhiteSpace(stderr) ? "" : Environment.NewLine + stderr);
            _status.Text = process.ExitCode == 0 ? "Preview conversion completed; inspect MIGRATION_EVIDENCE.md before building." : $"Conversion failed with exit code {process.ExitCode}.";
        }
        catch (Exception ex) { _log.Text = ex.ToString(); _status.Text = "Conversion failed."; }
        finally { _run.Enabled = true; }
    }
}
