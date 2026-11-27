using System.Text.Json.Nodes;

namespace Hermes.Core.Heads;

// A bot's picture as a small record (spec 02 §10.2–10.3), ported from App/Heads/HeadModel.swift (itself the web app's
// `src/ui-heads/head.ts`). Pure value code; drawing lives in HeadGeometry / ThemeHeadSvg / MatrixHead.

public enum HeadTheme { Robot, Persona, Dots, Orb, Pixel, Glyph, Shape, Matrix }
public enum HeadColor
{
    Ink, Mint, Teal, Sky, Lilac, Pink, Coral, Peach, Butter, Lime, Paper,
    Red, Grass, Forest, Cobalt, Denim, Grape, Plum, Magenta, Rose, Wine, Caramel, Cocoa, Slate,
}
public enum HeadForm { Round, Blob, Square, Pill, Triangle, Hex, Cloud, Drop, Star, Heart }
public enum HeadLook { Slits, Dots, Ovals, Googly, Happy, Sleepy, Stars, Hearts }
public enum HeadSpecs { None, Shades, Aviators, Round, Monocle }
public enum HeadHat { None, Crown, Halo, Sprout, Party, Bow, Beanie }
public enum HeadMouth { None, Smile, Open, Cat, Grille }
public enum HeadTile { Dark, Light, Color, None }

/// How a head is posed: idle at rest; thinking/speaking while its bot works (spec 02 §10.4 item 5).
public enum HeadState { Idle, Thinking, Speaking, Done, Offline }

/// The wire names of the head enums: the case name in lower case ("round", "googly").
public static class HeadWire
{
    public static string Name<T>(T value) where T : struct, Enum => value.ToString().ToLowerInvariant();

    /// The case whose wire name is exactly `text`, else null.
    public static T? Parse<T>(string? text) where T : struct, Enum
    {
        if (text is null) return null;
        foreach (var v in Enum.GetValues<T>()) if (Name(v) == text) return v;
        return null;
    }
}

/// A parsed head record. Only the fields a Shapes or dot-matrix head draws are kept; a Robot, Dots, Orb, Pixel or Emoji
/// head carries its whole stored record in `Themed` (HeadModel.swift `Head`).
public sealed record Head
{
    public HeadTheme Theme { get; init; } = HeadTheme.Shape;
    public HeadColor Color { get; init; } = HeadColor.Mint;
    /// Keeps a generated picture (the blob's wobble) the same on every device. Clamped to [1, 2^31 − 1].
    public int Seed { get; init; } = 1;
    public HeadForm Form { get; init; } = HeadForm.Round;
    public HeadLook Look { get; init; } = HeadLook.Slits;
    public HeadSpecs Specs { get; init; } = HeadSpecs.None;
    /// Parsed for fidelity, never drawn: the owner rejected hats on Shapes heads (spec 06 §12).
    public HeadHat Hat { get; init; } = HeadHat.None;
    public HeadMouth Mouth { get; init; } = HeadMouth.None;
    public bool Blush { get; init; }
    public HeadTile Tile { get; init; } = HeadTile.None;
    /// A dot-matrix head's outline (saved in `form`).
    public MatrixSilhouette Silhouette { get; init; } = MatrixSilhouette.Round;
    /// A Robot, Dots, Orb, Pixel or Emoji head: the whole stored record. Null for a Shapes or dot-matrix head.
    public HeadRecord? Themed { get; init; }

    /// What a head prints as (`Plain` would print forever).
    private bool PrintMembers(System.Text.StringBuilder builder)
    {
        builder.Append(CacheKey);
        return true;
    }

    static readonly HashSet<string> RobotShapes = ["dome", "blob", "puff", "pebble", "shield", "diamond", "cat", "ghost",
        "cloud", "heart", "star", "drop"];
    static readonly HashSet<string> RobotFaces = ["visor", "pill", "dots", "surprised", "happy", "content", "wink", "sleepy",
        "bars", "side", "angry", "worried", "heart", "sparkle", "dizzy", "scanner"];

