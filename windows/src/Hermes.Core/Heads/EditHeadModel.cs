using System.Text.Json.Nodes;
using Hermes.Core.Model;

namespace Hermes.Core.Heads;

/// Edit Head's state (App/Heads/EditHeadView.swift `EditHeadModel`; spec 1x-settings §7): the draft head with Shuffle
/// and Undo, Describe it, the themes, ten ideas for this bot, the theme's parts, colours, extras, My Style, and the
/// compare-and-swap save. Never hats; Character is not offered (owner). Pure: the dialog draws it.
public sealed class EditHeadModel
{
    public Bot Bot { get; }
    public string About { get; }
    public StoredHeadState Opened { get; }
    public HeadRecord Start { get; }
    /// A saved Character head (a theme the owner removed): the note under the stage says saving changes it.
    public string? OtherTheme { get; }
    public HeadRecord Draft { get; private set; }
    public HeadRecord? Undo { get; private set; }
    /// Describe it: the words typed, and what was understood (null before anything is typed).
    public string Words { get; private set; } = "";
    public List<string>? Understood { get; private set; }
    public int Revision { get; private set; }
    public int Round { get; private set; }
    public string? Notice { get; private set; }
    public bool Saving { get; private set; }
    public HeadRecord? Style { get; private set; }

    HeadRecord? _describeBase;
    (int Round, string Theme, List<HeadRecord> Ideas)? _ideaCache;
    readonly Func<string?> _readStyle;
    readonly Action<string> _writeStyle;

    /// Anything shown changed.
    public event Action? Changed;

    /// `readStyle` / `writeStyle`: My Style as stored JSON on this computer (`hqn.head.style`).
    public EditHeadModel(Bot bot, StoredHeadState opened, Func<string?>? readStyle = null, Action<string>? writeStyle = null)
    {
        Bot = bot;
        About = $"{bot.Name} {bot.Description ?? ""}";
        Opened = opened;
        _readStyle = readStyle ?? (() => null);
        _writeStyle = writeStyle ?? (_ => { });
        if (opened.Saved && HeadRecord.Parse(opened.Record) is { } record)
        {
            OtherTheme = record.Theme == "persona" ? HeadLabels.Themes["persona"] : null;
            Start = record.ForSaving;
        }
        else
        {
            Start = HeadRecord.DefaultRecord(bot.Name);
        }
        Draft = Start;
        Revision = opened.Revision;
        Style = _readStyle() is { } json ? HeadRecord.Parse(J.Parse(json)) : null;
    }

    public bool HasChanges => Draft != Start;

    /// The same ten until the theme changes or Shuffle asks for more.
    public List<HeadRecord> Ideas
    {
        get
        {
            if (_ideaCache is { } c && c.Round == Round && c.Theme == Draft.Theme) return c.Ideas;
            var ideas = HeadRecord.Ideas(Bot.Name, About, Round, Draft.Theme).Select(h => h.ForSaving).ToList();
            _ideaCache = (Round, Draft.Theme, ideas);
            return ideas;
        }
    }

    void Touch() => Changed?.Invoke();

    /// One part changed (a strip pick, a colour, an extra).
    public void Set(Action<HeadRecord> change)
    {
        Notice = null;
        _describeBase = null;
        var next = Draft with { };
        change(next);
        next.Hat = "none";
        Draft = next;
        Touch();
    }

    /// A whole new head (an idea, Shuffle, New Blob, My Style) can be undone.
    public void SetWhole(HeadRecord head)
    {
        Notice = null;
        _describeBase = null;
        Undo = Draft;
        Draft = head.ForSaving;
        Touch();
    }

    public void Shuffle(Func<double>? random = null)
    {
        var rng = random ?? Random.Shared.NextDouble;
        SetWhole(HeadRecord.Roll(rng, Draft.Theme));
        Round += 1;
        Touch();
    }

    /// The draft in another theme: a Shapes head starts with no board and a dot-matrix head never has one; another
    /// theme can't go without one. A Shapes form and a dot-matrix outline carry over as the nearest one.
    public static HeadRecord Themed(HeadRecord head, string theme)
    {
        var next = head with { Theme = theme };
        if (theme is "shape" or "matrix") next.Tile = "none";
        else if (next.Tile == "none") next.Tile = "dark";
        if (theme == "matrix") next.Form = HeadWire.Name(MatrixSilhouettes.FromStored(head.Form));
        else if (!HeadRecord.Forms.Contains(next.Form)) next.Form = MatrixSilhouettes.ShapesForm(MatrixSilhouettes.FromStored(head.Form));
        return next;
    }

    public void PickTheme(string theme)
    {
        if (theme == Draft.Theme) return;
        Notice = null;
        _describeBase = null;
        Draft = Themed(Draft, theme) with { Hat = "none" };
        Round += 1;
        Touch();
    }

