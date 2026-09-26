using System.Diagnostics;
using System.IO.Compression;
using System.Reflection;
using System.Text;
using Microsoft.Win32;

namespace RB.RB262To263Converter.Setup;

public sealed class SetupForm : Form
{
    private const string AppDisplayName = "RB 26.2 to 26.3 Converter";
    private const string ExeName = "RB-26.2-to-26.3-Converter.exe";
    private const string UninstallRegKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\RB-26.2-to-26.3-Converter";
    private const string AppPathsKey = @"Software\Microsoft\Windows\CurrentVersion\App Paths\RB-26.2-to-26.3-Converter.exe";
    private const string DesktopLnk = "RB 26.2 to 26.3 Converter.lnk";
    private const string StartMenuFolder = "RB 26.2 to 26.3 Converter";

    private readonly TextBox _txtDir = new();
    private readonly CheckBox _chkDesktop = new() { Text = "Create desktop shortcut", Checked = true, AutoSize = true };
    private readonly CheckBox _chkStartMenu = new() { Text = "Create Start Menu shortcut", Checked = true, AutoSize = true };
    private readonly ProgressBar _progress = new() { Style = ProgressBarStyle.Continuous, Minimum = 0, Maximum = 100 };
    private readonly Button _btnInstall = new() { Text = "Install", Height = 32, Width = 120 };
    private readonly Button _btnUninstall = new() { Text = "Uninstall", Height = 32, Width = 120 };
    private readonly Button _btnBrowse = new() { Text = "Browse...", Height = 28, Width = 100 };
    private readonly Button _btnCancel = new() { Text = "Close", Height = 32, Width = 100 };
    private readonly Label _status = new() { AutoSize = false, Height = 40 };
    private bool _busy;

    public SetupForm()
    {
        Text = "Install " + AppDisplayName;
        ClientSize = new Size(600, 400);
        MinimumSize = new Size(580, 380);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { /* optional */ }
        BackColor = Color.FromArgb(32, 34, 40);
        ForeColor = Color.Gainsboro;
        Font = new Font("Segoe UI", 9.5f);
        Padding = new Padding(0, 0, 0, 12);
        AutoScaleMode = AutoScaleMode.Dpi;

        var title = new Label
        {
            Text = AppDisplayName + " v" + (Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "3.0.0"),
            Font = new Font("Segoe UI Semibold", 14f),
            ForeColor = Color.White,
            Location = new Point(24, 18),
            AutoSize = true
        };
        var sub = new Label
        {
            Text = "Installs a portable tool for NeoForge 26.2 → NeoForge 26.3 conversion (preview).\nUninstall is available here, from Start Menu, or Apps & features.",
            ForeColor = Color.FromArgb(160, 200, 160),
            Location = new Point(24, 52),
            Size = new Size(550, 40)
        };

        var lbl = new Label { Text = "Install folder:", Location = new Point(24, 104), AutoSize = true };
        _txtDir.Location = new Point(24, 130);
        _txtDir.Width = 440;
        _txtDir.Height = 26;
        _txtDir.BackColor = Color.FromArgb(45, 48, 56);
        _txtDir.ForeColor = Color.White;
        _txtDir.BorderStyle = BorderStyle.FixedSingle;
        _txtDir.Text = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "RB-Legacy-Java-Converter");

        _btnBrowse.Location = new Point(474, 128);
        _btnBrowse.FlatStyle = FlatStyle.Flat;
        _btnBrowse.BackColor = Color.FromArgb(60, 64, 78);
        _btnBrowse.ForeColor = Color.White;

        _chkDesktop.Location = new Point(24, 174);
        _chkDesktop.ForeColor = Color.Gainsboro;
        _chkStartMenu.Location = new Point(24, 204);
        _chkStartMenu.ForeColor = Color.Gainsboro;

        _progress.Location = new Point(24, 246);
        _progress.Size = new Size(552, 22);

        _status.Location = new Point(24, 286);
        _status.Size = new Size(220, 48);
        _status.ForeColor = Color.Gainsboro;

        StylePrimary(_btnInstall, new Point(250, 292));
        StyleDanger(_btnUninstall, new Point(378, 292));
        StyleSecondary(_btnCancel, new Point(496, 292));

        Controls.AddRange(new Control[]
        {
            title, sub, lbl, _txtDir, _btnBrowse, _chkDesktop, _chkStartMenu,
            _progress, _status, _btnInstall, _btnUninstall, _btnCancel
        });