    /// `parseHead` (`head.ts:117-160`): null when `raw` is not an object or names no known theme/shape/face.
    public static Head? Parse(JsonNode? raw)
    {
        if (raw is not JsonObject value) return null;
        static bool Known(IEnumerable<string> list, JsonNode? field) =>
            field is JsonValue v && v.TryGetValue(out string? s) && list.Contains(s);
        if (!Known(Enum.GetValues<HeadTheme>().Select(HeadWire.Name), value["theme"]) && !Known(RobotShapes, value["shape"])
            && !Known(RobotFaces, value["face"])) return null;
        string? Str(string key) => value[key] is JsonValue v && v.TryGetValue(out string? s) ? s : null;
        var theme = HeadWire.Parse<HeadTheme>(Str("theme")) ?? HeadTheme.Robot;
        var version = HeadRecord.Number(value["v"]) ?? 0;
        var mouth = HeadWire.Parse<HeadMouth>(Str("mouth")) ?? HeadMouth.None;
        var blush = value["blush"] is JsonValue b && b.TryGetValue(out bool bb) && bb;
        var tile = HeadWire.Parse<HeadTile>(Str("tile")) ?? HeadTile.Dark;
        if (theme == HeadTheme.Shape && !(version >= 5)) { mouth = HeadMouth.None; blush = false; }
        if (theme == HeadTheme.Shape && !(version >= 6)) tile = HeadTile.None;
        return new Head
        {
            Theme = theme,
            Color = HeadWire.Parse<HeadColor>(Str("color")) ?? HeadColor.Mint,
            Seed = HeadRecord.ParseSeed(value["seed"]),
            Form = HeadWire.Parse<HeadForm>(Str("form")) ?? HeadForm.Round,
            Look = HeadWire.Parse<HeadLook>(Str("look")) ?? HeadLook.Slits,
            Specs = HeadWire.Parse<HeadSpecs>(Str("specs")) ?? HeadSpecs.None,
            Hat = HeadWire.Parse<HeadHat>(Str("hat")) ?? HeadHat.None,
            Mouth = mouth, Blush = blush, Tile = tile,
        };
    }

    /// The picture a bot wears: its saved head, else its §10.3 default. A Character head (a theme the owner removed)
    /// falls back to the default.
    public static Head Resolve(JsonNode? raw, string profile)
    {
        if (Parse(raw) is { Theme: HeadTheme.Shape } head) return head;
        if (HeadRecord.Parse(raw) is { } record) return FromRecord(record) ?? DefaultHead(profile);
        return DefaultHead(profile);
    }

    /// A head from a full record: a Shapes or dot-matrix head as its fields, the drawn themes carrying the record; null
    /// for Character.
    public static Head? FromRecord(HeadRecord record)
    {
        if (record.Theme == "shape") return Parse(record.Stored());
        if (record.Theme == "matrix")
            return new Head
            {
                Theme = HeadTheme.Matrix,
                Color = HeadWire.Parse<HeadColor>(record.Color) ?? HeadColor.Mint,
                Seed = Math.Clamp(record.Seed, 1, int.MaxValue),
                Silhouette = MatrixSilhouettes.FromStored(record.Form),
                Look = HeadWire.Parse<HeadLook>(record.Look) ?? HeadLook.Slits,
                Mouth = HeadWire.Parse<HeadMouth>(record.Mouth) ?? HeadMouth.None,
                Blush = record.Blush,
            };
        if (!ThemeHeadSvg.DrawnThemes.Contains(record.Theme)) return null;
        return new Head
        {
            Theme = HeadWire.Parse<HeadTheme>(record.Theme) ?? HeadTheme.Robot,
            Color = HeadWire.Parse<HeadColor>(record.Color) ?? HeadColor.Mint,
            Seed = record.Seed,
            Themed = record,
        };
    }

    /// The head a bot wears until it is given another: the name's plain Shapes head (owner 2026-11-08).
    public static Head DefaultHead(string profile) => DefaultShapeHead(profile);

    /// What a default head is picked from: the profile name trimmed and in lower case ("default" when empty).
    public static string DefaultKey(string profile)
    {
        var trimmed = profile.Trim().ToLowerInvariant();
        return trimmed.Length == 0 ? "default" : trimmed;
    }

    /// SHAPE_COLORS without ink, slate and paper, in the editor's order (`head.ts:30-31,250`).
    public static readonly HeadColor[] DefaultColours =
    [
        HeadColor.Red, HeadColor.Coral, HeadColor.Peach, HeadColor.Butter, HeadColor.Lime, HeadColor.Grass, HeadColor.Mint,
        HeadColor.Teal, HeadColor.Sky, HeadColor.Cobalt, HeadColor.Lilac, HeadColor.Grape, HeadColor.Rose, HeadColor.Pink,
        HeadColor.Magenta, HeadColor.Plum, HeadColor.Denim, HeadColor.Forest, HeadColor.Wine, HeadColor.Cocoa, HeadColor.Caramel,
    ];

    /// `defaultHead` (`head.ts:246-258`): the web's default, a plain Shapes head picked from the profile name.
    public static Head DefaultShapeHead(string profile)
    {
        var hash = Math.Max(NameHash(DefaultKey(profile)), 1u);
        var random = new SeededRandom(hash);
        HeadForm[] forms = [HeadForm.Round, HeadForm.Blob, HeadForm.Square, HeadForm.Pill, HeadForm.Hex, HeadForm.Cloud];
        var seed = (int)(hash % 2147483647u);
        return new Head
        {
            Theme = HeadTheme.Shape,
            Color = DefaultColours[(int)(hash % (uint)DefaultColours.Length)],
            Seed = seed == 0 ? 1 : seed,
            Form = forms[(int)Math.Floor(random.Next() * forms.Length)],
            Tile = HeadTile.None,
        };
    }

