using Hermes.Core.Attachments;
using Hermes.Core.Chat;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.Windows.Storage.Pickers;
using Windows.ApplicationModel.DataTransfer;
using Windows.Devices.Enumeration;
using Windows.Storage;
using Windows.System;

namespace HermesHQ.Features.Attachments;

/// One chat's photos and files (App/Chat/Attachments/ChatAttachmentsController.swift; spec 1x-attachments §4, §6): the
/// + button and its menu, the tray bound to this chat's draft (restored when the chat opens, kept when it closes),
/// drag and drop and paste onto the chat, imports into the account's AttachmentCenter, and what Send takes.
internal sealed class ChatAttachments
{
    /// The + menu's ordered slots (ComposerPlusMenu.Slot): other features add Voice Memo, Talk, Link…, Folder…, Prompt
    /// Snippets… here; this one fills Pickers and Paste.
    public static class Slot
    {
        public const int Pickers = 0, Memo = 10, Talk = 20, Paste = 30, Link = 40, Folder = 50, Snippets = 60, More = 70;
    }

    /// Items other features put in the + menu, made each time it opens.
    public static readonly List<(int Slot, Func<ChatContext, IEnumerable<MenuFlyoutItemBase>> Items)> PlusMenuProviders = [];

    public static string LimitNote => $"Up to {AttachmentCenter.MaxPerMessage} per message";

    private readonly ChatContext _ctx;
    private readonly ChatSession _session;
    private readonly AttachmentCenter _center;
    private readonly Microsoft.UI.Dispatching.DispatcherQueue _ui;
    private readonly AttachmentTray _tray = new();
    private readonly Button _plus;
    private readonly MenuFlyout _menu = new() { Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.TopEdgeAlignedLeft };
    private readonly MediaContext _media;
    private readonly DragEventHandler _dragOverHandler;
    private readonly DragEventHandler _dropHandler;
    private readonly KeyboardAccelerator _attachFilesAccelerator;
    private HashSet<string> _draftIds = [];
    private bool _syncingText;
    private bool _closed;
    private static bool? _hasCamera;
    private static Task? _cameraProbe;

    internal static ChatAttachments? Current { get; private set; }

    private string Scope => _session.DraftScope;
    private string Profile => _session.Profile;

    public static void Attach(ChatContext ctx) => _ = new ChatAttachments(ctx);

