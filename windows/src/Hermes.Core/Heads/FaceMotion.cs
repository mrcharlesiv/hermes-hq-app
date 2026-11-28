namespace Hermes.Core.Heads;

// [moods] How every face moves while its bot is at something (App/Heads/FaceMotion.swift):
// body poses (x, y, roll, turn, tip, squash), eye gaze & lids, cubic-bezier eases, all 12 mood routines,
// 2-stage cascaded critically damped C³ spring (`FaceLoop.SoftSamples`) with harmonic breathing & exact periodic
// closure, 0.82-damped secondary squash/lean (`FaceJelly`), and 3D cushion geometry (`FaceSolid`).

/// Where the body is: moved (shares of the head's side, + right and down), tilted (`Roll`, degrees, + clockwise),
/// turned (`Turn`, degrees about the upright, + toward the viewer's right), tipped (`Tip`, degrees, + face down) and
/// squashed (+ wider and shorter, − taller and thinner).
public readonly record struct FaceBody(
    double X = 0.0,
    double Y = 0.0,
    double Roll = 0.0,
    double Turn = 0.0,
    double Tip = 0.0,
    double Squash = 0.0)
{
    public static readonly FaceBody Rest = new();

    public FaceBody Mixed(FaceBody other, double k)
    {
        static double Mix(double a, double b, double t) => a + (b - a) * t;
        return new FaceBody(
            Mix(X, other.X, k),
            Mix(Y, other.Y, k),
            Mix(Roll, other.Roll, k),
            Mix(Turn, other.Turn, k),
            Mix(Tip, other.Tip, k),
            Mix(Squash, other.Squash, k));
    }

    /// Shortest signed angular difference from `from` to `to`, in (−180°, 180°], so settling from 360° back to 0° moves 0°.
    public static double ShortestAngleDelta(double from, double to)
    {
        var d = (to - from) % 360.0;
        if (d > 180.0) d -= 360.0;
        else if (d <= -180.0) d += 360.0;
        return d;
    }

    /// Smooth blend between poses using shortest angular arcs (never unwinds a full 360° spin backwards).
    public FaceBody MixedShortest(FaceBody other, double k)
    {
        static double Mix(double a, double b, double t) => a + (b - a) * t;
        return new FaceBody(
            Mix(X, other.X, k),
            Mix(Y, other.Y, k),
            Roll + ShortestAngleDelta(Roll, other.Roll) * k,
            Turn + ShortestAngleDelta(Turn, other.Turn) * k,
            Tip + ShortestAngleDelta(Tip, other.Tip) * k,
            Mix(Squash, other.Squash, k));
    }

    /// C² quintic S-curve (0→1 with zero velocity and zero acceleration at both ends) for silk-smooth transitions.
    public static double Quintic(double u)
    {
        var c = Math.Clamp(u, 0.0, 1.0);
        return c * c * c * (10.0 + c * (-15.0 + 6.0 * c));
    }
}

/// Where the eyes look (−1…1 each way, + right and down), how far shut they are (0 open … 1 shut), how wide/perked
/// they open (0 normal … 1 wide, still normal slits), and subtle inquisitive asymmetry (−1…1: + right eye slightly
/// wider than left).
public readonly record struct FaceEyes(
    double X = 0.0,
    double Y = 0.0,
    double Lids = 0.0,
    double Wide = 0.0,
    double Tilt = 0.0)
{
    public static readonly FaceEyes Rest = new();
    /// How far a look all the way across (1) or down turns the eyes round a round body, degrees.
    public const double Across = 34.0;
    public const double Down = 26.0;

    public FaceEyes Mixed(FaceEyes other, double k)
    {
        static double Mix(double a, double b, double t) => a + (b - a) * t;
        return new FaceEyes(
            Mix(X, other.X, k),
            Mix(Y, other.Y, k),
            Mix(Lids, other.Lids, k),
            Mix(Wide, other.Wide, k),
            Mix(Tilt, other.Tilt, k));
    }
}

/// How a move goes, as CSS's `cubic-bezier`: its middle points may run past 1, for a move that overshoots and settles.
public readonly record struct FaceEase(double X1, double Y1, double X2, double Y2)
{
    public static readonly FaceEase Linear = new(0, 0, 1, 1);
    /// Soft at both ends: most moves.
    public static readonly FaceEase Glide = new(0.42, 0, 0.22, 1);
    /// Quick off, running about 15% past and settling back: a head swinging round, a landing.
    public static readonly FaceEase Spring = new(0.3, 1.6, 0.45, 1.1);
    /// Livelier overshoot for playful hops and joyful settles.
    public static readonly FaceEase Bouncy = new(0.26, 1.75, 0.42, 1.08);
    /// Crisp off, soft landing: quick eye saccades and alert snaps.
    public static readonly FaceEase Snappy = new(0.18, 0, 0.12, 1);
    /// Faster and faster: a fall, a push.
    public static readonly FaceEase Drop = new(0.55, 0, 0.9, 0.55);
    /// Fast off, slowing to the top: a jump.
    public static readonly FaceEase Rise = new(0.1, 0.55, 0.35, 1);

    /// How far along the move is at `t` (0…1 of its time).
    public double Evaluate(double t)
    {
        var clamped = Math.Clamp(t, 0.0, 1.0);
        static double Curve(double s, double a, double b)
        {
            var u = 1.0 - s;
            return 3.0 * u * u * s * a + 3.0 * u * s * s * b + s * s * s;
        }
        static double Slope(double s, double x1, double x2)
        {
            var u = 1.0 - s;
            return 3.0 * u * u * x1 + 6.0 * u * s * (x2 - x1) + 3.0 * s * s * (1.0 - x2);
        }
        var s = clamped;
        for (var i = 0; i < 8; i++)
        {
            var d = Slope(s, X1, X2);
            if (Math.Abs(d) <= 1e-6) break;
            s = Math.Clamp(s - (Curve(s, X1, X2) - clamped) / d, 0.0, 1.0);
        }
        if (Math.Abs(Curve(s, X1, X2) - clamped) > 1e-4)
        {
            var low = 0.0;
            var high = 1.0;
            for (var i = 0; i < 40; i++)
            {
                s = (low + high) * 0.5;
                if (Curve(s, X1, X2) < clamped) low = s;
                else high = s;
            }
        }
        return Curve(s, Y1, Y2);
    }
}

/// A value at a moment of a routine, reached from the one before by `Ease`.
public readonly record struct FaceKey<TValue>(double At, TValue Value, FaceEase Ease);

/// One routine: how the body and the eyes go, each on its own timeline.
public sealed class FaceClip
{
    public double Length { get; }
    public IReadOnlyList<FaceKey<FaceBody>> Body { get; }
    public IReadOnlyList<FaceKey<FaceEyes>> Eyes { get; }
    /// Beats in it a light may flash on (a nod's dip, a hop's landing).
    public IReadOnlyList<double> Marks { get; }

    public FaceClip(double length, IReadOnlyList<FaceKey<FaceBody>> body, IReadOnlyList<FaceKey<FaceEyes>> eyes,
        IReadOnlyList<double>? marks = null)
    {
        Length = length;
        Body = body;
        Eyes = eyes;
        Marks = marks ?? [];
    }

    public FaceBody BodyAt(double t) => Evaluate(Body, t, static (a, b, k) => a.Mixed(b, k));
    public FaceEyes EyesAt(double t) => Evaluate(Eyes, t, static (a, b, k) => a.Mixed(b, k));

    public (FaceBody Body, FaceEyes Eyes) First => (Body[0].Value, Eyes[0].Value);
    public (FaceBody Body, FaceEyes Eyes) Last => (Body[^1].Value, Eyes[^1].Value);

    /// Times to sample it at, evenly about `rate` a second, both ends included.
    public double[] Times(double rate)
    {
        var steps = Math.Max(1, (int)Math.Ceiling(Length * rate));
        var times = new double[steps + 1];
        for (var i = 0; i <= steps; i++) times[i] = Length * i / steps;
        return times;
    }

    private static T Evaluate<T>(IReadOnlyList<FaceKey<T>> keys, double t, Func<T, T, double, T> mix)
    {
        var previous = keys[0];
        for (var i = 1; i < keys.Count; i++)
        {
            var key = keys[i];
            if (t < key.At)
            {
                var span = key.At - previous.At;
                return mix(previous.Value, key.Value, span > 0 ? key.Ease.Evaluate((t - previous.At) / span) : 1.0);
            }
            previous = key;
        }
        return previous.Value;
    }
}

/// Writes a routine as moves from where the face is: hold, then go somewhere over a while.
public sealed class FaceScript
{
    private readonly List<FaceKey<FaceBody>> _body;
    private readonly List<FaceKey<FaceEyes>> _eyes;
    private readonly List<double> _marks = [];

    public FaceScript(FaceBody? body = null, FaceEyes? eyes = null)
    {
        _body = [new FaceKey<FaceBody>(0, body ?? FaceBody.Rest, FaceEase.Linear)];
        _eyes = [new FaceKey<FaceEyes>(0, eyes ?? FaceEyes.Rest, FaceEase.Linear)];
    }

    public FaceBody Now => _body[^1].Value;
    public FaceEyes Looking => _eyes[^1].Value;

    public void Move(double at, double over, Func<FaceBody, FaceBody> change) =>
        Move(at, over, FaceEase.Glide, change);

    public void Move(double at, double over, FaceEase ease, Func<FaceBody, FaceBody> change) =>
        Add(_body, at, over, ease, change(Now));

    public void MoveTo(double at, double over, FaceBody to, FaceEase? ease = null) =>
        Add(_body, at, over, ease ?? FaceEase.Glide, to);

    public void Look(double at, double over, Func<FaceEyes, FaceEyes> change) =>
        Look(at, over, FaceEase.Glide, change);

