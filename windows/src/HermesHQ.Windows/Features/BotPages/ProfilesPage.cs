using Hermes.Core.BotPages;
using Hermes.Core.Composer;
using Hermes.Core.Model;
using HermesHQ.Controls;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Features.BotPages;

/// Bot Profiles (App/Pages/More/Profiles/ProfilesViews.swift, ProfilesModel.swift): the list (the bot's head, its name,
/// the model and skills, search on the bar), a profile's page (facts, Instructions, Rename Bot…, Delete Bot…) and the
/// SOUL.md editor. New Profile is not offered on the list (Bots › New Bot is the one way to make a bot, D-M9); the
/// argument "new" (Navigator.Open("profiles", "new"), the Bots list's New Bot) opens New Bot over it.
[Microsoft.UI.Xaml.Data.Bindable]
public sealed partial class ProfilesPage : PageHost
{
    public static SoulDraftStore Drafts { get; } = new(Path.Combine(AppPaths.Root, "cache", "pages"));

    protected override Screen First(object? argument)
    {
        var list = new ProfilesList();
        if (argument as string == "new") DispatcherQueue.TryEnqueue(() => _ = NewBotDialog.ShowAsync(this));
        return list;
    }

    protected override void Reopened(object? argument)
    {
        if (argument as string == "new") _ = NewBotDialog.ShowAsync(this);
    }
}

internal sealed class ProfilesList : Screen
{
    private ProfilesApi Api => new(Host.Gateway!);
    private IReadOnlyList<ProfileRow> _rows = [];
    private bool _loaded;
    private string? _failure;
    private string? _stale;
    private string? _renaming;
    private readonly PageSearchBox _search = new(ProfileName.SearchPlaceholder);
    private bool _wasOnline = true;

    public override string Title => "Bot Profiles";

    public ProfilesList()
    {
        _search.QueryChanged += _ => Redraw();
    }

    public override IEnumerable<UIElement> Bar() => [_search];

    public override void Shown()
    {
        _search.FocusOn(Host);
        Host.OnlineChanged -= Link;
        Host.OnlineChanged += Link;
        if (!_loaded) Load();
    }

    public override void Left() => Host.OnlineChanged -= Link;

    /// The link is back: a list that failed, or went stale, reads again by itself.
    private void Link(bool online)
    {
        if (online && !_wasOnline && (!_loaded || _stale != null)) Load();
        _wasOnline = online;
    }

    public override void Refresh() => Load();

    internal ProfileRow? Row(string name) => _rows.FirstOrDefault(r => r.Name == name);
    internal IReadOnlyList<ProfileRow> Rows => _rows;
    internal string? Renaming => _renaming;

    public void Load()
    {
        if (Host.Gateway == null) return;
        _ = Read();
    }

    internal async Task Read()
    {
        try
        {
            var fresh = await Api.ListAsync();
            Host.Ui(() => { _rows = fresh; _loaded = true; _failure = null; _stale = null; Redraw(); Host.Top?.Redraw(); });
        }
        catch (Exception e)
        {
            var reason = PagesRest.IsNotAvailable(e) ? PagesRest.OlderHermes : PagesRest.Reason(e);
            AppLog.Note("pages", "profiles list failed");
            Host.Ui(() => { if (_rows.Count == 0) _failure = reason; else _stale = reason; Redraw(); });
        }
    }

    internal Bot? Bot(ProfileRow row) => Host.Client?.Bots?.FirstOrDefault(b => b.Name == row.Name);
    internal string TitleOf(ProfileRow row) => ProfileName.Title(row, Bot(row)?.DisplayName);
    internal string? ModelName(ProfileRow row) => row.Model is { } m ? ModelNames.DisplayModelName(m) : null;
    internal string Subtitle(ProfileRow row) => ProfileName.Subtitle(ModelName(row), row.SkillCount);
    internal bool CanWrite => Host.Online;
    /// Rename and Delete: never for the default profile, or offline.
    internal bool CanChange(ProfileRow row) => CanWrite && !row.IsDefault && _renaming == null;

    public override UIElement Build()
    {
        if (!_loaded && _failure == null) return Kit.Loading("Loading profiles…", Load);
        if (!_loaded) return Kit.Error(ProfileName.LoadFailTitle, _failure!, Load, page: "Bot Profiles");
        var rows = ProfileName.Filter(_rows, _search.Query, TitleOf);
        if (rows.Count == 0 && _search.IsSearching) return Kit.SearchMiss(_search.Query);
        var scroll = Kit.Column(out var col);
        col.Children.Add(Kit.Card([.. rows.Select(RowView)]));
        // Owner 2026-11-17 (Mac calls Q5): no "5 profiles" under the list on the Mac.
        if (_stale != null)
        {
            col.Children.Add(Kit.Footer($"Couldn’t refresh. {_stale}"));
            var retry = new HyperlinkButton { Content = "Try Again", Margin = new Thickness(4, 0, 0, 0) };
            retry.Click += (_, _) => Load();
            col.Children.Add(retry);
        }
        return scroll;
    }

