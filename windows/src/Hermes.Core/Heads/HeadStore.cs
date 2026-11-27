using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using Hermes.Core.Model;
using Hermes.Core.Net;

namespace Hermes.Core.Heads;

/// One JSON-RPC call (HermesClient.Rpc.RequestAsync), so the head code can be tested against a recorded gateway.
public delegate Task<JsonNode> RpcCall(string method, JsonObject parameters, TimeSpan timeout, CancellationToken ct);

/// A head save that didn't land (Contracts+settings.swift `HeadSaveError`): another device saved first (`Conflict`,
/// with the gateway's revision), or the gateway refused or didn't answer.
public sealed class HeadSaveException(string message, int? actualRevision = null) : Exception(message)
{
    public int? ActualRevision { get; } = actualRevision;
    public bool IsConflict => ActualRevision != null;

    public const string ConflictWords = "This bot’s head was changed on another device. Save again to replace it with yours.";
    public const string NoAnswer = "The gateway didn’t answer. Check the connection and try again.";
    public const string Outdated = "This gateway can’t save bot heads yet. Update Hermes on the computer running Hermes, then try again.";
    public const string NotSaved = "The gateway didn’t save the head. Try again.";
}

/// A saved head as the editor opens it (spec 1x-settings §7.2): the raw record (null: the name's default), its revision,
/// and whether a head was saved at all.
public sealed record StoredHeadState(JsonNode? Record, int Revision, bool Saved);

/// Saving heads (spec 1x-settings §7.5, BotStore+Editing.swift `saveHead` / `mirrorHead`) and the overlay that shows a
/// saved head everywhere at once, before the roster catches up (`$headOverlay`).
public static class HeadStore
{
    public const string HeadKey = "dispatch-head";
    static readonly TimeSpan Timeout = TimeSpan.FromSeconds(30);

    /// name → (head, revision): wins while its revision is greater than the roster row's.
    static readonly ConcurrentDictionary<string, (JsonNode? Head, int Revision)> Overlay = new();

    /// A bot's face may have changed (a save here, an Undo, a photo arriving): its name.
    public static event Action<string>? Changed;

    public static void NotifyChanged(string name) => Changed?.Invoke(name);

    /// Sign-out or a gateway switch: nothing of the account before is drawn after this.
    public static void Forget() => Overlay.Clear();

    /// The head a bot wears now: the overlay's when it is newer than the row's.
    public static (JsonNode? Raw, int Revision) Effective(Bot bot) =>
        Overlay.TryGetValue(bot.Name, out var o) && o.Revision > bot.HeadRevision ? (o.Head, o.Revision) : (bot.HeadRaw, bot.HeadRevision);

    /// `headState(bot)`: what Edit Head opens with.
    public static StoredHeadState State(Bot bot)
    {
        var (raw, revision) = Effective(bot);
        var saved = HeadRecord.Parse(raw) != null;
        return new StoredHeadState(saved ? raw : null, revision, saved);
    }

    /// The face a bot wears (`Head.resolve` over the effective record).
    public static Head HeadOf(Bot bot) => Head.Resolve(Effective(bot).Raw, bot.Name);

    /// The `profiles.configure` params of a compare-and-swap head save (null record: Reset Head).
    public static JsonObject SaveParams(string name, JsonObject? record, int revision) => new()
    {
        ["name"] = name,
        ["ui_meta"] = new JsonObject { [HeadKey] = record?.DeepClone() },
        ["ui_meta_expected_revisions"] = new JsonObject { [HeadKey] = revision },
    };

    /// Reads `profiles.configure`'s answer: the new revision, or a HeadSaveException.
    public static int ReadSaveResult(JsonNode? result, int revision)
    {
        var applied = result.Obj("applied");
        if (applied.Obj("ui_meta_conflicts")?[HeadKey] is { } conflict)
        {
            var actual = conflict.Int("actual") is { } a ? (int)a : revision + 1;
            throw new HeadSaveException(HeadSaveException.ConflictWords, actual >= 0 ? actual : revision + 1);
        }
        if (applied == null || !applied.ContainsKey("ui_meta")) throw new HeadSaveException(HeadSaveException.Outdated);
        if (applied["ui_meta"] is not JsonValue v || v.GetValueKind() != System.Text.Json.JsonValueKind.True)
            throw new HeadSaveException(HeadSaveException.NotSaved);
        var next = applied.Obj("ui_meta_revisions").Int(HeadKey) is { } n ? (int)n : 0;
        return next > revision ? next : revision + 1;
    }

    /// Compare-and-swap save of `dispatch-head` (null record = Reset Head). Returns the new revision; on success the
    /// head shows everywhere at once (the overlay) and the bot's photo, if it wore one, gives way to the head.
    public static async Task<int> SaveAsync(RpcCall rpc, string name, HeadRecord? record, int revision, CancellationToken ct = default)
    {
        var stored = record?.ForSaving.Stored();
        JsonNode result;
        try
        {
            result = await rpc("profiles.configure", SaveParams(name, stored, revision), Timeout, ct);
        }
        catch (GatewayException e)
        {
            throw new HeadSaveException(e.Code == "rpc" && e.Message.Length > 0 ? e.Message : HeadSaveException.NoAnswer);
        }
        var saved = ReadSaveResult(result, revision);
        Overlay[name] = (stored, saved);
        if (stored != null) BotPhotos.Shared.HeadSaved(name, saved);
        NotifyChanged(name);
        return saved;
    }

    /// The desktop copy (`mirror.ts`): a saved head's 288 × 288 PNG as the profile's avatar; after a reset (null), the copy
    /// this app put there is removed (a photo someone chose is left alone). Never fails anything.
    public static async Task MirrorAsync(RpcCall rpc, string name, string? pngDataUrl, CancellationToken ct = default)
    {
        try
        {
            if (pngDataUrl != null)
            {
                await rpc("profiles.set_asset", new JsonObject { ["name"] = name, ["asset"] = "avatar", ["data"] = pngDataUrl }, Timeout, ct);
                return;
            }
            var current = await rpc("profiles.get_asset", new JsonObject { ["name"] = name, ["asset"] = "avatar" }, Timeout, ct);
            if (current.Bool("found") != true || !HeadRecord.IsHeadMirror(current.Str("data"))) return;
            await rpc("profiles.set_asset", new JsonObject { ["name"] = name, ["asset"] = "avatar", ["clear"] = true }, Timeout, ct);
        }
        catch (Exception e) when (e is GatewayException or OperationCanceledException) { }
    }

    /// The desktop copy's data URL from a PNG of the head (`mirrorPNG`): with the dark-flip mark when inverting the
    /// light picture gives the dark one.
    public static string MirrorDataUrl(Head head, byte[] png) =>
        "data:image/png;base64," + Convert.ToBase64String(HeadGeometry.InvertsOnDarkPage(head.Plain) ? HeadRecord.WithDarkFlipMark(png) : png);
}