    private ChatAttachments(ChatContext ctx)
    {
        _ctx = ctx;
        _session = ctx.Session;
        _center = AttachmentsFeature.CenterFor(_session.Client);
        _ui = ctx.Page.DispatcherQueue;
        _media = new MediaContext(_center, _session);
        MediaContext.Current = _media;
        Current = this;
        EnsureCameraChecked();

        _plus = new Button
        {
            Style = (Style)Application.Current.Resources["QuietButtonStyle"],
            Content = new FontIcon { Glyph = "", FontSize = 14 },
            Flyout = _menu,
            VerticalAlignment = VerticalAlignment.Bottom,
        };
        ToolTipService.SetToolTip(_plus, "Attach");
        AutomationProperties.SetName(_plus, "Attach");
        AutomationProperties.SetAutomationId(_plus, "composer.plus");
        _menu.Opening += (_, _) => FillMenu();
        ctx.ComposerLeading.Children.Add(_plus);

        // Chat › Attach Files… (the Mac's ⇧⌘A) is Ctrl+Shift+A here.
        _attachFilesAccelerator = new KeyboardAccelerator { Key = VirtualKey.A, Modifiers = VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift };
        _attachFilesAccelerator.Invoked += (s, e) => { e.Handled = true; _ = PickFilesAsync(); };
        ctx.Page.KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        ctx.Page.KeyboardAccelerators.Add(_attachFilesAccelerator);

        _tray.RemoveRequested += a => _center.Remove(a.Id, Scope);
        _tray.RetryRequested += a => _center.Retry(a.Id);
        _tray.OpenRequested += a => _ = OpenTileAsync(a);
        ctx.Shelf.Children.Add(_tray.View);

        ctx.HasDraftContent.Add(() => _center.Count(Scope) > 0);
        ctx.HoldsSend.Add(() => _center.GetDraft(Scope).Attachments.Any(a => a.IsPreparing));
        ctx.SendHandlers.Add(TakeSend);

        // The chat's saved draft comes back with it (spec §6.6).
        var draft = _center.GetDraft(Scope);
        if (ctx.Composer.Text.Length == 0 && draft.Text.Length > 0)
        {
            _syncingText = true;
            ctx.Composer.Text = draft.Text;
            ctx.Composer.SelectionStart = draft.Text.Length;
            _syncingText = false;
        }
        ctx.Composer.TextChanged += OnTyped;
        ctx.Composer.Paste += OnPaste;

        _dragOverHandler = new DragEventHandler(OnDragOver);
        _dropHandler = new DragEventHandler(OnDrop);
        ctx.Page.AllowDrop = true;
        ctx.Page.AddHandler(UIElement.DragOverEvent, _dragOverHandler, handledEventsToo: true);
        ctx.Page.AddHandler(UIElement.DropEvent, _dropHandler, handledEventsToo: true);

        _center.DraftChanged += OnDraftChanged;
        _center.ItemChanged += OnItemChanged;
        _session.SendReturned += OnSendReturned;
        ctx.Closed += () =>
        {
            // The saved draft is the box as the chat leaves. TextChanged comes a beat after the box changes, so a send
            // that empties the box and leaves at once (`/new words`: a new chat in this one's place) would otherwise
            // keep the typed command as this chat's draft; the Mac's submit empties the field before it acts.
            // [WIN-33] CI run 44989322637: Hermes's chat came back with "/new draft words" in its box.
            if (!_syncingText) _center.SetText(Scope, Profile, ctx.Composer.Text);
            _closed = true;
            _tray.Show([]);
            _center.DraftChanged -= OnDraftChanged;
            _center.ItemChanged -= OnItemChanged;
            _session.SendReturned -= OnSendReturned;
            ctx.Composer.TextChanged -= OnTyped;
            ctx.Composer.Paste -= OnPaste;
            ctx.Page.KeyboardAccelerators.Remove(_attachFilesAccelerator);
            ctx.Page.RemoveHandler(UIElement.DragOverEvent, _dragOverHandler);
            ctx.Page.RemoveHandler(UIElement.DropEvent, _dropHandler);
            if (MediaContext.Current == _media) MediaContext.Current = null;
            if (Current == this) Current = null;
        };
        Refresh();
    }

    private int Count => _center.Count(Scope);
    private bool CanAttach => Count < AttachmentCenter.MaxPerMessage;

    private void OnTyped(object sender, TextChangedEventArgs e)
    {
        if (!_closed && !_syncingText) _center.SetText(Scope, Profile, _ctx.Composer.Text);
    }

    private void OnDraftChanged(string scope)
    {
        if (_closed || AppShutdown.Stopping || scope != Scope) return;
        _ui.TryEnqueue(() =>
        {
            if (_closed || AppShutdown.Stopping) return;
            // A refused or stopped send's words come back when the box is empty (spec §6.4 step 8).
            var text = _center.GetDraft(Scope).Text;
            if (_ctx.Composer.Text.Length == 0 && text.Length > 0)
            {
                _syncingText = true;
                _ctx.Composer.Text = text;
                _ctx.Composer.SelectionStart = text.Length;
                _syncingText = false;
            }
            Refresh();
        });
    }

    private void OnItemChanged(string id)
    {
        if (!_closed && !AppShutdown.Stopping && _draftIds.Contains(id))
            _ui.TryEnqueue(() => { if (!_closed && !AppShutdown.Stopping) Refresh(); });
    }

    private void OnSendReturned(string? reason)
    {
        if (!_closed && !AppShutdown.Stopping)
            _ui.TryEnqueue(() => { if (!_closed && !AppShutdown.Stopping) Refresh(); });
    }

    private void Refresh()
    {
        var items = _center.GetDraft(Scope).Attachments;
        _draftIds = [.. items.Select(a => a.Id)];
        _tray.Show(items);
        _ctx.RefreshComposer();
    }

