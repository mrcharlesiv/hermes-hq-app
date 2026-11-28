using Hermes.Core.Attachments;
using HermesHQ.Services;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Attachments;

/// The tray above the message box (App/Chat/Attachments/AttachmentTrayView.swift; spec 1x-attachments §6.2): photos as
/// 64 px square thumbnails, files as cards with their kind, name and "PDF · 2.4 MB", each with its state — preparing
/// (a ring), waiting (dimmed), uploading (a scrim and a progress ring), failed (a red mark; a click shows the reason with
/// Try Again and Remove) — and a ✕ in its corner. Opaque, in the page's colour. A click on a ready tile opens it.
internal sealed class AttachmentTray
{
    public ScrollViewer View { get; } = new();
    private readonly StackPanel _row = new() { Orientation = Orientation.Horizontal, Spacing = 8, Padding = new Thickness(6, 8, 6, 2) };
    private readonly Dictionary<string, Tile> _tiles = [];

    public event Action<DraftAttachment>? RemoveRequested;
    public event Action<DraftAttachment>? RetryRequested;
    public event Action<DraftAttachment>? OpenRequested;

    public AttachmentTray()
    {
        View.HorizontalScrollBarVisibility = ScrollBarVisibility.Auto;
        View.HorizontalScrollMode = ScrollMode.Enabled;
        View.VerticalScrollBarVisibility = ScrollBarVisibility.Disabled;
        View.VerticalScrollMode = ScrollMode.Disabled;
        View.Content = _row;
        View.Visibility = Visibility.Collapsed;
        AutomationProperties.SetName(View, "Attachments");
    }