    private UIElement RowView(ProfileRow row)
    {
        var title = TitleOf(row);
        var subtitle = Subtitle(row);
        var line = new Grid { ColumnSpacing = 12 };
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var head = new BotHead { Bot = Bot(row), DisplayName = title, Width = 30, Height = 30, VerticalAlignment = VerticalAlignment.Center };
        line.Children.Add(head);
        var name = Kit.Text(title, 14, wrap: false);
        name.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(name, 1); line.Children.Add(name);
        var sub = Kit.Text(subtitle, 12, Kit.Secondary, wrap: false);
        sub.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(sub, 2); line.Children.Add(sub);
        var button = Kit.LinkRow(line, () => Host.Push(new ProfileDetail(this, row.Name)), name: $"{title}, {subtitle}");
        AutomationProperties.SetAutomationId(button, "profiles.row." + row.Name);
        if (CanChange(row))
        {
            var menu = new MenuFlyout();
            var rename = new MenuFlyoutItem { Text = "Rename Bot…", Icon = new FontIcon { Glyph = "" } };
            rename.Click += (_, _) => _ = Rename(row, null);
            var delete = new MenuFlyoutItem { Text = "Delete Bot…", Icon = new FontIcon { Glyph = "" } };
            delete.Click += (_, _) => _ = Delete(row, null);
            menu.Items.Add(rename);
            menu.Items.Add(delete);
            button.ContextFlyout = menu;
        }
        return button;
    }

    // ------------------------------------------------------------------ Rename

    internal async Task Rename(ProfileRow row, ProfileDetail? detail)
    {
        if (!CanChange(row)) return;
        var name = await RenamePrompt(row.Name);
        if (name == null) return;
        await SendRename(row, name, detail);
    }

    /// "Rename Bot": one field, the name rule checked as it is typed (an invalid name turns red and Rename stays off).
    private async Task<string?> RenamePrompt(string current)
    {
        var existing = _rows.Select(r => r.Name).ToList();
        var field = new TextBox { Text = current, MaxLength = ProfileName.MaxLength, IsSpellCheckEnabled = false, IsTextPredictionEnabled = false };
        AutomationProperties.SetAutomationId(field, "profiles.rename.field");
        var panel = new StackPanel { Spacing = 10, Width = 360 };
        panel.Children.Add(Kit.Text(ProfileName.Hint, 13, Kit.Secondary));
        panel.Children.Add(field);
        var dialog = new ContentDialog { Title = ProfileName.RenameTitle, Content = panel, PrimaryButtonText = "Rename", CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary };
        var normal = field.Foreground;
        void Check()
        {
            var result = ProfileName.Of(field.Text, current, existing);
            dialog.IsPrimaryButtonEnabled = result is ProfileName.Check.Ok or ProfileName.Check.Taken;
            var invalid = result == ProfileName.Check.Invalid && field.Text.Length > 0;
            field.Foreground = invalid ? Kit.Red : normal;
            AutomationProperties.SetItemStatus(field, invalid ? $"{field.Text}, not a valid name" : "");
        }
        field.TextChanged += (_, _) => Check();
        field.Loaded += (_, _) => { field.Focus(FocusState.Programmatic); field.SelectAll(); };
        Check();
        return await Kit.Show(Root, dialog) == ContentDialogResult.Primary ? field.Text : null;
    }

    private async Task SendRename(ProfileRow row, string name, ProfileDetail? detail)
    {
        if (_renaming != null) return;
        switch (ProfileName.Of(name, row.Name, _rows.Select(r => r.Name)))
        {
            case ProfileName.Check.Unchanged or ProfileName.Check.Invalid: return;
            case ProfileName.Check.Taken:
                await Kit.Failure(Root, ProfileName.RenameFailTitle, ProfileName.Taken);
                return;
        }
        _renaming = row.Name;
        Host.Top?.Redraw();
        try
        {
            var renamed = await Api.RenameAsync(row.Name, name);
            Host.Ui(() =>
            {
                _renaming = null;
                _rows = [.. _rows.Select(r => r.Name == row.Name ? r with { Name = renamed.Name, Path = string.IsNullOrEmpty(renamed.Path) ? r.Path : renamed.Path } : r)];
                if (detail != null) detail.Name = renamed.Name;
                // A draft of the old id's SOUL.md has no file to go back to.
                ProfilesPage.Drafts.Remove(Host.Account, row.Name);
                Host.Top?.Redraw();
            });
            // The bot's id changed: the roster is read again, then this list.
            if (Host.Client is { } c) { try { await c.BotsAsync(); } catch (Exception) { } }
            await Read();
        }
        catch (Exception e)
        {
            Host.Ui(() => { _renaming = null; Host.Top?.Redraw(); });
            var refused = PagesRest.Status(e) is 400 or 409 or 422;
            await Kit.Failure(Root, ProfileName.RenameFailTitle, ProfileName.RenameReason(e), refused ? null : () => SendRename(row, name, detail));
        }
    }

