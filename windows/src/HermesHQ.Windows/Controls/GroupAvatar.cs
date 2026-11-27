using Hermes.Core.Groups;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;

namespace HermesHQ.Controls;

/// [groups] A room's avatar (App/Groups/GroupAvatarView.swift `GroupAvatar`): the room photo in a circle when it has one,
/// else up to three member faces at the web's placements (`GroupAvatarLayout`), else the two-people glyph in the
/// tertiary label colour. Faces are drawn by `BotHead`, as every other face is.
public sealed partial class GroupAvatar : Canvas
{
    public GroupAvatar(GroupRowModel room, double size, Func<string, Hermes.Core.Model.Bot?>? bot = null)
    {
        Width = Height = size;
        IsHitTestVisible = false;
        if (GroupAvatarLayout.ImageData(room.Image) is { Length: > 0 } bytes)
        {
            var photo = new Ellipse { Width = size, Height = size };
            Children.Add(photo);
            _ = LoadAsync(photo, bytes);
            return;
        }
        var faces = room.Faces.Take(3).ToList();
        if (faces.Count == 0)
        {
            var glyph = new FontIcon
            {
                Glyph = "\uE716", FontSize = size * 0.4, Width = size, Height = size,   // person.2.fill
                Foreground = ThemeBrushes.Get("HQLabel3Brush"),
            };
            Children.Add(glyph);
            return;
        }
        var places = GroupAvatarLayout.Placements(faces.Count);
        for (var i = 0; i < faces.Count; i++)
        {
            var side = Math.Round(size * places[i].Scale);
            var head = new BotHead { Width = side, Height = side };
            if (bot?.Invoke(faces[i].Profile) is { } model) head.Bot = model;
            else head.DisplayName = faces[i].Profile;
            SetLeft(head, Math.Round(size * places[i].X));
            SetTop(head, Math.Round(size * places[i].Y));
            Children.Add(head);
        }
    }

    private static async Task LoadAsync(Ellipse target, byte[] bytes)
    {
        try
        {
            using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
            using (var writer = new Windows.Storage.Streams.DataWriter(stream))
            {
                writer.WriteBytes(bytes);
                await writer.StoreAsync();
                writer.DetachStream();
            }
            stream.Seek(0);
            var image = new BitmapImage();
            await image.SetSourceAsync(stream);
            target.Fill = new ImageBrush { ImageSource = image, Stretch = Stretch.UniformToFill };
        }
        catch (Exception)
        {
            // A photo that doesn't decode leaves the circle empty, as the Mac's nil image does.
        }
    }
}
