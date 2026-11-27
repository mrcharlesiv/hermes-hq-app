using System.Text.Json.Nodes;
using Hermes.Core.Composer;
using Hermes.Core.Net;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Composer;

/// ⋯ › Usage & Limits (App/Chat/Menus/UsageLimitsSheet.swift): how old the numbers are, Plan Limits (a bar per window,
/// each login of a pool, rate limits, the pace), This Chat (context, tokens, cache, speed, cost), Credits, Pay As You
/// Go balances, and Hermes's Full Usage Report for this chat. The gateway refreshes usage after a read, so the page
/// asks once more a few seconds later when something wasn't reported yet.
internal static class UsageDialog
{
    public static async Task ShowAsync(XamlRoot root, ChatComposer c)
    {
        var ui = DispatcherQueue.GetForCurrentThread();
        var dialog = new ContentDialog { Title = UsageLimitsModel.Title, CloseButtonText = "Done", DefaultButton = ContentDialogButton.Close };
        var fresh = Ui.Text("", 12, secondary: true);
        var page = new StackPanel { Spacing = 4 };
        var content = new StackPanel { Width = 480, Spacing = 4 };
        content.Children.Add(fresh);
        content.Children.Add(new ScrollViewer { Content = page, Height = 440 });
        dialog.Content = content;

        DateTimeOffset? updated = null;
        Exception? failure = null;
        JsonNode? usage = null;
        UsageRead<IReadOnlyDictionary<string, UsageBalance>> report = new UsageRead<IReadOnlyDictionary<string, UsageBalance>>.NotAsked();
        UsageRead<JsonNode> billing = new UsageRead<JsonNode>.NotAsked();
        string? reportText = null;
        var open = true;

        void Draw()
        {
            page.Children.Clear();
            var now = DateTimeOffset.UtcNow;
            fresh.Text = UsageLimitsModel.Freshness(updated, now, c.Offline) ?? "";
            var options = c.Options;
            var current = c.Current();
            page.Children.Add(Ui.Header(UsageLimitsModel.PlanLimits));
            if (options == null)
            {
                page.Children.Add(Ui.Text(failure != null ? UsageLimitsModel.CouldNotRead : UsageLimitsModel.Checking, 13, secondary: true));
                return;
            }
            var blocks = UsageLimitsModel.Blocks(options, current.Provider, now);
            if (blocks.Count == 0) page.Children.Add(Ui.Text(UsageLimitsModel.NoPlans, 13, secondary: true));
            foreach (var block in blocks)
            {
                var head = block.Title + (block.Account is { } a ? $" · {a}" : "") + (block.Current ? $" · {UsageLimitsModel.ThisChat}" : "");
                page.Children.Add(Ui.Text(head, 14, bold: true));
                foreach (var gauge in block.Gauges) page.Children.Add(Gauge(gauge));
                foreach (var note in block.Notes) page.Children.Add(Ui.Text(note, 12, secondary: true));
                if (block.Current && block.Account == null
                    && UsageLimitsModel.BalanceInItsOwnChat.Contains(block.Provider)
                    && report is UsageRead<IReadOnlyDictionary<string, UsageBalance>>.Done d && d.Value.TryGetValue(block.Provider, out var bal))
                    page.Children.Add(Pair("Credits balance", new UsageBalanceRow(block.Provider, "", true, bal, null).Value));
            }

            var rows = UsageLimitsModel.ChatRows(usage, ModelPricesModel.MenuSubtitle(options, current.Id, current.Provider, ComposerServices.ModelsDev.Stored()));
            if (rows.Count > 0)
            {
                page.Children.Add(Ui.Header(UsageLimitsModel.ThisChat));
                foreach (var row in rows)
                {
                    page.Children.Add(Pair(row.Label, row.Value));
                    if (row.Bar is { } bar) page.Children.Add(new ProgressBar { Value = bar * 100, Maximum = 100, Margin = new Thickness(0, 0, 0, 2) });
                    if (row.Note != null) page.Children.Add(Ui.Text(row.Note, 12, secondary: true));
                }
            }
            var credits = UsageLimitsModel.CreditLines(usage);
            if (credits.Count > 0)
            {
                page.Children.Add(Ui.Header(UsageLimitsModel.Credits));
                foreach (var line in credits) page.Children.Add(Ui.Text(line, 13));
            }

            var balances = UsageLimitsModel.BalanceRows(options, blocks, current.Provider, report, billing, c.Offline);
            if (balances.Count > 0)
            {
                page.Children.Add(Ui.Header(UsageLimitsModel.PayAsYouGo));
                var loud = balances.Where(b => !b.Quiet).ToList();
                var quiet = balances.Where(b => b.Quiet).ToList();
                foreach (var b in loud)
                {
                    page.Children.Add(Pair(b.Label, b.Value));
                    if (b.Note != null) page.Children.Add(Ui.Text(b.Note, 12, secondary: true));
                }
                if (quiet.Count > 0)
                {
                    var inner = new StackPanel();
                    foreach (var b in quiet) inner.Children.Add(Pair(b.Label, b.Value));
                    page.Children.Add(new Expander
                    {
                        Header = $"No Balance Reported {quiet.Count}", Content = inner,
                        HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
                    });
                }
                page.Children.Add(Ui.Text(UsageLimitsModel.BalanceFooter, 12, secondary: true));
            }

            page.Children.Add(Ui.Header(UsageLimitsModel.UsageReport));
            var full = new Expander
            {
                Header = UsageLimitsModel.FullUsageReport,
                Content = new TextBlock
                {
                    Text = reportText ?? (report is UsageRead<IReadOnlyDictionary<string, UsageBalance>>.Failed f ? f.Why : UsageLimitsModel.BalanceChecking),
                    FontFamily = Ui.Res<FontFamily>("CodeFont"), FontSize = 12, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true,
                },
                HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left,
            };
            page.Children.Add(full);
            page.Children.Add(Ui.Text(UsageLimitsModel.FullReportFooter, 12, secondary: true));
        }

        async Task Read(bool again)
        {
            try
            {
                await c.LoadModelsAsync(reread: true);
                updated = DateTimeOffset.UtcNow;
                failure = null;
            }
            catch (Exception x) { failure = x; }
            ui.TryEnqueue(Draw);
            if (!again && c.Options is { } o && UsageLimitsModel.WorthAskingAgain(o))
            {
                await Task.Delay(TimeSpan.FromSeconds(4));
                if (open) await Read(again: true);
            }
        }

        async Task ReadChat()
        {
            if (c.Offline) return;
            try { usage = await c.SessionUsageAsync(); } catch (Exception) { }
            ui.TryEnqueue(Draw);
            report = new UsageRead<IReadOnlyDictionary<string, UsageBalance>>.Pending();
            try
            {
                reportText = await c.UsageReportAsync();
                report = new UsageRead<IReadOnlyDictionary<string, UsageBalance>>.Done(UsageLimitsModel.ReportedBalances(reportText));
                if (reportText.Trim().Length == 0) reportText = UsageLimitsModel.NoReport;
            }
            catch (Exception x) { report = new UsageRead<IReadOnlyDictionary<string, UsageBalance>>.Failed(MenusText.Of(x)); }
            ui.TryEnqueue(Draw);
        }

        async Task ReadBilling()
        {
            // billing.state reads the gateway's own Nous login: asked in the main bot's chats only.
            if (c.Offline || c.Session.Profile != "default") return;
            billing = new UsageRead<JsonNode>.Pending();
            try { billing = new UsageRead<JsonNode>.Done(await c.BillingStateAsync()); }
            catch (Exception x) { billing = new UsageRead<JsonNode>.Failed(MenusText.Of(x)); }
            ui.TryEnqueue(Draw);
        }

        Draw();
        _ = Task.Run(() => Read(false));
        _ = Task.Run(ReadChat);
        _ = Task.Run(ReadBilling);
        try { await Ui.Show(root, dialog); }
        finally { open = false; }
    }

