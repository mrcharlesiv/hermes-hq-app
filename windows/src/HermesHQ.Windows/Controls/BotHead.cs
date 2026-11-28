using Hermes.Core.Heads;
using Hermes.Core.Model;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;

namespace HermesHQ.Controls;

/// A bot's face. Every list, header and rail draws heads through this one control, so the drawn robot heads
/// (App/Heads, spec 02 §10) replace the initials here and nowhere else.
public sealed partial class BotHead : Grid
{
    public static readonly DependencyProperty BotProperty = DependencyProperty.Register(nameof(Bot), typeof(Bot),
        typeof(BotHead), new PropertyMetadata(null, (d, _) => ((BotHead)d).Redraw()));
    public static readonly DependencyProperty DisplayNameProperty = DependencyProperty.Register("DisplayName", typeof(string),
        typeof(BotHead), new PropertyMetadata(null, (d, _) => ((BotHead)d).Redraw()));
    public static readonly DependencyProperty WorkingProperty = DependencyProperty.Register(nameof(Working), typeof(bool),
        typeof(BotHead), new PropertyMetadata(false, (d, _) => ((BotHead)d).SyncAnimation()));
    public static readonly DependencyProperty FollowsMoodProperty = DependencyProperty.Register(nameof(FollowsMood), typeof(bool),
        typeof(BotHead), new PropertyMetadata(false, (d, _) => ((BotHead)d).SyncAnimation()));
    public static readonly DependencyProperty MoodProperty = DependencyProperty.Register(nameof(Mood), typeof(object),
        typeof(BotHead), new PropertyMetadata(null, (d, _) => ((BotHead)d).SyncAnimation()));

    public Bot? Bot { get => (Bot?)GetValue(BotProperty); set => SetValue(BotProperty, value); }
    /// For rows without a Bot (a session's profile name).
    public string? DisplayName { get => (string?)GetValue(DisplayNameProperty); set => SetValue(DisplayNameProperty, value); }
    /// Whether this bot is actively working (drives animated thinking mood unless a specific step mood is active).
    public bool Working { get => (bool)GetValue(WorkingProperty); set => SetValue(WorkingProperty, value); }
    /// When true, subscribes the rendered face to `BotMoods.Shared` for this bot's profile.
    public bool FollowsMood { get => (bool)GetValue(FollowsMoodProperty); set => SetValue(FollowsMoodProperty, value); }
    /// Optional explicit mood override.
    public BotMood? Mood { get => GetValue(MoodProperty) as BotMood?; set => SetValue(MoodProperty, value); }

    /// Replaced by the heads renderer when it lands: (bot or null, display name, size) → the face.
    public static Func<Bot?, string, double, UIElement>? Renderer { get; set; }

    public BotHead()
    {
        Width = Height = 28;
        SizeChanged += (_, _) => Redraw();
    }

    private void Redraw()
    {
        Children.Clear();
        var name = Bot?.DisplayName ?? DisplayName ?? "";
        var size = double.IsNaN(Width) ? 28 : Width;
        if (Renderer != null)
        {
            var elem = Renderer(Bot, name, size);
            Children.Add(elem);
            SyncAnimation();
            return;
        }
        Children.Add(new Ellipse { Fill = new SolidColorBrush(ColorFor(Bot?.Name ?? name)) });
        Children.Add(new TextBlock
        {
            Text = Initial(name), Foreground = new SolidColorBrush(Colors.White), FontSize = size * 0.45,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
        });
    }

    private void SyncAnimation()
    {
        if (Children.FirstOrDefault() is not Features.Heads.HeadFace face) return;
        face.Working = Working;
        face.PosedMood = Mood;
        face.Follow(FollowsMood ? (Bot?.Name ?? DisplayName) : null);
    }

    private static string Initial(string name) => name.Length > 0 ? char.ToUpperInvariant(name[0]).ToString() : "?";

    /// A steady colour per profile name, from the iPhone app's head palette family.
    public static Color ColorFor(string key)
    {
        uint[] palette = [0xD93A63, 0x30B94D, 0x0A84FF, 0xFF9F0A, 0x8E5CD9, 0x00A2B8, 0xE5446D, 0x5E5CE6, 0xA2845E];
        var h = 0u;
        foreach (var c in key) h = h * 31 + c;
        var v = palette[h % (uint)palette.Length];
        return Color.FromArgb(255, (byte)(v >> 16), (byte)(v >> 8), (byte)v);
    }
}