    public void Look(double at, double over, FaceEase ease, Func<FaceEyes, FaceEyes> change) =>
        Add(_eyes, at, over, ease, change(Looking));

    public void LookTo(double at, double over, FaceEyes to, FaceEase? ease = null) =>
        Add(_eyes, at, over, ease ?? FaceEase.Glide, to);

    /// The lids drop smoothly, pause briefly shut, and lift again softly (0.28 s).
    public void Blink(double at)
    {
        var open = Looking;
        Look(at, 0.09, FaceEase.Glide, e => e with { Lids = 1, Wide = 0 });
        LookTo(at + 0.12, 0.16, open, FaceEase.Glide);
    }

    /// Two quick natural blinks (0.58 s).
    public void DoubleBlink(double at)
    {
        Blink(at);
        Blink(at + 0.3);
    }

    public void Mark(double at) => _marks.Add(at);

    /// The routine, `length` seconds long: the last pose held to the end.
    public FaceClip Clip(double length)
    {
        var body = new List<FaceKey<FaceBody>>(_body);
        var eyes = new List<FaceKey<FaceEyes>>(_eyes);
        if (body.Count > 0 && body[^1].At < length) body.Add(new FaceKey<FaceBody>(length, body[^1].Value, FaceEase.Linear));
        if (eyes.Count > 0 && eyes[^1].At < length) eyes.Add(new FaceKey<FaceEyes>(length, eyes[^1].Value, FaceEase.Linear));
        return new FaceClip(length, body, eyes, [.. _marks]);
    }

    private static void Add<T>(List<FaceKey<T>> keys, double at, double over, FaceEase ease, T value)
    {
        var last = keys[^1];
        if (at > last.At + 1e-9) keys.Add(new FaceKey<T>(at, last.Value, FaceEase.Linear));
        keys.Add(new FaceKey<T>(Math.Max(at, last.At) + over, value, ease));
    }
}

/// Each mood's routines: the body in degrees and shares of the head, the eyes −1…1.
public static class FaceRoutines
{
    /// Browsing: where the pointer stops (fractions of the head), each stop a second.
    public static readonly IReadOnlyList<P> Stops =
    [
        new(0.3, 0.68), new(0.72, 0.4), new(0.6, 0.74), new(0.34, 0.36),
    ];
    public const double StopLength = 1.0;
    /// Writing: how long a line takes to type, and the pause before the next two.
    public const double LineLength = 1.4;
    public const double TypingPause = 0.4;

    /// `mood`'s routines for a face turned to `facing` (−1 left, +1 right).
    public static IReadOnlyList<FaceClip> Clips(BotMood mood, int facing)
    {
        var f = facing < 0 ? -1.0 : 1.0;
        return mood switch
        {
            BotMood.Thinking => Thinking(f),
            BotMood.Reading => Reading(),
            BotMood.Searching => Searching(f),
            BotMood.Running => Running(f),
            BotMood.Writing => Writing(f),
            BotMood.Browsing => Browsing(),
            BotMood.Messaging => Messaging(f),
            BotMood.Making => Making(f),
            BotMood.Replying => Replying(f),
            BotMood.Asking => Asking(f),
            BotMood.Done => Done(f),
            BotMood.Failed => Failed(f),
            _ => Thinking(f),
        };
    }

    /// The eyes kept still under Reduce Motion: the mood's own look (up for done, down and half shut for failed).
    public static FaceEyes Still(BotMood mood, int facing) => mood switch
    {
        BotMood.Done => new FaceEyes(Y: -0.6),
        BotMood.Failed => new FaceEyes(Y: 0.5, Lids: 0.45),
        _ => Clips(mood, facing)[0].First.Eyes,
    };

    private static double Hop(FaceScript script, double at, double height, double roll = 0)
    {
        var from = script.Now;
        script.Move(at, 0.1, b => b with { Squash = from.Squash + 0.08, Y = from.Y + 0.012 });
        script.Move(at + 0.1, 0.16, FaceEase.Rise, b => b with
        {
            Y = from.Y - height, Squash = from.Squash - 0.07, Roll = from.Roll + roll,
        });
        script.Move(at + 0.26, 0.14, FaceEase.Drop, b => b with
        {
            Y = from.Y + 0.008, Squash = from.Squash + 0.075, Roll = from.Roll,
        });
        script.MoveTo(at + 0.4, 0.22, from, FaceEase.Spring);
        return at + 0.4;
    }

    private static void Nod(FaceScript script, double at, double depth = 11)
    {
        var from = script.Now;
        script.Move(at, 0.15, FaceEase.Snappy, b => b with
        {
            Tip = from.Tip + depth, Y = from.Y + 0.016, Squash = from.Squash + 0.03,
        });
        script.MoveTo(at + 0.15, 0.35, from, FaceEase.Spring);
        script.Mark(at + 0.15);
    }

    private static FaceClip[] Thinking(double f)
    {
        var body = new FaceBody(Roll: 5 * f, Turn: 14 * f, Tip: -8);
        var eyes = new FaceEyes(X: 0.65 * f, Y: -0.85);

        var over = new FaceScript(body, eyes);
        over.Look(0.85, 0.22, FaceEase.Snappy, e => e with { X = -0.75 * f, Y = -0.95, Tilt = -0.25 * f });
        over.Move(0.95, 1.25, b => b with { Turn = -18 * f, Roll = -6 * f, Tip = -10, X = -0.015 * f });
        over.Blink(2.55);
        over.LookTo(3.25, 0.25, eyes, FaceEase.Snappy);
        over.MoveTo(3.35, 1.3, body);

        var hmm = new FaceScript(body, eyes);
        hmm.Move(0.45, 0.48, b => b with { Tip = 6, Squash = 0.055, Y = 0.018, Turn = 6 * f, Roll = -2 * f });
        hmm.Look(0.45, 0.26, e => e with { Lids = 0.55, Y = 0.18, X = 0.25 * f, Tilt = 0.45 * f });
        hmm.Move(1.75, 0.24, FaceEase.Rise, b => b with { Tip = -13, Squash = -0.08, Y = -0.048, Turn = 0, Roll = 3 * f });
        hmm.Look(1.72, 0.12, FaceEase.Snappy, e => e with { Lids = 0, Wide = 0.85, Y = -0.45, X = 0, Tilt = 0 });
        hmm.Mark(1.95);
        hmm.MoveTo(2.05, 0.55, body, FaceEase.Bouncy);
        hmm.LookTo(2.55, 0.22, eyes);
        hmm.DoubleBlink(3.35);

        var about = new FaceScript(body, eyes);
        about.Look(0.4, 0.12, FaceEase.Snappy, e => e with { X = -0.65 * f, Y = -1, Wide = 0.2 });
        about.Move(0.45, 0.52, FaceEase.Spring, b => b with { Turn = -10 * f, Roll = -3 * f, Tip = -11 });
        about.Look(1.3, 0.12, FaceEase.Snappy, e => e with { X = 1 * f, Y = -0.55, Wide = 0.3 });
        about.Move(1.35, 0.52, FaceEase.Spring, b => b with { Turn = 22 * f, Roll = 7 * f, Tip = -6 });
        about.Blink(2.15);
        about.LookTo(2.65, 0.2, eyes);
        about.MoveTo(2.7, 0.9, body);

        var weigh = new FaceScript(body, eyes);
        weigh.Look(0.35, 0.16, FaceEase.Snappy, e => e with { X = -0.8 * f, Y = -0.35, Tilt = -0.35 * f });
        weigh.Move(0.4, 0.65, FaceEase.Spring, b => b with { Roll = -10 * f, Turn = -15 * f, Tip = -3, Y = 0.01 });
        weigh.Look(1.5, 0.16, FaceEase.Snappy, e => e with { X = 0.85 * f, Y = -0.45, Tilt = 0.35 * f });
        weigh.Move(1.55, 0.65, FaceEase.Spring, b => b with { Roll = 10 * f, Turn = 18 * f, Tip = -5, Y = -0.01 });
        weigh.Blink(2.5);
        weigh.LookTo(2.95, 0.22, eyes);
        weigh.MoveTo(3.0, 0.85, body);

        return [over.Clip(5.2), hmm.Clip(4.4), about.Clip(4.0), weigh.Clip(4.2)];
    }