    private static UIElement Gauge(UsageGauge g)
    {
        var box = new StackPanel { Spacing = 2, Margin = new Thickness(0, 4, 0, 4) };
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(Ui.Text(g.Title, 13, wrap: false));
        var detail = Ui.Text(g.Detail, 12, secondary: true, wrap: false);
        Grid.SetColumn(detail, 1);
        grid.Children.Add(detail);
        box.Children.Add(grid);
        var bar = new ProgressBar { Value = g.Left * 100, Maximum = 100 };
        if (g.Low) bar.Foreground = Ui.Res<Brush>("SystemFillColorCriticalBrush");
        else if (g.Warning) bar.Foreground = Ui.Res<Brush>("SystemFillColorCautionBrush");
        box.Children.Add(bar);
        if (g.Pace is { } pace && pace is not UsagePace.Steady) box.Children.Add(Ui.Text(pace.Text, 12, secondary: true));
        return box;
    }

    private static UIElement Pair(string label, string value)
    {
        var grid = new Grid { Margin = new Thickness(0, 2, 0, 2) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(Ui.Text(label, 13, wrap: false));
        var v = Ui.Text(value, 13, secondary: true, wrap: false);
        Grid.SetColumn(v, 1);
        grid.Children.Add(v);
        return grid;
    }
}
