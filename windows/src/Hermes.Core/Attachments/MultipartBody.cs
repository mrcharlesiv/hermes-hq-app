using System.Text;

namespace Hermes.Core.Attachments;

/// The upload-stream body, built on disk (HermesKit/Attachments/MultipartBody.swift; spec §3.3), byte for byte as the
/// web's native layer: fields `path`, `overwrite=false`, `file`, the file streamed in 64 KiB reads with a byte ceiling.
/// Never in memory.
public static class MultipartBody
{
    public sealed record Built(string FilePath, string Boundary, long Length)
    {
        public string ContentType => "multipart/form-data; boundary=" + Boundary;
    }

    public enum Failure { UnsafeName, TooLarge, Unreadable }

    public sealed class BuildException(Failure failure) : Exception(failure.ToString())
    {
        public Failure Failure { get; } = failure;
    }

    /// "hermes-" and an upper-case UUID, as the web.
    public static string NewBoundary() => "hermes-" + Guid.NewGuid().ToString().ToUpperInvariant();

    public static byte[] Head(string destination, string filename, string boundary) => Encoding.UTF8.GetBytes(
        $"--{boundary}\r\nContent-Disposition: form-data; name=\"path\"\r\n\r\n{destination}\r\n"
        + $"--{boundary}\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\nfalse\r\n"
        + $"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{filename}\"\r\n"
        + "Content-Type: application/octet-stream\r\n\r\n");

    public static byte[] Tail(string boundary) => Encoding.UTF8.GetBytes($"\r\n--{boundary}--\r\n");

    /// Builds the body for `source` (sent as `filename`, to `destination` on the gateway) in `directory`. Stops with
    /// TooLarge past `limit` bytes of file and leaves no body file behind on any failure.
    public static Built Build(string source, string destination, string filename, string boundary, string directory,
        long limit, CancellationToken ct = default)
    {
        // The filename sits in a quoted header, so quotes and backslashes break it. The destination is a field's value:
        // a Windows gateway's folder (C:\Users\…) has backslashes and is fine; only a line break is not.
        if (filename.IndexOfAny(['\r', '\n', '"', '\\']) >= 0) throw new BuildException(Failure.UnsafeName);
        if (destination.IndexOfAny(['\r', '\n']) >= 0) throw new BuildException(Failure.UnsafeName);
        Directory.CreateDirectory(directory);
        var output = Path.Combine(directory, "upload-" + Guid.NewGuid().ToString("N") + ".multipart");
        FileStream? outStream = null;
        try
        {
            outStream = new FileStream(output, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            var head = Head(destination, filename, boundary);
            outStream.Write(head);
            long length = head.Length;
            FileStream input;
            try { input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { throw new BuildException(Failure.Unreadable); }
            using (input)
            {
                var buffer = new byte[64 * 1024];
                long count = 0;
                int n;
                while ((n = input.Read(buffer, 0, buffer.Length)) > 0)
                {
                    ct.ThrowIfCancellationRequested();
                    count += n;
                    if (count > limit) throw new BuildException(Failure.TooLarge);
                    outStream.Write(buffer, 0, n);
                }
                length += count;
            }
            var tail = Tail(boundary);
            outStream.Write(tail);
            length += tail.Length;
            outStream.Dispose();
            return new Built(output, boundary, length);
        }
        catch
        {
            outStream?.Dispose();
            try { File.Delete(output); } catch (IOException) { }
            throw;
        }
    }
}