    // ------------------------------------------------------------------ Delete

    /// The Bots list's own question and call (BotExtras.confirmDelete, BotStore.deleteBot).
    internal async Task Delete(ProfileRow row, ProfileDetail? detail)
    {
        if (!CanChange(row)) return;
        var title = TitleOf(row);
        if (!await Kit.Confirm(Root, BotDelete.Title(title), BotDelete.Message(title), BotDelete.Action)) return;
        await PerformDelete(row, title, detail);
    }

    private async Task PerformDelete(ProfileRow row, string title, ProfileDetail? detail)
    {
        try
        {
            await Api.DeleteAsync(row.Name, title);
            Host.Ui(() =>
            {
                _rows = [.. _rows.Where(r => r.Name != row.Name)];
                ProfilesPage.Drafts.Remove(Host.Account, row.Name);
                // The detail of a deleted profile goes back to the list.
                if (detail != null) Host.PopTo(this); else Redraw();
            });
            if (Host.Client is { } c) { try { await c.BotsAsync(); } catch (Exception) { } }
            await Read();
        }
        catch (BotWriteException w)
        {
            await Kit.Failure(Root, w.Title, w.Message, () => PerformDelete(row, title, detail));
        }
    }
}

/// A profile's page (ProfileDetailView): the head and name, Bot ID, Default Model, Provider, Skills Installed, Folder;
/// Instructions; Rename Bot… and Delete Bot… (or why they aren't there).
internal sealed class ProfileDetail(ProfilesList list, string name) : Screen
{
    /// A rename gives it a new id while the page stays.
    public string Name { get; set; } = name;
    private ProfileRow Row => list.Row(Name) ?? new ProfileRow(Name);

    public override string Title => list.TitleOf(Row);
    public override void Refresh() => list.Load();

    public override UIElement Build()
    {
        var row = Row;
        var title = list.TitleOf(row);
        var scroll = Kit.Column(out var col);
        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 14, Margin = new Thickness(4, 8, 0, 8) };
        header.Children.Add(new BotHead { Bot = list.Bot(row), DisplayName = title, Width = 56, Height = 56 });
        var h = Kit.Text(title, 20, bold: true);
        h.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetHeadingLevel(h, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level1);
        header.Children.Add(h);
        col.Children.Add(header);

        var facts = new List<UIElement> { Kit.Fact("Bot ID", row.Name) };
        if (list.ModelName(row) is { } model) facts.Add(Kit.Fact("Default Model", model));
        if (row.Provider is { } provider) facts.Add(Kit.Fact("Provider", provider));
        facts.Add(Kit.Fact("Skills Installed", row.SkillCount.ToString(System.Globalization.CultureInfo.InvariantCulture)));
        if (row.Path is { } path)
        {
            var folder = new StackPanel { Spacing = 3 };
            folder.Children.Add(Kit.Text("Folder"));
            var p = Kit.Mono(path, 12);
            p.Foreground = Kit.Secondary;
            p.MaxLines = 4;
            folder.Children.Add(p);
            var r = Kit.Row(folder);
            AutomationProperties.SetName(r, $"Folder, {path}");
            r.ContextFlyout = Kit.CopyMenu(path);
            facts.Add(r);
        }
        col.Children.Add(Kit.Card([.. facts]));

        col.Children.Add(new Border { Height = 18 });
        var soul = Kit.LinkRow(Kit.Text(SoulRules.Title), () => Host.Push(new SoulEditor(Name, title)));
        AutomationProperties.SetAutomationId(soul, "profiles.detail.soul");
        col.Children.Add(Kit.Card(soul));
        col.Children.Add(Kit.Footer(ProfileName.InstructionsFooter(title)));

        if (row.IsDefault)
        {
            col.Children.Add(new Border { Height = 12 });
            col.Children.Add(Kit.Footer(ProfileName.DefaultFooter));
        }
        else if (!list.CanWrite)
        {
            col.Children.Add(new Border { Height = 12 });
            col.Children.Add(Kit.Footer(PagesRest.OfflineFooter));
        }
        else
        {
            var renaming = list.Renaming == row.Name;
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 20, 0, 0) };
            var rename = Kit.Push(renaming ? "Renaming…" : "Rename Bot…", () => _ = list.Rename(Row, this));
            var delete = Kit.Push("Delete Bot…", () => _ = list.Delete(Row, this), destructive: true);
            rename.IsEnabled = delete.IsEnabled = list.Renaming == null;
            buttons.Children.Add(rename);
            buttons.Children.Add(delete);
            if (renaming) buttons.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
            col.Children.Add(buttons);
        }
        return scroll;
    }
}