        _btnBrowse.Click += (_, _) =>
        {
            using var dlg = new FolderBrowserDialog
            {
                Description = "Choose install folder",
                UseDescriptionForTitle = true,
                ShowNewFolderButton = true
            };
            if (Directory.Exists(_txtDir.Text))
                dlg.SelectedPath = _txtDir.Text;
            if (dlg.ShowDialog(this) == DialogResult.OK)
                _txtDir.Text = dlg.SelectedPath;
        };

        _btnCancel.Click += (_, _) => Close();
        _btnInstall.Click += async (_, _) => await InstallAsync();
        _btnUninstall.Click += async (_, _) => await UninstallAsync();
    }

    private static void StylePrimary(Button b, Point loc)
    {
        b.Location = loc;
        b.Size = new Size(120, 36);
        b.FlatStyle = FlatStyle.Flat;
        b.BackColor = Color.FromArgb(46, 120, 80);
        b.ForeColor = Color.White;
        b.FlatAppearance.BorderColor = Color.FromArgb(70, 160, 100);
    }

    private static void StyleDanger(Button b, Point loc)
    {
        b.Location = loc;
        b.Size = new Size(110, 36);
        b.FlatStyle = FlatStyle.Flat;
        b.BackColor = Color.FromArgb(120, 50, 50);
        b.ForeColor = Color.White;
        b.FlatAppearance.BorderColor = Color.FromArgb(160, 80, 80);
    }

    private static void StyleSecondary(Button b, Point loc)
    {
        b.Location = loc;
        b.Size = new Size(80, 36);
        b.FlatStyle = FlatStyle.Flat;
        b.BackColor = Color.FromArgb(60, 64, 78);
        b.ForeColor = Color.White;
    }

    private async Task InstallAsync()
    {
        if (_busy) return;
        var dest = _txtDir.Text.Trim();
        if (string.IsNullOrWhiteSpace(dest))
        {
            MessageBox.Show(this, "Choose an install folder.", "Setup", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }

        try { dest = Path.GetFullPath(dest); }
        catch (Exception ex)
        {
            MessageBox.Show(this, "Invalid folder: " + ex.Message, "Setup", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        _busy = true;
        SetUiEnabled(false);
        _status.Text = "Installing...";
        _progress.Value = 5;

        try
        {
            await Task.Run(() => InstallCore(dest));
            _progress.Value = 100;
            _status.Text = "Installation complete.";
            _status.ForeColor = Color.LightGreen;

            var exe = Path.Combine(dest, ExeName);
            var r = MessageBox.Show(this,
                "Installed successfully to:\n" + dest +
                "\n\nUninstall via:\n• This setup's Uninstall button\n• Start Menu → " + AppDisplayName + " → Uninstall\n• Windows Apps & features\n\nLaunch " + AppDisplayName + " now?",
                "Setup complete", MessageBoxButtons.YesNo, MessageBoxIcon.Information);
            if (r == DialogResult.Yes && File.Exists(exe))
                Process.Start(new ProcessStartInfo(exe) { UseShellExecute = true, WorkingDirectory = dest });
        }
        catch (Exception ex)
        {
            _status.Text = "Install failed.";
            _status.ForeColor = Color.Salmon;
            MessageBox.Show(this, ex.Message, "Setup failed", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        finally
        {
            _busy = false;
            SetUiEnabled(true);
        }
    }

    private async Task UninstallAsync()
    {
        if (_busy) return;
        var dest = _txtDir.Text.Trim();
        try { dest = Path.GetFullPath(dest); } catch { /* use as-is */ }

        if (!Directory.Exists(dest) && !IsRegisteredInstall(out dest))
        {
            MessageBox.Show(this,
                "No install found at that folder, and no registered " + AppDisplayName + " install was found.",
                "Uninstall", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        var confirm = MessageBox.Show(this,
            "Uninstall " + AppDisplayName + " from:\n" + dest +
            "\n\nThis removes the app, shortcuts, and Apps & features entry.",
            "Confirm uninstall", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
        if (confirm != DialogResult.Yes) return;

        _busy = true;
        SetUiEnabled(false);
        _status.Text = "Uninstalling...";
        _progress.Value = 10;

        try
        {
            await Task.Run(() => UninstallCore(dest));
            _progress.Value = 100;
            _status.Text = "Uninstalled.";
            _status.ForeColor = Color.LightGreen;
            MessageBox.Show(this, AppDisplayName + " has been uninstalled.", "Uninstall complete",
                MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
        catch (Exception ex)
        {
            _status.Text = "Uninstall failed.";
            _status.ForeColor = Color.Salmon;
            MessageBox.Show(this, ex.Message, "Uninstall failed", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        finally
        {
            _busy = false;
            SetUiEnabled(true);
        }
    }

    private void SetUiEnabled(bool enabled)
    {
        _btnInstall.Enabled = enabled;
        _btnUninstall.Enabled = enabled;
        _btnBrowse.Enabled = enabled;
        _txtDir.Enabled = enabled;
    }

    private void InstallCore(string dest)
    {
        Directory.CreateDirectory(dest);
        Report(10, "Locating package...");

        string? payloadZip = null;
        try
        {
            payloadZip = ExtractEmbeddedPayloadZip();
            if (payloadZip is null)
                throw new InvalidOperationException(
                    "This installer has no embedded portable package.\n\nRebuild with scripts\\Build-Release.ps1 so portable-payload.zip is embedded into the Setup EXE.");

            Report(20, "Extracting tools...");
            ExtractZip(payloadZip, dest, progress => Report(20 + (int)(progress * 50), "Extracting..."));
        }
        finally
        {
            if (payloadZip is not null)
            {
                try { File.Delete(payloadZip); } catch { /* temp cleanup */ }
            }
        }

        var exe = Path.Combine(dest, ExeName);
        if (!File.Exists(exe))
            throw new InvalidOperationException("Package extracted but " + ExeName + " is missing.");

        var iconPath = Path.Combine(dest, "app.ico");
        TryExtractEmbeddedIcon(iconPath);

        Report(75, "Writing uninstaller...");
        WriteUninstaller(dest, exe);

        Report(85, "Creating shortcuts...");
        if (_chkDesktop.Checked)
            CreateShortcut(
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), DesktopLnk),
                exe, dest, null, exe);

        var sm = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.StartMenu), "Programs", StartMenuFolder);
        if (_chkStartMenu.Checked)
        {
            Directory.CreateDirectory(sm);
            CreateShortcut(Path.Combine(sm, AppDisplayName + ".lnk"), exe, dest, null, exe);
            CreateShortcut(Path.Combine(sm, "Uninstall " + AppDisplayName + ".lnk"),
                Path.Combine(dest, "Uninstall.cmd"), dest, null, exe);
        }

        Report(92, "Registering Apps & features...");
        RegisterUninstall(dest, exe);

        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(AppPathsKey);
            key?.SetValue("", exe);
            key?.SetValue("Path", dest);
        }
        catch { /* non-fatal */ }

        File.WriteAllText(Path.Combine(dest, "UNINSTALL.txt"),
            "Uninstall " + AppDisplayName + ":\r\n" +
            "• Run Uninstall.cmd in this folder\r\n" +
            "• Or Start Menu → " + AppDisplayName + " → Uninstall\r\n" +
            "• Or Windows Settings → Apps → " + AppDisplayName + "\r\n" +
            "• Or open the Setup and click Uninstall\r\n");

        Report(100, "Done.");
    }

    private void UninstallCore(string dest)
    {
        Report(20, "Stopping app if running...");
        try
        {
            foreach (var p in Process.GetProcessesByName(Path.GetFileNameWithoutExtension(ExeName)))
            {
                try { p.Kill(entireProcessTree: true); } catch { /* ignore */ }
            }
        }
        catch { /* ignore */ }

        Report(40, "Removing shortcuts...");
        TryDelete(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), DesktopLnk));
        var sm = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.StartMenu), "Programs", StartMenuFolder);
        TryDeleteDir(sm);

        Report(60, "Removing registry entries...");
        try { Registry.CurrentUser.DeleteSubKeyTree(UninstallRegKey, throwOnMissingSubKey: false); } catch { /* ignore */ }
        try { Registry.CurrentUser.DeleteSubKeyTree(AppPathsKey, throwOnMissingSubKey: false); } catch { /* ignore */ }

        Report(80, "Removing install folder...");
        var cmd = "timeout /t 1 /nobreak >nul & rmdir /s /q \"" + dest + "\"";
        Process.Start(new ProcessStartInfo
        {
            FileName = "cmd.exe",
            Arguments = "/c " + cmd,
            UseShellExecute = false,
            CreateNoWindow = true
        });

        Report(100, "Done.");
    }

    private static bool IsRegisteredInstall(out string installLocation)
    {
        installLocation = "";
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(UninstallRegKey);
            var loc = key?.GetValue("InstallLocation") as string;
            if (!string.IsNullOrWhiteSpace(loc) && Directory.Exists(loc))
            {
                installLocation = loc;
                return true;
            }
        }
        catch { /* ignore */ }
        return false;
    }

    private static void WriteUninstaller(string dest, string exe)
    {
        var version = Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "3.0.0";
        var ps1 = Path.Combine(dest, "Uninstall.ps1");
        var cmd = Path.Combine(dest, "Uninstall.cmd");

        var fullPs = @"
Add-Type -AssemblyName System.Windows.Forms
$ErrorActionPreference = 'Stop'
$InstallDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Product = '" + AppDisplayName.Replace("'", "''") + @"'
$ExeBase = '" + Path.GetFileNameWithoutExtension(ExeName).Replace("'", "''") + @"'
$DesktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) '" + DesktopLnk.Replace("'", "''") + @"'
$StartMenu = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs\\" + StartMenuFolder.Replace("'", "''") + @"'
$UninstallKey = 'HKCU:\\" + UninstallRegKey.Replace("'", "''") + @"'
$AppPaths = 'HKCU:\\" + AppPathsKey.Replace("'", "''") + @"'

$r = [System.Windows.Forms.MessageBox]::Show(
  ""Uninstall $Product from:`n$InstallDir`n`nContinue?"",
  ""Uninstall $Product"",
  [System.Windows.Forms.MessageBoxButtons]::YesNo,
  [System.Windows.Forms.MessageBoxIcon]::Question)
if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { exit 0 }

Get-Process -Name $ExeBase -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 400

if (Test-Path -LiteralPath $DesktopLnk) { Remove-Item -LiteralPath $DesktopLnk -Force -ErrorAction SilentlyContinue }
if (Test-Path -LiteralPath $StartMenu) { Remove-Item -LiteralPath $StartMenu -Recurse -Force -ErrorAction SilentlyContinue }
if (Test-Path $UninstallKey) { Remove-Item $UninstallKey -Recurse -Force -ErrorAction SilentlyContinue }
if (Test-Path $AppPaths) { Remove-Item $AppPaths -Recurse -Force -ErrorAction SilentlyContinue }

$cmd = 'timeout /t 1 /nobreak >nul & rmdir /s /q ""' + $InstallDir + '""'
Start-Process -FilePath cmd.exe -ArgumentList '/c', $cmd -WindowStyle Hidden
[System.Windows.Forms.MessageBox]::Show(""$Product has been uninstalled."", ""Uninstall complete"")
";
        File.WriteAllText(ps1, fullPs, Encoding.UTF8);

        File.WriteAllText(cmd,
            "@echo off\r\n" +
            "cd /d \"%~dp0\"\r\n" +
            "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"%~dp0Uninstall.ps1\"\r\n",
            Encoding.ASCII);

        File.WriteAllText(Path.Combine(dest, "version.txt"), version);
    }

    private static void RegisterUninstall(string dest, string exe)
    {
        var version = Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "3.0.0";
        var versionFile = Path.Combine(dest, "version.txt");
        if (File.Exists(versionFile))
            version = File.ReadAllText(versionFile).Trim();

        var uninstallCmd = Path.Combine(dest, "Uninstall.cmd");
        using var key = Registry.CurrentUser.CreateSubKey(UninstallRegKey);
        if (key is null) return;
        key.SetValue("DisplayName", AppDisplayName);
        key.SetValue("DisplayVersion", version);
        key.SetValue("Publisher", "RobbieB1980");
        key.SetValue("InstallLocation", dest);
        key.SetValue("DisplayIcon", exe);
        key.SetValue("UninstallString", "\"" + uninstallCmd + "\"");
        key.SetValue("QuietUninstallString", "\"" + uninstallCmd + "\"");
        key.SetValue("NoModify", 1, RegistryValueKind.DWord);
        key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
        try
        {
            long size = 0;
            foreach (var f in Directory.EnumerateFiles(dest, "*", SearchOption.AllDirectories))
                size += new FileInfo(f).Length;
            key.SetValue("EstimatedSize", (int)Math.Max(1, size / 1024), RegistryValueKind.DWord);
        }
        catch { /* optional */ }
    }

    private static void TryExtractEmbeddedIcon(string destIco)
    {
        if (File.Exists(destIco)) return;
        try
        {
            using var icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath ?? Application.ExecutablePath);
            if (icon is null) return;
            using var fs = File.Create(destIco);
            icon.Save(fs);
        }
        catch { /* optional */ }
    }

    /// <summary>
    /// Installer must only use the payload embedded in this EXE.
    /// Sibling portable ZIPs beside Setup are ignored so an older zip cannot override a newer installer.
    /// </summary>
    private static string? ExtractEmbeddedPayloadZip()
    {
        var asm = Assembly.GetExecutingAssembly();
        var resourceName = asm.GetManifestResourceNames()
            .FirstOrDefault(n => n.EndsWith("portable-payload.zip", StringComparison.OrdinalIgnoreCase)
                                 || n.Equals("portable-payload.zip", StringComparison.OrdinalIgnoreCase));
        if (resourceName is null)
            return null;

        var temp = Path.Combine(Path.GetTempPath(), "RB-26.2-to-26.3-payload-" + Guid.NewGuid().ToString("N") + ".zip");
        using (var stream = asm.GetManifestResourceStream(resourceName)!)
        using (var fs = File.Create(temp))
            stream.CopyTo(fs);
        return temp;
    }

    private static void ExtractZip(string zipPath, string dest, Action<double> progress)
    {
        using var zip = ZipFile.OpenRead(zipPath);
        var rootPrefix = DetectSingleRootPrefix(zip.Entries.Select(e => e.FullName));
        var total = Math.Max(1, zip.Entries.Count(e => !string.IsNullOrEmpty(e.Name)));
        var done = 0;

        foreach (var entry in zip.Entries)
        {
            var name = entry.FullName.Replace('\\', '/');
            if (!string.IsNullOrEmpty(rootPrefix) && name.StartsWith(rootPrefix, StringComparison.OrdinalIgnoreCase))
                name = name[rootPrefix.Length..];
            if (string.IsNullOrWhiteSpace(name)) continue;

            var target = Path.Combine(dest, name.Replace('/', Path.DirectorySeparatorChar));
            if (name.EndsWith('/'))
            {
                Directory.CreateDirectory(target);
                continue;
            }

            var dir = Path.GetDirectoryName(target);
            if (!string.IsNullOrEmpty(dir))
                Directory.CreateDirectory(dir);

            entry.ExtractToFile(target, overwrite: true);
            done++;
            progress(done / (double)total);
        }
    }

    private static string DetectSingleRootPrefix(IEnumerable<string> names)
    {
        var roots = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var n in names)
        {
            var norm = n.Replace('\\', '/').TrimStart('/');
            if (string.IsNullOrEmpty(norm)) continue;
            var slash = norm.IndexOf('/');
            if (slash <= 0) return "";
            roots.Add(norm[..(slash + 1)]);
            if (roots.Count > 1) return "";
        }
        return roots.Count == 1 ? roots.First() : "";
    }

    private void Report(int value, string status)
    {
        if (IsDisposed) return;
        if (InvokeRequired)
        {
            BeginInvoke(() => Report(value, status));
            return;
        }
        _progress.Value = Math.Clamp(value, 0, 100);
        _status.Text = status;
    }

    private static void CreateShortcut(string lnkPath, string target, string workingDir, string? args = null, string? iconPath = null)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(lnkPath)!);
        var iconLine = string.IsNullOrEmpty(iconPath)
            ? ""
            : $"$s.IconLocation = '{EscapePs(iconPath)},0'";
        var ps = $@"
$w = New-Object -ComObject WScript.Shell
$s = $w.CreateShortcut('{EscapePs(lnkPath)}')
$s.TargetPath = '{EscapePs(target)}'
$s.WorkingDirectory = '{EscapePs(workingDir)}'
{(args is null ? "" : $"$s.Arguments = '{EscapePs(args)}'")}
{iconLine}
$s.Description = '{EscapePs(AppDisplayName)}'
$s.Save()
";
        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = "-NoProfile -ExecutionPolicy Bypass -Command " + Quote(ps),
            UseShellExecute = false,
            CreateNoWindow = true
        };
        using var p = Process.Start(psi);
        p?.WaitForExit(15000);
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { /* ignore */ }
    }

    private static void TryDeleteDir(string path)
    {
        try { if (Directory.Exists(path)) Directory.Delete(path, recursive: true); } catch { /* ignore */ }
    }

    private static string EscapePs(string s) => s.Replace("'", "''");
    private static string Quote(string s) => "\"" + s.Replace("\"", "\\\"") + "\"";
}

