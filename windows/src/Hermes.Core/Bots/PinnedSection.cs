using System.Text.Json;
using System.Text.Json.Nodes;

namespace Hermes.Core.Bots;

/// The Pinned section rules (spec 1x-settings §5.2): a pinned bot is filed in the "Pinned" section so desktop Hermes,
/// which has no pinned area, shows what the tiles do. Port of HermesKit/Model/PinnedSection.swift. A meta is the bot's
/// `ui_meta['hermes-bots']` object; a patch is the keys to set (JSON null is a value, sent as null, never a deletion).
public static class PinnedSection
{
    public const string Id = RosterRules.PinnedSectionId;
    public const string Name = RosterRules.PinnedSectionName;
    public const string HomeKey = "pinnedFrom";

    public static PinHome PinHomeOf(JsonObject? meta) => PinHome.From(meta, HomeKey);

    /// `typeof meta.sectionId === 'string' && meta.sectionId ? meta.sectionId : null`
    public static string? Current(JsonObject? meta) =>
        meta?["sectionId"] is JsonValue v && v.GetValueKind() == JsonValueKind.String && v.GetValue<string>() is { Length: > 0 } s ? s : null;

    /// The section menus and Bot Info show: a pinned bot's is the home it goes back to when unpinned.
    public static string? ShownSectionId(JsonObject? meta, string? sectionId) =>
        sectionId != Id ? sectionId : PinHomeOf(meta) is PinHome.Section s ? s.Id : null;

    private static string? StringOf(JsonNode? n) =>
        n is JsonValue v && v.GetValueKind() == JsonValueKind.String ? v.GetValue<string>() : null;

    /// The write that makes a bot's section agree with its pin, or null when they agree.
    public static JsonObject? PinnedSectionPatch(JsonObject? meta, Func<string, string?> sectionName)
    {
        if (meta == null) return null;
        var home = PinHomeOf(meta);
        var current = Current(meta);
        var homeUndefined = home is PinHome.Unrecorded;
        if (RosterText.Truthy(meta["pinned"]))
        {
            if (current != Id)
            {
                JsonNode? from = current == null ? null : new JsonObject { ["id"] = current, ["name"] = StringOf(meta["sectionName"]) };
                return new JsonObject { ["sectionId"] = Id, ["sectionName"] = Name, [HomeKey] = from };
            }
            if (StringOf(meta["sectionName"]) != Name)
            {
                var patch = new JsonObject { ["sectionName"] = Name };
                if (homeUndefined) patch[HomeKey] = null;
                return patch;
            }
            return homeUndefined ? new JsonObject { [HomeKey] = null } : null;
        }
        if (current != Id) return homeUndefined ? null : new JsonObject { [HomeKey] = false };
        if (homeUndefined) return new JsonObject { ["pinned"] = true, ["sectionName"] = Name, [HomeKey] = null };
        if (home is PinHome.Section s && sectionName(s.Id) is { } back)
            return new JsonObject { ["sectionId"] = s.Id, ["sectionName"] = back, [HomeKey] = false };
        return new JsonObject { ["sectionId"] = null, ["sectionName"] = null, [HomeKey] = false };
    }

    /// A pin or unpin as one write: the flag and the section it implies.
    public static JsonObject PinPatch(JsonObject? meta, bool pinned, Func<string, string?> sectionName)
    {
        var next = meta == null ? new JsonObject() : (JsonObject)meta.DeepClone();
        next["pinned"] = pinned;
        var patch = new JsonObject { ["pinned"] = pinned };
        if (PinnedSectionPatch(next, sectionName) is { } extra)
            foreach (var (k, v) in extra) patch[k] = v?.DeepClone();
        return patch;
    }

    /// Moving a bot from a menu or a drop. A pinned bot stays in Pinned (the pick is where an unpin puts it); moving onto
    /// Pinned pins it. Null: an ordinary move (`{"sectionId", "sectionName"}`) applies.
    public static JsonObject? SectionMovePatch(JsonObject? meta, string? target, Func<string, string?> sectionName)
    {
        var pinned = RosterText.Truthy(meta?["pinned"]);
        if (target == Id) return pinned ? new JsonObject() : PinPatch(meta, true, sectionName);
        if (!pinned) return null;
        if (target == null) return new JsonObject { [HomeKey] = null };
        return new JsonObject { [HomeKey] = new JsonObject { ["id"] = target, ["name"] = sectionName(target) } };
    }

    /// The values `patch` replaces, to put back if the gateway refuses it.
    public static JsonObject UndoOf(JsonObject? meta, JsonObject patch)
    {
        var undo = new JsonObject();
        foreach (var (key, _) in patch)
        {
            var value = meta?[key];
            undo[key] = value is not null ? value.DeepClone() : key == HomeKey ? false : null;
        }
        return undo;
    }

    /// `{...meta, ...patch}`.
    public static JsonObject Apply(JsonObject? patch, JsonObject meta)
    {
        var next = (JsonObject)meta.DeepClone();
        if (patch != null) foreach (var (k, v) in patch) next[k] = v?.DeepClone();
        return next;
    }
}
