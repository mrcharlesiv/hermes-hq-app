namespace Hermes.Core.Groups;

/// [WIN-GROUP-EMPTY-FIT] How an empty room fits the transcript's room (App/Groups/GroupRoomChrome.swift RoomEmptyView
/// `layoutSubviews`, framed by ChatViewController `layoutEmpty(in: transcriptRoom)`): a column of at most 320 wide with
/// 32 either side, the 56 avatar, the name, the members and the hint, 12 after the avatar, 10 after the members and 6
/// otherwise. Short of room it leaves out the avatar, then the hint, then the members; the name stays. Centred in what
/// is left, 20 high, never above the room's top; still too tall (huge text), it is cut off at the room's edges, never
/// drawn under the composer. Every height is in the window's own units (WinUI's effective pixels, the Mac's points):
/// the text heights come measured, so the text size (Windows' TextScaleFactor, the Mac's Dynamic Type) is in them once.
public static class RoomEmptyFit
{
    public const double MaxColumn = 320;
    public const double Side = 32;
    public const double AvatarSide = 56;
    public const double Spacing = 6;
    public const double AfterAvatar = 12;
    public const double AfterMembers = 10;
    /// How far above the room's middle the column's middle sits (`(bounds.height - fit.height) / 2 - 20`).
    public const double Lift = 20;

    public enum Part { Avatar, Name, Members, Hint }

    /// Top to bottom, as the stack holds them.
    public static readonly IReadOnlyList<Part> Order = [Part.Avatar, Part.Name, Part.Members, Part.Hint];

    /// What goes first when the room is short (`for view in [avatar, hint, members]`). The name is never left out.
    public static readonly IReadOnlyList<Part> Squeeze = [Part.Avatar, Part.Hint, Part.Members];

    /// The column's width in a room this wide (`min(320, bounds.width - 64)`), never below nothing.
    public static double Column(double roomWidth) => Math.Max(0, Math.Min(MaxColumn, roomWidth - 2 * Side));

    /// The space after a part when another shown part follows it (the stack's custom spacing).
    public static double After(Part part) => part switch
    {
        Part.Avatar => AfterAvatar,
        Part.Members => AfterMembers,
        _ => Spacing,
    };

    /// The column as laid out: which parts show, the space above each shown part, where the column starts, its width
    /// and height, and whether the room cuts it off.
    public sealed record Layout(IReadOnlyList<Part> Shown, IReadOnlyDictionary<Part, double> Above, double Top, double Column, double Height, bool Clips)
    {
        public bool Shows(Part part) => Shown.Contains(part);
        public double GapAbove(Part part) => Above.TryGetValue(part, out var gap) ? gap : 0;
    }

    /// The column's height with these parts shown: each shown part's height, and the spacing after every shown part
    /// but the last (a left-out part takes its spacing with it, as UIStackView's hidden views do).
    public static double Height(IReadOnlyList<Part> shown, Func<Part, double> height)
    {
        var total = 0.0;
        for (var i = 0; i < shown.Count; i++)
        {
            total += height(shown[i]);
            if (i < shown.Count - 1) total += After(shown[i]);
        }
        return total;
    }

    /// The empty room in a room this big. `nameHeight`, `membersHeight` and `hintHeight` are the words' heights
    /// measured at `Column(roomWidth)` as drawn (wrapped, at the text size); the avatar is always 56.
    public static Layout Fit(double roomWidth, double roomHeight, double nameHeight, double membersHeight, double hintHeight)
    {
        double HeightOf(Part p) => p switch
        {
            Part.Avatar => AvatarSide,
            Part.Name => Math.Max(0, nameHeight),
            Part.Members => Math.Max(0, membersHeight),
            _ => Math.Max(0, hintHeight),
        };
        var room = Math.Max(0, roomHeight);
        var shown = Order.ToList();
        var fit = Height(shown, HeightOf);
        foreach (var part in Squeeze)
        {
            if (fit <= room) break;
            shown.Remove(part);
            fit = Height(shown, HeightOf);
        }
        var above = new Dictionary<Part, double>();
        for (var i = 1; i < shown.Count; i++) above[shown[i]] = After(shown[i - 1]);
        var top = Math.Max(0, Round((room - fit) / 2 - Lift));
        return new Layout(shown, above, top, Column(roomWidth), Math.Ceiling(fit), fit > room);
    }

    /// Swift's `.rounded()`: to the nearest, halves away from zero.
    private static double Round(double value) => Math.Round(value, MidpointRounding.AwayFromZero);

    /// The words the empty room says (RoomEmptyView `set(name:members:…)`): the room's name, its members or "No bots
    /// yet", and the hint. Kept here so the fit and the words are checked together.
    public static (string Name, string Members, string Hint) Words(string title, IReadOnlyList<string> memberNames) =>
        (title, GroupRowWords.MembersOrNone(memberNames), GroupRoomChrome.EmptyHint);
}
