using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Hermes.Core.Heads;

/// A head as the gateway stores it (spec 1x-settings §7): every field of the web's v6 head, so a save writes exactly what
/// the web would (`Stored`) and a seeded idea or Shuffle draws the same `random()` sequence as `rollHead`. Ported from
/// App/Heads/HeadRecord.swift. A mutable record: copy with `with { }` before changing a shared one.
public sealed record HeadRecord
{
    public const int Version = 6;
    /// `matrix` is native only (MatrixHead); the web, and builds before it, read a saved one as a robot.
    public static readonly string[] Themes = ["robot", "persona", "dots", "orb", "pixel", "glyph", "shape", "matrix"];
    public static readonly string[] Shapes = ["dome", "blob", "puff", "pebble", "shield", "diamond", "cat", "ghost", "cloud", "heart", "star", "drop"];
    public static readonly string[] OfferedShapes = Shapes[..8];
    public static readonly string[] Faces = ["visor", "pill", "dots", "surprised", "happy", "content", "wink", "sleepy", "bars", "side",
        "angry", "worried", "heart", "sparkle", "dizzy", "scanner"];
    public static readonly string[] Visors = ["band", "goggles", "screen", "none"];
    public static readonly string[] Shells = ["ink", "color", "duo", "chrome"];
    public static readonly string[] Colors = ["ink", "mint", "teal", "sky", "lilac", "pink", "coral", "peach", "butter", "lime", "paper",
        "red", "grass", "forest", "cobalt", "denim", "grape", "plum", "magenta", "rose", "wine", "caramel", "cocoa", "slate"];
    public static readonly string[] ThemeColors = Colors[..11];
    /// The editor's order, six to a row (`SHAPE_COLORS`).
    public static readonly string[] ShapeColors = ["red", "coral", "peach", "butter", "lime", "grass", "mint", "teal", "sky", "cobalt",
        "lilac", "grape", "rose", "pink", "magenta", "plum", "denim", "forest", "wine", "cocoa", "caramel", "ink", "slate", "paper"];
    /// [face-colour] Colours out of the picker since 2026-11-17, each with the colour a head that has one is drawn in.
    public static readonly Dictionary<string, string> Retired = new() { ["butter"] = "peach", ["lime"] = "grass", ["rose"] = "pink", ["caramel"] = "cocoa" };
    /// A colour as offered: a retired one is its stand-in.
    public static string Offered(string colour) => Retired.TryGetValue(colour, out var s) ? s : colour;
    public static readonly string[] PickerShapeColors = [.. ShapeColors.Where(c => !Retired.ContainsKey(c))];
    public static readonly string[] PickerThemeColors = [.. ThemeColors.Where(c => !Retired.ContainsKey(c))];
    public static readonly string[] Antennas = ["none", "bulb", "twin", "bolt", "ring"];
    public static readonly string[] Ears = ["none", "headset", "bolts", "fins"];
    public static readonly string[] Mouths = ["none", "smile", "open", "cat", "grille"];
    public static readonly string[] Hairs = ["bob", "long", "twin", "pixie", "buns", "pony"];
    public static readonly string[] Patterns = ["face", "grid", "bloom", "ring", "spark", "wave"];
    public static readonly string[] Tiles = ["dark", "light", "color", "none"];
    public static readonly string[] Forms = ["round", "blob", "square", "pill", "triangle", "hex", "cloud", "drop", "star", "heart"];
    public static readonly string[] Looks = ["slits", "dots", "ovals", "googly", "happy", "sleepy", "stars", "hearts"];
    public static readonly string[] SpecsList = ["none", "shades", "aviators", "round", "monocle"];
    /// A dot-matrix head's outlines, in the `form` field.
    public static readonly string[] Outlines = [.. Enum.GetValues<MatrixSilhouette>().Select(HeadWire.Name)];
    public static readonly string[] Hats = ["none", "crown", "halo", "sprout", "party", "bow", "beanie"];
    public static readonly string[] Glyphs = ["✨", "🦊", "🧠", "🛰️", "🌵", "🐙", "⚡️", "🍋", "🪐", "🔧", "📚", "🎧", "🦉", "🧪", "🚀", "🎨", "🧭", "🫧"];

    // ICON_HEAD (`head.ts:97-100`) is the default value of every field.
    public string Theme { get; set; } = "robot";
    public string Color { get; set; } = "ink";
    public int Seed { get; set; } = 1;
    public string Shape { get; set; } = "dome";
    public string Face { get; set; } = "visor";
    public string Visor { get; set; } = "band";
    public string Shell { get; set; } = "ink";
    public string Antenna { get; set; } = "bulb";
    public string EarsKind { get; set; } = "headset";
    public string Mouth { get; set; } = "none";
    public bool Blush { get; set; }
    public string Hair { get; set; } = "bob";
    public string Pattern { get; set; } = "face";
    public string Tile { get; set; } = "dark";
    public bool Eyes { get; set; } = true;
    public string Glyph { get; set; } = "✨";
    public string Form { get; set; } = "round";
    public string Look { get; set; } = "slits";
    public string Specs { get; set; } = "none";
    public string Hat { get; set; } = "none";

    public static HeadRecord Icon => new();

    /// What a record prints as (its computed records would print forever).
    private bool PrintMembers(StringBuilder builder)
    {
        builder.Append(PictureKey);
        return true;
    }