    /// Describe it: lays the understood parts over the draft as it is typed (undoable as one change).
    public void Describe(string text)
    {
        Words = text;
        var described = HeadDescribe.Describe(text);
        Understood = text.Trim().Length == 0 ? null : described.Understood;
        if (_describeBase == null)
        {
            if (described.Understood.Count == 0) { Touch(); return; }
            _describeBase = Draft;
            Undo = Draft;
        }
        Notice = null;
        var next = _describeBase with { };
        next.ApplyDescribed(described.Parts);
        if (next.Theme == "matrix") next.Tile = "none";
        else if (next.Theme != "shape" && next.Tile == "none") next.Tile = "dark";
        if (!HeadLabels.OfferedThemes.Contains(next.Theme)) next.Theme = _describeBase.Theme;
        Draft = next.ForSaving;
        Touch();
    }

    /// What "Got it" says under Describe it.
    public string? UnderstoodWords => Understood is null ? null
        : Understood.Count == 0 ? "Try a color, an animal, a mood, or what the bot does." : "Got it: " + string.Join(", ", Understood);

    /// A new seed: a new blob, creature, light or pattern.
    public void Remix(Func<double>? random = null)
    {
        var rng = random ?? Random.Shared.NextDouble;
        SetWhole(Draft with { Seed = 1 + (int)Math.Floor(rng() * 1e6) });
    }

    public void UndoLast()
    {
        if (Undo is not { } previous) return;
        Draft = previous;
        Undo = null;
        _describeBase = null;
        Touch();
    }

    // MARK: My Style

    public void SetStyle()
    {
        _writeStyle(Draft.Stored().ToJsonString());
        Style = Draft;
        Touch();
    }

    public void UseStyle()
    {
        if (Style is { } style) SetWhole(Draft.ApplyingStyle(style));
    }

    // MARK: The theme's parts and colours

    /// A Shapes or dot-matrix head has 20 colours; the other themes the first eight (plus the draft's own).
    public string[] Palette
    {
        get
        {
            if (Draft.Theme is "shape" or "matrix") return HeadRecord.PickerShapeColors;
            var own = HeadRecord.Offered(Draft.Color);
            return HeadRecord.PickerThemeColors.Contains(own) ? HeadRecord.PickerThemeColors : [.. HeadRecord.PickerThemeColors, own];
        }
    }

    /// The strips the draft's theme shows: title, options, names, and the field they set.
    public List<(string Title, string[] Options, Dictionary<string, string> Names, string Field)> Strips => Draft.Theme switch
    {
        "robot" => [("Head", HeadRecord.OfferedShapes.Contains(Draft.Shape) ? HeadRecord.OfferedShapes : [.. HeadRecord.OfferedShapes, Draft.Shape],
                HeadLabels.Shapes, "shape"),
            ("Visor", HeadRecord.Visors, HeadLabels.Visors, "visor"), ("Shell", HeadRecord.Shells, HeadLabels.Shells, "shell")],
        "dots" => [("Pattern", HeadRecord.Patterns, HeadLabels.Patterns, "pattern")],
        "shape" => [("Shape", HeadRecord.Forms, HeadLabels.Forms, "form")],
        "matrix" => [("Shape", HeadRecord.Outlines, HeadLabels.Outlines, "form")],
        _ => [],
    };

    /// The draft with one string field set (a strip's picture of that choice).
    public static HeadRecord With(HeadRecord head, string field, string value)
    {
        var next = head with { };
        Assign(next, field, value);
        return next;
    }

    public static string Field(HeadRecord head, string field) => field switch
    {
        "shape" => head.Shape, "visor" => head.Visor, "shell" => head.Shell, "pattern" => head.Pattern, "form" => head.Form,
        "antenna" => head.Antenna, "ears" => head.EarsKind, "tile" => head.Tile, "color" => head.Color, _ => "",
    };

    public static void Assign(HeadRecord head, string field, string value)
    {
        switch (field)
        {
            case "shape": head.Shape = value; break;
            case "visor": head.Visor = value; break;
            case "shell": head.Shell = value; break;
            case "pattern": head.Pattern = value; break;
            case "form": head.Form = value; break;
            case "antenna": head.Antenna = value; break;
            case "ears": head.EarsKind = value; break;
            case "tile": head.Tile = value; break;
            case "color": head.Color = value; break;
        }
    }

    // MARK: Save

    /// Saves the draft (or null: Reset Head). True when saved. `mirror`: the desktop copy's PNG of a head (best effort).
    public async Task<bool> SaveAsync(RpcCall rpc, HeadRecord? record, Func<Head, Task<byte[]?>>? mirror = null)
    {
        Saving = true;
        Notice = null;
        Touch();
        try
        {
            Revision = await HeadStore.SaveAsync(rpc, Bot.Name, record, Revision);
            if (record == null) _ = HeadStore.MirrorAsync(rpc, Bot.Name, null);
            else if (mirror != null)
            {
                var head = record.ForSaving.Head;
                byte[]? png = null;
                try { png = await mirror(head); } catch (Exception) { }
                if (png != null) _ = HeadStore.MirrorAsync(rpc, Bot.Name, HeadStore.MirrorDataUrl(head, png));
            }
            return true;
        }
        catch (HeadSaveException e)
        {
            if (e.ActualRevision is { } actual) Revision = actual;
            Notice = e.Message;
            return false;
        }
        finally
        {
            Saving = false;
            Touch();
        }
    }
}