    /// Send with the tray: the draft (words and attachments) goes to the session's pipeline; the box and tray clear.
    private bool TakeSend(string text)
    {
        if (_center.Count(Scope) == 0) return false;
        _center.SetText(Scope, Profile, text);
        var (words, attachments) = _center.TakeForSend(Scope);
        _ = SendAsync(words, attachments);
        return true;
    }

    private async Task SendAsync(string text, IReadOnlyList<DraftAttachment> attachments)
    {
        try { await _session.SendAsync(text, attachments, _center); }
        catch (Exception e) { AppLog.Error("attachments", e); }
    }

    // ------------------------------------------------------------------ the + menu

    private static void EnsureCameraChecked()
    {
        if (_hasCamera != null || _cameraProbe != null) return;
        _cameraProbe = Task.Run(async () => _hasCamera = await HasCameraAsync());
    }

    /// Populates the + menu synchronously during Opening (never awaits inside Opening: mutating MenuFlyout.Items
    /// asynchronously while WinUI is opening/measuring the presenter causes empty menus or native XAML crashes).
    private void FillMenu()
    {
        _menu.Items.Clear();
        var full = !CanAttach;
        // A PC with no camera has no Camera at all (the Mac leaves the row out rather than greying it).
        var pickers = new List<MenuFlyoutItem>();
        if (_hasCamera == true) pickers.Add(Item("Camera", "", "composer.plus.camera", () => Defer(() => _ = CameraAsync())));
        pickers.Add(Item("Photos", "", "composer.plus.photos", () => Defer(() => _ = PickPhotosAsync())));
        pickers.Add(Item("Files", "", "composer.plus.files", () => Defer(() => _ = PickFilesAsync())));
        if (full)
        {
            _menu.Items.Add(new MenuFlyoutItem { Text = LimitNote, IsEnabled = false });
            foreach (var p in pickers) p.IsEnabled = false;
        }
        foreach (var p in pickers) _menu.Items.Add(p);
        var slots = PlusMenuProviders.Select(p => (p.Slot, Items: (Func<IEnumerable<MenuFlyoutItemBase>>)(() => p.Items(_ctx)))).ToList();
        slots.Add((Slot.Paste, PasteItems));
        foreach (var (_, items) in slots.OrderBy(s => s.Slot))
        {
            var made = items().ToList();
            if (made.Count == 0) continue;
            _menu.Items.Add(new MenuFlyoutSeparator());
            foreach (var m in made) _menu.Items.Add(m);
        }
    }

