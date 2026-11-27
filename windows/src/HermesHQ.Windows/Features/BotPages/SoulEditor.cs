using Hermes.Core.BotPages;
using HermesHQ.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace HermesHQ.Features.BotPages;

/// A profile's SOUL.md, shown as "Instructions" (App/Pages/More/Profiles/SoulEditorViewController.swift): read-only at
/// first with Edit on the bar; Edit puts Cancel and Save there. Save reads the file again first (it may have changed on
/// the gateway), then writes it. A refused Save shows a notice above the text with Try Again; nothing typed is lost.
/// What is typed is kept on every pause and offered back when the editor opens after the app went away. A prompt
/// file: no spelling fixes. The text never goes to the log.
internal sealed class SoulEditor(string profile, string botName) : Screen
{
    private readonly TextBox _text = new()
    {
        AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, IsReadOnly = true, IsSpellCheckEnabled = false,
        IsTextPredictionEnabled = false, FontFamily = Kit.Res<FontFamily>("CodeFont"), FontSize = 14,
        BorderThickness = new Thickness(0), Padding = new Thickness(16, 12, 16, 24), Background = null,
    };
    private readonly Button _edit = new() { Content = "Edit" };
    private readonly Button _cancel = new() { Content = "Cancel" };
    private readonly Button _save = new() { Content = "Save" };
    private ProfilesApi Api => new(Host.Gateway!);

    private string _baseText = "";
    private string _baseHash = SoulDraft.Hash("");
    private bool _baseExists;
    /// The gateway's newer file a Save found and you didn't replace: Discard goes back to it.
    private SoulDocument? _theirs;
    private bool _loaded, _loading, _editing, _saving, _dirty;
    private string? _loadFailure;
    private string? _failure;
    private DispatcherTimer? _draftTimer;
    private bool _wired;

    public override string Title => SoulRules.Title;

    private bool CanEdit => _loaded;

    public override IEnumerable<UIElement> Bar()
    {
        if (_editing)
        {
            var bar = SoulRules.BarFor(_dirty || _failure != null, _saving);
            _cancel.IsEnabled = bar.CancelEnabled;
            _save.IsEnabled = bar.SaveEnabled;
            _save.Content = bar.SaveTitle;
            return [_cancel, _save];
        }
        if (!CanEdit) return [];
        _edit.IsEnabled = Host.Online;
        return [_edit];
    }

    public override void Shown()
    {
        if (!_wired)
        {
            _wired = true;
            _save.Style = Kit.Res<Style>("AccentButtonStyle");
            AutomationProperties.SetAutomationId(_edit, "soul.edit");
            AutomationProperties.SetAutomationId(_text, "soul.text");
            AutomationProperties.SetName(_text, SoulRules.Title);
            _edit.Click += (_, _) => BeginEditing();
            _cancel.Click += (_, _) => _ = Cancel();
            _save.Click += (_, _) => _ = Save();
            _text.TextChanged += (_, _) => TextChanged(keepDraft: true);
            var save = new KeyboardAccelerator { Key = VirtualKey.S, Modifiers = VirtualKeyModifiers.Control };
            save.Invoked += (s, e) => { e.Handled = true; if (_editing) _ = Save(); };
            _text.KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
            _text.KeyboardAccelerators.Add(save);
        }
        if (!_loaded && !_loading) _ = Load();
    }

    public override void Left()
    {
        // Leaving with an edit open (another place, a gateway switch): what was typed is kept for the next visit.
        KeepDraftNow();
        _draftTimer?.Stop();
    }

    public override void Refresh()
    {
        if (!_editing) _ = Load();
    }

    /// Esc while editing runs Cancel (with Discard Changes? when there are changes), never a plain Back.
    public override bool Escape()
    {
        if (!_editing) return false;
        _ = Cancel();
        return true;
    }

    public override async Task<bool> CanLeave()
    {
        if (!_editing || !_dirty) return true;
        if (!await AskDiscard()) return false;
        Discard();
        return true;
    }

    // ------------------------------------------------------------------ reading

    private async Task Load()
    {
        _loading = true;
        _loadFailure = null;
        Redraw();
        try
        {
            var doc = await Api.SoulAsync(profile);
            Host.Ui(() => { _loading = false; Show(doc); });
        }
        catch (Exception e)
        {
            var gone = PagesRest.Status(e) == 404;
            Host.Ui(() => { _loading = false; _loadFailure = gone ? SoulRules.Gone : PagesRest.Reason(e); Redraw(); });
        }
    }