    private static FaceClip[] Reading()
    {
        var body = new FaceBody(Turn: -8, Tip: 10, Squash: 0.025);
        var eyes = new FaceEyes(X: -0.85, Y: 0.32, Lids: 0.32);

        var lines = new FaceScript(body, eyes);
        for (var line = 0; line < 3; line++)
        {
            var l = line;
            var t = l * 1.15;
            var rowY = 0.32 + 0.23 * l;
            lines.Look(t + 0.04, 0.4, FaceEase.Glide, e => e with { X = 0.05, Y = rowY });
            lines.Look(t + 0.48, 0.4, FaceEase.Glide, e => e with { X = 0.88, Y = rowY });
            lines.Move(t + 0.04, 0.84, b => b with { Turn = 8, Tip = 10 + 2.5 * l, Roll = 2 });
            lines.Mark(t + 0.92);
            var nextY = l < 2 ? 0.32 + 0.23 * (l + 1) : 0.32;
            var nextTip = l < 2 ? 10 + 2.5 * (l + 1) : 10;
            lines.Look(t + 0.92, 0.12, FaceEase.Snappy, e => e with { X = -0.85, Y = nextY });
            lines.Move(t + 0.92, 0.18, FaceEase.Snappy, b => b with { Turn = -8, Tip = nextTip, Roll = 0 });
        }

        var close = new FaceScript(body, eyes);
        close.Move(0.18, 0.46, b => b with { Tip = 16, Y = 0.025, Squash = -0.025, Roll = -3 });
        close.Look(0.18, 0.24, e => e with { Lids = 0.52, Y = 0.5 });
        close.Look(0.75, 0.92, FaceEase.Linear, e => e with { X = 0.88 });
        close.Move(0.75, 0.92, b => b with { Turn = 9, Roll = 2 });
        close.Look(1.72, 0.12, FaceEase.Snappy, e => e with { X = -0.85, Y = 0.65 });
        close.Move(1.72, 0.26, b => b with { Turn = -8, Roll = 0 });
        Nod(close, 2.05, depth: 8);
        close.Blink(2.6);
        close.MoveTo(2.95, 0.6, body);
        close.LookTo(2.95, 0.25, eyes);

        var skim = new FaceScript(body, eyes);
        skim.Move(0.2, 0.55, b => b with { Turn = 0, Tip = 6, Y = -0.008 });
        skim.Look(0.2, 0.16, FaceEase.Snappy, e => e with { X = -0.2, Y = 0.1, Lids = 0.15 });
        skim.Look(0.65, 0.65, FaceEase.Glide, e => e with { X = 0.25, Y = 0.82 });
        skim.Move(0.75, 0.65, b => b with { Tip = 15, Y = 0.02 });
        skim.Look(1.45, 0.12, FaceEase.Snappy, e => e with { Lids = 0, Wide = 0.55, X = 0.4, Y = 0.6 });
        skim.Move(1.45, 0.28, FaceEase.Spring, b => b with { Roll = 6, Squash = -0.04, Tip = 11 });
        skim.Mark(1.55);
        skim.Blink(2.1);
        skim.MoveTo(2.55, 0.65, body);
        skim.LookTo(2.55, 0.22, eyes);

        return [lines.Clip(3.6), close.Clip(3.8), skim.Clip(3.4)];
    }

    private static FaceClip[] Searching(double f)
    {
        var body = new FaceBody(Tip: -3);
        var eyes = new FaceEyes(Y: -0.2);

        var sides = new FaceScript(body, eyes);
        sides.Look(0.18, 0.09, FaceEase.Snappy, e => e with { X = -1, Wide = 0.25 });
        sides.Move(0.22, 0.34, FaceEase.Spring, b => b with { Turn = -28, X = -0.036, Roll = -6 });
        sides.Look(1.05, 0.09, FaceEase.Snappy, e => e with { X = 1, Wide = 0.25 });
        sides.Move(1.09, 0.42, FaceEase.Spring, b => b with { Turn = 28, X = 0.036, Roll = 6 });
        sides.Blink(1.85);
        sides.LookTo(2.25, 0.12, eyes, FaceEase.Snappy);
        sides.MoveTo(2.3, 0.48, body);

        var peer = new FaceScript(body, eyes);
        peer.Move(0.25, 0.42, b => b with { Tip = 13, Y = 0.028, Squash = 0.045 });
        peer.Look(0.25, 0.18, e => e with { Y = 0.48, Lids = 0.35 });
        peer.Look(1.05, 0.12, FaceEase.Snappy, e => e with { X = -0.9 * f });
        peer.Move(1.1, 0.36, FaceEase.Spring, b => b with { Turn = -16 * f, Roll = -3 * f });
        peer.Look(1.85, 0.12, FaceEase.Snappy, e => e with { X = 0.9 * f });
        peer.Move(1.9, 0.38, FaceEase.Spring, b => b with { Turn = 16 * f, Roll = 3 * f });
        peer.LookTo(2.75, 0.18, eyes);
        peer.MoveTo(2.8, 0.52, body);

        var up = new FaceScript(body, eyes);
        up.Look(0.2, 0.12, FaceEase.Snappy, e => e with { X = 0.8 * f, Y = -1, Wide = 0.3 });
        up.Move(0.24, 0.45, FaceEase.Spring, b => b with { Turn = 18 * f, Tip = -16, Roll = 4 * f });
        up.Look(1.1, 0.18, FaceEase.Glide, e => e with { X = -0.8 * f, Y = -0.95 });
        up.Move(1.15, 0.62, b => b with { Turn = -18 * f, Tip = -14, Roll = -4 * f });
        up.LookTo(2.15, 0.15, eyes);
        up.MoveTo(2.2, 0.5, body);

        var doubleTake = new FaceScript(body, eyes);
        doubleTake.Look(0.18, 0.1, FaceEase.Snappy, e => e with { X = -0.9 * f });
        doubleTake.Move(0.22, 0.34, FaceEase.Spring, b => b with { Turn = -20 * f, Roll = -4 * f });
        doubleTake.Look(0.85, 0.12, FaceEase.Snappy, e => e with { X = 0.6 * f });
        doubleTake.Move(0.88, 0.28, b => b with { Turn = 10 * f, Roll = 2 * f });
        doubleTake.Look(1.24, 0.08, FaceEase.Snappy, e => e with { X = -1 * f, Y = -0.05, Wide = 0.75, Tilt = -0.4 * f });
        doubleTake.Move(1.26, 0.3, FaceEase.Bouncy, b => b with { Turn = -26 * f, Roll = -8 * f, Y = -0.022, Squash = -0.04, Tip = 4 });
        doubleTake.Mark(1.42);
        doubleTake.Blink(2.2);
        doubleTake.LookTo(2.7, 0.16, eyes);
        doubleTake.MoveTo(2.75, 0.55, body);

        return [sides.Clip(3.1), peer.Clip(3.6), up.Clip(3.0), doubleTake.Clip(3.6)];
    }

    private static FaceClip[] Running(double f)
    {
        var body = new FaceBody(Tip: 6);
        var eyes = new FaceEyes(Y: 0.42, Lids: 0.28);

        var busy = new FaceScript(body, eyes);
        for (var beat = 0; beat < 4; beat++)
        {
            var t = 0.04 + beat * 0.56;
            var side = beat % 2 == 0 ? f : -f;
            busy.Move(t, 0.24, FaceEase.Drop, b => b with { Y = 0.038, Squash = 0.07, Roll = 4.5 * side, Tip = 10 });
            busy.MoveTo(t + 0.24, 0.30, body, FaceEase.Spring);
            busy.Mark(t + 0.24);
            if (beat is 0 or 2)
                busy.Look(t + 0.04, 0.14, FaceEase.Snappy, e => e with { X = 0.45 * side });
        }
        busy.LookTo(1.75, 0.16, eyes);
        busy.Blink(1.96);

        var check = new FaceScript(body, eyes);
        check.Look(0.32, 0.1, FaceEase.Snappy, e => e with { X = 0.95 * f, Y = -0.2, Lids = 0, Wide = 0.5 });
        check.Move(0.35, 0.38, FaceEase.Spring, b => b with { Turn = 22 * f, Roll = 5 * f, Tip = -2, Y = -0.015 });
        check.Blink(1.0);
        Nod(check, 1.25, depth: 7);
        check.LookTo(1.78, 0.12, eyes, FaceEase.Snappy);
        check.MoveTo(1.8, 0.32, body);
        double[] checkBeats = [2.14, 2.62];
        for (var i = 0; i < checkBeats.Length; i++)
        {
            var t = checkBeats[i];
            var side = i == 0 ? f : -f;
            check.Move(t, 0.22, FaceEase.Drop, b => b with { Y = 0.036, Squash = 0.068, Roll = 4 * side, Tip = 10 });
            check.MoveTo(t + 0.22, 0.26, body, FaceEase.Spring);
            check.Mark(t + 0.22);
        }

        var rev = new FaceScript(body, eyes);
        rev.Move(0.2, 0.38, b => b with { Tip = 12, Squash = 0.05, Y = 0.022 });
        rev.Look(0.2, 0.18, e => e with { Lids = 0.45, Y = 0.55, X = -0.65 * f });
        rev.Look(0.7, 0.22, FaceEase.Snappy, e => e with { X = 0.7 * f, Y = 0.35 });
        rev.Move(0.72, 0.34, b => b with { Turn = 10 * f, Roll = 3 * f });
        rev.Look(1.18, 0.22, FaceEase.Snappy, e => e with { X = -0.55 * f, Y = 0.65 });
        rev.Move(1.2, 0.34, b => b with { Turn = -10 * f, Roll = -3 * f });
        rev.Move(1.75, 0.26, FaceEase.Rise, b => b with { Tip = -1, Squash = -0.055, Y = -0.028, Turn = 0, Roll = 0 });
        rev.Look(1.75, 0.14, FaceEase.Snappy, e => e with { Lids = 0, Wide = 0.45, X = 0, Y = 0.1 });
        rev.Mark(1.9);
        rev.MoveTo(2.15, 0.52, body, FaceEase.Spring);
        rev.LookTo(2.2, 0.22, eyes);

        return [busy.Clip(2.4), check.Clip(3.2), rev.Clip(2.8)];
    }