    /// Defers modal pickers and camera UI until the MenuFlyout popup has finished dismissing.
    private void Defer(Action action) => _ui.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => action());

    /// Paste Image, present only when the clipboard holds a picture.
    private IEnumerable<MenuFlyoutItemBase> PasteItems()
    {
        bool hasBitmap;
        try { hasBitmap = Clipboard.GetContent().Contains(StandardDataFormats.Bitmap); }
        catch (Exception e) { AppLog.Error("attachments", e); yield break; }
        if (!hasBitmap) yield break;
        var paste = Item("Paste Image", "", "composer.plus.paste", () => Defer(() => _ = PasteFromClipboardAsync()));
        paste.IsEnabled = CanAttach;
        yield return paste;
    }

    private static MenuFlyoutItem Item(string text, string glyph, string id, Action click)
    {
        var item = new MenuFlyoutItem { Text = text, Icon = new FontIcon { Glyph = glyph } };
        AutomationProperties.SetAutomationId(item, id);
        item.Click += (_, _) => click();
        return item;
    }

    private static async Task<bool> HasCameraAsync()
    {
        try { return (await DeviceInformation.FindAllAsync(DeviceClass.VideoCapture)).Count > 0; }
        catch (Exception e) { AppLog.Error("attachments", e); return false; }
    }

    private int Remaining(int perPick) => Math.Min(perPick, AttachmentCenter.MaxPerMessage - Count);

    private async Task PickPhotosAsync()
    {
        if (!CanAttach || App.Window is not { } window) return;
        var picker = new FileOpenPicker(window.AppWindow.Id)
        {
            ViewMode = PickerViewMode.Thumbnail,
            SuggestedStartLocation = PickerLocationId.PicturesLibrary,
        };
        foreach (var ext in MediaKinds.ImageExtensions.Concat(MediaKinds.VideoExtensions)) picker.FileTypeFilter.Add("." + ext);
        await PickAsync(picker, PickSource.Photo);
    }

    private async Task PickFilesAsync()
    {
        if (!CanAttach || App.Window is not { } window) return;
        var picker = new FileOpenPicker(window.AppWindow.Id)
        {
            ViewMode = PickerViewMode.List,
            SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
        };
        picker.FileTypeFilter.Add("*");
        await PickAsync(picker, PickSource.File);
    }

    private async Task PickAsync(FileOpenPicker picker, PickSource source)
    {
        IReadOnlyList<PickFileResult> files;
        try { files = await picker.PickMultipleFilesAsync(); }
        catch (Exception e) { AppLog.Error("attachments", e); return; }
        if (files == null || files.Count == 0) return;
        // At most 8 a pick, as the Mac's; past the 16 a message takes, the rest is dropped with the alert. A video from
        // Photos attaches as a file.
        var valid = files.Where(f => !string.IsNullOrEmpty(f.Path)).ToList();
        if (valid.Count == 0) return;
        var room = Math.Max(0, AttachmentCenter.MaxPerMessage - Count);
        await AddAsync([.. valid.Take(Math.Min(AttachmentCenter.MaxPerPick, room)).Select(f =>
        {
            var name = Path.GetFileName(f.Path);
            return new PickedItem(f.Path, name,
                source == PickSource.Photo && MediaKinds.Kind(name) != MediaKind.Image ? PickSource.File : source);
        })], dropped: valid.Count > room);
    }

    /// Automation entry point for the Windows CI attachment proof walk (feeds local files through the exact post-pick path).
    internal Task AddPickedFilesAsync(IReadOnlyList<PickedItem> picks) => AddAsync(picks);

    /// The Windows camera (Windows App SDK CameraCaptureUI): a photo, normalised as camera.jpg.
    private async Task CameraAsync()
    {
        if (!CanAttach || App.Window is not { } window) return;
        try
        {
            var ui = new Microsoft.Windows.Media.Capture.CameraCaptureUI(window.AppWindow.Id);
            ui.PhotoSettings.Format = Microsoft.Windows.Media.Capture.CameraCaptureUIPhotoFormat.Jpeg;
            var file = await ui.CaptureFileAsync(Microsoft.Windows.Media.Capture.CameraCaptureUIMode.Photo);
            if (file == null) return;
            await AddAsync([new PickedItem(file.Path, "camera.jpg", PickSource.Camera)]);
        }
        catch (Exception e)
        {
            AppLog.Error("attachments", e);
            await MediaActions.AlertAsync(_ctx.Page.XamlRoot, "Couldn’t Attach", "Couldn’t save the camera photo.");
        }
    }

    // ------------------------------------------------------------------ paste and drop

    /// Ctrl+V in the message box: a picture or files on the clipboard attach; text pastes as text.
    private void OnPaste(object sender, TextControlPasteEventArgs e)
    {
        DataPackageView content;
        bool files, bitmap, text;
        try
        {
            content = Clipboard.GetContent();
            files = content.Contains(StandardDataFormats.StorageItems);
            bitmap = !files && content.Contains(StandardDataFormats.Bitmap);
            text = bitmap && content.Contains(StandardDataFormats.Text);
        }
        catch (Exception ex) { AppLog.Error("attachments", ex); return; }
        if (!files && !bitmap) return;
        // A text snippet copied with a picture (a web page's selection) pastes as text.
        if (text) return;
        e.Handled = true;
        _ = PasteAsync(content);
    }

    private async Task PasteFromClipboardAsync()
    {
        DataPackageView content;
        try { content = Clipboard.GetContent(); }
        catch (Exception e) { AppLog.Error("attachments", e); return; }
        await PasteAsync(content);
    }

    private async Task PasteAsync(DataPackageView content)
    {
        if (!CanAttach) { await LimitAlert(); return; }
        string? tempFolder = null;
        try
        {
            if (content.Contains(StandardDataFormats.StorageItems))
            {
                await AddItemsAsync(await content.GetStorageItemsAsync());
                return;
            }
            var bitmap = await content.GetBitmapAsync();
            using var stream = await bitmap.OpenReadAsync();
            stream.Seek(0);
            tempFolder = Path.Combine(Path.GetTempPath(), "HQNPaste-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(tempFolder);
            var path = Path.Combine(tempFolder, "clipboard.png");
            await using (var output = File.Create(path))
                await stream.AsStreamForRead().CopyToAsync(output);
            await AddAsync([new PickedItem(path, "clipboard.png", PickSource.Clipboard)]);
        }
        catch (Exception e)
        {
            AppLog.Error("attachments", e);
            await MediaActions.AlertAsync(_ctx.Page.XamlRoot, "Couldn’t Attach", "Couldn’t read the selected photo or video.");
        }
        finally
        {
            if (tempFolder != null)
            {
                try { Directory.Delete(tempFolder, recursive: true); }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
            }
        }
    }

    /// Files dragged from Explorer onto the chat (the Mac's "Drop to Attach"; "No Room for More Files" with the tray
    /// full). A text drag stays the message box's own.
    private void OnDragOver(object sender, DragEventArgs e)
    {
        try { if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return; }
        catch (Exception ex) { AppLog.Error("attachments", ex); return; }
        e.Handled = true;
        if (CanAttach)
        {
            e.AcceptedOperation = DataPackageOperation.Copy;
            e.DragUIOverride.Caption = "Drop to Attach";
        }
        else
        {
            e.AcceptedOperation = DataPackageOperation.None;
            e.DragUIOverride.Caption = "No Room for More Files";
        }
        e.DragUIOverride.IsCaptionVisible = true;
    }

    private async void OnDrop(object sender, DragEventArgs e)
    {
        try { if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return; }
        catch (Exception ex) { AppLog.Error("attachments", ex); return; }
        e.Handled = true;
        if (!CanAttach) return;
        var deferral = e.GetDeferral();
        try { await AddItemsAsync(await e.DataView.GetStorageItemsAsync()); }
        catch (Exception x) { AppLog.Error("attachments", x); }
        finally { deferral.Complete(); }
    }

    private async Task AddItemsAsync(IReadOnlyList<IStorageItem> items)
    {
        var files = items.OfType<StorageFile>().ToList();
        if (files.Count == 0) return;
        var room = AttachmentCenter.MaxPerMessage - Count;
        await AddAsync([.. files.Take(room).Select(f => new PickedItem(f.Path, f.Name, PickSource.File))], dropped: files.Count > room);
    }

    private async Task AddAsync(IReadOnlyList<PickedItem> picks, bool dropped = false)
    {
        if (picks.Count == 0) { if (dropped) await LimitAlert(); return; }
        var problems = await _center.AddPicksAsync(Scope, Profile, picks);
        _ui.TryEnqueue(Refresh);
        var first = problems.FirstOrDefault() ?? (dropped ? new AttachmentPrepareException(AttachmentPrepareException.Reason.LimitReached).Message : null);
        if (first != null)
        {
            AppLog.Note("attachments", $"{problems.Count} item(s) couldn't attach");
            _ui.TryEnqueue(() => _ = MediaActions.AlertAsync(_ctx.Page.XamlRoot, "Couldn’t Attach", first));
        }
    }

    private Task LimitAlert() => MediaActions.AlertAsync(_ctx.Page.XamlRoot, "Couldn’t Attach",
        new AttachmentPrepareException(AttachmentPrepareException.Reason.LimitReached).Message);

    /// A click on a ready tile: a photo in the viewer, a file in its own app, from this PC's copy (no download).
    private async Task OpenTileAsync(DraftAttachment a)
    {
        if (a.IsLink)
        {
            if (Uri.TryCreate(a.Name, UriKind.Absolute, out var url)) await Launcher.LaunchUriAsync(url);
            return;
        }
        if (!File.Exists(a.LocalFile)) return;
        if (a.Kind == DraftKind.Image)
            MediaViewerWindow.Show([new ViewerItem(a.Name, () => Task.FromResult(a.LocalFile))], 0);
        else await MediaActions.OpenAsync(a.LocalFile, a.Name);
    }
}
