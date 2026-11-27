using System.Globalization;
using System.Text;
using Hermes.Core.Insights;

namespace Hermes.Core.Transcripts;

// The picture a page card shows in a reply (App/Chat/Viewer/PageSnapshots.swift at 93f984bb1): the bot's HTML page drawn
// off screen with its scripts, then photographed. A picture keeps a chat scrolling smoothly, and a click opens the live
// page (FileWindows). One page draws at a time; pages are read side by side. Pictures are kept in memory per page, chat
// look and generation: a chat's turn ending starts a new generation for its pages, since a bot answers a page's button by
// rewriting the file. The drawing itself (an off-screen WebView2) is the Windows app's (PagePictures.cs); the rules are
// here.

/// The chat a page belongs to: its account and bot (`MediaContext`).
public readonly record struct PageContext(string AccountId, string Profile);

/// A rectangle in the drawing view's points.
public readonly record struct PageRect(double X, double Y, double Width, double Height)
{
    public double MaxY => Y + Height;
}

/// The window a page is drawn in (`PageSnapshots.Shape`). A chat's card draws it a phone's screen tall; a tile's picture
/// its own shape.
public sealed record PageShape
{
    private enum Kind { Phone, Box, Frame }
    private readonly Kind _kind;
    private readonly double _aspect;
    private readonly int _width, _height, _zoom;

    private PageShape(Kind kind, double aspect = 0, int width = 0, int height = 0, int zoom = 100) =>
        (_kind, _aspect, _width, _height, _zoom) = (kind, aspect, width, height, zoom);

    public static readonly PageShape Phone = new(Kind.Phone);

    /// A tile's or card's picture, this many times as wide as it is high.
    public static PageShape Box(double aspect) => new(Kind.Box, aspect);

    /// A tile's own size in points at `zoom` percent.
    public static PageShape Frame(int width, int height, int zoom = 100) => new(Kind.Frame, 0, width, height, zoom);

    /// `Shape.tile(width:height:)`: kept to a twentieth, 0.4–3, so near shapes share a picture.
    public static PageShape Tile(double width, double height) =>
        width > 0 && height > 0 ? Box(Math.Max(0.4, Math.Min(3, Math.Round(width / height * 20, MidpointRounding.AwayFromZero) / 20))) : Box(1);

    /// `Shape.frame(width:height:zoom:)`: sizes kept to 5 pt (60–1600), zoom to 5 % (50–300 %).
    public static PageShape FrameOf(double width, double height, double zoom = 1)
    {
        static int Step(double v) => (int)Math.Round(Math.Max(60, Math.Min(1600, v)) / 5, MidpointRounding.AwayFromZero) * 5;
        if (width <= 0 || height <= 0) return Box(1);
        return Frame(Step(width), Step(height), (int)Math.Round(Math.Max(0.5, Math.Min(3, zoom)) * 20, MidpointRounding.AwayFromZero) * 5);
    }

    public bool IsPhone => _kind == Kind.Phone;
    public bool IsFrame => _kind == Kind.Frame;

    /// The page's zoom in this shape (1 but in a zoomed Grid tile).
    public double Zoom => _kind == Kind.Frame ? _zoom / 100.0 : 1;

    public (double Width, double Height) Size => _kind switch
    {
        Kind.Phone => (PageSnapshotRules.DrawWidth, PageSnapshotRules.DrawHeight),
        Kind.Box => (PageSnapshotRules.DrawWidth, Math.Round(PageSnapshotRules.DrawWidth / _aspect, MidpointRounding.AwayFromZero)),
        _ => (_width, _height),
    };

    /// A frame's fall-back: a phone's width in the tile's shape.
    public PageShape FrameAsBox => _kind == Kind.Frame ? Box((double)_width / _height) : this;

    public string Key => _kind switch
    {
        Kind.Phone => "phone",
        Kind.Box => "box" + _aspect.ToString("0.00", CultureInfo.InvariantCulture),
        _ => $"frame{_width}x{_height}" + (_zoom == 100 ? "" : $"z{_zoom}"),
    };
}