    private static FaceClip[] Writing(double f)
    {
        var body = new FaceBody(Roll: -3, Turn: -8, Tip: 8);
        var eyes = new FaceEyes(X: -0.85, Y: 0.32, Lids: 0.28);

        FaceScript Typed(double tilt)
        {
            var script = new FaceScript(body, eyes);
            for (var line = 0; line < 2; line++)
            {
                var l = line;
                var t = l * LineLength;
                var rowY = l == 0 ? 0.32 : 0.65;
                script.Look(t + 0.05, LineLength - 0.16, FaceEase.Linear, e => e with { X = 0.88, Y = rowY });
                var half = (LineLength - 0.16) * 0.5;
                script.Move(t + 0.05, half, b => b with { Turn = 0, Roll = tilt * 0.3, Y = 0.014, Squash = 0.025 });
                script.Move(t + 0.05 + half, half, b => b with { Turn = 9, Roll = tilt, Y = 0, Squash = 0, Tip = 8 + l * 3 });
                if (l != 0) continue;
                script.Move(t + LineLength - 0.11, 0.11, FaceEase.Snappy, b => b with { Turn = -8, Roll = -tilt * 0.7, Tip = 11 });
                script.Look(t + LineLength - 0.09, 0.09, FaceEase.Snappy, e => e with { X = -0.85, Y = 0.65 });
            }
            return script;
        }

        const double end = 2 * LineLength;
        const double length = end + TypingPause;

        var plain = Typed(3);
        plain.LookTo(end, 0.16, eyes, FaceEase.Snappy);
        plain.MoveTo(end, 0.32, body, FaceEase.Spring);

        var pleased = Typed(6 * f);
        pleased.Look(end - 0.08, 0.1, FaceEase.Snappy, e => e with { Lids = 0, Wide = 0.45 });
        pleased.Move(end - 0.06, 0.1, FaceEase.Snappy, b => b with { Tip = 15, Y = 0.018, Squash = 0.035 });
        pleased.Mark(end + 0.04);
        pleased.LookTo(end + 0.06, 0.18, eyes);
        pleased.MoveTo(end + 0.04, 0.28, body, FaceEase.Spring);

        var revise = new FaceScript(body, eyes);
        revise.Look(0.05, 0.42, FaceEase.Linear, e => e with { X = 0.05, Y = 0.32 });
        revise.Move(0.05, 0.42, b => b with { Turn = 0, Roll = -7 * f });
        revise.Look(0.5, 0.14, e => e with { Lids = 0.52, Tilt = 0.35 * f });
        revise.Look(0.78, 0.5, FaceEase.Snappy, e => e with { X = 0.88, Lids = 0.28, Tilt = 0 });
        revise.Move(0.78, 0.5, FaceEase.Snappy, b => b with { Turn = 9, Roll = 4 * f });
        revise.Move(LineLength - 0.11, 0.11, FaceEase.Snappy, b => b with { Turn = -8, Roll = -3, Tip = 11 });
        revise.Look(LineLength - 0.09, 0.09, FaceEase.Snappy, e => e with { X = -0.85, Y = 0.65 });
        revise.Look(LineLength + 0.05, LineLength - 0.16, FaceEase.Linear, e => e with { X = 0.88, Y = 0.65 });
        revise.Move(LineLength + 0.05, LineLength - 0.16, b => b with { Turn = 9, Roll = 3, Tip = 11 });
        revise.LookTo(end, 0.16, eyes);
        revise.MoveTo(end, 0.32, body, FaceEase.Spring);

        return [plain.Clip(length), pleased.Clip(length), revise.Clip(length)];
    }

    private static FaceClip[] Browsing()
    {
        static (FaceBody Body, FaceEyes Eyes) At(P stop, double turn, double rollScale = 4.5)
        {
            var x = (stop.X - 0.5) * 2.6;
            var y = (stop.Y - 0.5) * 2.6;
            return (new FaceBody(Roll: x * rollScale, Turn: x * turn, Tip: y * 13), new FaceEyes(X: x, Y: y));
        }
        var last = Stops[^1];
        var home = At(last, 18);
        var clicks = new FaceScript(home.Body, home.Eyes);
        var follows = new FaceScript(home.Body, home.Eyes);
        var inspect = new FaceScript(home.Body, home.Eyes);
        for (var index = 0; index < Stops.Count; index++)
        {
            var stop = Stops[index];
            var t = index * StopLength;
            var (body, eyes) = At(stop, 18);
            clicks.LookTo(t, 0.24, eyes, FaceEase.Snappy);
            clicks.MoveTo(t + 0.02, 0.32, body, FaceEase.Spring);
            clicks.Move(t + 0.35, 0.07, FaceEase.Drop, b => b with { Squash = 0.065, Tip = body.Tip + 7, Y = 0.02 });
            clicks.Mark(t + 0.36);
            clicks.MoveTo(t + 0.42, 0.28, body, FaceEase.Bouncy);

            var (swung, looked) = At(stop, index == Stops.Count - 1 ? 18 : 26);
            follows.LookTo(t, 0.2, looked, FaceEase.Snappy);
            follows.MoveTo(t + 0.06, 0.46, swung, FaceEase.Spring);
            if (index == 1) follows.Blink(t + 0.6);

            var (tilted, gazed) = At(stop, 18, index == Stops.Count - 1 ? 4.5 : 8.5);
            var idx = index;
            inspect.Look(t, 0.22, FaceEase.Snappy, _ =>
                idx is 1 or 2 ? gazed with { Lids = 0.32, Tilt = 0.35 * (gazed.X >= 0 ? 1 : -1) } : gazed);
            inspect.MoveTo(t + 0.04, 0.34, tilted, FaceEase.Spring);
            if (index < Stops.Count - 1)
            {
                inspect.Look(t + 0.42, 0.1, FaceEase.Snappy, e => e with { Lids = 0, Wide = 0.4, Tilt = 0 });
                inspect.Move(t + 0.42, 0.07, FaceEase.Drop, b => b with { Squash = 0.055, Y = 0.015 });
                inspect.Mark(t + 0.43);
                inspect.MoveTo(t + 0.49, 0.28, tilted, FaceEase.Spring);
            }
        }
        var length = Stops.Count * StopLength;
        return [clicks.Clip(length), follows.Clip(length), inspect.Clip(length)];
    }

    private static FaceClip[] Messaging(double f)
    {
        var body = new FaceBody(X: 0.025 * f, Roll: 4 * f, Turn: 24 * f);
        var eyes = new FaceEyes(X: f);

        var send = new FaceScript(body, eyes);
        foreach (var t in new[] { 0.3, 1.55 })
        {
            send.Move(t, 0.22, FaceEase.Glide, b => b with { X = -0.02 * f, Turn = 10 * f, Squash = -0.06, Tip = -7, Roll = -3 * f });
            send.Look(t, 0.16, e => e with { Wide = 0.35 });
            send.Move(t + 0.22, 0.13, FaceEase.Drop, b => b with { X = 0.068 * f, Turn = 32 * f, Squash = 0.065, Tip = 8, Roll = 7 * f });
            send.Look(t + 0.22, 0.12, e => e with { Wide = 0, Lids = 0.2 });
            send.Mark(t + 0.35);
            send.MoveTo(t + 0.35, 0.5, body, FaceEase.Bouncy);
            send.LookTo(t + 0.38, 0.18, eyes);
            if (t < 1.0) send.Blink(1.08);
        }

        var back = new FaceScript(body, eyes);
        back.Look(0.62, 0.14, FaceEase.Snappy, e => e with { X = 0, Wide = 0.4 });
        back.Move(0.66, 0.46, FaceEase.Spring, b => b with { Turn = 0, X = 0, Roll = -3 * f, Tip = -2 });
        back.DoubleBlink(1.25);
        back.LookTo(1.98, 0.14, eyes, FaceEase.Snappy);
        back.MoveTo(2.02, 0.52, body, FaceEase.Spring);

        var listen = new FaceScript(body, eyes);
        listen.Move(0.2, 0.4, FaceEase.Spring, b => b with { Turn = 28 * f, Roll = 9 * f, Tip = -4 });
        listen.Look(0.2, 0.18, e => e with { Wide = 0.35, Tilt = 0.25 * f });
        Nod(listen, 0.7, depth: 8);
        Nod(listen, 1.32, depth: 7);
        listen.Move(1.95, 0.16, FaceEase.Drop, b => b with { X = 0.06 * f, Squash = 0.055, Tip = 6 });
        listen.Mark(2.1);
        listen.MoveTo(2.12, 0.52, body, FaceEase.Spring);
        listen.LookTo(2.12, 0.2, eyes);

        return [send.Clip(2.8), back.Clip(3.0), listen.Clip(3.0)];
    }

    private static FaceClip[] Making(double f)
    {
        var body = new FaceBody(Tip: -5);
        var eyes = new FaceEyes(Y: -0.55);

        var wiggle = new FaceScript(body, eyes);
        wiggle.Move(0.22, 0.28, FaceEase.Spring, b => b with { Roll = -13 * f, Y = 0.02, Squash = 0.045, Turn = -8 * f });
        wiggle.Look(0.22, 0.12, FaceEase.Snappy, e => e with { X = -0.6 * f, Wide = 0.4 });
        wiggle.Move(0.55, 0.34, FaceEase.Spring, b => b with { Roll = 13 * f, Y = -0.022, Squash = -0.045, Turn = 8 * f });
        wiggle.Look(0.58, 0.12, FaceEase.Snappy, e => e with { X = 0.6 * f, Wide = 0.45 });
        wiggle.Move(0.95, 0.32, FaceEase.Spring, b => b with { Roll = -10 * f, Y = 0.015, Squash = 0.035, Turn = -6 * f });
        wiggle.Look(0.98, 0.12, FaceEase.Snappy, e => e with { X = -0.4 * f });
        wiggle.MoveTo(1.32, 0.48, body, FaceEase.Bouncy);
        wiggle.LookTo(1.36, 0.18, eyes);

        var bounce = new FaceScript(body, eyes);
        bounce.Look(0.25, 0.14, e => e with { Wide = 0.6, Y = -0.7 });
        Hop(bounce, 0.18, height: 0.095, roll: 7 * f);
        bounce.LookTo(0.85, 0.16, eyes);
        bounce.Look(1.22, 0.14, e => e with { Wide = 0.65, Y = -0.7 });
        Hop(bounce, 1.15, height: 0.095, roll: -7 * f);
        bounce.LookTo(1.85, 0.18, eyes);

        var admire = new FaceScript(body, eyes);
        admire.Move(0.24, 0.5, FaceEase.Spring, b => b with { Turn = 24 * f, Roll = 7 * f, X = 0.02 * f });
        admire.Look(0.24, 0.15, FaceEase.Snappy, e => e with { X = 0.75 * f, Lids = 0.22, Tilt = 0.3 * f });
        admire.Move(1.12, 0.6, FaceEase.Spring, b => b with { Turn = -24 * f, Roll = -7 * f, X = -0.02 * f });
        admire.Look(1.15, 0.15, FaceEase.Snappy, e => e with { X = -0.75 * f, Lids = 0.22, Tilt = -0.3 * f });
        admire.Move(1.98, 0.24, FaceEase.Rise, b => b with { Turn = 0, Roll = 0, X = 0, Tip = -11, Squash = -0.065, Y = -0.028 });
        admire.Look(1.96, 0.14, FaceEase.Snappy, e => e with { X = 0, Lids = 0, Wide = 0.7, Tilt = 0 });
        admire.MoveTo(2.28, 0.48, body, FaceEase.Spring);
        admire.LookTo(2.35, 0.2, eyes);

        var flourish = new FaceScript(body, eyes);
        flourish.Move(0.2, 0.55, b => b with { Turn = 16 * f, Tip = -12, Roll = 8 * f, Y = -0.02 });
        flourish.Look(0.2, 0.2, e => e with { X = 0.6 * f, Y = -0.85, Wide = 0.35 });
        flourish.Move(0.85, 0.6, b => b with { Turn = -16 * f, Tip = 2, Roll = -8 * f, Y = 0.015 });
        flourish.Look(0.85, 0.2, e => e with { X = -0.6 * f, Y = -0.25 });
        flourish.Move(1.55, 0.5, b => b with { Turn = 10 * f, Tip = -10, Roll = 5 * f, Y = -0.015 });
        flourish.Look(1.55, 0.2, e => e with { X = 0.4 * f, Y = -0.75 });
        flourish.MoveTo(2.15, 0.5, body, FaceEase.Spring);
        flourish.LookTo(2.15, 0.2, eyes);

        return [wiggle.Clip(2.3), bounce.Clip(2.4), admire.Clip(3.0), flourish.Clip(2.8)];
    }