    private void Show(SoulDocument doc)
    {
        _baseText = doc.Content;
        _baseHash = SoulDraft.Hash(doc.Content);
        _baseExists = doc.Exists;
        _loaded = true;
        _theirs = null;
        _text.Text = doc.Content;
        _dirty = false;
        Redraw();
        _ = OfferDraft();
    }

    /// A draft kept from an edit the app left: offered back when it says something the gateway's file does not.
    private async Task OfferDraft()
    {
        var account = Host.Account;
        if (ProfilesPage.Drafts.Read(account, profile) is not { } draft) return;
        if (SoulRules.OfferFor(draft, _baseText) != SoulRules.DraftOffer.Offer)
        {
            ProfilesPage.Drafts.Remove(account, profile);
            return;
        }
        var dialog = new ContentDialog
        {
            Title = SoulRules.RestoreTitle, Content = Kit.Text(SoulRules.RestoreMessage(botName)),
            PrimaryButtonText = "Restore", CloseButtonText = "Discard", DefaultButton = ContentDialogButton.Primary,
        };
        var answer = await Kit.Show(Root, dialog);
        if (answer == ContentDialogResult.Primary)
        {
            if (!_loaded || _editing) return;
            // The Save that follows checks the gateway's file against what the draft was typed over.
            BeginEditing();
            _baseHash = draft.BaseHash;
            _text.Text = draft.Text;
            _text.Select(_text.Text.Length, 0);
            TextChanged(keepDraft: false);
        }
        else if (answer == ContentDialogResult.None)
        {
            ProfilesPage.Drafts.Remove(account, profile);
        }
    }

    // ------------------------------------------------------------------ editing

    private void BeginEditing()
    {
        if (!CanEdit || _editing) return;
        _failure = null;
        _editing = true;
        _text.IsReadOnly = false;
        Redraw();
        _text.Focus(FocusState.Programmatic);
        _text.Select(_text.Text.Length, 0);
    }

    private void EndEditing()
    {
        _draftTimer?.Stop();
        _text.IsReadOnly = true;
        _failure = null;
        _saving = false;
        _dirty = false;
        _editing = false;
        Redraw();
    }

    private void TextChanged(bool keepDraft)
    {
        var was = _dirty;
        _dirty = _text.Text != _baseText;
        if (was != _dirty) RedrawBar();
        if (!keepDraft || !_editing) return;
        // Written on every pause in typing (1 s).
        _draftTimer ??= MakeTimer();
        _draftTimer.Stop();
        _draftTimer.Start();
    }

    private DispatcherTimer MakeTimer()
    {
        var t = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        t.Tick += (_, _) => { t.Stop(); KeepDraftNow(); };
        return t;
    }

    /// The draft file follows the editor: written while there are unsaved changes, removed when there are none.
    private void KeepDraftNow()
    {
        if (!_editing || !_loaded) return;
        _draftTimer?.Stop();
        var account = Host.Account;
        if (!_dirty) { ProfilesPage.Drafts.Remove(account, profile); return; }
        var draft = new SoulDraft(_text.Text, _baseHash);
        var p = profile;
        _ = Task.Run(() => ProfilesPage.Drafts.Write(draft, account, p));   // a large file must not hold a keystroke
    }

    // ------------------------------------------------------------------ Cancel

    private async Task<bool> AskDiscard() => await Kit.Show(Root, new ContentDialog
    {
        Title = SoulRules.DiscardTitle, Content = Kit.Text(SoulRules.DiscardMessage), PrimaryButtonText = SoulRules.DiscardConfirm,
        CloseButtonText = SoulRules.DiscardCancel, DefaultButton = ContentDialogButton.Close,
    }) == ContentDialogResult.Primary;

    private async Task Cancel()
    {
        if (!_editing || _saving) return;
        if (!_dirty) { EndEditing(); return; }
        if (await AskDiscard()) Discard();
    }

    private void Discard()
    {
        if (!_editing || _saving) return;
        if (_theirs is { } theirs) { Adopt(theirs); return; }
        _text.Text = _baseText;
        _baseHash = SoulDraft.Hash(_baseText);
        ProfilesPage.Drafts.Remove(Host.Account, profile);
        EndEditing();
    }

    // ------------------------------------------------------------------ Save