    /// `Number(value)` as the web reads `v`: a number, or a string that reads as one.
    internal static double? Number(JsonNode? node) => node switch
    {
        JsonValue v when Numeric(v) is { } d => d,
        JsonValue v when v.TryGetValue(out string? s) && double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var d) => d,
        _ => null,
    };

    /// A JSON number as a double, whether it came off the wire or was built in memory (a JsonValue<int> won't
    /// TryGetValue as a double).
    internal static double? Numeric(JsonValue v) =>
        v.GetValueKind() == System.Text.Json.JsonValueKind.Number
            ? double.Parse(v.ToJsonString(), NumberStyles.Float, CultureInfo.InvariantCulture) : null;

    /// `Number.isInteger(seed) ? clamp(seed, 1, 2^31 - 1) : 1`.
    internal static int ParseSeed(JsonNode? node)
    {
        if (node is JsonValue v && Numeric(v) is { } n && double.IsFinite(n) && Math.Truncate(n) == n)
            return (int)Math.Min(Math.Max(n, 1), 2147483647);
        return 1;
    }

    // MARK: parseHead (`head.ts:122-160`)

    public static HeadRecord? Parse(JsonNode? raw)
    {
        if (raw is not JsonObject value) return null;
        string? Str(string key) => value[key] is JsonValue v && v.TryGetValue(out string? s) ? s : null;
        bool Known(string[] list, string key) => Str(key) is { } s && list.Contains(s);
        if (!Known(Themes, "theme") && !Known(Shapes, "shape") && !Known(Faces, "face")) return null;
        string Pick(string[] list, string key, string fallback) => Str(key) is { } s && list.Contains(s) ? s : fallback;
        bool IsBool(string key, bool b) => value[key] is JsonValue v && v.TryGetValue(out bool x) && x == b;
        var head = new HeadRecord
        {
            Seed = ParseSeed(value["seed"]),
            Theme = Pick(Themes, "theme", "robot"),
            Color = Pick(Colors, "color", "mint"),
            Shape = Pick(Shapes, "shape", "blob"),
            Face = Pick(Faces, "face", "pill"),
            Visor = Pick(Visors, "visor", "band"),
            Shell = Pick(Shells, "shell", "ink"),
            Antenna = Pick(Antennas, "antenna", "none"),
            EarsKind = Pick(Ears, "ears", IsBool("headset", true) ? "headset" : "none"),
            Mouth = Pick(Mouths, "mouth", "none"),
            Blush = IsBool("blush", true),
            Hair = Pick(Hairs, "hair", "bob"),
            Pattern = Pick(Patterns, "pattern", "face"),
            Tile = Pick(Tiles, "tile", "dark"),
            Eyes = !IsBool("eyes", false),
            Glyph = CleanGlyph(value["glyph"]),
            Look = Pick(Looks, "look", "slits"),
            Specs = Pick(SpecsList, "specs", "none"),
            Hat = Pick(Hats, "hat", "none"),
        };
        // A dot-matrix head's form is one of its outlines (a Shapes name saved by build 378 reads as the nearest one).
        head.Form = head.Theme == "matrix" ? HeadWire.Name(MatrixSilhouettes.FromStored(Str("form") ?? "round")) : Pick(Forms, "form", "round");
        var version = Number(value["v"]) ?? 0;
        if (head.Theme == "dots" && head.Pattern == "face" && !(version >= 4))
        {
            (string, string)[] seedFaces = [("pill", "smile"), ("happy", "smile"), ("surprised", "open"), ("wink", "smile"), ("sleepy", "grille"), ("pill", "cat")];
            var random = new SeededRandom(unchecked((uint)head.Seed));
            random.Next();
            var pick = seedFaces[(int)Math.Floor(random.Next() * seedFaces.Length)];
            head.Face = pick.Item1;
            head.Mouth = pick.Item2;
        }
        if (head.Theme == "shape" && !(version >= 5)) { head.Mouth = "none"; head.Blush = false; }
        if (head.Theme == "shape" && !(version >= 6)) head.Tile = "none";
        return head;
    }

    /// One emoji, or up to two letters (`cleanGlyph`).
    public static string CleanGlyph(JsonNode? raw) =>
        raw is JsonValue v && v.TryGetValue(out string? text) ? CleanGlyph(text) : Icon.Glyph;

    public static string CleanGlyph(string text)
    {
        var trimmed = text.Trim();
        var cut = trimmed.Length > 64 ? trimmed[..64] : trimmed;
        if (cut.Length > 0 && char.IsHighSurrogate(cut[^1])) cut = cut[..^1];
        var parts = TextElements(cut);
        if (parts.FirstOrDefault(IsEmoji) is { } emoji) return emoji;
        var letters = parts.Where(part =>
        {
            var runes = part.EnumerateRunes().ToList();
            return runes.Count == 1 && Rune.GetUnicodeCategory(runes[0]) is UnicodeCategory.UppercaseLetter
                or UnicodeCategory.LowercaseLetter or UnicodeCategory.TitlecaseLetter or UnicodeCategory.ModifierLetter
                or UnicodeCategory.OtherLetter or UnicodeCategory.DecimalDigitNumber or UnicodeCategory.LetterNumber
                or UnicodeCategory.OtherNumber;
        });
        var joined = string.Concat(letters.Take(2));
        return joined.Length == 0 ? Icon.Glyph : joined;
    }

    public static List<string> TextElements(string text)
    {
        var list = new List<string>();
        var e = StringInfo.GetTextElementEnumerator(text);
        while (e.MoveNext()) list.Add((string)e.Current);
        return list;
    }

    /// Whether a character holds an emoji code point (beyond ASCII): Swift's `Unicode.Scalar.Properties.isEmoji`,
    /// from the Emoji=Yes ranges of Unicode's emoji-data.
    public static bool IsEmoji(string part) => part.EnumerateRunes().Any(r => r.Value > 0x7F && IsEmojiScalar(r.Value));

    static bool IsEmojiScalar(int v) => v switch
    {
        0xA9 or 0xAE or 0x203C or 0x2049 or 0x2122 or 0x2139 or 0x2328 or 0x23CF or 0x24C2 or 0x25B6 or 0x25C0 or 0x2934 or 0x2935
            or 0x2B50 or 0x2B55 or 0x3030 or 0x303D or 0x3297 or 0x3299 => true,
        >= 0x2194 and <= 0x2199 => true,
        >= 0x21A9 and <= 0x21AA => true,
        >= 0x231A and <= 0x231B => true,
        >= 0x23E9 and <= 0x23F3 => true,
        >= 0x23F8 and <= 0x23FA => true,
        >= 0x25AA and <= 0x25AB => true,
        >= 0x25FB and <= 0x25FE => true,
        >= 0x2600 and <= 0x27BF => true,
        >= 0x2B05 and <= 0x2B07 => true,
        >= 0x2B1B and <= 0x2B1C => true,
        >= 0x1F000 and <= 0x1FAFF => true,
        _ => false,
    };

    /// `headKey` (`head.ts:167-181`): one string per distinct picture; fields a theme doesn't draw are left out.
    public string PictureKey
    {
        get
        {
            var b = Blush ? 1 : 0;
            return Theme switch
            {
                "robot" => $"robot|{Shape}|{Face}|{Visor}|{Shell}|{Color}|{Antenna}|{EarsKind}|{Mouth}|{b}|{(Shape is "blob" or "cloud" ? Seed : 0)}",
                "persona" => $"persona|{Hair}|{Face}|{Shell}|{Color}|{EarsKind}|{Mouth}|{b}|{Tile}",
                "dots" => Pattern == "face" ? $"dots|face|{Face}|{Mouth}|{b}|{Color}|{Tile}" : $"dots|{Pattern}|{Color}|{Tile}|{(Eyes ? 1 : 0)}|{Seed}",
                "orb" => $"orb|{Color}|{Tile}|{(Eyes ? 1 : 0)}|{Seed}",
                "pixel" => $"pixel|{Color}|{Tile}|{Seed}",
                "glyph" => $"glyph|{Glyph}|{Color}|{Tile}",
                "matrix" => $"matrix|{HeadWire.Name(MatrixSilhouettes.FromStored(Form))}|{Look}|{Mouth}|{b}|{Color}|{Facing}",
                _ => $"shape|{Form}|{Look}|{Specs}|{Hat}|{Mouth}|{b}|{Color}|{Tile}|{(Form == "blob" ? Seed : 0)}",
            };
        }
    }

    /// `storedHead(head)`: every field, `v: 6`, plus `headset` for builds from before Ears.
    public JsonObject Stored() => new()
    {
        ["v"] = Version, ["theme"] = Theme, ["color"] = Color, ["seed"] = Seed, ["shape"] = Shape, ["face"] = Face,
        ["visor"] = Visor, ["shell"] = Shell, ["antenna"] = Antenna, ["ears"] = EarsKind, ["mouth"] = Mouth, ["blush"] = Blush,
        ["hair"] = Hair, ["pattern"] = Pattern, ["tile"] = Tile, ["eyes"] = Eyes, ["glyph"] = Glyph, ["form"] = Form,
        ["look"] = Look, ["specs"] = Specs, ["hat"] = Hat, ["headset"] = EarsKind == "headset",
    };

    /// The record a save writes (spec §7.5–7.6): never a hat, and never Character (the owner removed it), which becomes a
    /// Shapes head. A dot-matrix head's is its outline, with no visor, antenna or ears.
    public HeadRecord ForSaving
    {
        get
        {
            var record = Theme == "persona" ? ThemedAsShape : this with { };
            record.Hat = "none";
            if (record.Theme == "matrix")
            {
                record.Form = HeadWire.Name(MatrixSilhouettes.FromStored(record.Form));
                record.Specs = "none";
                record.Antenna = "none";
                record.EarsKind = "none";
            }
            return record;
        }
    }

    /// The picture the native renderer draws for this record.
    public Head Head => Head.FromRecord(ForSaving) ?? Head.DefaultHead("default");

    /// `Head.Plain` for a record: a robot's own icon eyes, a Dots face's two tall lamp eyes, slits on a Shapes or
    /// dot-matrix head; no mouth, cheeks or glasses.
    public HeadRecord Plain => this with
    {
        Face = Theme == "dots" ? "pill" : "visor", Mouth = "none", Blush = false, Look = "slits", Specs = "none", Hat = "none",
    };

    /// Copies a native head's Shapes fields in (a strip pick).
    public void SetShapes(Head head)
    {
        Theme = "shape"; Color = HeadWire.Name(head.Color); Seed = head.Seed; Form = HeadWire.Name(head.Form);
        Look = HeadWire.Name(head.Look); Specs = HeadWire.Name(head.Specs); Mouth = HeadWire.Name(head.Mouth);
        Blush = head.Blush; Tile = HeadWire.Name(head.Tile); Hat = "none";
    }

    /// Copies a dot-matrix head's fields in.
    public void SetMatrix(Head head)
    {
        Theme = "matrix"; Color = HeadWire.Name(head.Color); Seed = head.Seed; Form = HeadWire.Name(head.Silhouette);
        Look = HeadWire.Name(head.Look); Specs = "none"; Mouth = HeadWire.Name(head.Mouth); Blush = head.Blush;
        Antenna = "none"; EarsKind = "none"; Tile = "none"; Hat = "none";
    }

    /// The record of the head a bot wears until it is given another: its plain Shapes head.
    public static HeadRecord DefaultRecord(string profile)
    {
        var record = new HeadRecord();
        record.SetShapes(Head.DefaultShapeHead(profile));
        return record;
    }

    public static HeadRecord DefaultMatrixRecord(string profile)
    {
        var record = new HeadRecord();
        record.SetMatrix(Head.DefaultMatrixHead(profile));
        return record;
    }

    /// Which way a dot-matrix head faces (bit 7 of its seed): −1 left, +1 right.
    public int Facing => MatrixHead.Facing(Seed);

    /// A saved head in another theme becomes a Shapes head with no board.
    public HeadRecord ThemedAsShape
    {
        get
        {
            var record = this with { };
            if (record.Theme != "shape") record.Tile = "none";
            if (record.Theme == "matrix") record.Form = MatrixSilhouettes.ShapesForm(MatrixSilhouettes.FromStored(record.Form));
            record.Theme = "shape";
            return record;
        }
    }

    // MARK: rollHead (`head.ts:207-242`)

    static T Any<T>(Func<double> random, IReadOnlyList<T> list) => list[(int)Math.Floor(random() * list.Count)];

    static string Weighted(Func<double> random, (string, double)[] list)
    {
        var left = random() * list.Sum(x => x.Item2);
        foreach (var (value, weight) in list)
        {
            left -= weight;
            if (left < 0) return value;
        }
        return list[0].Item1;
    }

    /// A fresh head in a theme, drawing `random()` in exactly the web's order (robot fields first).
    public static HeadRecord Roll(Func<double> random, string theme = "shape")
    {
        var persona = theme == "persona";
        var head = new HeadRecord { Theme = theme };
        head.Color = Offered(Any(random, theme == "shape" ? ShapeColors : ThemeColors));
        head.Seed = 1 + (int)Math.Floor(random() * 1e6);
        head.Shape = Any(random, OfferedShapes);
        head.Face = persona
            ? Weighted(random, [("visor", 5), ("happy", 2), ("content", 1.5), ("wink", 1.5), ("surprised", 1), ("side", 1), ("sleepy", 0.8),
                ("sparkle", 0.8), ("angry", 0.6), ("worried", 0.6), ("heart", 0.5)])
            : Weighted(random, [("visor", 3), ("pill", 3), ("dots", 2), ("happy", 2), ("content", 1.5), ("bars", 1.2), ("side", 1),
                ("wink", 1), ("angry", 0.8), ("worried", 0.8), ("surprised", 1), ("sleepy", 0.8), ("sparkle", 0.7),
                ("heart", 0.5), ("dizzy", 0.4), ("scanner", 0.8)]);
        head.Visor = Weighted(random, [("band", 5), ("goggles", 2), ("screen", 2), ("none", 1)]);
        head.Shell = persona ? Weighted(random, [("ink", 4), ("color", 4), ("chrome", 1.5), ("duo", 2)])
            : Weighted(random, [("ink", 5), ("color", 2), ("duo", 1.5), ("chrome", 1)]);
        head.Antenna = Weighted(random, [("bulb", 4), ("none", 2.5), ("twin", 1.5), ("bolt", 1), ("ring", 1)]);
        head.EarsKind = Weighted(random, [("none", 4), ("headset", 3), ("bolts", 1.5), ("fins", 1.5)]);
        head.Mouth = persona ? Weighted(random, [("smile", 4), ("none", 2), ("cat", 1.5), ("open", 1)])
            : Weighted(random, [("none", 7), ("smile", 1.5), ("grille", 1), ("open", 0.5), ("cat", 0.5)]);
        head.Blush = random() < (persona ? 0.5 : 0.15);
        head.Hair = Any(random, Hairs);
        head.Pattern = Any(random, Patterns);
        head.Tile = Weighted(random, [("dark", 3), ("light", 2), ("color", 2)]);
        head.Eyes = random() < 0.5;
        head.Glyph = Any(random, Glyphs);
        head.Form = Any(random, Forms);
        head.Look = Weighted(random, [("slits", 6), ("dots", 2), ("ovals", 2)]);
        head.Specs = "none";
        head.Hat = "none";
        if (theme == "shape")
        {
            head.Tile = Weighted(random, [("none", 8), ("dark", 1.5), ("color", 1), ("light", 0.5)]);
            head.Look = Weighted(random, [("slits", 5), ("dots", 1.5), ("ovals", 1.5), ("googly", 1.5), ("happy", 1), ("sleepy", 0.7),
                ("stars", 0.6), ("hearts", 0.6)]);
            head.Specs = Weighted(random, [("none", 6), ("shades", 1.5), ("aviators", 0.7), ("round", 0.9), ("monocle", 0.5)]);
            Weighted(random, [("none", 5), ("crown", 1), ("halo", 0.8), ("sprout", 1), ("party", 0.8), ("bow", 0.8), ("beanie", 0.8)]);
            head.Hat = "none";
            head.Mouth = Weighted(random, [("none", 5), ("smile", 2.5), ("open", 0.7), ("cat", 0.7), ("grille", 0.5)]);
            head.Blush = random() < 0.25;
        }
        if (theme == "dots")
        {
            if (random() < 0.45) head.Pattern = "face";
            head.Mouth = Weighted(random, [("smile", 4), ("none", 2), ("cat", 1), ("open", 1), ("grille", 1)]);
            head.Blush = random() < 0.2;
        }
        if (theme == "matrix")
        {
            head.Color = Offered(Any(random, ShapeColors.Where(c => c != "slate" && c != "paper").ToArray()));
            head.Tile = "none";
            head.Form = Any(random, Outlines);
            head.Look = Weighted(random, [("slits", 5), ("ovals", 2), ("dots", 2), ("happy", 1), ("googly", 1), ("sleepy", 0.7),
                ("stars", 0.6), ("hearts", 0.6)]);
            head.Specs = "none";
            head.Antenna = "none";
            head.EarsKind = "none";
            Weighted(random, [("none", 6), ("smile", 2), ("open", 0.6), ("cat", 0.6), ("grille", 0.6)]);
            head.Mouth = "none";
            head.Blush = random() < 0.15;
        }
        return head;
    }

    /// `ideasFor(theme, about, random, count)`: fresh heads; the first half take what the bot is about.
    public static List<HeadRecord> Ideas(string theme, string about, Func<double> random, int count = 10)
    {
        var topic = HeadTopics.Topic(about);
        var half = (int)Math.Ceiling(count / 2.0);
        var list = new List<HeadRecord>();
        for (var index = 0; index < count; index++)
        {
            var head = Roll(random, theme);
            if (topic != null && index < half)
            {
                var tile = head.Tile;
                head.Apply(topic);
                head.Theme = theme;
                if (theme is "shape" or "matrix") head.Tile = tile;
                if (theme == "matrix") head.ApplyMatrix(topic, outline: index == 0);
            }
            list.Add(head);
        }
        return list;
    }

    /// The editor's seeded ideas for a bot: `seededRandom(nameHash("<profile>|<theme>|<round>"))`.
    public static List<HeadRecord> Ideas(string profile, string about, int round, string theme = "shape")
    {
        var random = new SeededRandom(Head.NameHash($"{profile}|{theme}|{round}"));
        return Ideas(theme, about, () => random.Next());
    }

    public void Apply(IReadOnlyDictionary<string, string> parts)
    {
        foreach (var (key, value) in parts)
        {
            switch (key)
            {
                case "glyph": Glyph = value; break;
                case "color": Color = value; break;
                case "face": Face = value; break;
                case "pattern": Pattern = value; break;
                case "visor": Visor = value; break;
                case "hair": Hair = value; break;
                case "ears": EarsKind = value; break;
                case "mouth": Mouth = value; break;
                case "shape": Shape = value; break;
                case "antenna": Antenna = value; break;
                case "tile": Tile = value; break;
            }
        }
    }

    /// A topic's robot words as a dot-matrix head's parts.
    public void ApplyMatrix(IReadOnlyDictionary<string, string> topic, bool outline)
    {
        var outlines = new Dictionary<string, string>
        {
            ["🛡️"] = "shield", ["🌵"] = "leaf", ["⛅️"] = "cloud", ["🌙"] = "cloud", ["🪐"] = "round", ["🧭"] = "round", ["💻"] = "square",
            ["📊"] = "square", ["📅"] = "square", ["✉️"] = "wide", ["🕹️"] = "wide", ["🏡"] = "arch", ["🚀"] = "drop", ["🍳"] = "pebble",
            ["🛠️"] = "hex",
        };
        if (outline && topic.TryGetValue("glyph", out var glyph) && outlines.TryGetValue(glyph, out var form)) Form = form;
        Antenna = "none";
        EarsKind = "none";
        Mouth = "none";
        var looks = new Dictionary<string, string>
        { ["happy"] = "happy", ["sleepy"] = "sleepy", ["heart"] = "hearts", ["sparkle"] = "stars", ["dots"] = "dots", ["surprised"] = "ovals" };
        if (topic.TryGetValue("face", out var face) && looks.TryGetValue(face, out var look)) Look = look;
    }

    /// My Style applied to this bot: the style's look, this bot's colour, seed and glyph.
    public HeadRecord ApplyingStyle(HeadRecord style) =>
        (style with { Color = Color, Seed = Seed, Glyph = Glyph, Hat = "none" }).ForSaving;

    /// Lays described parts over this head (Describe it): booleans as "true", hats never.
    public void ApplyDescribed(IReadOnlyDictionary<string, string> parts)
    {
        foreach (var (key, value) in parts)
        {
            switch (key)
            {
                case "theme": Theme = value; break;
                case "form": Form = value; break;
                case "look": Look = value; break;
                case "specs": Specs = value; break;
                case "shell": Shell = value; break;
                case "blush": Blush = value == "true"; break;
                case "eyes": Eyes = value == "true"; break;
                default: Apply(new Dictionary<string, string> { [key] = value }); break;
            }
        }
        Hat = "none";
        if (Theme == "matrix")
            Form = parts.TryGetValue("outline", out var o) ? o : HeadWire.Name(MatrixSilhouettes.FromStored(Form));
        else if (Theme == "shape" && !Forms.Contains(Form))
            Form = MatrixSilhouettes.ShapesForm(MatrixSilhouettes.FromStored(Form));
    }

    // MARK: The desktop copy (`mirror.ts`)

    public const int MirrorSize = 288;

    /// Whether an avatar data URL is this app's own copy of a head: a PNG whose IHDR says exactly 288 × 288.
    public static bool IsHeadMirror(string? dataUrl)
    {
        const string prefix = "data:image/png;base64,";
        if (dataUrl is null || !dataUrl.StartsWith(prefix, StringComparison.Ordinal)) return false;
        var head = dataUrl.Substring(prefix.Length, Math.Min(32, dataUrl.Length - prefix.Length));
        byte[] bytes;
        try { bytes = Convert.FromBase64String(head); } catch (FormatException) { return false; }
        if (bytes.Length < 24) return false;
        uint Int(int at) => (uint)(bytes[at] << 24 | bytes[at + 1] << 16 | bytes[at + 2] << 8 | bytes[at + 3]);
        return Int(16) == MirrorSize && Int(20) == MirrorSize;
    }

    /// A copy desktop should draw inverted on a dark page carries this PNG text chunk straight after the 33-byte header.
    public const string DarkFlipMark = "AAAAGHRFWHRoZXJtZXMtaHEAaW52ZXJ0LW9uLWRhcmu4VO/y";

    /// `png` with `DarkFlipMark` after its header; unchanged when it isn't a PNG.
    public static byte[] WithDarkFlipMark(byte[] png)
    {
        byte[] sig = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
        if (png.Length <= 33 || !png.AsSpan(0, 8).SequenceEqual(sig)) return png;
        var chunk = Convert.FromBase64String(DarkFlipMark);
        return [.. png.AsSpan(0, 33), .. chunk, .. png.AsSpan(33)];
    }
}