    private static FaceClip[] Replying(double f)
    {
        var along = new FaceScript();
        Nod(along, 0.15, depth: 12);
        Nod(along, 0.72, depth: 8);
        Nod(along, 1.3, depth: 11);
        along.Blink(1.98);

        var sway = new FaceScript();
        sway.Move(0.12, 0.72, b => b with { Turn = 14 * f, Roll = 6 * f, Tip = -2 });
        sway.Look(0.18, 0.24, e => e with { X = 0.45 * f, Wide = 0.2 });
        Nod(sway, 1.02, depth: 10);
        sway.Look(1.56, 0.14, FaceEase.Snappy, e => e with { X = 0.8 * f });
        sway.MoveTo(1.88, 0.78, FaceBody.Rest, FaceEase.Spring);
        sway.LookTo(1.94, 0.26, FaceEyes.Rest);
        sway.Blink(2.5);

        var bright = new FaceScript();
        bright.Look(0.22, 0.12, FaceEase.Snappy, e => e with { Y = -0.55, Wide = 0.75 });
        bright.Move(0.24, 0.32, FaceEase.Bouncy, b => b with { Squash = -0.075, Tip = -9, Y = -0.036 });
        bright.MoveTo(0.86, 0.34, FaceBody.Rest);
        bright.LookTo(0.9, 0.18, FaceEyes.Rest);
        Nod(bright, 1.32, depth: 12);
        bright.Blink(1.92);

        var explain = new FaceScript();
        explain.Move(0.18, 0.55, FaceEase.Spring, b => b with { Turn = -14 * f, Roll = -5 * f, Tip = 4 });
        explain.Look(0.2, 0.18, e => e with { X = -0.35 * f, Wide = 0.2 });
        explain.Mark(0.55);
        explain.Move(1.05, 0.6, FaceEase.Spring, b => b with { Turn = 14 * f, Roll = 5 * f, Tip = 3 });
        explain.Look(1.08, 0.18, e => e with { X = 0.35 * f, Wide = 0.25 });
        explain.Mark(1.45);
        explain.MoveTo(1.86, 0.5, FaceBody.Rest, FaceEase.Spring);
        explain.LookTo(1.9, 0.22, FaceEyes.Rest);
        Nod(explain, 2.38, depth: 8);

        return [along.Clip(2.4), sway.Clip(3.0), bright.Clip(2.3), explain.Clip(3.0)];
    }

    private static FaceClip[] Asking(double f)
    {
        var body = new FaceBody(Roll: -11 * f, Tip: -4);
        var eyes = new FaceEyes(Y: -0.15, Wide: 0.25, Tilt: 0.25 * f);

        var hops = new FaceScript(body, eyes);
        hops.Blink(0.28);
        hops.Look(0.82, 0.14, e => e with { Wide = 0.75, Y = -0.25 });
        hops.Mark(Hop(hops, 0.75, height: 0.085));
        hops.Look(1.48, 0.14, e => e with { Wide = 0.8, Y = -0.28 });
        hops.Mark(Hop(hops, 1.42, height: 0.085));
        hops.LookTo(2.05, 0.16, eyes);
        hops.Blink(2.22);

        var tilt = new FaceScript(body, eyes);
        tilt.Move(0.55, 0.52, FaceEase.Bouncy, b => b with { Roll = 12 * f, Turn = 10 * f, Tip = -6 });
        tilt.Look(0.55, 0.18, FaceEase.Snappy, e => e with { X = 0.38 * f, Wide = 0.6, Tilt = -0.45 * f });
        tilt.Blink(1.45);
        tilt.MoveTo(2.05, 0.55, body, FaceEase.Bouncy);
        tilt.LookTo(2.05, 0.2, eyes);

        var curious = new FaceScript(body, eyes);
        curious.Move(0.35, 0.5, FaceEase.Spring, b => b with { Roll = -15 * f, Tip = -9, Squash = -0.06, Y = -0.028 });
        curious.Look(0.35, 0.18, e => e with { Wide = 0.85, Y = -0.22, Tilt = 0.45 * f });
        curious.DoubleBlink(1.15);
        curious.MoveTo(2.05, 0.52, body, FaceEase.Spring);
        curious.LookTo(2.05, 0.22, eyes);

        return [hops.Clip(2.6), tilt.Clip(3.2), curious.Clip(2.8)];
    }

    private enum DoneTrick { Plain, Cartwheel, Pirouette }

    private static FaceClip[] Done(double f)
    {
        FaceClip Jump(DoneTrick trick)
        {
            var spinRoll = trick == DoneTrick.Cartwheel ? 360 * f : 0;
            var spinTurn = trick == DoneTrick.Pirouette ? 360 * f : 0;
            var script = new FaceScript();
            script.Look(0.04, 0.14, FaceEase.Snappy, e => e with { Y = -0.65, Wide = 0.85 });
            script.Move(0, 0.16, FaceEase.Glide, b => b with { Squash = 0.11, Y = 0.02 });
            script.Move(0.16, 0.26, FaceEase.Rise, b => b with
            {
                Y = -0.19, Squash = -0.095, Tip = -10, Roll = spinRoll * 0.55, Turn = spinTurn * 0.55,
            });
            script.Move(0.42, 0.24, FaceEase.Drop, b => b with
            {
                Y = 0, Squash = 0.11, Tip = 2, Roll = spinRoll, Turn = spinTurn,
            });
            script.Mark(0.66);
            script.Move(0.66, 0.3, FaceEase.Spring, b => b with { Squash = 0, Tip = 0 });
            script.Move(1.0, 0.34, b => b with { Tip = -9, Roll = spinRoll + 7 * f });
            script.Move(1.58, 0.42, FaceEase.Glide, b => b with { Tip = 0, Roll = spinRoll, Turn = spinTurn });
            script.Look(0.78, 0.2, FaceEase.Glide, e => e with { Y = 0, Wide = 0.3 });
            script.DoubleBlink(1.10);
            script.LookTo(1.70, 0.22, FaceEyes.Rest, FaceEase.Glide);
            return script.Clip(BotMood.Done.Length());
        }
        return [Jump(DoneTrick.Plain), Jump(DoneTrick.Cartwheel), Jump(DoneTrick.Pirouette)];
    }

    private static FaceClip[] Failed(double f)
    {
        var shake = new FaceScript();
        shake.Look(0, 0.1, FaceEase.Drop, e => e with { Lids = 0.95 });
        shake.Move(0.02, 0.15, FaceEase.Snappy, b => b with { X = -0.036 * f, Turn = -22 * f, Roll = -6 * f });
        shake.Move(0.17, 0.19, FaceEase.Snappy, b => b with { X = 0.036 * f, Turn = 20 * f, Roll = 6 * f });
        shake.Move(0.36, 0.17, FaceEase.Snappy, b => b with { X = -0.018 * f, Turn = -10 * f, Roll = -3 * f });
        shake.Move(0.53, 0.16, b => b with { X = 0, Turn = 0, Roll = 0 });
        shake.Move(0.7, 0.36, b => b with { Tip = 17, Y = 0.045, Squash = 0.065 });
        shake.Look(0.72, 0.26, e => e with { Y = 0.65, Lids = 0.52 });
        shake.MoveTo(1.18, 0.36, FaceBody.Rest, FaceEase.Glide);
        shake.LookTo(1.22, 0.26, FaceEyes.Rest, FaceEase.Glide);

        var recoil = new FaceScript();
        recoil.Look(0, 0.09, FaceEase.Drop, e => e with { Lids = 0.95 });
        recoil.Move(0.02, 0.14, FaceEase.Rise, b => b with { Y = -0.04, Tip = -10, Squash = -0.05, X = -0.024 * f, Turn = -14 * f });
        recoil.Move(0.16, 0.16, FaceEase.Snappy, b => b with { Y = 0, Tip = 0, Squash = 0.03, X = 0.028 * f, Turn = 16 * f, Roll = 4 * f });
        recoil.Move(0.32, 0.16, FaceEase.Snappy, b => b with { X = -0.016 * f, Turn = -9 * f, Roll = -2 * f, Squash = 0 });
        recoil.Move(0.48, 0.16, b => b with { X = 0, Turn = 0, Roll = 0 });
        recoil.Move(0.68, 0.36, b => b with { Tip = 16, Roll = 9 * f, Y = 0.042, Squash = 0.06 });
        recoil.Look(0.7, 0.26, e => e with { Y = 0.6, Lids = 0.5, Tilt = -0.3 * f });
        recoil.MoveTo(1.18, 0.36, FaceBody.Rest, FaceEase.Glide);
        recoil.LookTo(1.22, 0.26, FaceEyes.Rest, FaceEase.Glide);

        return [shake.Clip(BotMood.Failed.Length()), recoil.Clip(BotMood.Failed.Length())];
    }
}