    private async Task Save()
    {
        if (!_editing || _saving || !(_dirty || _failure != null)) return;
        var sent = _text.Text;
        _saving = true;
        _failure = null;
        Redraw();
        try
        {
            // Read first: someone else may have changed the file since this edit began.
            var now = await Api.SoulAsync(profile);
            if (now.Exists && now.Content == sent) { Host.Ui(() => Saved(sent)); return; }   // an earlier Save landed
            if (SoulRules.ChangedOnGateway(_baseHash, _baseExists, now))
            {
                Host.Ui(() => { _saving = false; Redraw(); });
                await AskReplace(now);
                return;
            }
            await Api.SaveSoulAsync(profile, sent);
            Host.Ui(() => Saved(sent));
        }
        catch (Exception e)
        {
            AppLog.Note("config", "soul save failed");
            Host.Ui(() => { _saving = false; _failure = PagesRest.Reason(e); Redraw(); });
        }
    }

    private void Saved(string sent)
    {
        _saving = false;
        _baseText = sent;
        _baseHash = SoulDraft.Hash(sent);
        _baseExists = true;
        _theirs = null;
        ProfilesPage.Drafts.Remove(Host.Account, profile);
        Host.Hud(SoulRules.Saved);
        if (_text.Text == sent) EndEditing();
        else TextChanged(keepDraft: true);   // something was typed while the Save was out: the edit goes on
        Redraw();
    }

    /// Replace It saves yours over theirs; Use Their Version drops your edit; Cancel keeps editing.
    private async Task AskReplace(SoulDocument now)
    {
        _theirs = now;
        var answer = await Kit.Show(Root, new ContentDialog
        {
            Title = SoulRules.ChangedTitle, Content = Kit.Text(SoulRules.ChangedMessage), PrimaryButtonText = SoulRules.ReplaceIt,
            SecondaryButtonText = SoulRules.UseTheirs, CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close,
        });
        if (answer == ContentDialogResult.Primary)
        {
            _baseHash = SoulDraft.Hash(now.Content);
            _baseExists = now.Exists;
            await Save();
        }
        else if (answer == ContentDialogResult.Secondary) Adopt(now);
    }

    /// The gateway's file becomes the page's text and base; your edit (and its kept draft) is dropped.
    private void Adopt(SoulDocument doc)
    {
        ProfilesPage.Drafts.Remove(Host.Account, profile);
        EndEditing();
        Show(doc);
    }

    // ------------------------------------------------------------------ drawing

    private TextBlock? _hint;

    public override UIElement Build()
    {
        if (_loadFailure != null) return Kit.Error(SoulRules.LoadFailTitle, _loadFailure, () => _ = Load());
        if (!_loaded) return Kit.Loading(SoulRules.Loading);
        UiTree.DetachFromParent(_text);
        var grid = new Grid { MaxWidth = 900 };
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        if (Notice() is { } notice) grid.Children.Add(notice);
        Grid.SetRow(_text, 1);
        grid.Children.Add(_text);
        _text.TextChanged -= OnHintTextChanged;
        _hint = null;
        if (_text.Text.Length == 0)
        {
            // A hint, not the file's text: the body face, not the editor's code face.
            var hint = Kit.Text(SoulRules.Placeholder, 14, Kit.Tertiary);
            hint.Margin = new Thickness(21, 12, 21, 0);
            hint.IsHitTestVisible = false;
            AutomationProperties.SetAutomationId(hint, "soul.placeholder");
            Grid.SetRow(hint, 1);
            grid.Children.Add(hint);
            _hint = hint;
            _text.TextChanged += OnHintTextChanged;
        }
        return grid;
    }

    private void OnHintTextChanged(object sender, TextChangedEventArgs e)
    {
        if (_hint != null) _hint.Visibility = _text.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    /// The notice pinned above the text: a refused Save ("Couldn’t Save Instructions", the reason, Try Again), or why
    /// Edit is off.
    private UIElement? Notice()
    {
        StackPanel s;
        if (_failure != null && _editing)
        {
            s = new StackPanel { Spacing = 4 };
            s.Children.Add(Kit.Text(SoulRules.SaveFailTitle, 15, Kit.Red, bold: true));
            s.Children.Add(Kit.Text(_failure, 13, maxLines: 4));
            var retry = Kit.Push("Try Again", () => _ = Save());
            retry.Margin = new Thickness(0, 6, 0, 0);
            AutomationProperties.SetAutomationId(retry, "soul.save-failure.retry");
            s.Children.Add(retry);
        }
        else if (_loaded && !Host.Online && !_editing)
        {
            s = new StackPanel();
            s.Children.Add(Kit.Text(PagesRest.OfflineFooter, 13, Kit.Secondary));
        }
        else return null;
        var card = Kit.Card(Kit.Row(s));
        card.Margin = new Thickness(16, 8, 16, 4);
        return card;
    }
}
