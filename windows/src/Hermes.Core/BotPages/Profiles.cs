using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Gateways;
using Hermes.Core.Net;

namespace Hermes.Core.BotPages;

/// One row of `GET /api/profiles` (HermesKit/Pages/More/ProfilesAPI.swift `ProfileRow`). Lenient: every key optional, a
/// number may come as a string.
public sealed record ProfileRow(string Name, string? Path = null, bool IsDefault = false, string? Model = null,
    string? Provider = null, int SkillCount = 0, string? DisplayName = null)
{
    public static ProfileRow? From(JsonNode? json)
    {
        if (json is not JsonObject || json.Get("name") is not JsonValue nv || !nv.TryGetValue(out string? raw)) return null;
        var name = raw.Trim();
        if (name.Length == 0) return null;
        return new ProfileRow(name, json.Text("path"), name == "default" || (json.Bool("is_default") ?? false),
            json.Text("model"), json.Text("provider"), (int)Math.Max(0, json.Int("skill_count") ?? 0),
            json.Text("display_name") ?? json.Text("bot_title"));
    }

    /// `{"profiles":[…]}` (or a bare array): bad rows skipped, a repeated name kept once, the default profile first.
    public static IReadOnlyList<ProfileRow> Rows(JsonNode? json)
    {
        var list = json.Arr("profiles") ?? json as JsonArray ?? [];
        var seen = new HashSet<string>();
        var rows = list.Select(From).OfType<ProfileRow>().Where(r => seen.Add(r.Name)).ToList();
        return [.. rows.Where(r => r.IsDefault), .. rows.Where(r => !r.IsDefault)];
    }
}

/// `GET /api/profiles/<name>/soul`.
public sealed record SoulDocument(string Content, bool Exists)
{
    public static SoulDocument From(JsonNode? json)
    {
        var content = json.Str("content") ?? "";
        return new SoulDocument(content, json.Bool("exists") ?? content.Length > 0);
    }
}

public sealed record ProfileRenamed(string Name, string? Path);

/// The Bot Profiles wire (`AG/hermes_cli/web_routers/profiles.py`).
public sealed class ProfilesApi(IPagesGateway gw)
{
    public static string PathFor(string name) => "/api/profiles/" + PagesRest.Segment(name);

    public async Task<IReadOnlyList<ProfileRow>> ListAsync(CancellationToken ct = default)
    {
        var json = await PagesRest.JsonAsync(gw, "GET", "/api/profiles", ct: ct);
        if (json.Arr("profiles") == null && json is not JsonArray) throw PagesRest.UnreadableAnswer(json);
        return ProfileRow.Rows(json);
    }

    public async Task<SoulDocument> SoulAsync(string name, CancellationToken ct = default)
    {
        var json = await PagesRest.JsonAsync(gw, "GET", PathFor(name) + "/soul", ct: ct);
        if (json is not JsonObject) throw new PagesMessageException(PagesRest.Unreadable);
        return SoulDocument.From(json);
    }

    /// `PUT …/soul {"content"}`. A large file may take a while on a slow link: two minutes.
    public Task SaveSoulAsync(string name, string content, CancellationToken ct = default) =>
        gw.RestAsync("PUT", PathFor(name) + "/soul", body: new JsonObject { ["content"] = content }, timeout: TimeSpan.FromSeconds(120), ct: ct);

    /// `PATCH /api/profiles/<name> {"new_name"}`. Hermes stops the profile's gateway first (up to 10 s): a minute.
    public async Task<ProfileRenamed> RenameAsync(string name, string newName, CancellationToken ct = default)
    {
        var json = await PagesRest.JsonAsync(gw, "PATCH", PathFor(name), body: new JsonObject { ["new_name"] = newName },
            timeout: TimeSpan.FromSeconds(60), ct: ct);
        var answered = json.Str("name")?.Trim() ?? "";
        return new ProfileRenamed(answered.Length == 0 ? newName : answered, json.Str("path"));
    }

    /// `DELETE /api/profiles/<name>` (BotStore+Extras.swift `deleteBot`). A 404 is already gone: not a failure.
    public async Task DeleteAsync(string name, string display, CancellationToken ct = default)
    {
        if (name == "default") throw new BotWriteException(BotDelete.FailTitle(display), "The default profile cannot be deleted.");
        try { await gw.RestAsync("DELETE", PathFor(name), ct: ct); }
        catch (GatewayException e) when (e is { Code: "http", Status: 404 }) { }
        catch (GatewayException h) when (h.Code == "http") { throw new BotWriteException(BotDelete.FailTitle(display), BotDelete.RestReason(h.Status, h.Body)); }
        catch (Exception e) when (e is not BotWriteException) { throw new BotWriteException(BotDelete.FailTitle(display), PagesRest.Reason(e)); }
    }
}

/// A refused bot write, with its alert's title (HermesKit BotWriteError).
public sealed class BotWriteException(string title, string reason) : Exception(reason)
{
    public string Title { get; } = title;
}