/// One sampled moment of a face's routine.
public readonly record struct FaceSample(double At, FaceBody Body, FaceEyes Eyes);

/// The routines one face plays for a mood, in its own shuffled order: twice through, never the same one twice running,
/// or the one routine of a once-only mood. Faces given the same seed play in lockstep.
public sealed class FaceLoop
{
    public BotMood Mood { get; }
    public IReadOnlyList<FaceClip> Clips { get; }
    /// When each routine starts.
    public IReadOnlyList<double> Starts { get; }
    public double Period { get; }

    public FaceLoop(BotMood mood, int facing, int seed)
    {
        Mood = mood;
        var all = FaceRoutines.Clips(mood, facing);
        var dice = new MatrixActDice(seed);
        List<int> order;
        if (mood.IsOnce() || all.Count == 1)
        {
            order = [dice.NextInt(0, all.Count)];
        }
        else
        {
            List<int> Shuffled()
            {
                var picks = Enumerable.Range(0, all.Count).ToList();
                for (var i = picks.Count - 1; i >= 0; i--)
                {
                    var j = dice.NextInt(0, i + 1);
                    (picks[i], picks[j]) = (picks[j], picks[i]);
                }
                return picks;
            }
            var first = Shuffled();
            var second = Shuffled();
            for (var tries = 0; tries < 12 && (second[0] == first[^1] || second[^1] == first[0]); tries++)
                second = Shuffled();
            order = [.. first, .. second];
        }
        var clips = new List<FaceClip>(order.Count);
        var starts = new List<double>(order.Count);
        var clock = 0.0;
        foreach (var idx in order)
        {
            var clip = all[idx];
            clips.Add(clip);
            starts.Add(clock);
            clock += clip.Length;
        }
        Clips = clips;
        Starts = starts;
        Period = clock;
    }

    /// Every beat a light may flash on, in loop time.
    public IReadOnlyList<double> Marks
    {
        get
        {
            var list = new List<double>();
            for (var i = 0; i < Clips.Count; i++)
                foreach (var m in Clips[i].Marks) list.Add(m + Starts[i]);
            return list;
        }
    }

    /// The pose `t` seconds in (wrapping round).
    public (FaceBody Body, FaceEyes Eyes) PoseAt(double t)
    {
        if (Period <= 0 || Clips.Count == 0) return (FaceBody.Rest, FaceEyes.Rest);
        var u = t % Period;
        if (u < 0) u += Period;
        var index = 0;
        for (var i = Starts.Count - 1; i >= 0; i--)
        {
            if (Starts[i] <= u) { index = i; break; }
        }
        var local = u - Starts[index];
        return (Clips[index].BodyAt(local), Clips[index].EyesAt(local));
    }

    /// The loop sampled about `rate` times a second, each routine on its own even steps.
    public List<FaceSample> Samples(double rate = 30)
    {
        var list = new List<FaceSample>();
        for (var i = 0; i < Clips.Count; i++)
        {
            var clip = Clips[i];
            var start = Starts[i];
            foreach (var t in clip.Times(rate))
            {
                if (list.Count == 0 || start + t > list[^1].At + 1e-9)
                    list.Add(new FaceSample(start + t, clip.BodyAt(t), clip.EyesAt(t)));
            }
        }
        if (list.Count > 0)
        {
            list[0] = list[0] with { At = 0 };
            list[^1] = list[^1] with { At = Period };
        }
        return list;
    }

    /// Linearly interpolated pose at `t` in `samples` (`period` long), wrapping when `!once` and clamping when `once`.
    public static (FaceBody Body, FaceEyes Eyes) Interpolated(IReadOnlyList<FaceSample> samples, double t, double period, bool once)
    {
        if (samples.Count == 0) return (FaceBody.Rest, FaceEyes.Rest);
        if (samples.Count == 1 || period <= 0) return (samples[0].Body, samples[0].Eyes);
        var u = once ? Math.Clamp(t, 0, period) : t % period;
        if (u < 0) u += period;
        if (u <= samples[0].At) return (samples[0].Body, samples[0].Eyes);
        var last = samples.Count - 1;
        if (u >= samples[last].At) return (samples[last].Body, samples[last].Eyes);
        int low = 0, high = last;
        while (low + 1 < high)
        {
            var mid = (low + high) >> 1;
            if (samples[mid].At <= u) low = mid;
            else high = mid;
        }
        var a = samples[low];
        var b = samples[high];
        var span = b.At - a.At;
        var k = span > 1e-12 ? (u - a.At) / span : 0;
        return (a.Body.Mixed(b.Body, k), a.Eyes.Mixed(b.Eyes, k));
    }

    /// Uniformly spaced `(At, Turn, Tip)` poses at `rate` Hz over `period`.
    public static List<(double At, double Turn, double Tip)> UniformPoses(IReadOnlyList<FaceSample> samples, double period,
        double rate = 30, bool once = false)
    {
        if (samples.Count <= 1 || period <= 0)
            return [.. samples.Select(s => (s.At, s.Body.Turn, s.Body.Tip))];
        var steps = Math.Max(1, (int)Math.Round(period * rate, MidpointRounding.AwayFromZero));
        var output = new List<(double, double, double)>(steps + 1);
        for (var k = 0; k <= steps; k++)
        {
            var at = k == steps ? period : period * k / steps;
            if (!once && k == steps)
                output.Add((period, output[0].Item2, output[0].Item3));
            else
            {
                var pose = Interpolated(samples, at, period, once);
                output.Add((at, pose.Body.Turn, pose.Body.Tip));
            }
        }
        return output;
    }

    public List<FaceSample> SoftSamples(double rate = 60) => SoftSamples(Mood.IsOnce(), rate);

