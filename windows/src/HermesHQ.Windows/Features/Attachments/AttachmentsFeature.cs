using System.Text.Json.Nodes;
using Hermes.Core;
using Hermes.Core.Attachments;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using HermesHQ.Services;
using HermesHQ.Shell;

namespace HermesHQ.Features.Attachments;

/// Photos and files (the Mac's App/Chat/Attachments, App/Chat/Viewer; spec 1x-attachments): the + menu, the tray,
/// drag and drop and paste, uploads and sends through Hermes.Core.Attachments, pictures and file rows in bubbles,
/// generated images, and the viewer.
public static class AttachmentsFeature
{
    public static string Root => Path.Combine(AppPaths.Root, "attachments");

    public static void Register()
    {
        InlineMediaStore.Root = Path.Combine(AppPaths.Root, "media-inline");
        AttachmentLimit.Store = new SettingsFileStore();
        AttachmentCenter.Normalizer = new WindowsPhotoNormalizer();
        ChatExtensions.OnOpen.Add(ctx => ChatAttachments.Attach(ctx));
        ChatExtensions.PartRenderers[typeof(AttachmentPart)] = AttachmentRenderers.Attachment;
        ChatExtensions.PartRenderers[typeof(GeneratedImagePart)] = AttachmentRenderers.Generated;
    }

    /// The account's center (one per signed-in account).
    public static AttachmentCenter CenterFor(HermesClient client) => AttachmentCenter.For(client, Root);

    /// Sign-out: uploads stop; the account's copies, drafts and media go (spec §6.6).
    public static void SignedOut(string accountId)
    {
        AttachmentCenter.SignedOut(accountId);
        InlineMediaStore.Purge();
    }

    /// Largest Attachment, kept in %LOCALAPPDATA%\HermesHQ\settings-attachments.json (null: the default).
    private sealed class SettingsFileStore : AttachmentLimit.IStore
    {
        private static string FilePath => Path.Combine(AppPaths.Root, "settings-attachments.json");

        public int? Read()
        {
            try { return File.Exists(FilePath) ? (int?)J.Parse(File.ReadAllText(FilePath)).Int(AttachmentLimit.Key) : null; }
            catch (IOException) { return null; }
        }

        public void Write(int? value)
        {
            try
            {
                Directory.CreateDirectory(AppPaths.Root);
                var o = new JsonObject();
                if (value is { } v) o[AttachmentLimit.Key] = v;
                File.WriteAllText(FilePath, o.ToJsonString());
            }
            catch (IOException e) { AppLog.Error("attachments", e); }
        }
    }
}

/// The open chat's media context, for the bubble renderers (they get only the part and its message): the account's
/// center, the bot's profile and the stored session (a relative path is read against it). M1 shows one chat at a time.
internal sealed record MediaContext(AttachmentCenter Center, ChatSession Session)
{
    public static MediaContext? Current { get; set; }
    public string Profile => Session.Profile;
    public string SessionId => Session.MediaSessionId;
}