/// The fixed numbers and scripts of a page's picture.
public static class PageSnapshotRules
{
    /// The width a page is drawn at: a phone's column, so a page laid out for a phone pictures as it will open.
    public const double DrawWidth = 390;
    /// The most of a page pictured (in page points): a little more than the card shows at its widest.
    public const double PictureHeight = 300;
    /// The height a page is drawn at (a phone's screen).
    public const double DrawHeight = 844;
    /// Pictures kept in memory (`cache.countLimit`).
    public const int CountLimit = 24;
    /// How long a page's scripts get after it loads before the picture is taken.
    public static readonly TimeSpan Settle = TimeSpan.FromMilliseconds(700);
    /// How long a page gets to load before it is pictured as not drawable.
    public static readonly TimeSpan LoadLimit = TimeSpan.FromSeconds(15);
    /// How long a resized view gets to paint again.
    public static readonly TimeSpan Repaint = TimeSpan.FromMilliseconds(150);
    /// How much of a page's file is read for its head.
    public const int HeadBytes = 64_000;

    /// A tile's shape: does the page fit its window (no scrolling)? Then it is pictured whole.
    public const string FitsScript =
        "(function(){var d=document.documentElement;return d.scrollHeight<=Math.min(d.clientHeight,innerHeight)+1&&d.scrollWidth<=d.clientWidth+1})()";

    /// What the card shows: the page's first chart (its first big drawing or table) whole, when it has one; otherwise where
    /// the page's content is, whole when it is about as tall as it is wide, else its top. Answers
    /// [layout width, x, y, width, height] in page pixels.
    public const string ProbeScript =
        """(function(){var d=document.documentElement,h=Math.ceil(d.scrollHeight),w=d.clientWidth,y=window.scrollY;var els=document.querySelectorAll('svg,canvas,img,table');for(var i=0;i<els.length;i++){var r=els[i].getBoundingClientRect();if(r.width>=160&&r.height>=100)return [w,Math.max(0,r.left-8),Math.max(0,r.top+y-8),Math.min(w,r.width+16),r.height+16]}var bg=[getComputedStyle(d).backgroundColor,getComputedStyle(document.body).backgroundColor];var L=1e9,T=1e9,R=-1,B=-1,all=document.body.querySelectorAll('*');for(var j=0;j<all.length;j++){var e=all[j],s=getComputedStyle(e);if(s.visibility==='hidden'||+s.opacity===0)continue;var q=e.getBoundingClientRect();if(q.width<1||q.height<1)continue;var text=false;for(var c=e.firstChild;c;c=c.nextSibling)if(c.nodeType===3&&c.nodeValue.trim()){text=true;break}var fill=s.backgroundImage!=='none'||(!/rgba\\(.*, 0\\)$|transparent/.test(s.backgroundColor)&&bg.indexOf(s.backgroundColor)<0);if(!text&&!fill&&!/^(IMG|SVG|CANVAS|VIDEO|INPUT|BUTTON|SELECT|TEXTAREA)$/i.test(e.tagName))continue;if(fill&&!text&&q.width>=w-1&&q.height>=d.clientHeight-1)continue;L=Math.min(L,q.left);T=Math.min(T,q.top+y);R=Math.max(R,q.right);B=Math.max(B,q.bottom+y)}if(R<0)return [w,0,0,w,Math.min(h,260)];L=Math.max(0,L-8);T=Math.max(0,T-8);R=Math.min(w,R+8);B=Math.min(h,B+8);return [w,L,T,R-L,(B-T)<=(R-L)*1.25?B-T:Math.min(B-T,260)]})()""";

    /// The probe's answer in the view's points (page pixels × view width / layout width), kept to twice the picture's
    /// height and to the view's width; null when the probe found nothing usable.
    public static PageRect? CaptureRect(IReadOnlyList<double> found, double viewWidth)
    {
        if (found.Count != 5 || !(found[0] > 0)) return null;
        var k = viewWidth / found[0];
        var x = found[1] * k;
        var width = Math.Min(found[3] * k, viewWidth - x);
        return new PageRect(x, found[2] * k, width, Math.Min(found[4], PictureHeight * 2) * k);
    }
}

/// A drawn picture's pixels, BGRA top-down (what WebView2's capture decodes to).
public sealed record PagePixels(int Width, int Height, byte[] Bgra)
{
    /// The picture's top-left pixel: the page's background (null when it is see-through).
    public (byte R, byte G, byte B)? CornerColor()
    {
        if (Width <= 0 || Height <= 0 || Bgra.Length < 4 || Bgra[3] <= 200) return null;
        return (Bgra[2], Bgra[1], Bgra[0]);
    }