/// The Bots list's own Delete question (App/Bots/BotExtras.swift `BotExtrasRules`).
public static class BotDelete
{
    public static string Title(string name) => $"Delete “{name}”?";
    public const string Action = "Delete Bot";

    /// `groupChats`: the rooms it sits in, which it leaves.
    public static string Message(string name, IReadOnlyList<string>? groupChats = null)
    {
        var leaves = (groupChats?.Count ?? 0) switch
        {
            0 => "",
            1 => $" It leaves the group chat “{groupChats![0]}”.",
            var n => $" It leaves its {n} group chats.",
        };
        return $"{name}’s memory, skills, settings and chats are deleted from {HostWord.Phrase}.{leaves} This can’t be undone.";
    }

    public static string FailTitle(string display) => $"Couldn’t Delete {display}";

    /// The gateway's `detail` for a refused REST call, else plain words (BotStore+Extras.swift `restReason`).
    public static string RestReason(int status, string? body)
    {
        var v = J.Parse(body ?? "");
        if ((v.Text("detail") ?? v.Text("error")) is { } detail) return detail.Length > 200 ? detail[..200] : detail;
        return status == 409 ? "This bot is busy. Try again in a moment." : "Your gateway didn’t save the change.";
    }
}

/// The profile name rule and the Bot Profiles words (ProfilesAPI.swift `ProfileName`, ProfilesModel.swift).
public static class ProfileName
{
    public const string Hint = "Lowercase letters, digits, hyphens, and underscores. Must start with a letter or digit.";
    public const string Taken = "A profile with that name already exists.";
    public const int MaxLength = 64;

    /// `^[a-z0-9][a-z0-9_-]*$` (ASCII only).
    public static bool IsValid(string name)
    {
        if (name.Length == 0 || name.Length > MaxLength) return false;
        static bool Lead(char c) => c is >= 'a' and <= 'z' or >= '0' and <= '9';
        return Lead(name[0]) && name.All(c => Lead(c) || c is '_' or '-');
    }

    public enum Check { Ok, Unchanged, Invalid, Taken }

    /// What the Rename prompt makes of the typed name (not trimmed: a space is an invalid character, as on the web).
    public static Check Of(string typed, string current, IEnumerable<string> existing)
    {
        if (typed == current) return Check.Unchanged;
        if (!IsValid(typed) || typed == "default") return Check.Invalid;
        return existing.Contains(typed) ? Check.Taken : Check.Ok;
    }

    /// "Couldn’t Rename"'s reason: the gateway's own words, else the taken-name sentence for a 400 / 409.
    public static string RenameReason(Exception e)
    {
        if (e is GatewayException { Code: "http" } h)
        {
            if (PagesRest.Detail(h.Body) is { } detail) return detail;
            if (h.Status is 409 or 400) return Taken;
        }
        return PagesRest.Reason(e);
    }

    /// "1 profile" / "N profiles".
    public static string Count(int n) => n == 1 ? "1 profile" : $"{n} profiles";

    /// "12 skills" (ProfilesModel.skills).
    public static string Skills(int count) => count == 0 ? "No skills" : count == 1 ? "1 skill" : $"{count} skills";

    /// "`<model>` · `N skills`", without the internal profile name.
    public static string Subtitle(string? model, int skills) =>
        string.Join(" · ", new[] { model, Skills(skills) }.Where(s => !string.IsNullOrEmpty(s)));

    /// The id in Title Case (SessionsViewController.readableProfileName): "Hermes" for the default.
    public static string Readable(string profile)
    {
        var name = profile.Trim();
        if (name.Length == 0 || name == "default") return "Hermes";
        return string.Join(" ", name.Replace('-', ' ').Replace('_', ' ').Split(' ', StringSplitOptions.RemoveEmptyEntries)
            .Select(w => char.ToUpperInvariant(w[0]) + w[1..]));
    }

    /// The bot's display name: the roster's, else the gateway's `display_name`, else the id in Title Case.
    public static string Title(ProfileRow row, string? rosterName) => rosterName ?? row.DisplayName ?? Readable(row.Name);

    /// The list's search: name, title, model, provider (ProfilesModel.shown).
    public static IReadOnlyList<ProfileRow> Filter(IReadOnlyList<ProfileRow> rows, string query, Func<ProfileRow, string> title)
    {
        var words = query.Trim().ToLowerInvariant();
        if (words.Length == 0) return rows;
        return [.. rows.Where(r => new[] { r.Name, title(r), r.Model ?? "", r.Provider ?? "" }
            .Any(s => s.ToLowerInvariant().Contains(words)))];
    }

    public const string DefaultFooter = "The default profile can’t be renamed or deleted.";
    public const string RenameTitle = "Rename Bot";
    public const string RenameFailTitle = "Couldn’t Rename";
    public const string LoadFailTitle = "Couldn’t Load Profiles";
    public const string SearchPlaceholder = "Search Profiles";

    /// "What <bot> is told about who it is and how to work. Changes apply to its next chat." (BotInfoWords).
    public static string InstructionsFooter(string botName) =>
        $"What {botName} is told about who it is and how to work. Changes apply to its next chat.";
}

