using System.Globalization;

namespace Hermes.Core.Heads;

/// One figure of SVG path data in absolute coordinates: where it starts, its segments, and whether it is closed. The
/// renderer turns it into a PathFigure; arcs stay in SVG's endpoint form, which XAML's ArcSegment takes as is.
public sealed record SvgFigure(P Start, List<SvgSegment> Segments, bool Closed);

public abstract record SvgSegment
{
    public sealed record Line(P To) : SvgSegment;
    public sealed record Cubic(P C1, P C2, P To) : SvgSegment;
    public sealed record Quad(P C, P To) : SvgSegment;
    public sealed record Arc(double Rx, double Ry, double Rotation, bool Large, bool Sweep, P To) : SvgSegment;
}

/// A small SVG path-data reader (M L H V C Q A Z, absolute and relative, SVG's compact number grammar), as
/// App/Heads/SVGPathData.swift, so the heads' markup is carried over verbatim from the web renderer. Unknown commands
/// end the parse (what was read so far is kept).
public static class SvgPath
{
    public static List<SvgFigure> Parse(string d)
    {
        var figures = new List<SvgFigure>();
        var t = new Tokens(d);
        P current = default, start = default;
        List<SvgSegment>? segs = null;
        var command = 'M';
        var last = ' ';
        void Close(bool closed)
        {
            if (segs != null) figures.Add(new SvgFigure(start, segs, closed));
            segs = null;
        }
        while (true)
        {
            if (t.Command() is { } next) command = next;
            else if (t.AtEnd) break;
            else if (last == ' ' || command is 'Z' or 'z') break;
            var relative = char.IsLower(command);
            var bx = relative ? current.X : 0;
            var by = relative ? current.Y : 0;
            P Pt(double x, double y) => new(bx + x, by + y);
            List<SvgSegment> Open()
            {
                if (segs == null) { segs = []; start = current; }
                return segs;
            }
            switch (command)
            {
                case 'M' or 'm':
                    {
                        if (t.Number() is not { } x || t.Number() is not { } y) { Close(false); return figures; }
                        Close(false);
                        current = Pt(x, y);
                        start = current;
                        segs = [];
                        command = relative ? 'l' : 'L';
                        break;
                    }
                case 'L' or 'l':
                    {
                        if (t.Number() is not { } x || t.Number() is not { } y) { Close(false); return figures; }
                        current = Pt(x, y);
                        Open().Add(new SvgSegment.Line(current));
                        break;
                    }
                case 'H' or 'h':
                    {
                        if (t.Number() is not { } x) { Close(false); return figures; }
                        current = new P(relative ? current.X + x : x, current.Y);
                        Open().Add(new SvgSegment.Line(current));
                        break;
                    }
                case 'V' or 'v':
                    {
                        if (t.Number() is not { } y) { Close(false); return figures; }
                        current = new P(current.X, relative ? current.Y + y : y);
                        Open().Add(new SvgSegment.Line(current));
                        break;
                    }
                case 'C' or 'c':
                    {
                        if (t.Number() is not { } x1 || t.Number() is not { } y1 || t.Number() is not { } x2 || t.Number() is not { } y2
                            || t.Number() is not { } x || t.Number() is not { } y) { Close(false); return figures; }
                        var c1 = Pt(x1, y1);
                        var c2 = Pt(x2, y2);
                        current = Pt(x, y);
                        Open().Add(new SvgSegment.Cubic(c1, c2, current));
                        break;
                    }
                case 'Q' or 'q':
                    {
                        if (t.Number() is not { } x1 || t.Number() is not { } y1 || t.Number() is not { } x || t.Number() is not { } y)
                        { Close(false); return figures; }
                        var c = Pt(x1, y1);
                        current = Pt(x, y);
                        Open().Add(new SvgSegment.Quad(c, current));
                        break;
                    }
                case 'A' or 'a':
                    {
                        if (t.Number() is not { } rx || t.Number() is not { } ry || t.Number() is not { } rot || t.Flag() is not { } large
                            || t.Flag() is not { } sweep || t.Number() is not { } x || t.Number() is not { } y) { Close(false); return figures; }
                        var end = Pt(x, y);
                        if (end != current) Open().Add(new SvgSegment.Arc(Math.Abs(rx), Math.Abs(ry), rot, large, sweep, end));
                        current = end;
                        break;
                    }
                case 'Z' or 'z':
                    Close(true);
                    current = start;
                    break;
                default:
                    Close(false);
                    return figures;
            }
            last = command;
        }
        Close(false);
        return figures;
    }

    /// The bounds of a path's points (control points included): enough for tests and hit boxes.
    public static (double MinX, double MinY, double MaxX, double MaxY) Bounds(List<SvgFigure> figures)
    {
        double minX = double.MaxValue, minY = double.MaxValue, maxX = double.MinValue, maxY = double.MinValue;
        void Add(P p) { minX = Math.Min(minX, p.X); minY = Math.Min(minY, p.Y); maxX = Math.Max(maxX, p.X); maxY = Math.Max(maxY, p.Y); }
        foreach (var f in figures)
        {
            Add(f.Start);
            foreach (var s in f.Segments)
            {
                switch (s)
                {
                    case SvgSegment.Line l: Add(l.To); break;
                    case SvgSegment.Cubic c: Add(c.C1); Add(c.C2); Add(c.To); break;
                    case SvgSegment.Quad q: Add(q.C); Add(q.To); break;
                    case SvgSegment.Arc a: Add(a.To); break;
                }
            }
        }
        return (minX, minY, maxX, maxY);
    }

    /// Tokenizer: commands are letters; numbers follow SVG's compact grammar ("-42-9", ".5.5", "1e-3").
    sealed class Tokens(string text)
    {
        int _i;

        public bool AtEnd { get { Skip(); return _i >= text.Length; } }

        void Skip()
        {
            while (_i < text.Length && text[_i] is ' ' or ',' or '\n' or '\t' or '\r') _i++;
        }

        public char? Command()
        {
            Skip();
            if (_i >= text.Length || !char.IsLetter(text[_i]) || text[_i] is 'e' or 'E') return null;
            return text[_i++];
        }

        public bool? Flag()
        {
            Skip();
            if (_i >= text.Length || text[_i] is not ('0' or '1')) return null;
            return text[_i++] == '1';
        }

        public double? Number()
        {
            Skip();
            var begin = _i;
            if (_i < text.Length && text[_i] is '-' or '+') _i++;
            bool digits = false, dot = false;
            while (_i < text.Length)
            {
                var c = text[_i];
                if (c is >= '0' and <= '9') { digits = true; _i++; }
                else if (c == '.' && !dot) { dot = true; _i++; }
                else break;
            }
            if (digits && _i < text.Length && text[_i] is 'e' or 'E')
            {
                var j = _i + 1;
                if (j < text.Length && text[j] is '-' or '+') j++;
                if (j < text.Length && text[j] is >= '0' and <= '9')
                {
                    _i = j;
                    while (_i < text.Length && text[_i] is >= '0' and <= '9') _i++;
                }
            }
            if (!digits) { _i = begin; return null; }
            return double.Parse(text.AsSpan(begin, _i - begin), NumberStyles.Float, CultureInfo.InvariantCulture);
        }
    }
}
