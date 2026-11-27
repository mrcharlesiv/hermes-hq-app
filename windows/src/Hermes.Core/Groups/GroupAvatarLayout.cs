namespace Hermes.Core.Groups;

/// [groups] A room's avatar (App/Groups/GroupAvatarView.swift `GroupAvatarLayout`): the room photo when it has one, one
/// face for one member, else two or three faces at the web's placements (fractions of the avatar's side). Pure.
public static class GroupAvatarLayout
{
    public readonly record struct Place(double Scale, double X, double Y);

    public static IReadOnlyList<Place> Placements(int count) => count switch
    {
        < 1 => [],
        1 => [new(1, 0, 0)],
        2 => [new(0.64, 0, 0), new(0.64, 0.36, 0.36)],
        _ => [new(0.54, 0.23, 0), new(0.46, 0, 0.5), new(0.42, 0.56, 0.54)],
    };

    /// A `data:image/…;base64,` URL's bytes; null for anything else.
    public static byte[]? ImageData(string? dataUrl)
    {
        if (dataUrl == null || !dataUrl.StartsWith("data:image/", StringComparison.Ordinal)) return null;
        var comma = dataUrl.IndexOf(',');
        if (comma < 0) return null;
        var body = new string(dataUrl[(comma + 1)..].Where(c => char.IsAsciiLetterOrDigit(c) || c is '+' or '/' or '=').ToArray());
        try { return Convert.FromBase64String(body); }
        catch (FormatException) { return null; }
    }
}
