using Hermes.Core.Attachments;
using Windows.Graphics.Imaging;

namespace HermesHQ.Features.Attachments;

/// The photo normaliser (HermesKit/Attachments/PhotoNormalizer.swift; spec 1x-attachments §5.1) on Windows Imaging:
/// at most 3072 px on the long side, the EXIF orientation drawn into the pixels, no metadata written (no location),
/// JPEG at 0.85 — PNG when the picture has real transparency, and an animated GIF passes through untouched.
internal sealed class WindowsPhotoNormalizer : IPhotoNormalizer
{
    public const uint MaxPixel = 3072;
    public const float Quality = 0.85f;

    public async Task<NormalizedPhoto> NormalizeAsync(string source, string stem, string folder, CancellationToken ct)
    {
        await using var sourceStream = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 64 * 1024, useAsync: true);
        using var input = sourceStream.AsRandomAccessStream();
        var decoder = await BitmapDecoder.CreateAsync(input);
        ct.ThrowIfCancellationRequested();
        if (decoder.DecoderInformation == null) throw new InvalidDataException("No Windows codec could read this image.");
        if (decoder.DecoderInformation.CodecId == BitmapDecoder.GifDecoderId && decoder.FrameCount > 1)
        {
            var gif = Path.Combine(folder, stem + ".gif");
            File.Copy(source, gif, overwrite: true);
            return new NormalizedPhoto(gif, stem + ".gif", new FileInfo(gif).Length, (int)decoder.PixelWidth, (int)decoder.PixelHeight);
        }
        var w = decoder.OrientedPixelWidth;
        var h = decoder.OrientedPixelHeight;
        if (w == 0 || h == 0) throw new InvalidDataException("Image has empty dimensions.");
        var scale = Math.Min(1.0, (double)MaxPixel / Math.Max(1, Math.Max(w, h)));
        var outW = (uint)Math.Max(1, Math.Round(w * scale));
        var outH = (uint)Math.Max(1, Math.Round(h * scale));
        // The transform scales in the decoder's own orientation; the oriented size is what comes out.
        var swapped = w != decoder.PixelWidth;
        var transform = new BitmapTransform
        {
            ScaledWidth = swapped ? outH : outW,
            ScaledHeight = swapped ? outW : outH,
            InterpolationMode = BitmapInterpolationMode.Fant,
        };
        var pixels = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Straight, transform,
            ExifOrientationMode.RespectExifOrientation, ColorManagementMode.ColorManageToSRgb);
        var bytes = pixels.DetachPixelData();
        ct.ThrowIfCancellationRequested();
        var expectedBytes = (long)outW * outH * 4L;
        if (expectedBytes > 0 && bytes.LongLength != expectedBytes)
            throw new InvalidDataException("The decoded picture's buffer didn't match its size.");
        var png = decoder.BitmapAlphaMode != BitmapAlphaMode.Ignore && HasTransparency(bytes);
        var name = stem + (png ? ".png" : ".jpg");
        var target = Path.Combine(folder, name);
        Directory.CreateDirectory(folder);
        await using (var targetStream = new FileStream(target, FileMode.Create, FileAccess.ReadWrite, FileShare.None, 64 * 1024, useAsync: true))
        using (var output = targetStream.AsRandomAccessStream())
        {
            BitmapEncoder encoder;
            if (png) encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, output);
            else
            {
                var options = new BitmapPropertySet { ["ImageQuality"] = new BitmapTypedValue(Quality, Windows.Foundation.PropertyType.Single) };
                encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.JpegEncoderId, output, options);
            }
            // Pixels only: nothing of the original's metadata (GPS, camera) is written.
            encoder.SetPixelData(BitmapPixelFormat.Bgra8, png ? BitmapAlphaMode.Straight : BitmapAlphaMode.Ignore, outW, outH, 96, 96, bytes);
            await encoder.FlushAsync();
        }
        return new NormalizedPhoto(target, name, new FileInfo(target).Length, (int)outW, (int)outH);
    }

    /// Real transparency: an alpha channel and a pixel with alpha < 255 (sampled, as the Mac's 64 × 64 check).
    private static bool HasTransparency(byte[] bgra)
    {
        var pixels = bgra.Length / 4;
        var step = Math.Max(1, pixels / 4096);
        for (var i = 0; i < pixels; i += step)
            if (bgra[i * 4 + 3] < 255) return true;
        return false;
    }
}
