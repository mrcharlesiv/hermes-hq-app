using Hermes.Core.Groups;
using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace HermesHQ.Features.Groups;

/// [WIN-51] The picked image made a room photo (App/Groups/GroupPhoto.swift `square`, `dataURL`): decoded once, the
/// centre square drawn at each side of GroupPhoto's ladder over white (a JPEG has no transparency; the Mac fills white
/// first), then JPEG-encoded at each quality until the data URL fits. The ladder and the fit are Hermes.Core's.
public static class GroupPhotoImaging
{
    /// The data URL of the image in `stream`; null when it can't be read or made small enough.
    public static async Task<string?> DataUrlAsync(IRandomAccessStream stream)
    {
        BitmapDecoder decoder;
        try { decoder = await BitmapDecoder.CreateAsync(stream); }
        catch (Exception) { return null; }
        var squares = new Dictionary<int, byte[]?>();
        return await GroupPhoto.DataUrlAsync(async (side, quality) =>
        {
            if (!squares.TryGetValue(side, out var pixels))
            {
                try { pixels = await SquareAsync(decoder, side); }
                catch (Exception) { pixels = null; }
                squares[side] = pixels;
            }
            if (pixels == null) return null;
            try { return await JpegAsync(pixels, side, quality); }
            catch (Exception) { return null; }
        });
    }

    /// The centre square at `side` pixels, BGRA over white.
    private static async Task<byte[]> SquareAsync(BitmapDecoder decoder, int side)
    {
        var white = Enumerable.Repeat((byte)255, side * side * 4).ToArray();
        if (GroupPhoto.Square(decoder.OrientedPixelWidth, decoder.OrientedPixelHeight, side) is not { } fill) return white;
        var width = (uint)Math.Max(side, Math.Round(fill.Width));
        var height = (uint)Math.Max(side, Math.Round(fill.Height));
        // The scale is in the stored frame (before the EXIF turn), the crop in the turned one.
        var turned = decoder.PixelWidth != decoder.OrientedPixelWidth;
        var transform = new BitmapTransform
        {
            ScaledWidth = turned ? height : width, ScaledHeight = turned ? width : height,
            InterpolationMode = BitmapInterpolationMode.Fant,
            Bounds = new BitmapBounds { X = (width - (uint)side) / 2, Y = (height - (uint)side) / 2, Width = (uint)side, Height = (uint)side },
        };
        var data = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, transform,
            ExifOrientationMode.RespectExifOrientation, ColorManagementMode.ColorManageToSRgb);
        var pixels = data.DetachPixelData();
        if (pixels.Length != white.Length) return white;
        // Premultiplied over white: colour + (255 − alpha).
        for (var i = 0; i < pixels.Length; i += 4)
        {
            var clear = 255 - pixels[i + 3];
            pixels[i] = (byte)Math.Min(255, pixels[i] + clear);
            pixels[i + 1] = (byte)Math.Min(255, pixels[i + 1] + clear);
            pixels[i + 2] = (byte)Math.Min(255, pixels[i + 2] + clear);
            pixels[i + 3] = 255;
        }
        return pixels;
    }

    private static async Task<byte[]> JpegAsync(byte[] pixels, int side, double quality)
    {
        using var stream = new InMemoryRandomAccessStream();
        var options = new BitmapPropertySet { ["ImageQuality"] = new BitmapTypedValue((float)quality, PropertyType.Single) };
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.JpegEncoderId, stream, options);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, (uint)side, (uint)side, 72, 72, pixels);
        await encoder.FlushAsync();
        return await ReadAllAsync(stream);
    }

    private static async Task<byte[]> ReadAllAsync(IRandomAccessStream stream)
    {
        var bytes = new byte[stream.Size];
        using var reader = new DataReader(stream.GetInputStreamAt(0));
        await reader.LoadAsync((uint)stream.Size);
        reader.ReadBytes(bytes);
        return bytes;
    }

    /// A synthetic picture (a two-colour diagonal, `width` × `height`) as a PNG stream, for the CI walk: what a picked
    /// file would hand the same path. No real photo is used anywhere in the walks.
    public static async Task<IRandomAccessStream> SyntheticPngAsync(int width, int height)
    {
        var pixels = new byte[width * height * 4];
        for (var y = 0; y < height; y++)
            for (var x = 0; x < width; x++)
            {
                var i = (y * width + x) * 4;
                var upper = x * height > y * width;
                pixels[i] = (byte)(upper ? 0xE6 : 0x4D);       // B
                pixels[i + 1] = (byte)(upper ? 0x84 : 0xB9);   // G
                pixels[i + 2] = (byte)(upper ? 0x0A : 0x30);   // R
                pixels[i + 3] = 255;
            }
        var stream = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, (uint)width, (uint)height, 96, 96, pixels);
        await encoder.FlushAsync();
        stream.Seek(0);
        return stream;
    }
}
