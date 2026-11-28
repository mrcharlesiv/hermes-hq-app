using System.Runtime.InteropServices.WindowsRuntime;
using Hermes.Core.Attachments;
using HermesHQ.Services;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using Microsoft.Windows.Storage.Pickers;
using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.UI;

namespace HermesHQ.Features.Attachments;

// [image-markup] Interactive WinUI Canvas markup editor (App/Chat/Viewer/ImageMarkupController.swift):
// pen, highlighter, arrow, box, numbered pin notes, 6 color swatches, 50-step undo/redo/clear, optional edit note,
// and flattened PNG export to Send to Chat or Save Copy.
internal static class ImageMarkupDialog
{
    public sealed record Result(string FlattenedPath, string FileName, string Prompt);

    public static async Task<Result?> ShowAsync(
        XamlRoot root,
        string imagePath,
        string imageName,
        Window? ownerWindow,
        bool canSendToChat = true)
    {
        var doc = new ImageMarkupDocument();
        var activeTool = ImageMarkupTool.Pen;
        var activeColor = ImageMarkupColor.Red;
        ImageMarkupStroke? activeStroke = null;
        List<ImageMarkupPoint>? activePoints = null;
        uint activePointerId = 0;
        var pointerDown = false;

        // Track natural pixel dimensions for aspect-fit alignment.
        var headerSize = ImageHeader.PixelSizeOfFile(imagePath);
        double imgW = headerSize?.Width ?? 800;
        double imgH = headerSize?.Height ?? 600;

        var photo = new Image { Stretch = Stretch.Uniform };
        var overlay = new Canvas { Background = new SolidColorBrush(Colors.Transparent) };

        var compositeGrid = new Grid
        {
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Background = new SolidColorBrush(Colors.Black),
        };
        compositeGrid.Children.Add(photo);
        compositeGrid.Children.Add(overlay);

        var stage = new Grid
        {
            Background = new SolidColorBrush(Colors.Black),
            MinWidth = 520,
            MinHeight = 320,
            MaxWidth = 760,
            MaxHeight = 460,
            CornerRadius = new CornerRadius(8),
        };
        stage.Children.Add(compositeGrid);
        AutomationProperties.SetAutomationId(overlay, "markup.canvas");

        void LayoutComposite(Size available)
        {
            if (available.Width <= 1 || available.Height <= 1 || imgW <= 0 || imgH <= 0) return;
            var fit = Math.Min(available.Width / imgW, available.Height / imgH);
            var w = Math.Max(40, Math.Floor(imgW * fit));
            var h = Math.Max(40, Math.Floor(imgH * fit));
            compositeGrid.Width = w;
            compositeGrid.Height = h;
            photo.Width = w;
            photo.Height = h;
            overlay.Width = w;
            overlay.Height = h;
            RedrawOverlay();
        }

        stage.SizeChanged += (_, e) => LayoutComposite(e.NewSize);

        // Inline pin note bar (avoids opening a nested ContentDialog inside a live ContentDialog).
        ImageMarkupPoint? pendingPinPoint = null;
        ImageMarkupPin? editingPin = null;

        var pinBarTitle = new TextBlock { FontSize = 12, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
        var pinNoteInput = new TextBox { PlaceholderText = "e.g., Remove the background lamp", MinWidth = 220 };
        AutomationProperties.SetAutomationId(pinNoteInput, "markup.pin.field");
        var pinSaveBtn = new Button { Content = "Save Pin", Style = ThemeBrushes.Res<Style>("AccentButtonStyle") };
        var pinRemoveBtn = new Button { Content = "Remove Pin", Visibility = Visibility.Collapsed };
        var pinCancelBtn = new Button { Content = "Cancel" };

        var pinBar = new Border
        {
            Visibility = Visibility.Collapsed,
            Padding = new Thickness(10, 6, 10, 6),
            CornerRadius = new CornerRadius(8),
            Background = ThemeBrushes.Get("CardBackgroundFillColorDefaultBrush"),
            BorderBrush = ThemeBrushes.Get("CardStrokeColorDefaultBrush"),
            BorderThickness = new Thickness(1),
        };
        var pinBarGrid = new Grid { ColumnSpacing = 8 };
        pinBarGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        pinBarGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        pinBarGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        pinBarGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        pinBarGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(pinBarTitle, 0);
        Grid.SetColumn(pinNoteInput, 1);
        Grid.SetColumn(pinSaveBtn, 2);
        Grid.SetColumn(pinRemoveBtn, 3);
        Grid.SetColumn(pinCancelBtn, 4);
        pinBarGrid.Children.Add(pinBarTitle);
        pinBarGrid.Children.Add(pinNoteInput);
        pinBarGrid.Children.Add(pinSaveBtn);
        pinBarGrid.Children.Add(pinRemoveBtn);
        pinBarGrid.Children.Add(pinCancelBtn);
        pinBar.Child = pinBarGrid;

        var undoBtn = new Button { Content = new FontIcon { Glyph = "\uE7A7", FontSize = 14 }, Padding = new Thickness(8, 6, 8, 6) };
        ToolTipService.SetToolTip(undoBtn, "Undo");
        AutomationProperties.SetName(undoBtn, "Undo");
        AutomationProperties.SetAutomationId(undoBtn, "markup.undo");

        var redoBtn = new Button { Content = new FontIcon { Glyph = "\uE7A6", FontSize = 14 }, Padding = new Thickness(8, 6, 8, 6) };
        ToolTipService.SetToolTip(redoBtn, "Redo");
        AutomationProperties.SetName(redoBtn, "Redo");
        AutomationProperties.SetAutomationId(redoBtn, "markup.redo");

        var clearBtn = new Button { Content = new FontIcon { Glyph = "\uE74D", FontSize = 14 }, Padding = new Thickness(8, 6, 8, 6) };
        ToolTipService.SetToolTip(clearBtn, "Clear Markup");
        AutomationProperties.SetName(clearBtn, "Clear Markup");
        AutomationProperties.SetAutomationId(clearBtn, "markup.clear");

        var statusText = new TextBlock
        {
            FontSize = 12,
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
        };

        var noteBox = new TextBox { PlaceholderText = "Add edit note (optional)…" };
        AutomationProperties.SetAutomationId(noteBox, "markup.note");

        var pinsBadge = new TextBlock
        {
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
        };
        AutomationProperties.SetAutomationId(pinsBadge, "markup.pinsBadge");

        ContentDialog? dialog = null;

        var toolButtons = new Dictionary<ImageMarkupTool, ToggleButton>();
        var colorButtons = new Dictionary<ImageMarkupColor, Button>();

        void RefreshControls()
        {
            undoBtn.IsEnabled = doc.CanUndo;
            redoBtn.IsEnabled = doc.CanRedo;
            clearBtn.IsEnabled = !doc.IsEmpty;

            foreach (var (t, btn) in toolButtons)
                btn.IsChecked = t == activeTool;

            foreach (var (c, btn) in colorButtons)
            {
                var active = c == activeColor;
                btn.BorderThickness = new Thickness(active ? 3 : 1);
                btn.BorderBrush = new SolidColorBrush(active ? Colors.White : Color.FromArgb(160, 200, 200, 200));
            }

            var pinCount = doc.Pins.Count;
            pinsBadge.Visibility = pinCount == 0 ? Visibility.Collapsed : Visibility.Visible;
            pinsBadge.Text = pinCount == 1 ? "1 pin" : $"{pinCount} pins";

            if (dialog != null && canSendToChat)
                dialog.IsPrimaryButtonEnabled = !doc.IsEmpty || !string.IsNullOrWhiteSpace(noteBox.Text);
        }

        void RedrawOverlay()
        {
            overlay.Children.Clear();
            var w = overlay.Width;
            var h = overlay.Height;
            if (double.IsNaN(w) || double.IsNaN(h) || w <= 1 || h <= 1) return;
            var minSide = Math.Min(w, h);

            foreach (var s in doc.Strokes) DrawStroke(overlay, s, w, h, minSide);
            if (activeStroke != null) DrawStroke(overlay, activeStroke, w, h, minSide);
            foreach (var pin in doc.Pins) DrawPin(overlay, pin, w, h, minSide);
        }

        void ClosePinBar()
        {
            pendingPinPoint = null;
            editingPin = null;
            pinBar.Visibility = Visibility.Collapsed;
        }

        void OpenPinBar(ImageMarkupPoint pt, ImageMarkupPin? existing)
        {
            pendingPinPoint = pt;
            editingPin = existing;
            pinBarTitle.Text = existing != null ? $"Edit Pin {existing.Number}" : "Add Pin Note";
            pinNoteInput.Text = existing?.Note ?? "";
            pinRemoveBtn.Visibility = existing != null ? Visibility.Visible : Visibility.Collapsed;
            pinBar.Visibility = Visibility.Visible;
            pinNoteInput.Focus(FocusState.Programmatic);
        }

        pinSaveBtn.Click += (_, _) =>
        {
            if (editingPin != null) doc.UpdatePin(editingPin.Id, pinNoteInput.Text);
            else if (pendingPinPoint is { } pt) doc.AddPin(pt, activeColor, pinNoteInput.Text);
            ClosePinBar();
            RedrawOverlay();
            RefreshControls();
        };

        pinRemoveBtn.Click += (_, _) =>
        {
            if (editingPin != null) doc.RemovePin(editingPin.Id);
            ClosePinBar();
            RedrawOverlay();
            RefreshControls();
        };

        pinCancelBtn.Click += (_, _) => ClosePinBar();

        undoBtn.Click += (_, _) => { if (doc.Undo()) { ClosePinBar(); RedrawOverlay(); RefreshControls(); } };
        redoBtn.Click += (_, _) => { if (doc.Redo()) { ClosePinBar(); RedrawOverlay(); RefreshControls(); } };
        clearBtn.Click += (_, _) => { doc.Clear(); ClosePinBar(); RedrawOverlay(); RefreshControls(); };
        noteBox.TextChanged += (_, _) => RefreshControls();

        // Pointer drawing on the overlay Canvas
        overlay.PointerPressed += (_, e) =>
        {
            var pt = e.GetCurrentPoint(overlay).Position;
            var w = overlay.Width;
            var h = overlay.Height;
            if (double.IsNaN(w) || double.IsNaN(h) || w <= 1 || h <= 1) return;

            var norm = ImageMarkupPoint.FromCanvas(pt.X, pt.Y, w, h);
            if (activeTool == ImageMarkupTool.Pin)
            {
                var hit = FindPinNear(doc.Pins, pt, w, h);
                OpenPinBar(norm, hit);
                e.Handled = true;
                return;
            }

            ClosePinBar();
            pointerDown = true;
            activePointerId = e.Pointer.PointerId;
            overlay.CapturePointer(e.Pointer);
            activePoints = [norm];
            activeStroke = new ImageMarkupStroke(activeTool, activeColor, activeTool.DefaultWidthRatio(), activePoints);
            RedrawOverlay();
            e.Handled = true;
        };

        overlay.PointerMoved += (_, e) =>
        {
            if (!pointerDown || e.Pointer.PointerId != activePointerId || activePoints == null || activeStroke == null) return;
            var pt = e.GetCurrentPoint(overlay).Position;
            var w = overlay.Width;
            var h = overlay.Height;
            if (double.IsNaN(w) || double.IsNaN(h) || w <= 1 || h <= 1) return;

            var norm = ImageMarkupPoint.FromCanvas(pt.X, pt.Y, w, h);
            if (activeStroke.Tool is ImageMarkupTool.Arrow or ImageMarkupTool.Box)
            {
                if (activePoints.Count <= 1) activePoints.Add(norm);
                else activePoints[1] = norm;
            }
            else if (activePoints.Count < ImageMarkupDocument.MaxStrokePoints && activePoints[^1] != norm)
            {
                activePoints.Add(norm);
            }
            RedrawOverlay();
            e.Handled = true;
        };

        void FinishPointer(PointerRoutedEventArgs e, bool cancel)
        {
            if (!pointerDown || e.Pointer.PointerId != activePointerId) return;
            pointerDown = false;
            overlay.ReleasePointerCapture(e.Pointer);
            var stroke = activeStroke;
            var pts = activePoints;
            activeStroke = null;
            activePoints = null;

            if (!cancel && stroke != null && pts != null && pts.Count > 0)
            {
                var keep = true;
                if (stroke.Tool is ImageMarkupTool.Arrow or ImageMarkupTool.Box)
                {
                    if (pts.Count < 2) keep = false;
                    else
                    {
                        var (ax, ay) = pts[0].ToCanvas(overlay.Width, overlay.Height);
                        var (bx, by) = pts[^1].ToCanvas(overlay.Width, overlay.Height);
                        keep = double.Hypot(bx - ax, by - ay) >= 6;
                    }
                }
                if (keep) doc.AddStroke(stroke with { Points = [.. pts] });
            }
            RedrawOverlay();
            RefreshControls();
        }

        overlay.PointerReleased += (_, e) => FinishPointer(e, cancel: false);
        overlay.PointerCanceled += (_, e) => FinishPointer(e, cancel: true);
        overlay.PointerCaptureLost += (_, e) => FinishPointer(e, cancel: false);

        // Tool selector bar
        var toolsPanel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        foreach (var tool in ImageMarkupTools.All)
        {
            var t = tool;
            var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            content.Children.Add(new FontIcon { Glyph = t.Glyph(), FontSize = 13 });
            content.Children.Add(new TextBlock { Text = t.Title(), FontSize = 12 });
            var btn = new ToggleButton
            {
                Content = content,
                Padding = new Thickness(10, 5, 10, 5),
                CornerRadius = new CornerRadius(14),
            };
            AutomationProperties.SetName(btn, t.Title());
            AutomationProperties.SetAutomationId(btn, $"markup.tool.{t.Raw()}");
            btn.Click += (_, _) => { activeTool = t; ClosePinBar(); RefreshControls(); };
            toolButtons[t] = btn;
            toolsPanel.Children.Add(btn);
        }

        // Color swatch bar
        var colorsPanel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, VerticalAlignment = VerticalAlignment.Center };
        foreach (var color in ImageMarkupColors.All)
        {
            var c = color;
            var (r, g, b, a) = c.Bytes();
            var swatch = new Button
            {
                Width = 26,
                Height = 26,
                MinWidth = 26,
                MinHeight = 26,
                Padding = new Thickness(0),
                CornerRadius = new CornerRadius(13),
                Background = new SolidColorBrush(Color.FromArgb(a, r, g, b)),
            };
            ToolTipService.SetToolTip(swatch, c.Title());
            AutomationProperties.SetName(swatch, c.Title());
            AutomationProperties.SetAutomationId(swatch, $"markup.color.{c.Raw()}");
            swatch.Click += (_, _) => { activeColor = c; RefreshControls(); };
            colorButtons[c] = swatch;
            colorsPanel.Children.Add(swatch);
        }

        var topBar = new Grid { ColumnSpacing = 8 };
        topBar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        topBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(toolsPanel, 0);
        var historyBtns = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        historyBtns.Children.Add(undoBtn);
        historyBtns.Children.Add(redoBtn);
        historyBtns.Children.Add(clearBtn);
        Grid.SetColumn(historyBtns, 1);
        topBar.Children.Add(toolsPanel);
        topBar.Children.Add(historyBtns);

        var colorRow = new Grid { ColumnSpacing = 12 };
        colorRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        colorRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        colorRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(colorsPanel, 0);
        Grid.SetColumn(statusText, 1);
        Grid.SetColumn(pinsBadge, 2);
        colorRow.Children.Add(colorsPanel);
        colorRow.Children.Add(statusText);
        colorRow.Children.Add(pinsBadge);

        var body = new StackPanel { Spacing = 10 };
        body.Children.Add(topBar);
        body.Children.Add(stage);
        body.Children.Add(pinBar);
        body.Children.Add(colorRow);
        body.Children.Add(noteBox);

        // Load source image into the stage
        try
        {
            var bmp = await MediaActions.BitmapAsync(imagePath, 2048);
            if (bmp.PixelWidth > 0 && bmp.PixelHeight > 0)
            {
                imgW = bmp.PixelWidth;
                imgH = bmp.PixelHeight;
            }
            photo.Source = bmp;
        }
        catch (Exception ex)
        {
            AppLog.Error("attachments", ex);
        }

        Result? sentResult = null;
        dialog = new ContentDialog
        {
            Title = "Mark Up",
            Content = body,
            PrimaryButtonText = canSendToChat ? "Send to Chat" : "",
            SecondaryButtonText = "Save Copy",
            CloseButtonText = "Cancel",
            DefaultButton = canSendToChat ? ContentDialogButton.Primary : ContentDialogButton.Close,
        };
        dialog.Resources["ContentDialogMaxWidth"] = 840.0;
        AutomationProperties.SetAutomationId(dialog, "markup.editor");

        async Task<string?> FlattenToPngAsync()
        {
            var stem = System.IO.Path.GetFileNameWithoutExtension(string.IsNullOrWhiteSpace(imageName) ? imagePath : imageName);
            if (string.IsNullOrWhiteSpace(stem)) stem = "markup";
            var folder = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "HQNMarkup-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(folder);
            var outPath = System.IO.Path.Combine(folder, $"{stem}-markup.png");

            try
            {
                var rtb = new RenderTargetBitmap();
                await rtb.RenderAsync(compositeGrid);
                if (rtb.PixelWidth > 0 && rtb.PixelHeight > 0)
                {
                    var pixels = await rtb.GetPixelsAsync();
                    var bytes = pixels.ToArray();
                    await using var fs = new FileStream(outPath, FileMode.Create, FileAccess.ReadWrite, FileShare.None, 64 * 1024, useAsync: true);
                    using var ras = fs.AsRandomAccessStream();
                    var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, ras);
                    encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)rtb.PixelWidth, (uint)rtb.PixelHeight, 96, 96, bytes);
                    await encoder.FlushAsync();
                    return outPath;
                }
            }
            catch (Exception ex)
            {
                AppLog.Error("attachments", ex);
            }

            File.Copy(imagePath, outPath, overwrite: true);
            return outPath;
        }

        dialog.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            try
            {
                var flattened = await FlattenToPngAsync();
                if (flattened != null)
                {
                    var prompt = ImageMarkupPrompt.Compose(noteBox.Text, doc.Pins, hasMarks: !doc.IsEmpty);
                    sentResult = new Result(flattened, System.IO.Path.GetFileName(flattened), prompt);
                }
            }
            finally
            {
                deferral.Complete();
            }
        };

        dialog.SecondaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            var deferral = args.GetDeferral();
            try
            {
                var owner = ownerWindow ?? App.Window;
                if (owner == null) return;
                var flattened = await FlattenToPngAsync();
                if (flattened == null) return;

                var picker = new FileSavePicker(owner.AppWindow.Id)
                {
                    SuggestedStartLocation = PickerLocationId.PicturesLibrary,
                    SuggestedFileName = System.IO.Path.GetFileNameWithoutExtension(flattened),
                };
                picker.FileTypeChoices.Add("PNG image", [".png"]);
                var target = await picker.PickSaveFileAsync();
                if (target != null && !string.IsNullOrEmpty(target.Path))
                {
                    File.Copy(flattened, target.Path, overwrite: true);
                    statusText.Text = "Saved copy";
                    statusText.Visibility = Visibility.Visible;
                }
            }
            catch (Exception ex)
            {
                AppLog.Error("attachments", ex);
            }
            finally
            {
                deferral.Complete();
            }
        };

        RefreshControls();
        var outcome = await SafeDialog.ShowAsync(root, dialog);
        return outcome == ContentDialogResult.Primary ? sentResult : null;
    }

    private static ImageMarkupPin? FindPinNear(IReadOnlyList<ImageMarkupPin> pins, Point location, double w, double h)
    {
        const double hitRadius = 24;
        for (var i = pins.Count - 1; i >= 0; i--)
        {
            var (px, py) = pins[i].Point.ToCanvas(w, h);
            if (double.Hypot(location.X - px, location.Y - py) <= hitRadius)
                return pins[i];
        }
        return null;
    }

    private static void DrawStroke(Canvas canvas, ImageMarkupStroke stroke, double w, double h, double minSide)
    {
        if (stroke.Points.Count == 0) return;
        var (r, g, b, a) = stroke.Color.Bytes(stroke.Opacity);
        var brush = new SolidColorBrush(Color.FromArgb(a, r, g, b));
        var lineWidth = ImageMarkupDocument.LineWidth(stroke.WidthRatio, minSide);

        switch (stroke.Tool)
        {
            case ImageMarkupTool.Pen:
            case ImageMarkupTool.Highlighter:
                if (stroke.Points.Count == 1)
                {
                    var (cx, cy) = stroke.Points[0].ToCanvas(w, h);
                    var dot = new Ellipse { Width = lineWidth, Height = lineWidth, Fill = brush };
                    Canvas.SetLeft(dot, cx - lineWidth / 2);
                    Canvas.SetTop(dot, cy - lineWidth / 2);
                    canvas.Children.Add(dot);
                }
                else
                {
                    var pts = new PointCollection();
                    foreach (var p in stroke.Points)
                    {
                        var (px, py) = p.ToCanvas(w, h);
                        pts.Add(new Point(px, py));
                    }
                    canvas.Children.Add(new Polyline
                    {
                        Stroke = brush,
                        StrokeThickness = lineWidth,
                        StrokeStartLineCap = PenLineCap.Round,
                        StrokeEndLineCap = PenLineCap.Round,
                        StrokeLineJoin = PenLineJoin.Round,
                        Points = pts,
                    });
                }
                break;

            case ImageMarkupTool.Arrow:
                if (stroke.Points.Count >= 2)
                {
                    var (x1, y1) = stroke.Points[0].ToCanvas(w, h);
                    var (x2, y2) = stroke.Points[^1].ToCanvas(w, h);
                    canvas.Children.Add(new Line
                    {
                        X1 = x1, Y1 = y1, X2 = x2, Y2 = y2,
                        Stroke = brush,
                        StrokeThickness = lineWidth,
                        StrokeStartLineCap = PenLineCap.Round,
                        StrokeEndLineCap = PenLineCap.Round,
                    });
                    var dx = x2 - x1;
                    var dy = y2 - y1;
                    if (double.Hypot(dx, dy) > 4)
                    {
                        var angle = Math.Atan2(dy, dx);
                        var headLen = Math.Max(12, lineWidth * 3.8);
                        const double spread = Math.PI / 6;
                        var p1 = new Point(x2 - headLen * Math.Cos(angle - spread), y2 - headLen * Math.Sin(angle - spread));
                        var p2 = new Point(x2 - headLen * Math.Cos(angle + spread), y2 - headLen * Math.Sin(angle + spread));
                        canvas.Children.Add(new Polygon
                        {
                            Fill = brush,
                            Points = [new Point(x2, y2), p1, p2],
                        });
                    }
                }
                break;

            case ImageMarkupTool.Box:
                if (stroke.Points.Count >= 2)
                {
                    var (x1, y1) = stroke.Points[0].ToCanvas(w, h);
                    var (x2, y2) = stroke.Points[^1].ToCanvas(w, h);
                    var rw = Math.Abs(x2 - x1);
                    var rh = Math.Abs(y2 - y1);
                    var radius = Math.Min(10, Math.Min(rw, rh) * 0.15);
                    var box = new Rectangle
                    {
                        Width = rw,
                        Height = rh,
                        RadiusX = radius,
                        RadiusY = radius,
                        Stroke = brush,
                        StrokeThickness = lineWidth,
                    };
                    Canvas.SetLeft(box, Math.Min(x1, x2));
                    Canvas.SetTop(box, Math.Min(y1, y2));
                    canvas.Children.Add(box);
                }
                break;
        }
    }

    private static void DrawPin(Canvas canvas, ImageMarkupPin pin, double w, double h, double minSide)
    {
        var (cx, cy) = pin.Point.ToCanvas(w, h);
        var diameter = ImageMarkupDocument.BadgeDiameter(minSide);
        var (r, g, b, _) = pin.Color.Bytes();
        var textColor = pin.Color is ImageMarkupColor.White or ImageMarkupColor.Yellow ? Colors.Black : Colors.White;

        var badge = new Border
        {
            Width = diameter,
            Height = diameter,
            CornerRadius = new CornerRadius(diameter / 2),
            Background = new SolidColorBrush(Color.FromArgb(255, r, g, b)),
            BorderBrush = new SolidColorBrush(Colors.White),
            BorderThickness = new Thickness(Math.Max(1.5, diameter * 0.08)),
            Child = new TextBlock
            {
                Text = pin.Number.ToString(),
                FontSize = Math.Max(13, diameter * 0.54),
                FontWeight = FontWeights.Bold,
                Foreground = new SolidColorBrush(textColor),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            },
        };
        Canvas.SetLeft(badge, cx - diameter / 2);
        Canvas.SetTop(badge, cy - diameter / 2);
        canvas.Children.Add(badge);
    }
}