/// What a bot is about, from its name and description (`S/ui-heads/topics.ts`): the parts that suit it.
public static class HeadTopics
{
    static Regex R(string p) => new(p, RegexOptions.CultureInvariant);

    public static readonly (Regex Pattern, Dictionary<string, string> Parts)[] Entries =
    [
        (R(@"\b(deploy\w*|ship\w*|release\w*|launch\w*|ci|cd|build\w*|pipeline)\b"), new() { ["glyph"] = "🚀", ["color"] = "coral", ["face"] = "scanner", ["pattern"] = "ring" }),
        (R(@"\b(mail|inbox|email\w*|letter\w*|repl(y|ies))\b"), new() { ["glyph"] = "✉️", ["color"] = "sky", ["face"] = "content", ["pattern"] = "wave" }),
        (R(@"\b(research\w*|paper\w*|stud(y|ies)|scholar\w*|read\w*|librar\w*|book\w*)\b"), new() { ["glyph"] = "📚", ["color"] = "lilac", ["visor"] = "goggles", ["face"] = "pill", ["hair"] = "long" }),
        (R(@"\b(code\w*|coding|dev\w*|engineer\w*|program\w*|bug\w*|debug\w*|review\w*|repo\w*)\b"), new() { ["glyph"] = "💻", ["color"] = "teal", ["visor"] = "screen", ["face"] = "bars", ["pattern"] = "grid" }),
        (R(@"\b(writ\w*|draft\w*|blog\w*|editor\w*|copy|muse|idea\w*|stor(y|ies)|poet\w*)\b"), new() { ["glyph"] = "✍️", ["color"] = "pink", ["face"] = "sparkle", ["pattern"] = "bloom" }),
        (R(@"\b(ops|server\w*|infra\w*|sysadmin|devops|home\s?lab|network\w*|monitor\w*|uptime)\b"), new() { ["glyph"] = "🛠️", ["color"] = "peach", ["ears"] = "bolts", ["face"] = "bars", ["pattern"] = "grid" }),
        (R(@"\b(garden\w*|plant\w*|water\w*|farm\w*|green\w*|grow\w*)\b"), new() { ["glyph"] = "🌵", ["color"] = "grass", ["face"] = "happy", ["pattern"] = "bloom" }),
        (R(@"\b(money|financ\w*|budget\w*|ledger|account\w*|invoice\w*|tax\w*|bank\w*|trad\w*)\b"), new() { ["glyph"] = "💰", ["color"] = "peach", ["visor"] = "goggles", ["face"] = "side" }),
        (R(@"\b(music|song\w*|playlist\w*|audio|podcast\w*|dj)\b"), new() { ["glyph"] = "🎧", ["color"] = "lilac", ["ears"] = "headset", ["face"] = "content", ["pattern"] = "wave" }),
        (R(@"\b(calendar|schedul\w*|meeting\w*|plan\w*|agenda|remind\w*|todo\w*|task\w*)\b"), new() { ["glyph"] = "📅", ["color"] = "peach", ["face"] = "pill", ["pattern"] = "ring" }),
        (R(@"\b(news|headline\w*|press|brief\w*|digest)\b"), new() { ["glyph"] = "📰", ["color"] = "paper", ["visor"] = "goggles", ["face"] = "side" }),
        (R(@"\b(travel\w*|trip\w*|flight\w*|map\w*|route\w*|navigat\w*)\b"), new() { ["glyph"] = "🧭", ["color"] = "sky", ["face"] = "surprised", ["pattern"] = "spark" }),
        (R(@"\b(health|fitness|workout\w*|running|gym|diet)\b"), new() { ["glyph"] = "💪", ["color"] = "mint", ["face"] = "happy" }),
        (R(@"\b(cook\w*|food|recipe\w*|kitchen|meal\w*|chef)\b"), new() { ["glyph"] = "🍳", ["color"] = "peach", ["face"] = "happy", ["mouth"] = "smile" }),
        (R(@"\b(night\w*|dream\w*|moon|late)\b"), new() { ["glyph"] = "🌙", ["color"] = "lilac", ["face"] = "sleepy", ["tile"] = "dark" }),
        (R(@"\b(secur\w*|guard\w*|watch\w*|audit\w*|sentinel|firewall)\b"), new() { ["glyph"] = "🛡️", ["color"] = "ink", ["face"] = "angry", ["shape"] = "shield", ["visor"] = "band" }),
        (R(@"\b(data|analy\w*|report\w*|metric\w*|chart\w*|stat\w*|sql)\b"), new() { ["glyph"] = "📊", ["color"] = "teal", ["visor"] = "screen", ["face"] = "dots", ["pattern"] = "grid" }),
        (R(@"\b(support|help\w*|chat\w*|customer\w*|concierge|assist\w*)\b"), new() { ["glyph"] = "💬", ["color"] = "mint", ["ears"] = "headset", ["face"] = "happy", ["mouth"] = "smile", ["pattern"] = "face" }),
        (R(@"\b(shop\w*|order\w*|store|cart|deliver\w*|grocer\w*)\b"), new() { ["glyph"] = "🛒", ["color"] = "coral", ["face"] = "pill" }),
        (R(@"\b(photo\w*|image\w*|design\w*|art|draw\w*|paint\w*|creativ\w*)\b"), new() { ["glyph"] = "🎨", ["color"] = "pink", ["face"] = "sparkle", ["pattern"] = "bloom", ["hair"] = "buns" }),
        (R(@"\b(scien\w*|lab|experiment\w*|chem\w*|physic\w*|math\w*)\b"), new() { ["glyph"] = "🧪", ["color"] = "lime", ["visor"] = "goggles", ["face"] = "surprised" }),
        (R(@"\b(space|astro\w*|orbit\w*|star\w*|planet\w*|satellite)\b"), new() { ["glyph"] = "🪐", ["color"] = "lilac", ["antenna"] = "ring", ["face"] = "sparkle", ["pattern"] = "spark", ["tile"] = "dark" }),
        (R(@"\b(scout\w*|search\w*|find\w*|explor\w*|hunt\w*|crawl\w*)\b"), new() { ["glyph"] = "🔭", ["color"] = "teal", ["visor"] = "goggles", ["antenna"] = "twin", ["face"] = "side" }),
        (R(@"\b(game\w*|play\w*|arcade|retro)\b"), new() { ["glyph"] = "🕹️", ["color"] = "pink", ["face"] = "happy", ["visor"] = "screen" }),
        (R(@"\b(home|house|family|kid\w*|chore\w*)\b"), new() { ["glyph"] = "🏡", ["color"] = "peach", ["face"] = "happy" }),
        (R(@"\b(weather|rain\w*|storm\w*|forecast\w*)\b"), new() { ["glyph"] = "⛅️", ["color"] = "sky", ["antenna"] = "bolt", ["face"] = "content" }),
        (R(@"\b(learn\w*|teach\w*|tutor\w*|school|class\w*|language\w*)\b"), new() { ["glyph"] = "🎓", ["color"] = "butter", ["visor"] = "goggles", ["face"] = "pill", ["hair"] = "pony" }),
    ];

