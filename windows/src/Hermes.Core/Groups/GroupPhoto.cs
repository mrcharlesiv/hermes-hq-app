namespace Hermes.Core.Groups;

// [groups] A room's photo (App/Groups/GroupPhoto.swift; docs/spec/3x-groups.md §7.2, §7.5): the picked image cropped
// square and re-encoded as a JPEG data URL of at most 24,000 characters, since a longer one is left out of the mirror
// (§5.1). The decisions are here; the decode and the JPEG encode are the app's (Features/Groups/GroupPhotoImaging.cs).

public static class GroupPhoto
{
    public const string Prefix = "data:image/jpeg;base64,";
    /// Sides and qualities tried in order: 256 px at 0.8 first, stepping down until the data URL fits.
    public static readonly IReadOnlyList<int> Sides = [256, 224, 192, 160, 128, 112, 96, 80, 64, 48];
    public static readonly IReadOnlyList<double> Qualities = [0.8, 0.7, 0.6, 0.5, 0.4, 0.3];

    // Name & Photo's words (GroupInfoSheet.swift `GroupNamePhotoView`, GroupPhoto.swift `failed`).
    public const string Header = "Photo";
    public const string ChoosePhoto = "Choose Photo";
    public const string RemovePhoto = "Remove Photo";
    public const string FailedTitle = "Couldn’t Use That Photo";
    public const string FailedReason = "The photo could not be read. Choose another one.";

    /// Where the image is drawn in the `side` square: scaled to fill it, centred (the part outside is cut off).
    public readonly record struct Fill(double Width, double Height, double X, double Y);

    /// The centre square of a `width` × `height` image at `side` (GroupPhoto.square); null for an empty image, which
    /// leaves the square white.
    public static Fill? Square(double width, double height, double side)
    {
        if (width <= 0 || height <= 0) return null;
        var scale = Math.Max(side / width, side / height);
        var w = width * scale;
        var h = height * scale;
        return new Fill(w, h, (side - w) / 2, (side - h) / 2);
    }

    /// Base64 is 4 characters for every 3 bytes: whether `bytes` of JPEG fit `limit` characters with the prefix.
    public static bool Fits(int bytes, int limit) => Prefix.Length + (bytes + 2) / 3 * 4 <= limit;

    /// The data URL of the image `encode` draws (side in pixels, JPEG quality 0–1 → the bytes, or null when that try
    /// can't be made), at most `limit` characters; null when even the smallest try does not fit.
    public static async Task<string?> DataUrlAsync(Func<int, double, Task<byte[]?>> encode, int limit = GroupLimits.SyncImage)
    {
        foreach (var side in Sides)
        {
            foreach (var quality in Qualities)
            {
                if (await encode(side, quality) is not { } data) continue;
                if (!Fits(data.Length, limit)) continue;
                return Prefix + Convert.ToBase64String(data);
            }
        }
        return null;
    }
}

/// Name & Photo's state (GroupInfoSheet.swift `GroupNamePhotoModel`): the room's name and photo as opened, the edits,
/// and what Save may do.
public sealed class GroupNamePhotoDraft(string originalName, string? originalImage)
{
    public string OriginalName { get; } = originalName;
    public string? OriginalImage { get; } = originalImage;
    public string Name { get; set; } = originalName;
    public string? Image { get; set; } = originalImage;
    public bool Saving { get; set; }
    /// `A group named “<name>” already exists.`
    public string? Problem { get; set; }

    public string CleanName => GroupKeys.CleanName(Name);
    public bool NameChanged => CleanName.Length > 0 && CleanName != OriginalName;
    public bool ImageChanged => Image != OriginalImage;
    public bool HasChanges => NameChanged || ImageChanged;
    public bool CanSave => HasChanges && !Saving;
    /// Remove Photo shows only while there is a photo.
    public bool ShowsRemove => Image != null;
    public string SaveTitle => GroupInfoWords.SaveTitle(Saving);
}