/// What was being typed when the app went away (ProfilesAPI.swift `SoulDraft`).
public sealed record SoulDraft(string Text, string BaseHash)
{
    public static string Hash(string text) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
}

/// Drafts kept in `<cache>/pages/soul-draft-<account>-<profile>.txt`: written on every pause in typing, removed on Save
/// and on Discard. The text never goes to the log or a URL.
public sealed class SoulDraftStore(string directory)
{
    public string Directory { get; } = directory;
    private const string Header = "hq-soul-draft base=";

    public static string FileName(string account, string profile)
    {
        static string Short(string text) => SoulDraft.Hash(text)[..16];
        var safe = profile.Length is > 0 and <= 64 && profile.All(c => char.IsLetterOrDigit(c) || c is '-' or '_');
        return $"soul-draft-{Short(account)}-{(safe ? profile : Short(profile))}.txt";
    }

    public string PathFor(string account, string profile) => Path.Combine(Directory, FileName(account, profile));

    public static string Encode(SoulDraft draft) => Header + draft.BaseHash + "\n" + draft.Text;

    public static SoulDraft? Decode(string whole)
    {
        if (!whole.StartsWith(Header, StringComparison.Ordinal)) return null;
        var end = whole.IndexOf('\n');
        if (end < 0) return null;
        var baseHash = whole[Header.Length..end];
        if (baseHash.Length != 64 || !baseHash.All(Uri.IsHexDigit)) return null;
        return new SoulDraft(whole[(end + 1)..], baseHash);
    }

    public void Write(SoulDraft draft, string account, string profile)
    {
        try
        {
            System.IO.Directory.CreateDirectory(Directory);
            var path = PathFor(account, profile);
            File.WriteAllText(path + ".tmp", Encode(draft));
            File.Move(path + ".tmp", path, overwrite: true);
        }
        catch (IOException) { }   // a draft that can't be kept is not worth an alert: the text is still in the editor
        catch (UnauthorizedAccessException) { }
    }

    public SoulDraft? Read(string account, string profile)
    {
        try { var path = PathFor(account, profile); return File.Exists(path) ? Decode(File.ReadAllText(path)) : null; }
        catch (IOException) { return null; }
    }

    public void Remove(string account, string profile)
    {
        try { File.Delete(PathFor(account, profile)); } catch (IOException) { }
    }

    /// Sign-out: every draft of this account goes.
    public void RemoveAll(string account)
    {
        var prefix = "soul-draft-" + SoulDraft.Hash(account)[..16] + "-";
        try
        {
            if (!System.IO.Directory.Exists(Directory)) return;
            foreach (var f in System.IO.Directory.GetFiles(Directory, prefix + "*")) File.Delete(f);
        }
        catch (IOException) { }
    }
}

/// The SOUL.md editor's pure rules (ProfilesAPI.swift `SoulRules`), shown to users as "Instructions".
public static class SoulRules
{
    public enum DraftOffer { None, Offer }

    /// No draft, or it says what the gateway says: nothing to ask.
    public static DraftOffer OfferFor(SoulDraft? draft, string server) =>
        draft == null || draft.Text == server ? DraftOffer.None : DraftOffer.Offer;

    /// The file changed on the gateway since the edit's base was read (asked on Save, after a fresh read).
    public static bool ChangedOnGateway(string baseHash, bool baseExists, SoulDocument now)
    {
        if (!baseExists && !now.Exists) return false;
        return baseExists != now.Exists || SoulDraft.Hash(now.Content) != baseHash;
    }

    public sealed record Bar(bool CancelEnabled, bool SaveEnabled, string SaveTitle);

    /// Save is grey until something changed; while saving it reads "Saving…" and both buttons are off.
    public static Bar BarFor(bool dirty, bool saving) => new(!saving, dirty && !saving, saving ? "Saving…" : "Save");

    public const string Title = "Instructions";
    public const string DiscardTitle = "Discard Changes?";
    public const string DiscardMessage = "Your Instructions edits have not been saved.";
    public const string DiscardConfirm = "Discard Changes";
    public const string DiscardCancel = "Keep Editing";
    public const string Placeholder = "This bot has no instructions yet. What you write here tells the bot who it is.";
    public const string Loading = "Loading Instructions…";
    public const string LoadFailTitle = "Couldn’t Load Instructions";
    public const string Gone = "This bot isn’t on your gateway any more.";
    public const string SaveFailTitle = "Couldn’t Save Instructions";
    public const string Saved = "Instructions Saved";
    public const string RestoreTitle = "Restore Unsaved Changes?";
    public static string RestoreMessage(string botName) => $"You were editing {botName}’s Instructions and your changes were not saved.";
    public const string ChangedTitle = "Instructions Changed on Your Gateway";
    public const string ChangedMessage = "Someone else changed this file since you opened it.";
    public const string ReplaceIt = "Replace It";
    public const string UseTheirs = "Use Their Version";
}
