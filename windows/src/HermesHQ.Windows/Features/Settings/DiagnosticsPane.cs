using System.IO.Compression;
using Hermes.Core.Gateways;
using Hermes.Core.Settings;
using HermesHQ.Services;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;

namespace HermesHQ.Features.Settings;

/// Settings › About › Diagnostics (App/Settings/DiagnosticsView.swift): what went wrong, in plain words to copy into a
/// message. The intro with Copy Diagnostics and Share Logs… under it, then App, Gateway and Recent errors. The page and
/// the copied text are built from the same rows (DiagnosticsReport); what is copied is redacted line by line.
internal static class DiagnosticsPane
{
    public static (IReadOnlyList<DiagnosticsReport.Section> Sections, IReadOnlyList<DiagnosticsReport.ErrorGroup> Errors) Snapshot()
    {
        var info = SettingsFeature.Gateway();
        var app = new List<DiagnosticsReport.Row>
        {
            new("Version", SettingsFeature.AppVersion),
            new(DeviceWord.System, Environment.OSVersion.Version.ToString()),
            new("Network", System.Net.NetworkInformation.NetworkInterface.GetIsNetworkAvailable() ? "Online" : "Offline"),
        };
        var gateway = new List<DiagnosticsReport.Row>
        {
            new("Address", info.Host.Length > 0 ? info.Host : "Unknown"),
            new("Connection", SettingsWords.StateWords(info.State), "state"),
            new("Bots", info.Bots.ToString(System.Globalization.CultureInfo.InvariantCulture), "roster"),
            new("Hermes", info.Version ?? "Unavailable", "version"),
        };
        return ([new("App", app), new("Gateway", gateway)], ErrorLog.Recent());
    }

    public static string LogsSummary =>
        $"The app keeps a log of what it did and any crashes, on this {DeviceWord.Name} only. No messages or passwords are in it.";

    public static FrameworkElement Make()
    {
        var (sections, errors) = Snapshot();
        var copy = new Button { Content = "Copy Diagnostics" };
        AutomationProperties.SetAutomationId(copy, "diagnostics.copy");
        copy.Click += async (_, _) =>
        {
            var (s, e) = Snapshot();
            if (!SafeClipboard.TrySetText(DiagnosticsReport.Text(s, e))) return;
            copy.Content = "Copied";
            AutomationProperties.SetName(copy, "Copied");
            await Task.Delay(2000);
            copy.Content = "Copy Diagnostics";
            AutomationProperties.SetName(copy, "Copy Diagnostics");
        };
        var share = new Button { Content = "Share Logs…" };
        share.Click += async (_, _) => await ShareLogsAsync();
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        buttons.Children.Add(copy);
        buttons.Children.Add(share);
        var intro = new StackPanel { Spacing = 14, Padding = new Thickness(14, 12, 14, 12) };
        var introText = new TextBlock { Text = DiagnosticsReport.Intro, FontSize = 12, TextWrapping = TextWrapping.Wrap, Foreground = Kit.B("TextFillColorSecondaryBrush") };
        AutomationProperties.SetAutomationId(introText, "diagnostics.intro");
        intro.Children.Add(introText);
        intro.Children.Add(buttons);

        var parts = new List<UIElement?> { Kit.Section(null, LogsSummary, intro) };
        foreach (var section in sections)
        {
            var rows = section.Rows.Select(r => (UIElement?)Kit.Value(DiagnosticsReport.TitleCase(r.Label), r.Value)).ToList();
            parts.Add(Kit.Section(section.Title, null, [.. rows]));
        }
        var errorRows = errors.Count == 0
            ? [Kit.Row(null, "None since launch.")]
            : errors.Select(g =>
            {
                var meta = DiagnosticsReport.ErrorMeta(g);
                var stack = new StackPanel { Spacing = 2, Padding = new Thickness(14, 8, 14, 8) };
                stack.Children.Add(new TextBlock { Text = g.Message, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, FontWeight = FontWeights.Normal });
                if (meta.Length > 0) stack.Children.Add(new TextBlock { Text = meta, FontSize = 12, Foreground = Kit.B("TextFillColorSecondaryBrush") });
                return (UIElement?)stack;
            }).ToList();
        parts.Add(Kit.Section("Recent errors", null, [.. errorRows]));
        return Kit.Page([.. parts]);
    }

    /// Share Logs…: the logs folder as one zip, shown in File Explorer (the Mac's share sheet).
    private static async Task ShareLogsAsync()
    {
        try
        {
            var folder = Path.Combine(AppPaths.Root, "logs");
            var zip = Path.Combine(Path.GetTempPath(), $"Hermes HQ Logs {DateTime.Now:yyyy-MM-dd HH.mm.ss}.zip");
            await Task.Run(() =>
            {
                Directory.CreateDirectory(folder);
                if (File.Exists(zip)) File.Delete(zip);
                // The log is open for appending: copy it first so the zip reads a closed file.
                var staging = Path.Combine(Path.GetTempPath(), "HermesHQ-logs-" + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(staging);
                foreach (var f in Directory.GetFiles(folder)) File.Copy(f, Path.Combine(staging, Path.GetFileName(f)));
                ZipFile.CreateFromDirectory(staging, zip);
                Directory.Delete(staging, true);
            });
            AppLog.Note("screen", "share logs");
            System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{zip}\"");
        }
        catch (Exception x) when (x is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            AppLog.Note("screen", $"share logs failed: {x.GetType().Name}");
        }
    }
}