    static readonly Regex Apostrophes = new("[’']");
    static readonly Regex NonWords = new(@"[^\p{L}\p{N}\s.-]+");

    /// `plain`: lower case, apostrophes gone, anything but letters, digits, spaces, "." and "-" as a space.
    public static string Plain(string text) => NonWords.Replace(Apostrophes.Replace(text.ToLowerInvariant(), ""), " ");

    public static Dictionary<string, string>? Topic(string about)
    {
        var text = Plain(about);
        return Entries.FirstOrDefault(e => e.Pattern.IsMatch(text)).Parts;
    }
}

/// The names the editor shows (`S/ui-heads/labels.ts`).
public static class HeadLabels
{
    public static readonly Dictionary<string, string> Forms = new()
    {
        ["round"] = "Round", ["blob"] = "Blob", ["square"] = "Square", ["pill"] = "Pill", ["triangle"] = "Triangle",
        ["hex"] = "Hex", ["cloud"] = "Cloud", ["drop"] = "Drop", ["star"] = "Star", ["heart"] = "Heart",
    };
    public static readonly Dictionary<string, string> Colors = new()
    {
        ["ink"] = "Ink", ["mint"] = "Mint", ["teal"] = "Teal", ["sky"] = "Sky", ["lilac"] = "Lilac", ["pink"] = "Bubblegum", ["coral"] = "Coral",
        ["peach"] = "Orange", ["butter"] = "Orange", ["lime"] = "Grass", ["paper"] = "Paper", ["red"] = "Red", ["grass"] = "Grass", ["forest"] = "Forest",
        ["cobalt"] = "Cobalt", ["denim"] = "Denim", ["grape"] = "Grape", ["plum"] = "Plum", ["magenta"] = "Magenta", ["rose"] = "Bubblegum", ["wine"] = "Wine",
        ["caramel"] = "Cocoa", ["cocoa"] = "Cocoa", ["slate"] = "Slate",
    };
    public static readonly Dictionary<string, string> Tiles = new() { ["dark"] = "Dark", ["light"] = "Light", ["color"] = "Color", ["none"] = "None" };
    public static readonly Dictionary<string, string> Outlines = new()
    {
        ["round"] = "Round", ["square"] = "Square", ["tall"] = "Tall", ["wide"] = "Wide", ["pebble"] = "Pebble", ["cloud"] = "Cloud",
        ["arch"] = "Arch", ["shield"] = "Shield", ["drop"] = "Drop", ["leaf"] = "Leaf", ["hex"] = "Hex", ["octagon"] = "Octagon", ["heart"] = "Heart",
    };
    public static readonly Dictionary<string, string> Themes = new()
    {
        ["robot"] = "Robot", ["persona"] = "Character", ["dots"] = "Dots", ["orb"] = "Orb", ["pixel"] = "Pixel", ["glyph"] = "Emoji",
        ["shape"] = "Shapes", ["matrix"] = "Matrix",
    };
    /// The themes the editor offers, in its order (Character was removed by the owner; Shapes leads).
    public static readonly string[] OfferedThemes = ["shape", "matrix", "robot", "dots", "orb", "pixel", "glyph"];
    public static readonly Dictionary<string, string> Shapes = new()
    {
        ["dome"] = "Hermes HQ", ["blob"] = "Round", ["puff"] = "Block", ["pebble"] = "Wide", ["shield"] = "Bucket", ["diamond"] = "Hex",
        ["cat"] = "Cat", ["ghost"] = "Ghost", ["cloud"] = "Cloud", ["heart"] = "Heart", ["star"] = "Star", ["drop"] = "Drop",
    };
    public static readonly Dictionary<string, string> Visors = new() { ["band"] = "Visor", ["goggles"] = "Goggles", ["screen"] = "Screen", ["none"] = "None" };
    public static readonly Dictionary<string, string> Shells = new() { ["ink"] = "Ink", ["color"] = "Color", ["duo"] = "Two-Tone", ["chrome"] = "Chrome" };
    public static readonly Dictionary<string, string> Antennas = new() { ["none"] = "None", ["bulb"] = "Bulb", ["twin"] = "Twin", ["bolt"] = "Bolt", ["ring"] = "Halo" };
    public static readonly Dictionary<string, string> Ears = new() { ["none"] = "None", ["headset"] = "Headset", ["bolts"] = "Bolts", ["fins"] = "Fins" };
    public static readonly Dictionary<string, string> Patterns = new()
    { ["face"] = "Face", ["grid"] = "Ripple", ["bloom"] = "Bloom", ["ring"] = "Ring", ["spark"] = "Spark", ["wave"] = "Voice" };

