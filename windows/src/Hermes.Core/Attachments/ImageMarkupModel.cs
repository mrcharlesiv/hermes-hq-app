namespace Hermes.Core.Attachments;

// [image-markup] Pure data model, 50-step snapshot undo/redo history, and edit-prompt composer for image markup &
// annotated edits (Mac 8094c82cb: HermesKit/Media/ImageMarkupModel.swift). Coordinates are normalized 0..1 relative
// to image bounds so strokes and callout pins scale cleanly across views and export resolutions.

public enum ImageMarkupTool { Pen, Highlighter, Arrow, Box, Pin }

public static class ImageMarkupTools
{
    public static readonly ImageMarkupTool[] All =
        [ImageMarkupTool.Pen, ImageMarkupTool.Highlighter, ImageMarkupTool.Arrow, ImageMarkupTool.Box, ImageMarkupTool.Pin];

    public static string Raw(this ImageMarkupTool tool) => tool switch
    {
        ImageMarkupTool.Pen => "pen",
        ImageMarkupTool.Highlighter => "highlighter",
        ImageMarkupTool.Arrow => "arrow",
        ImageMarkupTool.Box => "box",
        ImageMarkupTool.Pin => "pin",
        _ => "pen",
    };

    public static string Title(this ImageMarkupTool tool) => tool switch
    {
        ImageMarkupTool.Pen => "Pen",
        ImageMarkupTool.Highlighter => "Highlighter",
        ImageMarkupTool.Arrow => "Arrow",
        ImageMarkupTool.Box => "Box",
        ImageMarkupTool.Pin => "Pin Note",
        _ => "Pen",
    };

    public static string Glyph(this ImageMarkupTool tool) => tool switch
    {
        ImageMarkupTool.Pen => "\uEE56",         // Edit / Pen
        ImageMarkupTool.Highlighter => "\uE7E6", // Highlight
        ImageMarkupTool.Arrow => "\uE72A",       // Forward arrow
        ImageMarkupTool.Box => "\uE739",         // Checkbox / Box
        ImageMarkupTool.Pin => "\uE718",         // Pin
        _ => "\uEE56",
    };

    public static double DefaultWidthRatio(this ImageMarkupTool tool) => tool switch
    {
        ImageMarkupTool.Highlighter => 0.036,
        ImageMarkupTool.Arrow or ImageMarkupTool.Box => 0.011,
        _ => 0.010,
    };
}

public enum ImageMarkupColor { Red, Yellow, Blue, Green, White, Black }

public static class ImageMarkupColors
{
    public static readonly ImageMarkupColor[] All =
        [ImageMarkupColor.Red, ImageMarkupColor.Yellow, ImageMarkupColor.Blue, ImageMarkupColor.Green, ImageMarkupColor.White, ImageMarkupColor.Black];

    public static string Raw(this ImageMarkupColor color) => color switch
    {
        ImageMarkupColor.Red => "red",
        ImageMarkupColor.Yellow => "yellow",
        ImageMarkupColor.Blue => "blue",
        ImageMarkupColor.Green => "green",
        ImageMarkupColor.White => "white",
        ImageMarkupColor.Black => "black",
        _ => "red",
    };

    public static string Title(this ImageMarkupColor color) => color switch
    {
        ImageMarkupColor.Red => "Red",
        ImageMarkupColor.Yellow => "Yellow",
        ImageMarkupColor.Blue => "Blue",
        ImageMarkupColor.Green => "Green",
        ImageMarkupColor.White => "White",
        ImageMarkupColor.Black => "Black",
        _ => "Red",
    };

    /// sRGB normalized RGBA values matching HermesKit/Media/ImageMarkupModel.swift `ImageMarkupColor.rgba`.
    public static (double R, double G, double B, double A) Rgba(this ImageMarkupColor color) => color switch
    {
        ImageMarkupColor.Red => (0.96, 0.24, 0.22, 1.0),
        ImageMarkupColor.Yellow => (0.99, 0.80, 0.08, 1.0),
        ImageMarkupColor.Blue => (0.14, 0.52, 0.98, 1.0),
        ImageMarkupColor.Green => (0.18, 0.78, 0.35, 1.0),
        ImageMarkupColor.White => (1.0, 1.0, 1.0, 1.0),
        ImageMarkupColor.Black => (0.08, 0.08, 0.10, 1.0),
        _ => (0.96, 0.24, 0.22, 1.0),
    };

