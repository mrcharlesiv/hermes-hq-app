using System.Runtime.InteropServices.WindowsRuntime;
using Hermes.Core;
using Hermes.Core.Attachments;
using HermesHQ.Features.Attachments;
using HermesHQ.Pages;
using HermesHQ.Shell;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.Storage.Pickers;
using Windows.Graphics.Imaging;

namespace HermesHQ.Services;

/// Real Windows CI walk for picture attachments (windows/ci/windows.yml on attachments-gateway.py):
///   attachments-photo  Opens the bot's chat, clicks + (composer.plus) on first open to prove the MenuFlyout populates
///                      synchronously without crashing ("attachments-plus-menu"), verifies WinAppSDK 1.8 FileOpenPicker
///                      construction, feeds a real opaque PNG (normalised to JPEG via WindowsPhotoNormalizer's Single
///                      ImageQuality path) and a transparent PNG (kept as PNG) through ChatAttachments → AttachmentTray
///                      ("attachments-tray"), then sends them to the fixture gateway ("attachments-sent").
internal static partial class ProofWalks
{
    private static void RegisterAttachmentsWalks()
    {
        Automation.NamedWalks["attachments-photo"] = AttachmentsPhotoAsync;
    }

    private static async Task AttachmentsPhotoAsync(Func<string, Task> shot)
    {
        var client = AppState.Client ?? throw new InvalidOperationException("not signed in");
        var url = client.Session.Address.ToString();
        var bots = await client.BotsAsync();
        var bot = bots.FirstOrDefault(b => b.Name == "default") ?? bots.FirstOrDefault() ?? throw new InvalidOperationException("no bots");
        var storedId = await client.BotChatIdAsync(bot);
        Navigator.Go(new ChatDestination(bot.Name, storedId, bot.DisplayName));
        var chat = await Until(() => ChatPage.Current is { IsLoaded: true } p && p.StoredId == storedId ? p : null, "the attachments chat", 30);
        var attach = await Until(() => ChatAttachments.Current, "ChatAttachments", 15);

        // 1. Open the + menu on the very first click: Photos and Files must appear synchronously without crashing.
        var plus = (Button)await Until(() => Find("composer.plus"), "the + button", 15);
        Invoke(plus);
        await Until(() => MenuItem("Photos"), "Photos in the + menu", 10);
        await Until(() => MenuItem("Files"), "Files in the + menu", 10);
        await Task.Delay(300);
        await shot("attachments-plus-menu");
        plus.Flyout?.Hide();
        await Task.Delay(250);

        // 2. Verify Windows App SDK 1.8 FileOpenPicker constructs and accepts photo filters cleanly in unpackaged mode.
        var picker = new FileOpenPicker(App.Window!.AppWindow.Id)
        {
            ViewMode = PickerViewMode.Thumbnail,
            SuggestedStartLocation = PickerLocationId.PicturesLibrary,
        };
        foreach (var ext in MediaKinds.ImageExtensions.Concat(MediaKinds.VideoExtensions)) picker.FileTypeFilter.Add("." + ext);
        if (picker.FileTypeFilter.Count != MediaKinds.ImageExtensions.Count + MediaKinds.VideoExtensions.Count)
            throw new InvalidOperationException("FileOpenPicker filter count mismatch");

        // 3. Create real opaque and transparent PNG files on disk and attach both through ChatAttachments.
        var temp = Path.Combine(Path.GetTempPath(), "hq-attach-walk-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(temp);
        try
        {
            var opaquePath = Path.Combine(temp, "opaque.png");
            var alphaPath = Path.Combine(temp, "alpha.png");
            await WriteSyntheticPngAsync(opaquePath, 320, 200, transparentCorner: false);
            await WriteSyntheticPngAsync(alphaPath, 160, 120, transparentCorner: true);

            await attach.AddPickedFilesAsync([
                new PickedItem(opaquePath, "opaque.png", PickSource.Photo),
                new PickedItem(alphaPath, "alpha.png", PickSource.Photo),
            ]);

            var center = AttachmentsFeature.CenterFor(client);
            var scope = AttachmentCenter.Scope(client.AccountId, bot.Name, storedId);
            var uploaded = await Until(() =>
            {
                var items = center.GetDraft(scope).Attachments;
                if (items.Count != 2) return null;
                if (items.Any(a => a.Failure != null))
                    throw new InvalidOperationException("attachment upload failed: " + string.Join("; ", items.Select(a => a.Failure?.Reason)));
                return items.All(a => a.IsUploaded) ? items : null;
            }, "both photos normalized and uploaded", 30);

            if (!uploaded[0].Name.EndsWith(".jpg", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException($"opaque photo normalized as {uploaded[0].Name}, expected .jpg");
            if (!uploaded[1].Name.EndsWith(".png", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException($"transparent photo normalized as {uploaded[1].Name}, expected .png");

            await Until(() => Find("composer.tray.tile.0"), "first tray tile", 10);
            await Until(() => Find("composer.tray.tile.1"), "second tray tile", 10);
            await Task.Delay(500);
            await shot("attachments-tray");

            // 4. Send the two attached photos and wait for the fixture gateway's reply.
            var beforeCount = chat.MessageCount;
            var send = (Button)await Until(() => Find("chat.send") is Button { IsEnabled: true } b ? b : null, "enabled Send button", 10);
            Invoke(send);
            await Until(() => chat.MessageCount >= beforeCount + 2 && !chat.IsBusy ? chat : null, "attached photo send and reply", 40);
            var state = await StandIn(url, "/__fixture/state");
            var uploads = state["uploads"]?.AsArray()?.Count ?? 0;
            if (uploads < 2) throw new InvalidOperationException($"fixture recorded {uploads} upload(s), expected >= 2");
            await Task.Delay(500);
            await shot("attachments-photo");
            AppLog.Note("automation", $"walk attachments-photo: + menu, FileOpenPicker, opaque->jpg + alpha->png normalize, tray and send passed ({uploads} uploads)");
        }
        finally
        {
            try { Directory.Delete(temp, recursive: true); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
    }

    private static async Task WriteSyntheticPngAsync(string path, uint width, uint height, bool transparentCorner)
    {
        var pixels = new byte[width * height * 4];
        for (uint y = 0; y < height; y++)
            for (uint x = 0; x < width; x++)
            {
                var i = (y * width + x) * 4;
                var clear = transparentCorner && x < 24 && y < 24;
                pixels[i] = (byte)(clear ? 0 : 0xD4);
                pixels[i + 1] = (byte)(clear ? 0 : 0x78);
                pixels[i + 2] = (byte)(clear ? 0 : 0x22);
                pixels[i + 3] = (byte)(clear ? 0 : 0xFF);
            }
        await using var fs = new FileStream(path, FileMode.Create, FileAccess.ReadWrite, FileShare.None, 64 * 1024, useAsync: true);
        using var stream = fs.AsRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Straight, width, height, 96, 96, pixels);
        await encoder.FlushAsync();
    }
}