    /// The tray's items, in order; tiles are kept by id so a state change redraws only its tile.
    /// [WIN-BUG1] Attaching a picture is the one routine act that puts an active ProgressRing in the tree and
    /// replaces it milliseconds later (Preparing ring → prepare finishes → ItemChanged → rebuild). The codebase's
    /// own documented fault (UiSafety.cs: DeactivateProgressRings — an active ring's animation can fail-fast
    /// natively when it leaves the tree) is guarded on page teardown but wasn't here; and one tile throwing no
    /// longer takes the whole tray's pass down.
    public void Show(IReadOnlyList<DraftAttachment> items)
    {
        var ids = items.Select(a => a.Id).ToHashSet();
        foreach (var gone in _tiles.Keys.Where(id => !ids.Contains(id)).ToList())
        {
            var tile = _tiles[gone];
            UiTree.DeactivateProgressRings(tile.Root);
            tile.Dispose();
            _row.Children.Remove(tile.Root);
            _tiles.Remove(gone);
        }
        for (var i = 0; i < items.Count; i++)
        {
            var a = items[i];
            try
            {
                if (!_tiles.TryGetValue(a.Id, out var tile))
                {
                    tile = new Tile(this);
                    _tiles[a.Id] = tile;
                }
                tile.Update(a, i);
                var at = _row.Children.IndexOf(tile.Root);
                if (at != i)
                {
                    if (at >= 0) _row.Children.RemoveAt(at);
                    _row.Children.Insert(Math.Min(i, _row.Children.Count), tile.Root);
                }
            }
            catch (Exception e) { AppLog.Error("attachments", e); }
        }
        View.Visibility = items.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private static T Res<T>(string key) => ThemeBrushes.Res<T>(key);

    private sealed class Tile
    {
        public readonly Grid Root = new() { Height = 72, VerticalAlignment = VerticalAlignment.Top };
        private readonly AttachmentTray _tray;
        private readonly Button _body = new() { Padding = new Thickness(0), BorderThickness = new Thickness(0), Background = new SolidColorBrush(Colors.Transparent) };
        private readonly Button _remove = new()
        {
            Width = 22, Height = 22, Padding = new Thickness(0), CornerRadius = new CornerRadius(11),
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 0, -2, 0),
            Content = new FontIcon { Glyph = "", FontSize = 9 },
        };
        private readonly Grid _face = new();
        private readonly Grid _overlay = new();
        private readonly Image _thumb = new() { Stretch = Stretch.UniformToFill };
        private TextBlock? _fileDetail;
        private ProgressRing? _uploadingRing;
        private DraftAttachment? _a;
        private string? _thumbFor;

        public Tile(AttachmentTray tray)
        {
            _tray = tray;
            _body.Margin = new Thickness(0, 8, 8, 0);
            _body.Content = _face;
            _body.Click += (_, _) =>
            {
                if (_a is not { } a) return;
                if (a.Failure != null) FailureMenu(a).ShowAt(_body);
                else if (!a.IsPreparing) _tray.OpenRequested?.Invoke(a);
            };
            _remove.Click += (_, _) => { if (_a is { } a) _tray.RemoveRequested?.Invoke(a); };
            _remove.Background = Res<Brush>("SolidBackgroundFillColorTertiaryBrush");
            _remove.BorderBrush = Res<Brush>("CardStrokeColorDefaultBrush");
            _remove.BorderThickness = new Thickness(1);
            Root.Children.Add(_body);
            Root.Children.Add(_remove);
        }

        private MenuFlyout FailureMenu(DraftAttachment a)
        {
            var menu = new MenuFlyout();
            menu.Items.Add(new MenuFlyoutItem { Text = a.Failure?.Reason ?? "Couldn’t upload", IsEnabled = false });
            menu.Items.Add(new MenuFlyoutSeparator());
            if (a.OffersRetry)
            {
                var retry = new MenuFlyoutItem { Text = "Try Again", Icon = new FontIcon { Glyph = "" } };
                retry.Click += (_, _) => _tray.RetryRequested?.Invoke(a);
                menu.Items.Add(retry);
            }
            var remove = new MenuFlyoutItem { Text = "Remove", Icon = new FontIcon { Glyph = "" } };
            remove.Click += (_, _) => _tray.RemoveRequested?.Invoke(a);
            menu.Items.Add(remove);
            return menu;
        }

        public void Update(DraftAttachment a, int index)
        {
            var kindChanged = _a == null || _a.Kind != a.Kind;
            _a = a;
            if (kindChanged) BuildFace(a);
            else if (_fileDetail != null) _fileDetail.Text = FileDetailText(a);
            if (a.Kind == DraftKind.Image && !a.IsPreparing && _thumbFor != a.LocalFile && File.Exists(a.LocalFile))
            {
                _thumbFor = a.LocalFile;
                _ = LoadThumb(a.LocalFile);
            }
            // States drawn on the tile.
            _face.Opacity = a.Upload is UploadState.Waiting && !a.IsLink ? 0.6 : 1;
            string? status = null;
            if (a.Upload is UploadState.Uploading u)
            {
                var fraction = u.Total > 0 ? Math.Clamp((double)u.Sent / u.Total, 0, 1) : 0;
                if (_uploadingRing == null)
                {
                    ClearOverlay();
                    _overlay.Background = new SolidColorBrush(Windows.UI.Color.FromArgb(77, 0, 0, 0));
                    _uploadingRing = new ProgressRing
                    {
                        IsActive = true, IsIndeterminate = false, Maximum = 100, Value = fraction * 100, Width = 24, Height = 24,
                        Foreground = new SolidColorBrush(Colors.White),
                    };
                    _overlay.Children.Add(_uploadingRing);
                }
                else
                {
                    _uploadingRing.Value = fraction * 100;
                }
                status = $"Uploading, {(int)(fraction * 100)} percent";
            }
            else
            {
                ClearOverlay();
                switch (a.Upload)
                {
                    case UploadState.Preparing:
                        _overlay.Children.Add(new ProgressRing { IsActive = true, Width = 20, Height = 20 });
                        status = "Preparing";
                        break;
                    case UploadState.Waiting when !a.IsLink:
                        status = "Waiting for connection";
                        break;
                    case UploadState.Failed:
                        _overlay.Children.Add(new FontIcon
                        {
                            Glyph = "", FontSize = 22, Foreground = Res<Brush>("SystemFillColorCriticalBrush"),
                            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
                        });
                        status = "Couldn’t upload";
                        break;
                }
            }
            var label = (a.Kind switch { DraftKind.Image => "Photo, ", DraftKind.Link => "Link, ", _ => "File, " }) + a.Name;
            AutomationProperties.SetName(_body, label);
            AutomationProperties.SetItemStatus(_body, status ?? "");
            AutomationProperties.SetAutomationId(_body, $"composer.tray.tile.{index}");
            var removeName = a.IsLink ? "Remove link" : $"Remove {a.Name}";
            AutomationProperties.SetName(_remove, removeName);
            AutomationProperties.SetAutomationId(_remove, $"composer.tray.remove.{index}");
            ToolTipService.SetToolTip(_remove, removeName);
            ToolTipService.SetToolTip(_body, a.Failure?.Reason ?? a.Name);
        }

        public void Dispose() => ClearOverlay();

        private void ClearOverlay()
        {
            foreach (var child in _overlay.Children)
                if (child is ProgressRing ring) ring.IsActive = false;
            _overlay.Children.Clear();
            _overlay.Background = null;
            _uploadingRing = null;
        }

        private static string FileDetailText(DraftAttachment a) =>
            a.IsLink ? "Link" : a.IsPreparing ? "Preparing…" : MediaKinds.Detail(a.Name, a.ByteSize);

        private async Task LoadThumb(string path)
        {
            try { _thumb.Source = await MediaActions.BitmapAsync(path, 128); }
            catch (Exception e) { AppLog.Error("attachments", e); }
        }

        private void BuildFace(DraftAttachment a)
        {
            ClearOverlay();   // [WIN-BUG1] a live ring under the old face leaves the tree here: deactivate it first
            _face.Children.Clear();
            _fileDetail = null;
            if (_thumb.Parent is Border old) old.Child = null;
            if (VisualTreeHelper.GetParent(_thumb) is Border visualOld) visualOld.Child = null;
            if (a.Kind == DraftKind.Image)
            {
                _face.Width = 64;
                _face.Height = 64;
                _face.Children.Add(new Border
                {
                    CornerRadius = new CornerRadius(10), Child = _thumb, Background = Res<Brush>("SubtleFillColorTertiaryBrush"),
                    BorderBrush = Res<Brush>("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(0.5),
                });
                _overlay.CornerRadius = new CornerRadius(10);
            }
            else
            {
                _face.Width = double.NaN;
                _face.Height = 64;
                var kind = a.IsLink ? MediaKind.Other : MediaKinds.Kind(a.Name);
                var grid = new Grid { ColumnSpacing = 10, Padding = new Thickness(12, 12, 14, 12), MinWidth = 160, MaxWidth = 240 };
                grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                grid.Children.Add(new Border
                {
                    Width = 40, Height = 40, CornerRadius = new CornerRadius(10), Background = Res<Brush>("SubtleFillColorTertiaryBrush"),
                    VerticalAlignment = VerticalAlignment.Center,
                    Child = new FontIcon { Glyph = a.IsLink ? "" : MediaKinds.Glyph(kind), FontSize = 18 },
                });
                var words = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
                words.Children.Add(new TextBlock
                {
                    Text = a.Name, FontSize = 14, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 1,
                });
                _fileDetail = new TextBlock
                {
                    Text = FileDetailText(a), FontSize = 12,
                    Foreground = Res<Brush>("TextFillColorSecondaryBrush"), TextTrimming = TextTrimming.CharacterEllipsis,
                };
                words.Children.Add(_fileDetail);
                Grid.SetColumn(words, 1);
                grid.Children.Add(words);
                _face.Children.Add(new Border
                {
                    CornerRadius = new CornerRadius(14), Child = grid, Background = Res<Brush>("SolidBackgroundFillColorBaseBrush"),
                    BorderBrush = Res<Brush>("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(0.5),
                });
                _overlay.CornerRadius = new CornerRadius(14);
            }
            _face.Children.Add(_overlay);
        }
    }
}