    /// How many distinct colours the picture holds (sampled on a grid, up to `cap`): one means a blank picture.
    public int Colours(int cap = 64)
    {
        if (Width <= 0 || Height <= 0) return 0;
        var seen = new HashSet<int>();
        var step = Math.Max(1, Math.Min(Width, Height) / 64);
        for (var y = 0; y < Height; y += step)
            for (var x = 0; x < Width; x += step)
            {
                var i = (y * Width + x) * 4;
                if (i + 3 >= Bgra.Length) continue;
                seen.Add(Bgra[i] | Bgra[i + 1] << 8 | Bgra[i + 2] << 16);
                if (seen.Count >= cap) return seen.Count;
            }
        return seen.Count;
    }
}

/// The pictures of pages (`PageSnapshots.shared`). `read`: the page's file on this computer (path, name, chat), or null
/// when it can't be had. `draw`: the file pictured (file, dark, shape), or null when it can't be drawn. Callbacks run
/// where the read or draw finished (the app's UI thread when asked from it).
public sealed class PageSnapshots<TImage>(
    Func<string, string, PageContext, Task<string?>> read,
    Func<string, bool, PageShape, Task<TImage?>> draw) where TImage : class
{
    private readonly object _gate = new();
    private readonly Dictionary<string, LinkedListNode<(string Key, TImage Image)>> _cache = [];
    private readonly LinkedList<(string Key, TImage Image)> _order = new();   // least recently used first
    private readonly Dictionary<PageContext, int> _generations = [];
    private readonly Dictionary<string, List<Action<TImage?>>> _waiting = [];
    /// Pages read and waiting to be drawn (one draws at a time; reading is not in line).
    private readonly Queue<(string Key, string File, bool Dark, PageShape Shape)> _queue = new();
    private bool _drawing;
    private readonly Dictionary<string, TileNames.Head> _heads = [];

    /// A chat's turn ended (`turnEnded`): its open pages' pictures redraw.
    public event Action<PageContext>? TurnEnded;
    /// A page's title was read for the first time or has changed (`headLearnt`).
    public event Action? HeadLearnt;

    /// A chat's turn ended: its pages may have changed.
    public void NoteTurnEnded(PageContext context)
    {
        lock (_gate) _generations[context] = Generation(context) + 1;
        TurnEnded?.Invoke(context);
    }

    /// A new generation for `context` alone, told to nobody.
    public void Freshen(PageContext context)
    {
        lock (_gate) _generations[context] = Generation(context) + 1;
    }

    /// The chat's page generation this run (0 until a turn of it ends).
    public int Generation(PageContext context)
    {
        lock (_gate) return _generations.GetValueOrDefault(context);
    }

    public string Key(string path, PageContext context, bool dark, PageShape? shape = null)
    {
        shape ??= PageShape.Phone;
        return $"{context.AccountId}|{context.Profile}|{path}|{Generation(context)}|{(dark ? "d" : "l")}" + (shape.IsPhone ? "" : "|" + shape.Key);
    }

    /// A page is drawing or waiting to.
    public bool IsBusy
    {
        get { lock (_gate) return _drawing || _queue.Count > 0; }
    }

    /// Pictures kept now.
    public int Count
    {
        get { lock (_gate) return _cache.Count; }
    }

    public TImage? Cached(string path, PageContext context, bool dark, PageShape? shape = null)
    {
        var k = Key(path, context, dark, shape);
        lock (_gate) return Hit(k);
    }

    /// What the page's head said when it was last read for a picture (null before then).
    public TileNames.Head? Head(string path, PageContext context)
    {
        lock (_gate) return _heads.GetValueOrDefault(HeadKey(path, context));
    }

    private static string HeadKey(string path, PageContext c) => $"{c.AccountId}|{c.Profile}|{path}";

    private TImage? Hit(string key)
    {
        if (!_cache.TryGetValue(key, out var node)) return null;
        _order.Remove(node);
        _order.AddLast(node);
        return node.Value.Image;
    }

    /// The page's picture (null when it can't be read or drawn).
    public void Picture(string path, string name, PageContext context, bool dark, PageShape shape, Action<TImage?> done)
    {
        var k = Key(path, context, dark, shape);
        TImage? hit;
        lock (_gate)
        {
            hit = Hit(k);
            if (hit == null)
            {
                if (_waiting.TryGetValue(k, out var list)) { list.Add(done); return; }
                _waiting[k] = [done];
            }
        }
        if (hit != null) { done(hit); return; }
        // Read again each time it's drawn (the bot may have rewritten it). Reads go side by side; only drawing waits.
        _ = ReadThenQueueAsync(k, path, name, context, dark, shape);
    }

    private async Task ReadThenQueueAsync(string k, string path, string name, PageContext context, bool dark, PageShape shape)
    {
        string? file;
        try { file = await read(path, name, context); }
        catch (Exception) { file = null; }
        if (file == null) { Answer(k, null); return; }
        LearnHead(HeadKey(path, context), file);
        lock (_gate) _queue.Enqueue((k, file, dark, shape));
        DrainQueue();
    }

    private void LearnHead(string headKey, string file)
    {
        TileNames.Head head;
        try
        {
            using var stream = File.OpenRead(file);
            var buffer = new byte[PageSnapshotRules.HeadBytes];
            var n = 0;
            while (n < buffer.Length && stream.Read(buffer, n, buffer.Length - n) is var got and > 0) n += got;
            head = TileNames.ReadHead(Encoding.UTF8.GetString(buffer, 0, n));
        }
        catch (Exception) { head = new TileNames.Head(); }
        bool learnt;
        lock (_gate)
        {
            learnt = _heads.GetValueOrDefault(headKey)?.Title != head.Title;
            _heads[headKey] = head;
        }
        if (learnt) HeadLearnt?.Invoke();
    }

    private void DrainQueue()
    {
        (string Key, string File, bool Dark, PageShape Shape) job;
        lock (_gate)
        {
            if (_drawing || _queue.Count == 0) return;
            _drawing = true;
            job = _queue.Dequeue();
        }
        _ = DrawAsync(job);
    }

    private async Task DrawAsync((string Key, string File, bool Dark, PageShape Shape) job)
    {
        TImage? image;
        try { image = await draw(job.File, job.Dark, job.Shape); }
        catch (Exception) { image = null; }
        lock (_gate)
        {
            if (image != null) Keep(job.Key, image);
        }
        Answer(job.Key, image);
        lock (_gate) _drawing = false;
        DrainQueue();
    }

    private void Keep(string key, TImage image)
    {
        if (_cache.Remove(key, out var old)) _order.Remove(old);
        _cache[key] = _order.AddLast((key, image));
        while (_cache.Count > PageSnapshotRules.CountLimit && _order.First is { } first)
        {
            _order.RemoveFirst();
            _cache.Remove(first.Value.Key);
        }
    }

    private void Answer(string key, TImage? image)
    {
        List<Action<TImage?>>? callbacks;
        lock (_gate) _waiting.Remove(key, out callbacks);
        foreach (var callback in callbacks ?? []) callback(image);
    }
}