    /// Two-stage cascaded critically damped C³ spring at `rate` Hz (60 Hz default) with harmonic breathing & sway,
    /// once-only quintic rest settle, and bit-exact periodic closure at `t = 0` and `t = Period`.
    public List<FaceSample> SoftSamples(bool once, double rate = 60)
    {
        var raw = Samples(rate);
        if (raw.Count <= 1) return raw;

        var targets = new double[raw.Count][];
        for (var i = 0; i < raw.Count; i++)
        {
            var s = raw[i];
            targets[i] =
            [
                s.Body.X, s.Body.Y, s.Body.Roll, s.Body.Turn, s.Body.Tip, s.Body.Squash,
                s.Eyes.X, s.Eyes.Y, s.Eyes.Wide, s.Eyes.Tilt,
            ];
        }
        for (var i = 1; i < targets.Length; i++)
        {
            for (var c = 2; c <= 4; c++)
            {
                while (targets[i][c] - targets[i - 1][c] > 180.0) targets[i][c] -= 360.0;
                while (targets[i][c] - targets[i - 1][c] < -180.0) targets[i][c] += 360.0;
            }
        }
        for (var i = 0; i < targets.Length; i++)
        {
            targets[i][6] += targets[i][3] / FaceEyes.Across;
            targets[i][7] += targets[i][4] / FaceEyes.Down;
        }
        var targetWrap = new double[10];
        for (var c = 0; c < 10; c++) targetWrap[c] = targets[^1][c] - targets[0][c];

        double[] baseFreq = [4.4, 4.4, 2.8, 2.8, 2.8, 4.4, 6.2, 6.2, 5.2, 4.6];
        double[] baseFreq2 = [6.8, 6.8, 4.8, 4.8, 4.8, 6.8, 9.5, 9.5, 8.0, 7.2];
        var omega = baseFreq.Select(f => 2.0 * Math.PI * f).ToArray();
        var omega2 = baseFreq2.Select(f => 2.0 * Math.PI * f).ToArray();
        int[] angleChannels = [2, 3, 4, 6, 7];

        double[][] Filter(double[][] input, double[] freq)
        {
            var wrap = new double[10];
            for (var c = 0; c < 10; c++) wrap[c] = input[^1][c] - input[0][c];
            var at = (double[])input[0].Clone();
            var speed = new double[10];
            var res = new double[raw.Count][];

            void Step(int idx)
            {
                var dt = raw[idx + 1].At - raw[idx].At;
                if (dt <= 0) return;
                var t0 = input[idx];
                var t1 = input[idx + 1];
                for (var c = 0; c < 10; c++)
                {
                    var w = freq[c];
                    var e = Math.Exp(-w * dt);
                    var m = 0.5 * (t0[c] + t1[c]);
                    var dx = at[c] - m;
                    var c2 = speed[c] + w * dx;
                    at[c] = m + (dx + c2 * dt) * e;
                    speed[c] = (speed[c] - w * c2 * dt) * e;
                }
            }

            if (!once)
            {
                var warmup = Math.Min(Period, 3.2);
                var warmStart = 0;
                for (var i = 0; i < raw.Count; i++)
                {
                    if (raw[i].At >= Period - warmup) { warmStart = i; break; }
                }
                at = (double[])input[warmStart].Clone();
                for (var i = warmStart; i < raw.Count - 1; i++) Step(i);
                foreach (var c in angleChannels) at[c] -= wrap[c];
                if (Period < 3.2)
                {
                    for (var i = 0; i < raw.Count - 1; i++) Step(i);
                    foreach (var c in angleChannels) at[c] -= wrap[c];
                }
            }

            for (var i = 0; i < raw.Count - 1; i++)
            {
                res[i] = (double[])at.Clone();
                Step(i);
            }

            if (!once)
            {
                var closed = (double[])res[0].Clone();
                foreach (var c in angleChannels) closed[c] += wrap[c];
                res[raw.Count - 1] = closed;
            }
            else
            {
                res[raw.Count - 1] = (double[])at.Clone();
            }
            return res;
        }

        var stage1 = Filter(targets, omega);
        var filtered = Filter(stage1, omega2);

        if (once)
        {
            var finalTarget = targets[^1];
            var settleWindow = Math.Min(0.32, Period * 0.25);
            var settleStart = Period - settleWindow;
            for (var i = 0; i < raw.Count; i++)
            {
                if (raw[i].At <= settleStart) continue;
                var w = FaceBody.Quintic((raw[i].At - settleStart) / Math.Max(settleWindow, 1e-6));
                for (var c = 0; c < 10; c++) filtered[i][c] += (finalTarget[c] - filtered[i][c]) * w;
            }
            filtered[^1] = (double[])finalTarget.Clone();
        }

        var breaths = once ? 0.0 : Math.Max(1.0, Math.Round(Period / 3.4, MidpointRounding.AwayFromZero));
        var lastIndex = raw.Count - 1;
        var baseSway = once ? 0.0 : Math.Sin(0.65);
        var result = new List<FaceSample>(raw.Count);
        for (var i = 0; i < raw.Count; i++)
        {
            var sample = raw[i];
            var c = filtered[i];
            var seam = !once && (i == 0 || i == lastIndex);
            var phase = Period > 0 ? 2.0 * Math.PI * breaths * sample.At / Period : 0.0;
            var breath = seam ? 0.0 : Math.Sin(phase);
            var sway = once ? 0.0 : (seam ? baseSway : Math.Sin(phase + 0.65));
            result.Add(new FaceSample(
                sample.At,
                new FaceBody(
                    X: c[0],
                    Y: c[1] - 0.004 * breath,
                    Roll: c[2] + 0.8 * sway,
                    Turn: c[3],
                    Tip: c[4] - 0.5 * breath,
                    Squash: c[5] - 0.015 * breath),
                new FaceEyes(
                    X: c[6] - c[3] / FaceEyes.Across,
                    Y: c[7] - c[4] / FaceEyes.Down,
                    Lids: sample.Eyes.Lids,
                    Wide: c[8],
                    Tilt: c[9])));
        }
        if (!once && result.Count > 1)
        {
            var first = result[0];
            var endBody = first.Body with
            {
                Roll = first.Body.Roll + targetWrap[2],
                Turn = first.Body.Turn + targetWrap[3],
                Tip = first.Body.Tip + targetWrap[4],
            };
            result[lastIndex] = new FaceSample(Period, endBody, first.Eyes);
        }
        return result;
    }
}

/// 0.82-damped plush secondary squash & lean following the body's motion (zero ringing).
public readonly record struct FaceJelly(double Squash = 0.0, double Lean = 0.0)
{
    public static readonly FaceJelly Rest = new();
    public const double Damping = 0.82;

    public static List<FaceJelly> Follow(IReadOnlyList<FaceSample> samples, double period, bool once)
    {
        if (samples.Count <= 1) return [.. samples.Select(_ => Rest)];
        const double degree = Math.PI / 180.0;
        const double omega = 2.0 * Math.PI * 2.0;
        const double damping = Damping;

        var n = samples.Count - 1;
        var rawSpeeds = new (double Stretch, double Down, double Across, double Swing)[n];
        for (var i = 0; i < n; i++)
        {
            var a = samples[i];
            var b = samples[i + 1];
            var span = Math.Max(b.At - a.At, 1e-6);
            var vy = (b.Body.Y - a.Body.Y) / span;
            var stretch = -0.075 * (Math.Sqrt(vy * vy + 0.01) - 0.1);
            var down = ((b.Body.Squash - a.Body.Squash) * 1.45 + (b.Body.Tip - a.Body.Tip) * degree * 0.55) / span;
            var across = (b.Body.X - a.Body.X) * 4.5 / span;
            var swing = ((b.Body.Roll - a.Body.Roll) * 2.2 + (b.Body.Turn - a.Body.Turn) * 1.05) * degree / span;
            rawSpeeds[i] = (stretch, down, across, swing);
        }

        // Light 3-tap velocity smoothing eliminates finite-difference noise before differentiation.
        var speeds = new (double Stretch, double Down, double Across, double Swing)[n];
        for (var i = 0; i < n; i++)
        {
            var p = rawSpeeds[once ? Math.Max(0, i - 1) : (i - 1 + n) % n];
            var c = rawSpeeds[i];
            var q = rawSpeeds[once ? Math.Min(n - 1, i + 1) : (i + 1) % n];
            speeds[i] = (
                0.25 * p.Stretch + 0.5 * c.Stretch + 0.25 * q.Stretch,
                0.25 * p.Down + 0.5 * c.Down + 0.25 * q.Down,
                0.25 * p.Across + 0.5 * c.Across + 0.25 * q.Across,
                0.25 * p.Swing + 0.5 * c.Swing + 0.25 * q.Swing);
        }

        double squashAt = 0.0, squashSpeed = 0.0;
        double leanAt = 0.0, leanSpeed = 0.0;
        var before = once ? (Stretch: 0.0, Down: 0.0, Across: 0.0, Swing: 0.0) : speeds[n - 1];

        void Advance(int idx)
        {
            var speed = speeds[idx];
            squashSpeed -= speed.Down - before.Down;
            leanSpeed -= (speed.Across - before.Across) + (speed.Swing - before.Swing);
            before = speed;
            var span = samples[idx + 1].At - samples[idx].At;
            var steps = Math.Max(1, (int)Math.Ceiling(span * 120.0));
            var dt = span / steps;
            for (var s = 0; s < steps; s++)
            {
                squashSpeed += (-omega * omega * (squashAt - speed.Stretch) - 2.0 * damping * omega * squashSpeed) * dt;
                squashAt += squashSpeed * dt;
                leanSpeed += (-omega * omega * leanAt - 2.0 * damping * omega * leanSpeed) * dt;
                leanAt += leanSpeed * dt;
            }
        }

        if (!once)
        {
            var warmup = Math.Min(period, 4.2);
            var warmStart = 0;
            for (var i = 0; i < samples.Count; i++)
            {
                if (samples[i].At >= period - warmup) { warmStart = i; break; }
            }
            if (warmStart >= n) warmStart = 0;
            before = speeds[(warmStart - 1 + n) % n];
            for (var i = warmStart; i < n; i++) Advance(i);
            if (period < 4.2)
                for (var i = 0; i < n; i++) Advance(i);
        }

        var raw = new FaceJelly[samples.Count];
        for (var i = 0; i < n; i++)
        {
            raw[i] = new FaceJelly(squashAt, leanAt);
            Advance(i);
        }
        raw[n] = !once ? raw[0] : new FaceJelly(squashAt, leanAt);

        static double Limit(double v, double most) => most * Math.Tanh(v / most);
        var result = new List<FaceJelly>(samples.Count);
        for (var i = 0; i < samples.Count; i++)
        {
            var fade = once ? FaceBody.Quintic((period - samples[i].At) / 0.4) : 1.0;
            var j = raw[i];
            result.Add(new FaceJelly(
                Limit(j.Squash, j.Squash < 0 ? 0.16 : 0.2) * fade,
                Limit(j.Lean, 0.14) * fade));
        }
        if (!once && result.Count > 1) result[^1] = result[0];
        return result;
    }

    public static FaceJelly Interpolated(IReadOnlyList<FaceJelly> wobble, IReadOnlyList<FaceSample> samples,
        double t, double period, bool once)
    {
        if (wobble.Count != samples.Count || wobble.Count == 0) return Rest;
        if (wobble.Count == 1 || period <= 0) return wobble[0];
        var u = once ? Math.Clamp(t, 0, period) : t % period;
        if (u < 0) u += period;
        if (u <= samples[0].At) return wobble[0];
        var last = samples.Count - 1;
        if (u >= samples[last].At) return wobble[last];
        int low = 0, high = last;
        while (low + 1 < high)
        {
            var mid = (low + high) >> 1;
            if (samples[mid].At <= u) low = mid;
            else high = mid;
        }
        var span = samples[high].At - samples[low].At;
        var k = span > 1e-12 ? (u - samples[low].At) / span : 0;
        var a = wobble[low];
        var b = wobble[high];
        return new FaceJelly(a.Squash + (b.Squash - a.Squash) * k, a.Lean + (b.Lean - a.Lean) * k);
    }

    /// How far a box (the eyes) can move in each direction and stay `margin` inside the outline.
    public static (double Left, double Right, double Up, double Down) Room(double minX, double minY, double maxX, double maxY,
        IReadOnlyList<P> outline, double margin)
    {
        if (outline.Count <= 2) return (0, 0, 0, 0);
        var edge = HeadGeometry.Spline(outline).Dense;
        if (edge.Count <= 2) return (0, 0, 0, 0);
        var midX = (minX + maxX) * 0.5;
        var midY = (minY + maxY) * 0.5;

        List<double> Xs(double y)
        {
            var hits = new List<double>();
            for (var i = 0; i < edge.Count; i++)
            {
                var a = edge[i];
                var b = edge[(i + 1) % edge.Count];
                if (a.Y != b.Y && (a.Y - y) * (b.Y - y) <= 0)
                    hits.Add(a.X + (y - a.Y) / (b.Y - a.Y) * (b.X - a.X));
            }
            return hits;
        }

        List<double> Ys(double x)
        {
            var hits = new List<double>();
            for (var i = 0; i < edge.Count; i++)
            {
                var a = edge[i];
                var b = edge[(i + 1) % edge.Count];
                if (a.X != b.X && (a.X - x) * (b.X - x) <= 0)
                    hits.Add(a.Y + (x - a.X) / (b.X - a.X) * (b.Y - a.Y));
            }
            return hits;
        }

        double[] rows = [minY, midY, maxY];
        double[] cols = [minX, midX, maxX];
        var right = rows.Min(y => (Xs(y).Where(x => x > midX).DefaultIfEmpty(maxX).Min()) - maxX);
        var left = rows.Min(y => minX - (Xs(y).Where(x => x < midX).DefaultIfEmpty(minX).Max()));
        var up = cols.Min(x => minY - (Ys(x).Where(y => y < midY).DefaultIfEmpty(minY).Max()));
        var down = cols.Min(x => (Ys(x).Where(y => y > midY).DefaultIfEmpty(maxY).Min()) - maxY);
        return (Math.Max(left - margin, 0), Math.Max(right - margin, 0), Math.Max(up - margin, 0), Math.Max(down - margin, 0));
    }
}

