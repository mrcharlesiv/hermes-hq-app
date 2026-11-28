using System.Runtime.InteropServices.WindowsRuntime;
using Hermes.Core.Transcripts;
using HermesHQ.Services;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.Windows.Storage.Pickers;
using Windows.Graphics.Imaging;

namespace HermesHQ.Controls;

// [mermaid] Expanded Mermaid diagram dialog (App/Chat/Sheets/MermaidSheetController.swift):
// zoom controls (−, level, +, 100%), Preview | Source toggle, Copy Source, and Save PNG via RenderTargetBitmap.
public static class MermaidDialog
{
    private const double MinZoom = 0.25;
    private const double MaxZoom = 4.0;
    private const double ZoomStep = 0.25;

    public static async Task ShowAsync(XamlRoot root, MermaidDiagram diagram)
    {
        var zoom = 1.0;
        var showsSource = false;

        var canvas = MermaidRenderer.RenderCanvas(diagram, solidBackground: true);
        var naturalW = Math.Max(120, canvas.Width);
        var naturalH = Math.Max(80, canvas.Height);

        var scaleTransform = new ScaleTransform { ScaleX = zoom, ScaleY = zoom };
        canvas.RenderTransform = scaleTransform;

        var scaledHost = new Grid
        {
            Width = naturalW,
            Height = naturalH,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Background = ThemeBrushes.Get("HQCodeFillBrush"),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(8),
        };
        scaledHost.Children.Add(canvas);

        var scroller = new ScrollViewer
        {
            Content = scaledHost,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollMode = ScrollMode.Auto,
            VerticalScrollMode = ScrollMode.Auto,
            MinWidth = 520,
            MinHeight = 320,
            MaxHeight = 520,
        };

        var codeFont = Application.Current.Resources.TryGetValue("CodeFont", out var f) && f is FontFamily ff
            ? ff
            : new FontFamily("Consolas");
        var sourceBox = new TextBox
        {
            AcceptsReturn = true,
            IsReadOnly = true,
            TextWrapping = TextWrapping.NoWrap,
            Text = diagram.Source,
            FontFamily = codeFont,
            FontSize = 13,
            MinWidth = 520,
            MinHeight = 320,
            MaxHeight = 520,
            Visibility = Visibility.Collapsed,
        };
        ScrollViewer.SetHorizontalScrollBarVisibility(sourceBox, ScrollBarVisibility.Auto);
        ScrollViewer.SetVerticalScrollBarVisibility(sourceBox, ScrollBarVisibility.Auto);
        AutomationProperties.SetAutomationId(sourceBox, "mermaid.source");

        var zoomLabel = new TextBlock
        {
            Text = "100%",
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
            MinWidth = 42,
            TextAlignment = TextAlignment.Center,
        };

        void ApplyZoom(double next)
        {
            zoom = Math.Clamp(Math.Round(next * 100) / 100.0, MinZoom, MaxZoom);
            scaleTransform.ScaleX = zoom;
            scaleTransform.ScaleY = zoom;
            scaledHost.Width = Math.Ceiling(naturalW * zoom) + 16;
            scaledHost.Height = Math.Ceiling(naturalH * zoom) + 16;
            zoomLabel.Text = $"{(int)Math.Round(zoom * 100)}%";
        }

        var zoomOut = new Button { Content = "\u2212", MinWidth = 32, Padding = new Thickness(8, 4, 8, 4) };
        AutomationProperties.SetName(zoomOut, "Zoom Out");
        zoomOut.Click += (_, _) => ApplyZoom(zoom - ZoomStep);

        var zoomIn = new Button { Content = "+", MinWidth = 32, Padding = new Thickness(8, 4, 8, 4) };
        AutomationProperties.SetName(zoomIn, "Zoom In");
        zoomIn.Click += (_, _) => ApplyZoom(zoom + ZoomStep);

        var zoomReset = new Button { Content = "100%", Padding = new Thickness(8, 4, 8, 4) };
        AutomationProperties.SetName(zoomReset, "Reset Zoom");
        zoomReset.Click += (_, _) => ApplyZoom(1.0);

        var toggleSource = new Button { Content = "Source", Padding = new Thickness(10, 4, 10, 4) };
        AutomationProperties.SetAutomationId(toggleSource, "mermaid.toggleSource");
        toggleSource.Click += (_, _) =>
        {
            showsSource = !showsSource;
            sourceBox.Visibility = showsSource ? Visibility.Visible : Visibility.Collapsed;
            scroller.Visibility = showsSource ? Visibility.Collapsed : Visibility.Visible;
            zoomOut.IsEnabled = !showsSource;
            zoomIn.IsEnabled = !showsSource;
            zoomReset.IsEnabled = !showsSource;
            toggleSource.Content = showsSource ? "Diagram" : "Source";
        };

        var copyBtn = new Button { Content = "Copy Source", Padding = new Thickness(10, 4, 10, 4) };
        AutomationProperties.SetAutomationId(copyBtn, "mermaid.copySource");
        copyBtn.Click += async (_, _) =>
        {
            if (!SafeClipboard.TrySetText(diagram.Source)) return;
            copyBtn.Content = "Copied";
            try { await Task.Delay(1500); copyBtn.Content = "Copy Source"; }
            catch (Exception) { }
        };

        var saveBtn = new Button { Content = "Save PNG", Padding = new Thickness(10, 4, 10, 4) };
        AutomationProperties.SetAutomationId(saveBtn, "mermaid.savePng");
        saveBtn.Click += async (_, _) => await SavePngAsync(scaledHost, diagram.KindLabel, saveBtn);

        var toolbar = new Grid { ColumnSpacing = 8, Margin = new Thickness(0, 0, 0, 8) };
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var zoomGroup = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        zoomGroup.Children.Add(zoomOut);
        zoomGroup.Children.Add(zoomLabel);
        zoomGroup.Children.Add(zoomIn);
        zoomGroup.Children.Add(zoomReset);

        var actionGroup = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        actionGroup.Children.Add(toggleSource);
        actionGroup.Children.Add(copyBtn);
        actionGroup.Children.Add(saveBtn);

        Grid.SetColumn(zoomGroup, 0);
        Grid.SetColumn(actionGroup, 2);
        toolbar.Children.Add(zoomGroup);
        toolbar.Children.Add(actionGroup);

        var stage = new Grid();
        stage.Children.Add(scroller);
        stage.Children.Add(sourceBox);

        var layout = new StackPanel { Spacing = 4 };
        layout.Children.Add(toolbar);
        layout.Children.Add(stage);

        var dialog = new ContentDialog
        {
            Title = diagram.KindLabel,
            Content = layout,
            CloseButtonText = "Done",
            DefaultButton = ContentDialogButton.Close,
        };
        dialog.Resources["ContentDialogMaxWidth"] = 920.0;
        AutomationProperties.SetAutomationId(dialog, "mermaid.sheet");
        await SafeDialog.ShowAsync(root, dialog);
    }