    public static (byte R, byte G, byte B, byte A) Bytes(this ImageMarkupColor color, double opacity = 1.0)
    {
        var (r, g, b, a) = color.Rgba();
        return (
            (byte)Math.Round(Math.Clamp(r, 0, 1) * 255),
            (byte)Math.Round(Math.Clamp(g, 0, 1) * 255),
            (byte)Math.Round(Math.Clamp(b, 0, 1) * 255),
            (byte)Math.Round(Math.Clamp(a * opacity, 0, 1) * 255));
    }
}

/// Normalized point clamped to 0..1 relative to image bounds.
public readonly record struct ImageMarkupPoint
{
    public double X { get; }
    public double Y { get; }

    public ImageMarkupPoint(double x, double y)
    {
        X = ClampUnit(x);
        Y = ClampUnit(y);
    }

    private static double ClampUnit(double v) =>
        double.IsNaN(v) ? 0 : double.IsPositiveInfinity(v) ? 1 : double.IsNegativeInfinity(v) ? 0 : Math.Clamp(v, 0, 1);

    public static ImageMarkupPoint FromCanvas(double px, double py, double width, double height) =>
        new(px / Math.Max(1, width), py / Math.Max(1, height));

    public (double X, double Y) ToCanvas(double width, double height) => (X * width, Y * height);
}

public sealed record ImageMarkupStroke(
    string Id,
    ImageMarkupTool Tool,
    ImageMarkupColor Color,
    double WidthRatio,
    IReadOnlyList<ImageMarkupPoint> Points)
{
    public ImageMarkupStroke(ImageMarkupTool tool, ImageMarkupColor color, double widthRatio, IReadOnlyList<ImageMarkupPoint> points)
        : this(Guid.NewGuid().ToString("D"), tool, color, widthRatio, points) { }

    public double Opacity => Tool == ImageMarkupTool.Highlighter ? 0.38 : 1.0;
}

public sealed record ImageMarkupPin(
    string Id,
    int Number,
    ImageMarkupPoint Point,
    ImageMarkupColor Color,
    string Note)
{
    public ImageMarkupPin(int number, ImageMarkupPoint point, ImageMarkupColor color, string note)
        : this(Guid.NewGuid().ToString("D"), number, point, color, note) { }
}

/// Snapshot-based 50-step undo/redo document for image markup annotations.
public sealed class ImageMarkupDocument
{
    public sealed record State(IReadOnlyList<ImageMarkupStroke> Strokes, IReadOnlyList<ImageMarkupPin> Pins);

    public const int MaxHistory = 50;
    public const int MaxStrokePoints = 4_000;

    private List<ImageMarkupStroke> _strokes = [];
    private List<ImageMarkupPin> _pins = [];
    private readonly List<State> _undoStack = [];
    private readonly List<State> _redoStack = [];

    public IReadOnlyList<ImageMarkupStroke> Strokes => _strokes;
    public IReadOnlyList<ImageMarkupPin> Pins => _pins;
    public State Current => new([.. _strokes], [.. _pins]);
    public bool IsEmpty => _strokes.Count == 0 && _pins.Count == 0;
    public bool CanUndo => _undoStack.Count > 0;
    public bool CanRedo => _redoStack.Count > 0;

    /// Pin badge diameter matching ImageMarkupRenderer.badgeDiameter(forMinSide:).
    public static double BadgeDiameter(double minSide) => Math.Max(24, Math.Min(48, minSide * 0.062));

    /// Stroke thickness clamped to [2, 20% of minSide], guarding NaN/Infinity ratios.
    public static double LineWidth(double ratio, double minSide)
    {
        var wanted = ratio * minSide;
        if (!double.IsFinite(wanted)) return 2;
        return Math.Min(Math.Max(2, wanted), Math.Max(2, minSide * 0.2));
    }

