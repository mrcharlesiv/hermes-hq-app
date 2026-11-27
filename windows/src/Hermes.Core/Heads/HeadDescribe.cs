using System.Text.RegularExpressions;

namespace Hermes.Core.Heads;

/// "Describe it" (`S/ui-heads/describe.ts`, App/Heads/HeadDescribe.swift): a few typed words turned into head parts,
/// entirely on this computer. It reads the words it knows and ignores the rest.
public static class HeadDescribe
{
    /// What the words asked for, and the words understood as people would say them ("Got it: …").
    public sealed record Described(Dictionary<string, string> Parts, List<string> Understood);

    public static readonly string[] TopicNames = ["shipping", "mail", "reading", "code", "writing", "ops", "plants", "money", "music",
        "planning", "news", "travel", "health", "food", "night", "security", "data", "support", "shopping", "art", "science", "space",
        "scouting", "games", "home", "weather", "learning"];

    static (Regex, Dictionary<string, string>, string) W(string pattern, Dictionary<string, string> parts, string name) =>
        (new Regex(pattern, RegexOptions.CultureInvariant), parts, name);

    /// The words a description can use. Order matters where one phrase contains another.
    public static readonly (Regex Pattern, Dictionary<string, string> Parts, string Name)[] Words =
    [
        W(@"\b(robot\w*|bot|android|mech\w*)\b", new() { ["theme"] = "robot" }, "robot"),
        W(@"\b(dots?|lamps?)\b", new() { ["theme"] = "dots" }, "dots"),
        W(@"\b(matrix|leds?)\b", new() { ["theme"] = "matrix" }, "matrix"),
        W(@"\b(orb|ball|sphere|bubble|glass|marble|aura)\b", new() { ["theme"] = "orb" }, "orb"),
        W(@"\b(pixel\w*|8.?bit|sprite|creature|monster|alien|invader|critter)\b", new() { ["theme"] = "pixel" }, "pixel"),
        W(@"\b(emoji|letters?|initials?|monogram)\b", new() { ["theme"] = "glyph" }, "emoji"),
        W(@"\b(shapes?|grok|geometric)\b", new() { ["theme"] = "shape" }, "shapes"),
        W(@"\b(purple|violet|lilac|lavender)\b", new() { ["color"] = "lilac" }, "purple"),
        W(@"\b(blue|sky|azure|navy)\b", new() { ["color"] = "sky" }, "blue"),
        W(@"\b(teal|cyan|aqua|turquoise)\b", new() { ["color"] = "teal" }, "teal"),
        W(@"\b(mint|seafoam)\b", new() { ["color"] = "mint" }, "mint"),
        W(@"\b(green|lime)\b", new() { ["color"] = "grass" }, "green"),
        W(@"\b(red|coral|crimson|scarlet)\b", new() { ["color"] = "coral" }, "red"),
        W(@"\b(orange|peach|amber|yellow|gold\w*|butter)\b", new() { ["color"] = "peach" }, "orange"),
        W(@"\b(pink|rose|magenta|bubblegum)\b", new() { ["color"] = "pink" }, "pink"),
        W(@"\b(white|cream|paper|beige|ivory)\b", new() { ["color"] = "paper" }, "white"),
        W(@"\b(black|ink|noir)\b", new() { ["color"] = "ink" }, "black"),
        W(@"\b(cat|kitty|kitten|feline)\b", new() { ["shape"] = "cat", ["mouth"] = "cat" }, "cat"),
        W(@"\b(triangle\w*|pyramid)\b", new() { ["form"] = "triangle" }, "triangle"),
        W(@"\b(cloud\w*|fluffy)\b", new() { ["form"] = "cloud" }, "cloud"),
        W(@"\b(drop\w*|droplet|tear\w*)\b", new() { ["form"] = "drop" }, "drop"),
        W(@"\b(blob\w*|bean)\b", new() { ["form"] = "blob" }, "blob"),
        W(@"\b(pill|capsule)\b", new() { ["form"] = "pill", ["shape"] = "pebble" }, "pill"),
        W(@"\b(ghost|spooky|phantom)\b", new() { ["shape"] = "ghost", ["outline"] = "arch" }, "ghost"),
        W(@"\b(round|ball.?head|circle)\b", new() { ["shape"] = "blob", ["form"] = "round" }, "round"),
        W(@"\b(square|block\w*|boxy|box|tv)\b", new() { ["shape"] = "puff", ["form"] = "square" }, "block"),
        W(@"\b(wide|flat)\b", new() { ["shape"] = "pebble", ["outline"] = "wide" }, "wide"),
        W(@"\b(bucket)\b", new() { ["shape"] = "shield" }, "bucket"),
        W(@"\b(hex\w*|gem)\b", new() { ["shape"] = "diamond", ["form"] = "hex" }, "hex"),
        W(@"\b(dispatch|hermes|classic|original|logo)\b", new() { ["shape"] = "dome", ["face"] = "visor", ["visor"] = "band" }, "Hermes HQ"),
        W(@"\b(lanky|tall head|long face)\b", new() { ["outline"] = "tall" }, "tall"),
        W(@"\b(pebble|stone|egg)\b", new() { ["outline"] = "pebble" }, "pebble"),
        W(@"\b(arch|arched|tombstone)\b", new() { ["outline"] = "arch" }, "arch"),
        W(@"\b(shield|badge|crest)\b", new() { ["outline"] = "shield" }, "shield"),
        W(@"\b(leaf|leafy|petal)\b", new() { ["outline"] = "leaf" }, "leaf"),
        W(@"\b(octagon\w*|stop.?sign)\b", new() { ["outline"] = "octagon" }, "octagon"),
        W(@"\b(sleepy|tired|drowsy|asleep)\b", new() { ["face"] = "sleepy", ["look"] = "sleepy" }, "sleepy"),
        W(@"\b(happy|cheerful|joy\w*|smiling|glad)\b", new() { ["face"] = "happy", ["look"] = "happy" }, "happy"),
        W(@"\b(calm|content|peaceful|chill|relaxed)\b", new() { ["face"] = "content" }, "calm"),
        W(@"\b(grumpy|angry|mad|fierce|stern|serious)\b", new() { ["face"] = "angry" }, "grumpy"),
        W(@"\b(worried|anxious|nervous|sad)\b", new() { ["face"] = "worried" }, "worried"),
        W(@"\b(wink\w*|cheeky|playful)\b", new() { ["face"] = "wink" }, "winking"),
        W(@"\b(love|loving|smitten|hearts?)\b", new() { ["face"] = "heart", ["form"] = "heart", ["look"] = "hearts" }, "smitten"),
        W(@"\b(sparkl\w*|starry|magic\w*|excited)\b", new() { ["face"] = "sparkle", ["look"] = "stars" }, "sparkly"),
        W(@"\b(dizzy|confused|broken)\b", new() { ["face"] = "dizzy" }, "dizzy"),
        W(@"\b(deadpan|bored|blank|neutral)\b", new() { ["face"] = "bars" }, "deadpan"),
        W(@"\b(surprised|shocked|wide.?eyed|curious)\b", new() { ["face"] = "surprised" }, "wide-eyed"),
        W(@"\b(side.?eye|suspicious|skeptical|sly)\b", new() { ["face"] = "side" }, "side-eye"),
        W(@"\b(scanner|cylon|laser)\b", new() { ["face"] = "scanner", ["visor"] = "band" }, "scanner"),
        W(@"\b(sun ?glasses|shades|cool)\b", new() { ["specs"] = "shades" }, "sunglasses"),
        W(@"\b(aviators?|pilot)\b", new() { ["specs"] = "aviators" }, "aviators"),
        W(@"\b(monocle|fancy|posh)\b", new() { ["specs"] = "monocle" }, "monocle"),
        W(@"\b(goggles|glasses|spectacles|nerd\w*)\b", new() { ["visor"] = "goggles", ["specs"] = "round" }, "goggles"),
        W(@"\b(screen|monitor|display)\b", new() { ["visor"] = "screen" }, "screen"),
        W(@"\b(no visor|bare)\b", new() { ["visor"] = "none" }, "no visor"),
        W(@"\b(visor)\b", new() { ["visor"] = "band" }, "visor"),
        W(@"\b(chrome|metal\w*|silver|steel)\b", new() { ["shell"] = "chrome" }, "chrome"),
        W(@"\b(two.?tone|duo)\b", new() { ["shell"] = "duo" }, "two-tone"),
        W(@"\b(colou?red|colou?rful|bright|painted)\b", new() { ["shell"] = "color" }, "colored"),
        W(@"\b(twin antenna\w*|two antenna\w*|antennae)\b", new() { ["antenna"] = "twin" }, "twin antennae"),
        W(@"\b(bolt|lightning|electric)\b", new() { ["antenna"] = "bolt" }, "bolt"),
        W(@"\b(halo|angel\w*)\b", new() { ["antenna"] = "ring" }, "halo"),
        W(@"\b(googly|silly|goofy)\b", new() { ["look"] = "googly" }, "googly eyes"),
        W(@"\b(antenna)\b", new() { ["antenna"] = "bulb" }, "antenna"),
        W(@"\b(headset|headphones?|earphones?)\b", new() { ["ears"] = "headset" }, "headset"),
        W(@"\b(bolts|screws)\b", new() { ["ears"] = "bolts" }, "bolts"),
        W(@"\b(fins?|wings?)\b", new() { ["ears"] = "fins" }, "fins"),
        W(@"\b(blush\w*|shy|rosy|cute)\b", new() { ["blush"] = "true" }, "blush"),
        W(@"\b(smile|smiley)\b", new() { ["mouth"] = "smile" }, "smile"),
        W(@"\b(grille|speaker|vent)\b", new() { ["mouth"] = "grille" }, "grille"),
        W(@"\b(wave\w*|voice|sound|equali[sz]er)\b", new() { ["pattern"] = "wave" }, "voice wave"),
        W(@"\b(ring|loader|circle of)\b", new() { ["pattern"] = "ring" }, "ring"),
        W(@"\b(bloom|flower|sun)\b", new() { ["pattern"] = "bloom" }, "bloom"),
        W(@"\b(ripple|grid)\b", new() { ["pattern"] = "grid" }, "ripple"),
        W(@"\b(spark|star)\b", new() { ["pattern"] = "spark", ["form"] = "star" }, "spark"),
        W(@"\b(slits?|slanted)\b", new() { ["look"] = "slits" }, "slit eyes"),
        W(@"\b(ovals?|tall eyes)\b", new() { ["look"] = "ovals" }, "oval eyes"),
        W(@"\b(dark|night|midnight)\b", new() { ["tile"] = "dark" }, "dark"),
        W(@"\b(light|daylight)\b", new() { ["tile"] = "light" }, "light"),
        W(@"\b(transparent|floating|no (?:background|backdrop|board|tile))\b", new() { ["tile"] = "none" }, "no backdrop"),
        W(@"\b(eyes|face)\b", new() { ["eyes"] = "true", ["pattern"] = "face" }, "eyes"),
    ];