    public static string Name(Dictionary<string, string> names, string key) => names.TryGetValue(key, out var s) ? s : key;

    /// A head in a few words for Narrator ("Robot, Teal, Cat"): its theme, its colour and the theme's main part.
    public static string Summary(HeadRecord head)
    {
        string? part = head.Theme switch
        {
            "robot" => Shapes.GetValueOrDefault(head.Shape),
            "dots" => Patterns.GetValueOrDefault(head.Pattern),
            "glyph" => head.Glyph,
            "shape" => Forms.GetValueOrDefault(head.Form),
            "matrix" => Outlines.GetValueOrDefault(head.Form),
            _ => null,
        };
        var words = new List<string> { Name(Themes, head.Theme), Name(Colors, head.Color) };
        if (part != null) words.Add(part);
        return string.Join(", ", words);
    }

    /// What Narrator reads for the editor's stage ("Cobalt Hex").
    public static string Describe(HeadRecord head)
    {
        var colour = Name(Colors, head.Color);
        return head.Theme switch
        {
            "robot" => $"{colour} {Name(Shapes, head.Shape)} robot",
            "dots" => head.Pattern == "face" ? $"{colour} dots face" : $"{colour} dots, {Name(Patterns, head.Pattern)}",
            "orb" => $"{colour} orb",
            "pixel" => $"{colour} pixel creature",
            "glyph" => $"{head.Glyph} on {Name(Tiles, head.Tile)}",
            "matrix" => $"{colour} {Name(Outlines, head.Form)} dot-matrix head",
            _ => $"{colour} {Name(Forms, head.Form)}",
        };
    }
}
