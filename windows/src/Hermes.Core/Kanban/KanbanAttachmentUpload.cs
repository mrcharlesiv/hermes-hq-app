using System.Text;
using System.Text.RegularExpressions;
using Hermes.Core.Attachments;
using Hermes.Core.Net;

namespace Hermes.Core.Kanban;

/// Adding a file to a Kanban task (HermesKit/Pages/KanbanAttachmentUpload.swift; docs/spec/3x-morepages.md §4):
/// `POST /api/plugins/kanban/tasks/{id}/attachments`, multipart/form-data with the one part `file`. The body is built on
/// disk and removed afterwards, success or not. The gateway's limit is 25 MB.
public static partial class KanbanAttachmentUpload
{
    public const long MaxBytes = 25L * 1024 * 1024;
    public const string FailureTitle = "Couldn’t Add Attachment";
    /// A row shows a progress bar past this size.
    public const long ProgressFloor = 1024 * 1024;

    public static string TooLarge(int megabytes) => $"This file is larger than {megabytes} MB, the most a task can hold.";

    private static readonly Dictionary<string, string> Types = new(StringComparer.OrdinalIgnoreCase)
    {
        ["txt"] = "text/plain", ["md"] = "text/markdown", ["csv"] = "text/csv", ["html"] = "text/html", ["htm"] = "text/html",
        ["json"] = "application/json", ["pdf"] = "application/pdf", ["png"] = "image/png", ["jpg"] = "image/jpeg",
        ["jpeg"] = "image/jpeg", ["gif"] = "image/gif", ["heic"] = "image/heic", ["webp"] = "image/webp",
        ["mov"] = "video/quicktime", ["mp4"] = "video/mp4", ["m4a"] = "audio/mp4", ["mp3"] = "audio/mpeg", ["wav"] = "audio/wav",
        ["zip"] = "application/zip", ["xml"] = "application/xml", ["rtf"] = "text/rtf", ["svg"] = "image/svg+xml",
        ["xlsx"] = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        ["docx"] = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    };

    public static string ContentType(string filename)
    {
        var ext = Path.GetExtension(filename).TrimStart('.');
        return ext.Length > 0 && Types.TryGetValue(ext, out var t) ? t : "application/octet-stream";
    }

    /// The name sent: the last path component, with the characters a multipart header can't hold replaced.
    public static string SendName(string name)
    {
        var last = name.Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? "";
        var sb = new StringBuilder();
        foreach (var rune in last.EnumerateRunes())
        {
            if (Rune.IsControl(rune)) continue;
            sb.Append(rune.Value == '"' ? "_" : rune.ToString());
        }
        var output = sb.ToString().Trim(' ', '\t');
        while (output.StartsWith('.')) output = output[1..];
        return output;
    }

    public static byte[] FileOnlyHead(string filename, string contentType, string boundary) => Encoding.UTF8.GetBytes(
        $"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{filename}\"\r\nContent-Type: {contentType}\r\n\r\n");

    /// A body holding only the `file` part, built in `directory`. TooLarge past `limit` bytes of file; no body file is
    /// left behind on any failure. A name with CR, LF, `"` or `\` is refused before a byte is written.
    public static MultipartBody.Built BuildFileOnly(string source, string filename, string contentType, string boundary,
        string directory, long limit, CancellationToken ct = default)
    {
        if (filename.Length == 0 || filename.IndexOfAny(['\r', '\n', '"', '\\']) >= 0 || contentType.IndexOfAny(['\r', '\n', '"', '\\']) >= 0)
            throw new MultipartBody.BuildException(MultipartBody.Failure.UnsafeName);
        try { if (new FileInfo(source).Length > limit) throw new MultipartBody.BuildException(MultipartBody.Failure.TooLarge); }
        catch (FileNotFoundException) { throw new MultipartBody.BuildException(MultipartBody.Failure.Unreadable); }
        Directory.CreateDirectory(directory);
        var output = Path.Combine(directory, "upload-" + Guid.NewGuid().ToString("N") + ".multipart");
        FileStream? outStream = null;
        try
        {
            outStream = new FileStream(output, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            var head = FileOnlyHead(filename, contentType, boundary);
            outStream.Write(head);
            FileStream input;
            try { input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { throw new MultipartBody.BuildException(MultipartBody.Failure.Unreadable); }
            long count = 0;
            using (input)
            {
                var buffer = new byte[64 * 1024];
                int n;
                while ((n = input.Read(buffer, 0, buffer.Length)) > 0)
                {
                    ct.ThrowIfCancellationRequested();
                    count += n;
                    if (count > limit) throw new MultipartBody.BuildException(MultipartBody.Failure.TooLarge);
                    outStream.Write(buffer, 0, n);
                }
            }
            var tail = MultipartBody.Tail(boundary);
            outStream.Write(tail);
            outStream.Dispose();
            return new MultipartBody.Built(output, boundary, head.Length + count + tail.Length);
        }
        catch
        {
            outStream?.Dispose();
            try { File.Delete(output); } catch (IOException) { }
            throw;
        }
    }

    [GeneratedRegex(@"(\d+)\s*MB", RegexOptions.IgnoreCase)] private static partial Regex Megabytes();

    /// Why the attachment was not added, in words. `Gone` = the task is no longer on the board.
    public static (string Text, bool Gone) Reason(Exception error)
    {
        var max = (int)(MaxBytes / (1024 * 1024));
        if (error is MultipartBody.BuildException b)
            return b.Failure switch
            {
                MultipartBody.Failure.TooLarge => (TooLarge(max), false),
                MultipartBody.Failure.UnsafeName => ("The gateway couldn’t use this file’s name.", false),
                _ => ("This file could not be read.", false),
            };
        if (error is GatewayException { Code: "http" } http)
        {
            var detail = KanbanRest.Detail(http.Body) ?? "";
            switch (http.Status)
            {
                case 413:
                    var said = Megabytes().Match(detail) is { Success: true } m && int.TryParse(m.Groups[1].Value, out var mb) ? mb : max;
                    return (TooLarge(said), false);
                case 400: return (detail.Length == 0 ? "The gateway couldn’t use this file’s name." : detail, false);
                case 404: return ("This task is no longer on the board.", true);
            }
        }
        return (KanbanRest.Reason(error), false);
    }
}