    static readonly Regex Board = new(@"\b(dark|night|midnight|light|daylight)\b");

    /// The first emoji in the text (with its variation selector or joined parts), if any.
    public static string? FirstEmoji(string text) => HeadRecord.TextElements(text).FirstOrDefault(HeadRecord.IsEmoji);

    /// Reads a description: an emoji makes an Emoji head; a subject ("deploys", "garden") brings its parts; named parts
    /// win over a subject's. Nothing understood gives no parts.
    public static Described Describe(string text)
    {
        var plain = HeadTopics.Plain(text);
        var parts = new Dictionary<string, string>();
        var understood = new List<string>();
        var index = Array.FindIndex(HeadTopics.Entries, e => e.Pattern.IsMatch(plain));
        if (index >= 0)
        {
            foreach (var (k, v) in HeadTopics.Entries[index].Parts) parts[k] = v;
            understood.Add(TopicNames[index]);
        }
        var themed = false;
        foreach (var (pattern, word, name) in Words)
        {
            if (!pattern.IsMatch(plain)) continue;
            foreach (var (k, v) in word) parts[k] = v;
            understood.Add(name);
            if (word.ContainsKey("theme")) themed = true;
        }
        if (FirstEmoji(text) is { } emoji)
        {
            parts["glyph"] = emoji;
            parts["theme"] = "glyph";
            understood.Insert(0, emoji);
        }
        else if (!themed)
        {
            parts.Remove("theme");
        }
        if ((parts.ContainsKey("face") || parts.ContainsKey("mouth")) && !parts.ContainsKey("pattern")) parts["pattern"] = "face";
        if (!parts.ContainsKey("theme") && (parts.GetValueOrDefault("look") == "googly" || parts.GetValueOrDefault("tile") == "none"
            || parts.GetValueOrDefault("specs") is "shades" or "aviators" or "monocle"))
            parts["theme"] = "shape";
        if (parts.GetValueOrDefault("theme") == "shape" && !Board.IsMatch(plain)) parts["tile"] = "none";
        var seen = new HashSet<string>();
        return new Described(parts, [.. understood.Where(seen.Add)]);
    }
}