    private void RecordUndo()
    {
        _undoStack.Add(Current);
        if (_undoStack.Count > MaxHistory)
            _undoStack.RemoveRange(0, _undoStack.Count - MaxHistory);
        _redoStack.Clear();
    }

    public void AddStroke(ImageMarkupStroke stroke)
    {
        if (stroke.Points.Count == 0) return;
        RecordUndo();
        var pts = stroke.Points.Count > MaxStrokePoints ? stroke.Points.Take(MaxStrokePoints).ToList() : stroke.Points;
        _strokes.Add(ReferenceEquals(pts, stroke.Points) ? stroke : stroke with { Points = pts });
    }

    public ImageMarkupPin AddPin(ImageMarkupPoint point, ImageMarkupColor color, string note)
    {
        RecordUndo();
        var nextNumber = _pins.Count == 0 ? 1 : _pins.Max(p => p.Number) + 1;
        var pin = new ImageMarkupPin(nextNumber, point, color, (note ?? "").Trim());
        _pins.Add(pin);
        return pin;
    }

    public void UpdatePin(string id, string note)
    {
        var idx = _pins.FindIndex(p => p.Id == id);
        if (idx < 0) return;
        var cleaned = (note ?? "").Trim();
        if (_pins[idx].Note == cleaned) return;
        RecordUndo();
        _pins[idx] = _pins[idx] with { Note = cleaned };
    }

    public void RemovePin(string id)
    {
        if (!_pins.Any(p => p.Id == id)) return;
        RecordUndo();
        _pins.RemoveAll(p => p.Id == id);
        for (var i = 0; i < _pins.Count; i++)
            _pins[i] = _pins[i] with { Number = i + 1 };
    }

    public void Clear()
    {
        if (IsEmpty) return;
        RecordUndo();
        _strokes = [];
        _pins = [];
    }

    public bool Undo()
    {
        if (_undoStack.Count == 0) return false;
        _redoStack.Add(Current);
        var prev = _undoStack[^1];
        _undoStack.RemoveAt(_undoStack.Count - 1);
        _strokes = [.. prev.Strokes];
        _pins = [.. prev.Pins];
        return true;
    }

    public bool Redo()
    {
        if (_redoStack.Count == 0) return false;
        _undoStack.Add(Current);
        var next = _redoStack[^1];
        _redoStack.RemoveAt(_redoStack.Count - 1);
        _strokes = [.. next.Strokes];
        _pins = [.. next.Pins];
        return true;
    }
}

public static class ImageMarkupPrompt
{
    private static readonly char[] Newlines = ['\n', '\r', '\u000B', '\u000C', '\u0085', '\u2028', '\u2029'];

    /// Formats the edit prompt combining the overall note and any numbered pin notes.
    /// `hasMarks` is false when nothing was drawn or pinned.
    public static string Compose(string? note, IReadOnlyList<ImageMarkupPin> pins, bool hasMarks = true)
    {
        var trimmedNote = (note ?? "").Trim();
        var notedPins = pins
            .Where(p => !string.IsNullOrWhiteSpace(p.Note))
            .OrderBy(p => p.Number)
            .ToList();

        if (!hasMarks && pins.Count == 0)
            return trimmedNote.Length == 0 ? "" : $"Please edit this image: {trimmedNote}";

        if (trimmedNote.Length == 0 && notedPins.Count == 0)
            return "Please edit the marked-up areas of this image.";

        var lines = new List<string>(notedPins.Count + 1)
        {
            trimmedNote.Length > 0
                ? $"Please edit the marked-up areas of this image: {trimmedNote}"
                : "Please edit the marked-up areas of this image:",
        };

        foreach (var pin in notedPins)
        {
            var words = string.Join(" ", pin.Note.Split(Newlines, StringSplitOptions.RemoveEmptyEntries)).Trim();
            lines.Add($"{pin.Number}. {words}");
        }
        return string.Join("\n", lines);
    }
}