    /// Twelve colour families evenly round the wheel, so neighbouring bots rarely share one.
    public static readonly HeadColor[] MatrixColours =
    [
        HeadColor.Red, HeadColor.Peach, HeadColor.Butter, HeadColor.Lime, HeadColor.Grass, HeadColor.Mint, HeadColor.Teal,
        HeadColor.Sky, HeadColor.Cobalt, HeadColor.Lilac, HeadColor.Grape, HeadColor.Pink,
    ];

    /// The dot-matrix head picked from the profile name (each bot's default from build 378 until 2026-11-08).
    public static Head DefaultMatrixHead(string profile)
    {
        var key = DefaultKey(profile);
        var hash = Math.Max(NameHash(key), 1u);
        var random = new SeededRandom(hash);
        var outline = new SeededRandom(Math.Max(NameHash("matrix:" + key), 1u));
        var silhouette = Pick(ref outline, [(MatrixSilhouette.Round, 2), (MatrixSilhouette.Square, 2), (MatrixSilhouette.Tall, 1.5),
            (MatrixSilhouette.Wide, 1.5), (MatrixSilhouette.Pebble, 1.5), (MatrixSilhouette.Cloud, 1.5), (MatrixSilhouette.Arch, 1.5),
            (MatrixSilhouette.Shield, 1.5), (MatrixSilhouette.Drop, 1.5), (MatrixSilhouette.Leaf, 1.5), (MatrixSilhouette.Hex, 1.5),
            (MatrixSilhouette.Octagon, 1.5)]);
        random.Next();
        var look = Pick(ref random, [(HeadLook.Slits, 6), (HeadLook.Ovals, 3), (HeadLook.Dots, 2), (HeadLook.Happy, 1)]);
        for (var i = 0; i < 3; i++) random.Next();
        var mouth = Pick(ref random, [(HeadMouth.None, 12), (HeadMouth.Smile, 1)]);
        var blush = random.Next() < 0.08;
        var seed = (int)(hash % 2147483647u);
        return new Head
        {
            Theme = HeadTheme.Matrix, Color = MatrixColours[(int)(hash % (uint)MatrixColours.Length)],
            Seed = seed == 0 ? 1 : seed, Silhouette = silhouette, Look = look, Mouth = mouth, Blush = blush,
        };
    }

    static T Pick<T>(ref SeededRandom random, (T Value, double Weight)[] list)
    {
        var left = random.Next() * list.Sum(x => x.Weight);
        foreach (var (value, weight) in list)
        {
            left -= weight;
            if (left < 0) return value;
        }
        return list[0].Value;
    }

    /// FNV-1a 32-bit over the text's code points (`head.ts:185-189`).
    public static uint NameHash(string text)
    {
        var hash = 2166136261u;
        foreach (var rune in text.EnumerateRunes())
        {
            hash ^= (uint)rune.Value;
            unchecked { hash *= 16777619u; }
        }
        return hash;
    }

    /// One string per distinct picture (`headKey`, shape branch): what drawings are cached on.
    public string CacheKey
    {
        get
        {
            if (Themed is { } t) return t.PictureKey;
            if (Theme == HeadTheme.Matrix)
                return $"matrix|{HeadWire.Name(Silhouette)}|{HeadWire.Name(Look)}|{HeadWire.Name(Mouth)}|{(Blush ? 1 : 0)}|{HeadWire.Name(Color)}|"
                    + MatrixHead.Facing(Seed);
            return $"shape|{HeadWire.Name(Form)}|{HeadWire.Name(Look)}|{HeadWire.Name(Specs)}|{HeadWire.Name(Hat)}|{HeadWire.Name(Mouth)}|"
                + $"{(Blush ? 1 : 0)}|{HeadWire.Name(Color)}|{HeadWire.Name(Tile)}|{(Form == HeadForm.Blob ? Seed : 0)}";
        }
    }

    /// The head as the app draws it: its eyes and nothing else, and only the normal eyes (owner 2026-10-28). Slits on a
    /// Shapes or dot-matrix head, no glasses, mouth, cheeks or hat; a drawn theme's record as `HeadRecord.Plain`.
    public Head Plain => this with
    {
        Look = HeadLook.Slits, Specs = HeadSpecs.None, Hat = HeadHat.None, Mouth = HeadMouth.None, Blush = false,
        Themed = Themed?.Plain,
    };
}

/// mulberry32, exactly as `seededRandom` in `head.ts:190-197` (32-bit wrapping arithmetic).
public struct SeededRandom(uint seed)
{
    private uint _state = seed;

    public double Next()
    {
        unchecked
        {
            _state += 0x6D2B79F5u;
            var t = (_state ^ (_state >> 15)) * (1u | _state);
            t = (t + ((t ^ (t >> 7)) * (61u | t))) ^ t;
            return (t ^ (t >> 14)) / 4294967296.0;
        }
    }
}