/// What a card does about its picture (PageCardView.swift `configure` / `loadPicture`).
public enum PageCardPictureStep { Wait, ShowCached, Load }

/// What a card does with a picture that has arrived.
public enum PageCardArrival { Ignore, Show, Failed, KeepOld }

public static class PageCardPictures
{
    /// While the reply that hands the page over still arrives, a card with no picture yet waits (the bot may still be
    /// writing the file); a kept picture shows at once; otherwise the page is pictured, the last picture staying up.
    public static PageCardPictureStep Begin(bool building, bool hasPicture, bool cached) =>
        building && !hasPicture ? PageCardPictureStep.Wait : cached ? PageCardPictureStep.ShowCached : PageCardPictureStep.Load;

    /// A picture for a card that has since moved on is dropped; one that couldn't be drawn ends the wait only when the
    /// card has no picture (the last one stays up otherwise).
    public static PageCardArrival Arrived(bool stillWanted, bool got, bool hadPicture) =>
        !stillWanted ? PageCardArrival.Ignore : got ? PageCardArrival.Show : hadPicture ? PageCardArrival.KeepOld : PageCardArrival.Failed;
}

/// A chat's turn ending (`wasRunning && !session.isRunning`): Windows hears a reply's end at `message.complete` and again
/// when the gateway says it is idle; only the first after the chat ran starts a new generation.
public sealed class PageTurnEdge
{
    private readonly object _gate = new();
    private bool _ran;

    /// The chat was seen running (or not).
    public void Saw(bool busy)
    {
        lock (_gate) _ran |= busy;
    }

    /// A turn-end was heard: true the first time after the chat ran.
    public bool Ended()
    {
        lock (_gate)
        {
            var ended = _ran;
            _ran = false;
            return ended;
        }
    }
}