/// 3D cushion geometry for a Shapes head (72 angular bins, 25 rings): turns/tips smoothly in 3D space.
public sealed class FaceSolid
{
    public const int Bins = 72;
    private const double Fullness = 0.72;
    private static readonly (double X, double Y)[] Rays = Enumerable.Range(0, Bins).Select(b =>
    {
        var a = 2.0 * Math.PI * b / Bins;
        return (Math.Cos(a), Math.Sin(a));
    }).ToArray();

    public P Middle { get; }
    public double Depth { get; }
    public double[] Rest { get; }
    private readonly (double X, double Y, double Z)[][] _rings;
    private readonly double _side;

    public FaceSolid(IReadOnlyList<P> outline, double side)
    {
        var count = Math.Max(outline.Count, 1);
        Middle = new P(outline.Sum(p => p.X) / count, outline.Sum(p => p.Y) / count);
        var dense = outline.Count > 2 ? (IReadOnlyList<P>)HeadGeometry.Spline(outline).Dense : outline;
        var stride = Math.Max(1, dense.Count / 72);
        var edge = new List<(double X, double Y)>();
        for (var i = 0; i < dense.Count; i += stride)
            edge.Add((dense[i].X - Middle.X, dense[i].Y - Middle.Y));
        var radius = edge.Count > 0 ? edge.Average(p => Math.Sqrt(p.X * p.X + p.Y * p.Y)) : 1.0;
        Depth = 0.6 * radius;
        _side = Math.Max(side, 1.0);

        _rings = new (double, double, double)[25][];
        var maxM = 1.0;
        for (var k = 0; k <= 24; k++)
        {
            var a = -Math.PI * 0.5 + Math.PI * k / 24.0;
            var scale = Math.Pow(Math.Max(Math.Cos(a), 0.0), Fullness);
            var z = Depth * Math.Sin(a);
            _rings[k] = edge.Select(p => (p.X * scale, p.Y * scale, z)).ToArray();
            var m = scale / Math.Max(0.2, 1.0 - z / (_side * 2.5));
            if (m > maxM) maxM = m;
        }

        const double step = 2.0 * Math.PI / Bins;
        var flat = edge.Select(p => (X: p.X * maxM, Y: p.Y * maxM, A: Math.Atan2(p.Y, p.X))).ToArray();
        var restReach = new double[Bins];
        for (var i = 0; i < flat.Length; i++)
            MarkSegment(flat[i], flat[(i + 1) % flat.Length], step, restReach);
        FillGaps(restReach);
        Rest = restReach;
    }

    private static (double X, double Y, double Z) Turned((double X, double Y, double Z) p,
        (double Tip, double TipS, double Turn, double TurnS) c)
    {
        var y = p.Y * c.Tip + p.Z * c.TipS;
        var z = -p.Y * c.TipS + p.Z * c.Tip;
        return (p.X * c.Turn + z * c.TurnS, y, -p.X * c.TurnS + z * c.Turn);
    }

    private static (double Tip, double TipS, double Turn, double TurnS) Turning(double turn, double tip)
    {
        const double deg = Math.PI / 180.0;
        return (Math.Cos(tip * deg), Math.Sin(tip * deg), Math.Cos(turn * deg), Math.Sin(turn * deg));
    }

    private (double X, double Y) Shown((double X, double Y, double Z) p)
    {
        var near = 1.0 / Math.Max(0.2, 1.0 - p.Z / (_side * 2.5));
        return (p.X * near, p.Y * near);
    }

    private static void MarkSegment((double X, double Y, double A) a, (double X, double Y, double A) b, double step, double[] reach)
    {
        var span = b.A - a.A;
        if (span > Math.PI) span -= 2.0 * Math.PI;
        else if (span < -Math.PI) span += 2.0 * Math.PI;
        var from = span >= 0 ? a : b;
        var to = span >= 0 ? b : a;
        var first = (int)Math.Ceiling(from.A / step);
        var last = (int)Math.Floor((from.A + Math.Abs(span)) / step);
        if (first > last) return;
        var across = from.X * to.Y - from.Y * to.X;
        var dx = to.X - from.X;
        var dy = to.Y - from.Y;
        for (var n = first; n <= last; n++)
        {
            var bin = ((n % Bins) + Bins) % Bins;
            var ray = Rays[bin];
            var facing = ray.X * dy - ray.Y * dx;
            if (Math.Abs(facing) <= 1e-9) continue;
            var r = across / facing;
            if (r > reach[bin]) reach[bin] = r;
        }
    }

    private static void FillGaps(double[] reach)
    {
        for (var b = 0; b < Bins; b++)
        {
            if (reach[b] <= 0)
                reach[b] = Math.Max(reach[(b + Bins - 1) % Bins], reach[(b + 1) % Bins]);
        }
    }

    public double[] Reach(double turn, double tip)
    {
        if (Math.Abs(turn) < 0.01 && Math.Abs(tip) < 0.01) return Rest;
        var c = Turning(turn, tip);
        const double step = 2.0 * Math.PI / Bins;
        var flat = new (double X, double Y, double A)[_rings.Length][];
        for (var k = 0; k < _rings.Length; k++)
        {
            var ring = _rings[k];
            var projected = new (double X, double Y, double A)[ring.Length];
            for (var i = 0; i < ring.Length; i++)
            {
                var s = Shown(Turned(ring[i], c));
                projected[i] = (s.X, s.Y, Math.Atan2(s.Y, s.X));
            }
            flat[k] = projected;
        }
        var reach = new double[Bins];
        for (var k = 0; k < flat.Length; k++)
        {
            var ring = flat[k];
            for (var i = 0; i < ring.Length; i++)
            {
                MarkSegment(ring[i], ring[(i + 1) % ring.Length], step, reach);
                if (k + 1 < flat.Length) MarkSegment(ring[i], flat[k + 1][i], step, reach);
            }
        }
        FillGaps(reach);
        return reach;
    }

    public P[] Edge(IReadOnlyList<double> reach)
    {
        var step = 2.0 * Math.PI / reach.Count;
        var pts = new P[reach.Count];
        for (var b = 0; b < reach.Count; b++)
        {
            var a = b * step;
            pts[b] = new P(Middle.X + reach[b] * Math.Cos(a), Middle.Y + reach[b] * Math.Sin(a));
        }
        return pts;
    }

    public (double Dx, double Dy, double Wide, double High, double Facing, double Scale) Seat(P point, double turn, double tip)
    {
        var qx = point.X - Middle.X;
        var qy = point.Y - Middle.Y;
        var at = Math.Atan2(qy, qx) / (2.0 * Math.PI) * Rest.Length;
        if (at < 0) at += Rest.Length;
        var low = (int)at % Rest.Length;
        var k = at - (int)at;
        var r = Math.Max(Rest[low] * (1.0 - k) + Rest[(low + 1) % Rest.Length] * k, 1e-6);
        var share = Math.Min(Math.Sqrt(qx * qx + qy * qy) / r, 0.95);
        var p = (X: qx, Y: qy, Z: Depth * Math.Sqrt(Math.Max(0.0, 1.0 - Math.Pow(share, 2.0 / Fullness))));
        var c = Turning(turn, tip);
        var rot = Turned(p, c);
        var now = Shown(rot);
        var then = Shown(p);
        var restNear = 1.0 / Math.Max(0.2, 1.0 - p.Z / (_side * 2.5));
        var nowNear = 1.0 / Math.Max(0.2, 1.0 - rot.Z / (_side * 2.5));
        var depthScale = Math.Clamp(nowNear / restNear, 0.78, 1.18);
        var nx = qx / (r * r);
        var ny = qy / (r * r);
        var nz = p.Z / Math.Max(Depth * Depth, 1e-9);
        var len = Math.Max(Math.Sqrt(nx * nx + ny * ny + nz * nz), 1e-12);
        var n = (X: nx / len, Y: ny / len, Z: nz / len);
        var across = Turned((1.0, 0.0, -n.X / Math.Max(Math.Abs(n.Z), 1e-6)), c);
        var down = Turned((0.0, 1.0, -n.Y / Math.Max(Math.Abs(n.Z), 1e-6)), c);
        return (now.X - then.X, now.Y - then.Y, Math.Abs(across.X), Math.Abs(down.Y), Turned(n, c).Z, depthScale);
    }
}
