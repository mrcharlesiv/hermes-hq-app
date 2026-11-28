using Hermes.Core.Heads;
using Hermes.Core.Model;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage.Streams;

namespace HermesHQ.Features.Heads;

/// A bot's face (App/Heads/HeadView.swift `HeadImage`, still): the photo it wears, else its saved head
/// (`ui_meta["dispatch-head"]`, or the head saved here a moment ago) or its name's default. It looks to the right, at
/// the words beside it, and follows the page between light and dark. A photo is an app-icon tile (22.37 % corners),
/// never a circle. Redrawn when the bot's face changes anywhere (`HeadStore.Changed`).
public sealed partial class HeadFace : Grid
{
    readonly Bot? _bot;
    readonly string _profile;
    readonly Head? _head;
    readonly double _side;
    readonly bool? _dark;
    readonly bool _pageUnknown;
    string? _followsProfile;
    BotMood? _posedMood;
    bool _working;
    AnimatedHeadFace? _animated;
    string _drawn = "";
    readonly DispatcherQueue? _queue = DispatcherQueue.GetForCurrentThread();

    /// A bot's face (`bot` null: a profile known only by name, as a session's row).
    public HeadFace(Bot? bot, string profile, double side)
    {
        _bot = bot;
        _profile = bot?.Name ?? profile;
        _side = side;
        Init();
    }

    /// A head the caller holds (Edit Head's stage and strips): never a photo. `dark` null: follow the page.
    /// `pageUnknown`: drawn for no page in particular (the desktop copy: a black head keeps its rim).
    public HeadFace(Head head, double side, bool? dark = null, bool pageUnknown = false)
    {
        _head = head;
        _profile = "";
        _side = side;
        _dark = dark;
        _pageUnknown = pageUnknown;
        Init();
    }

    /// Has this face act out what `profile`'s bot is doing (`null` stops following).
    public void Follow(string? profile)
    {
        var next = string.IsNullOrEmpty(profile) ? null : profile;
        if (_followsProfile == next) return;
        _followsProfile = next;
        _drawn = "";
        Redraw();
    }

    /// Explicit mood override (e.g. preview); `null` follows the bot's own mood.
    public BotMood? PosedMood
    {
        get => _posedMood;
        set
        {
            if (_posedMood == value) return;
            _posedMood = value;
            _drawn = "";
            Redraw();
        }
    }

    /// Whether the bot is currently working (acts out `Thinking` when no specific step mood is active).
    public bool Working
    {
        get => _working;
        set
        {
            if (_working == value) return;
            _working = value;
            _drawn = "";
            Redraw();
        }
    }

    void Init()
    {
        Width = Height = _side;
        IsHitTestVisible = false;
        ActualThemeChanged += (_, _) => Redraw();
        Loaded += (_, _) =>
        {
            HeadStore.Changed += OnChanged;
            Redraw();
        };
        Unloaded += (_, _) => HeadStore.Changed -= OnChanged;
        if (_bot != null) BotPhotos.Shared.Note(_bot);
        Redraw();
    }

    void OnChanged(string name)
    {
        if (_head != null || name != _profile) return;
        if (_queue == null || _queue.HasThreadAccess) { _drawn = ""; Redraw(); }
        else _queue.TryEnqueue(() => { _drawn = ""; Redraw(); });
    }

    /// The head shown now.
    public Head Head => _head ?? (_bot != null ? HeadStore.HeadOf(_bot) : Head.DefaultHead(_profile));

    void Redraw()
    {
        bool? dark = _pageUnknown ? null : _dark ?? ActualTheme == ElementTheme.Dark;
        var scale = XamlRoot?.RasterizationScale ?? 2;
        if (_head == null && BotPhotos.Shared.Photo(_profile) is { } photo)
        {
            var key = "photo|" + BotPicture.Fingerprint(photo);
            if (key == _drawn) return;
            _drawn = key;
            _animated = null;
            Children.Clear();
            Children.Add(Photo(photo, _side));
            return;
        }
        var head = Head;
        var wantsAnimation = _followsProfile != null || _posedMood != null || _working;
        if (wantsAnimation)
        {
            var animKey = $"anim|{HeadPicture.Key(head, _side, dark)}|{scale}";
            if (_animated == null || animKey != _drawn)
            {
                _drawn = animKey;
                _animated = new AnimatedHeadFace(head, _side, _dark, _pageUnknown)
                {
                    Profile = _followsProfile,
                    PosedMood = _posedMood,
                    Working = _working,
                };
                Children.Clear();
                Children.Add(_animated);
            }
            else
            {
                _animated.Head = head;
                _animated.Profile = _followsProfile;
                _animated.PosedMood = _posedMood;
                _animated.Working = _working;
            }
            return;
        }
        var pictureKey = HeadPicture.Key(head, _side, dark) + "|" + scale;
        if (pictureKey == _drawn) return;
        _drawn = pictureKey;
        _animated = null;
        Children.Clear();
        Children.Add(HeadDrawing.Draw(HeadPicture.For(head, _side, dark), _side, scale));
    }

    static UIElement Photo(byte[] bytes, double side)
    {
        var bitmap = new BitmapImage { DecodePixelWidth = (int)Math.Ceiling(side * 3) };
        _ = SetAsync(bitmap, bytes);
        return new Border
        {
            Width = side, Height = side, CornerRadius = new CornerRadius(side * BotPicture.CornerShare),
            Background = new ImageBrush { ImageSource = bitmap, Stretch = Stretch.UniformToFill },
        };
    }

    static async Task SetAsync(BitmapImage bitmap, byte[] bytes)
    {
        try
        {
            using var stream = new InMemoryRandomAccessStream();
            using (var writer = new DataWriter(stream.GetOutputStreamAt(0)))
            {
                writer.WriteBytes(bytes);
                await writer.StoreAsync();
                writer.DetachStream();
            }
            stream.Seek(0);
            await bitmap.SetSourceAsync(stream);
        }
        catch (Exception e)
        {
            Services.AppLog.Error("heads", e);
        }
    }
}