    private static async Task SavePngAsync(FrameworkElement visual, string kindLabel, Button button)
    {
        if (App.Window is not { } owner) return;
        try
        {
            var rtb = new RenderTargetBitmap();
            await rtb.RenderAsync(visual);
            if (rtb.PixelWidth <= 0 || rtb.PixelHeight <= 0) return;
            var pixels = await rtb.GetPixelsAsync();
            var bytes = pixels.ToArray();

            var picker = new FileSavePicker(owner.AppWindow.Id)
            {
                SuggestedStartLocation = PickerLocationId.PicturesLibrary,
                SuggestedFileName = "mermaid-" + kindLabel.ToLowerInvariant().Replace(' ', '-'),
            };
            picker.FileTypeChoices.Add("PNG image", [".png"]);
            var picked = await picker.PickSaveFileAsync();
            if (picked == null || string.IsNullOrEmpty(picked.Path)) return;

            await using var fs = new FileStream(picked.Path, FileMode.Create, FileAccess.ReadWrite, FileShare.None, 64 * 1024, useAsync: true);
            using var ras = fs.AsRandomAccessStream();
            var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, ras);
            encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)rtb.PixelWidth, (uint)rtb.PixelHeight, 96, 96, bytes);
            await encoder.FlushAsync();

            button.Content = "Saved";
            await Task.Delay(1500);
            button.Content = "Save PNG";
        }
        catch (Exception ex)
        {
            AppLog.Error("mermaid", ex);
        }
    }
}
