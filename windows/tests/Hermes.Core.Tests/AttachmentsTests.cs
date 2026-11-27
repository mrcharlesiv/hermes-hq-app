using System.IO.Compression;
using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Attachments;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Rpc;

namespace Hermes.Core.Tests;

internal static class Pictures
{
    private static uint Crc(byte[] data)
    {
        var c = 0xFFFFFFFFu;
        foreach (var b in data)
        {
            c ^= b;
            for (var i = 0; i < 8; i++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
        }
        return c ^ 0xFFFFFFFFu;
    }

    /// A real PNG of the given size (one grey row repeated).
    public static byte[] Png(int width, int height)
    {
        static byte[] Chunk(string kind, byte[] body)
        {
            var k = Encoding.ASCII.GetBytes(kind);
            var len = new byte[4];
            System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(len, body.Length);
            var crc = new byte[4];
            System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(crc, Crc([.. k, .. body]));
            return [.. len, .. k, .. body, .. crc];
        }
        var ihdr = new byte[13];
        System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(ihdr, width);
        System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(ihdr.AsSpan(4), height);
        ihdr[8] = 8; ihdr[9] = 0;
        var raw = new MemoryStream();
        for (var y = 0; y < height; y++) { raw.WriteByte(0); raw.Write(Enumerable.Repeat((byte)128, width).ToArray()); }
        var z = new MemoryStream();
        using (var d = new ZLibStream(z, CompressionLevel.Fastest, leaveOpen: true)) d.Write(raw.ToArray());
        return [0x89, (byte)'P', (byte)'N', (byte)'G', 0x0D, 0x0A, 0x1A, 0x0A, .. Chunk("IHDR", ihdr), .. Chunk("IDAT", z.ToArray()), .. Chunk("IEND", [])];
    }
}

public class AttachmentWireTests
{
    [Theory]
    [InlineData("hello", "", true, "hello")]
    [InlineData("", "", true, "What do you see in this image?")]
    [InlineData("summarise", "@file:/Users/ivy/.hermes/attachments/report.pdf", false,
        "@file:/Users/ivy/.hermes/attachments/report.pdf\n\nsummarise")]
    [InlineData("  look \n", "@file:/a/report.pdf", true, "@file:/a/report.pdf\n\nlook")]
    [InlineData("", "", false, "")]
    public void PromptTextAsSpec(string typed, string refs, bool images, string expected) =>
        Assert.Equal(expected, AttachmentSender.PromptText(typed, refs.Length == 0 ? [] : refs.Split('|'), images));

    [Fact]
    public void KeptNameCarriesThePathsType()
    {
        // MediaStore.fileName(_:path:) (PreviewVideoNameTests.keptNameCarriesThePathsType), case for case.
        Assert.Equal("Demo video.mp4", MediaStore.KeptName("Demo video", "/Users/bot/out/demo.mp4"));
        Assert.Equal("Clip.MP4", MediaStore.KeptName("Clip.MP4", "/Users/bot/clip.mp4"));
        Assert.Equal("demo.mp4", MediaStore.KeptName("demo.mp4", "/Users/bot/demo.mp4"));
        Assert.Equal("Report v1.2.md", MediaStore.KeptName("Report v1.2", "~/report.md"));
        Assert.Equal("demo.mov", MediaStore.KeptName("", "/Users/bot/demo.mov"));
        Assert.Equal("demo.mov", MediaStore.KeptName("  ", "/Users/bot/demo.mov"));
        Assert.Equal("Notes", MediaStore.KeptName("Notes", "/Users/bot/README"));
    }

    [Fact]
    public void TwoFileRefsOnTheirOwnLines() =>
        Assert.Equal("@file:/a/report.pdf\n@file:`/a/My Notes.md`",
            AttachmentSender.PromptText("", ["@file:/a/report.pdf", "@file:`/a/My Notes.md`"], hasImages: false));

    [Fact]
    public void AttachParamsAreExactlyTheContract()
    {
        Assert.Equal(["session_id", "path", "profile"], AttachmentSender.ImageAttachParams("rt", "/p.png", "default").Select(k => k.Key));
        Assert.Equal(["session_id", "path", "name", "profile"],
            AttachmentSender.FileAttachParams("rt", "/r.pdf", "r.pdf", "default").Select(k => k.Key));
        Assert.Equal(["session_id", "path"], AttachmentSender.ImageDetachParams("rt", "/p.png", null).Select(k => k.Key));
        Assert.Equal("/x/My Notes.md", AttachmentSender.RefPath("@file:`/x/My Notes.md`"));
    }

    [Fact]
    public void MultipartBodyByteForByte()
    {
        var dir = Directory.CreateTempSubdirectory().FullName;
        var src = Path.Combine(dir, "report.pdf");
        File.WriteAllBytes(src, Encoding.ASCII.GetBytes("%PDF-1.4 hi"));
        var built = MultipartBody.Build(src, "/root/.dispatch-attachments/F/report.pdf", "report.pdf", "hermes-B", Path.Combine(dir, "up"), 1 << 20);
        var text = File.ReadAllText(built.FilePath);
        Assert.Equal("--hermes-B\r\nContent-Disposition: form-data; name=\"path\"\r\n\r\n/root/.dispatch-attachments/F/report.pdf\r\n"
            + "--hermes-B\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\nfalse\r\n"
            + "--hermes-B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"report.pdf\"\r\n"
            + "Content-Type: application/octet-stream\r\n\r\n%PDF-1.4 hi\r\n--hermes-B--\r\n", text);
        Assert.Equal(new FileInfo(built.FilePath).Length, built.Length);
        Assert.Equal("multipart/form-data; boundary=hermes-B", built.ContentType);
        Assert.StartsWith("hermes-", MultipartBody.NewBoundary());

        Assert.Equal(MultipartBody.Failure.UnsafeName, Assert.Throws<MultipartBody.BuildException>(() =>
            MultipartBody.Build(src, "/d/x", "a\"b.pdf", "b", dir, 1 << 20)).Failure);
        Assert.Equal(MultipartBody.Failure.TooLarge, Assert.Throws<MultipartBody.BuildException>(() =>
            MultipartBody.Build(src, "/d/x", "r.pdf", "b", Path.Combine(dir, "big"), 4)).Failure);
        Assert.Empty(Directory.GetFiles(Path.Combine(dir, "big"))); // nothing left behind
        // A Windows gateway's folder has backslashes: fine in a field's value.
        MultipartBody.Build(src, @"C:\Users\ivy\.dispatch-attachments\F\r.pdf", "r.pdf", "b", dir, 1 << 20);
    }

    [Fact]
    public void UploadErrorsInTheTraysWords()
    {
        Assert.Equal("Your gateway has no folder for uploads.",
            AttachmentStager.Map(new GatewayException("http", "x", 403), "p.jpg", reading: false).Reason);
        Assert.Equal("“clip.mov” is too big for your gateway.",
            AttachmentStager.Map(new GatewayException("http", "x", 413), "clip.mov", reading: false).Reason);
        Assert.Equal("Couldn’t upload “p.jpg” (gateway error 500).",
            AttachmentStager.Map(new GatewayException("http", "x", 500), "p.jpg", reading: false).Reason);
        Assert.Equal("Your gateway refused “p.jpg”: Invalid path",
            AttachmentStager.Map(new GatewayException("http", "x", 400, "{\"detail\":\"Invalid path\"}"), "p.jpg", reading: false).Reason);
        Assert.Equal(AttachmentUploadException.Kinds.Waiting,
            AttachmentStager.Map(new GatewayException("offline", "x"), "p.jpg", reading: false).Kind);
        Assert.Equal("Couldn’t upload “p.jpg”. Check your connection and try again.",
            AttachmentStager.Map(new GatewayException("timeout", "x"), "p.jpg", reading: false).Reason);
        Assert.Equal(AttachmentUploadException.Kinds.Retryable,
            AttachmentStager.Map(new GatewayException("http", "x", 502), "", reading: true).Kind);
        Assert.Equal(AttachmentUploadException.Kinds.SessionEnded,
            AttachmentStager.Map(new GatewayException("http", "x", 401), "", reading: false).Kind);
    }

    [Fact]
    public void StagingFolderReleasedOnlyWhenTheGatewayCopiedOut()
    {
        const string folder = "/u/.dispatch-attachments/F";
        Assert.True(AttachmentStager.StagedCopyReleased(true, "/home/.hermes/attachments/r.pdf", folder));
        Assert.False(AttachmentStager.StagedCopyReleased(false, "/home/.hermes/attachments/r.pdf", folder));
        Assert.False(AttachmentStager.StagedCopyReleased(true, folder + "/r.pdf", folder));
        Assert.False(AttachmentStager.StagedCopyReleased(true, @"\u\.dispatch-attachments\F\r.pdf", folder));
    }

    [Theory]
    [InlineData("/fixture/a.png", false)]
    [InlineData("~/a.png", false)]
    [InlineData(@"C:\Users\a.png", false)]
    [InlineData("file:///a.png", false)]
    [InlineData("out/chart.png", true)]
    public void SessionIdOnlyForRelativePaths(string path, bool relative)
    {
        Assert.Equal(relative, MediaStore.IsRelative(path));
        Assert.Equal(relative, MediaStore.DownloadQuery(path, "default", "sid").Any(q => q.Key == "session_id"));
    }

    [Fact]
    public void RemotePicturesOnlyFromThePublicInternet()
    {
        Assert.False(MediaStore.IsPublicAddress(System.Net.IPAddress.Parse("100.101.102.103"))); // Tailscale CGNAT
        Assert.False(MediaStore.IsPublicAddress(System.Net.IPAddress.Parse("192.168.1.4")));
        Assert.False(MediaStore.IsPublicAddress(System.Net.IPAddress.Parse("fd7a:115c:a1e0::1")));
        Assert.False(MediaStore.IsPublicAddress(System.Net.IPAddress.Loopback));
        Assert.True(MediaStore.IsPublicAddress(System.Net.IPAddress.Parse("93.184.216.34")));
        Assert.False(MediaStore.IsPublicAsync(new Uri("http://example.com/a.png")).Result);
        Assert.False(MediaStore.IsPublicAsync(new Uri("https://box.tail1234.ts.net/a.png")).Result);
        Assert.False(MediaStore.IsPublicAsync(new Uri("https://10.0.0.2/a.png")).Result);
    }
}

public class AttachmentModelTests
{
    [Theory]
    [InlineData("report.pdf", 2_400_000L, "PDF · 2.4 MB")]
    [InlineData("report.pdf", null, "PDF")]
    [InlineData("photo.jpeg", 812_345L, "JPEG · 812 KB")]
    [InlineData("notes.md", 12L, "Markdown · 12 bytes")]
    [InlineData("README", null, "File")]
    [InlineData(".env", 3L, "3 bytes")]
    public void DetailLine(string name, long? bytes, string expected) => Assert.Equal(expected, MediaKinds.Detail(name, bytes));

    [Theory]
    [InlineData("a.png", MediaKind.Image)]
    [InlineData("clip.MOV", MediaKind.Video)]
    [InlineData("memo.m4a", MediaKind.Audio)]
    [InlineData("r.pdf", MediaKind.Pdf)]
    [InlineData("data.csv", MediaKind.Table)]
    [InlineData("bundle.zip", MediaKind.Archive)]
    [InlineData("logo.svg", MediaKind.Other)]
    public void KindsByExtension(string name, MediaKind kind) => Assert.Equal(kind, MediaKinds.Kind(name));

    [Theory]
    [InlineData("/fixture/media/chart.png", true, "chart.png")]
    [InlineData(@"C:\Users\ivy\chart.png", true, "chart.png")]
    [InlineData("/", true, "Photo")]
    [InlineData("/dir/", false, "dir")]
    public void NamesOfPaths(string path, bool image, string name) => Assert.Equal(name, MediaKinds.NameOfPath(path, image));

    [Theory]
    [InlineData("C:\\fakepath\\My \"Report\".pdf", "My Report.pdf")]
    [InlineData("a:b/c.txt", "c.txt")]
    [InlineData("..", "attachment")]
    [InlineData("tab\there.txt", "tabhere.txt")]
    public void SafeNames(string raw, string safe) => Assert.Equal(safe, AttachmentCenter.SafeName(raw));

    [Fact]
    public void LongNamesKeepTheirExtensionUnder180Bytes()
    {
        var safe = AttachmentCenter.SafeName(new string('é', 200) + ".pdf");
        Assert.EndsWith(".pdf", safe);
        Assert.True(Encoding.UTF8.GetByteCount(safe) <= 180);
    }

    [Fact]
    public void LargestAttachmentClampsAndWords()
    {
        Assert.Equal(100, AttachmentLimit.Megabytes);
        AttachmentLimit.Megabytes = 500;
        Assert.Equal(100, AttachmentLimit.Megabytes);
        AttachmentLimit.Megabytes = 0;
        Assert.Equal(1, AttachmentLimit.Megabytes);
        Assert.Equal("“clip.mov” is larger than 1 MB, the largest attachment this PC is set to send. You can change it in Settings › Chat Behavior › Largest Attachment.",
            AttachmentLimit.Refusal("clip.mov"));
        AttachmentLimit.Megabytes = 100;
        Assert.Equal("“clip.mov” is larger than 100 MB, the most Hermes HQ can send.", AttachmentLimit.Refusal("clip.mov"));
        Assert.Equal(100L * 1024 * 1024, AttachmentLimit.Bytes);
    }

    [Fact]
    public void PixelSizesFromHeaders()
    {
        Assert.Equal((240, 180), ImageHeader.PixelSize(Pictures.Png(240, 180)));
        byte[] gif = [(byte)'G', (byte)'I', (byte)'F', (byte)'8', (byte)'9', (byte)'a', 0x40, 0x01, 0xC8, 0x00];
        Assert.Equal((320, 200), ImageHeader.PixelSize(gif));
        Assert.Null(ImageHeader.PixelSize("not a picture"u8));
    }

    [Fact]
    public void GeneratedImageFromResult()
    {
        var args = JsonNode.Parse("{\"prompt\":\"a red fox\",\"aspect_ratio\":\"square\"}");
        var info = GeneratedImageInfo.From(args, JsonValue.Create("{\"success\":true,\"image\":\"/fixture/media/fox.png\",\"pixel_size\":\"1024x1024\"}"), false)!;
        Assert.Equal("/fixture/media/fox.png", info.Source);
        Assert.Equal(1024, info.PixelWidth);
        Assert.Equal("fox.png", info.Name);
        Assert.Equal((320, 320), info.Frame(600));
        Assert.Contains("/fixture/media/fox.png", info.Echoes);
        Assert.Null(GeneratedImageInfo.From(args, JsonNode.Parse("{\"success\":false,\"error\":\"No image backend configured\"}"), false));
        Assert.Null(GeneratedImageInfo.From(args, null, running: false));
        Assert.Null(GeneratedImageInfo.From(args, null, running: true)!.Source);
        var portrait = GeneratedImageInfo.From(JsonNode.Parse("{\"aspect_ratio\":\"portrait\"}"), JsonNode.Parse("{\"image\":\"/x.png\"}"), false)!;
        Assert.Equal(400, portrait.Frame(600).Height);
    }
}

public class AttachmentHistoryTests
{
    private static List<MessageAttachment> Atts(ChatMessage m) => [.. m.Attachments];

    [Fact]
    public void ImageRefsLeaveTheWords()
    {
        var l = AttachmentHydration.LiftText("Here is the chart\n@image:/fixture/media/chart.png");
        Assert.Equal("Here is the chart", l.Text);
        Assert.Equal(new AttachmentSource.Gateway("/fixture/media/chart.png"), Assert.Single(l.Attachments).Source);
        Assert.Equal("chart.png", l.Attachments[0].Name);

        var quoted = AttachmentHydration.LiftText("@image:`/fixture/media/two words.png`\n[screenshot]");
        Assert.Equal("", quoted.Text);
        Assert.Equal("two words.png", Assert.Single(quoted.Attachments).Name);

        var at = AttachmentHydration.LiftText("[Image attached at: /fixture/media/a.png]");
        Assert.Equal(AttachmentKind.Image, Assert.Single(at.Attachments).Kind);
    }

    [Fact]
    public void LeadingFileRefsBecomeFileRows()
    {
        var l = AttachmentHydration.LiftText("@file:/fixture-home/attachments/report.pdf\n\nPlease summarise this");
        Assert.Equal("Please summarise this", l.Text);
        Assert.Equal(AttachmentKind.File, Assert.Single(l.Attachments).Kind);
        var two = AttachmentHydration.LiftText("@file:/fixture-home/attachments/report.pdf\n@file:`/fixture-home/attachments/My Notes.md`");
        Assert.Equal(["report.pdf", "My Notes.md"], two.Attachments.Select(a => a.Name));
        Assert.Equal("", two.Text);
        var folder = AttachmentHydration.LiftText("@folder:/home/fx/proj\nlook here");
        Assert.Equal(AttachmentKind.Folder, folder.Attachments[0].Kind);
        // A ref in the middle of the words stays words.
        Assert.Empty(AttachmentHydration.LiftText("see @file:/a.pdf please").Attachments);
    }

    [Fact]
    public void InlineDataPartsAreDecodedOnceIntoTheStore()
    {
        InlineMediaStore.Root = Directory.CreateTempSubdirectory().FullName;
        var png = Pictures.Png(240, 180);
        var url = "data:image/png;base64," + Convert.ToBase64String(png);
        var content = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = "what is this?" },
            new JsonObject { ["type"] = "image_url", ["image_url"] = new JsonObject { ["url"] = url } });
        var l = AttachmentHydration.LiftUser("what is this?", content);
        var a = Assert.Single(l.Attachments);
        var inline = Assert.IsType<AttachmentSource.Inline>(a.Source);
        Assert.Equal(240, a.PixelWidth);
        Assert.Equal(png, File.ReadAllBytes(InlineMediaStore.PathFor(inline.MediaKey)));
        Assert.Equal("what is this?", l.Text);

        // Hermes' native-vision form: N refs and N parts are the same pictures (the path's name, the part's bytes).
        var both = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = "compare these\n@image:/m/a.png\n@image:/m/b.png" },
            new JsonObject { ["type"] = "image_url", ["image_url"] = new JsonObject { ["url"] = url } },
            new JsonObject { ["type"] = "image_url", ["image_url"] = new JsonObject { ["url"] = url } });
        var pair = AttachmentHydration.LiftUser("compare these\n@image:/m/a.png\n@image:/m/b.png", both);
        Assert.Equal(["a.png", "b.png"], pair.Attachments.Select(x => x.Name));
        Assert.All(pair.Attachments, x => Assert.IsType<AttachmentSource.Inline>(x.Source));
        Assert.Equal("compare these", pair.Text);
    }

    [Fact]
    public void ReplyMediaBecomesRows()
    {
        var parts = AttachmentHydration.ReplyParts("Here you go:\nMEDIA:/fixture/media/result.png\nAnd the data: MEDIA:/fixture/media/data.csv");
        Assert.Equal("Here you go:\nAnd the data: data.csv", Assert.IsType<TextPart>(parts[0]).Text);
        var atts = parts.OfType<AttachmentPart>().Select(p => p.Attachment).ToList();
        Assert.Equal([AttachmentKind.Image, AttachmentKind.File], atts.Select(a => a.Kind));
        // Audio is the voice stream's; code is code; a relative path stays words.
        Assert.Single(AttachmentHydration.ReplyParts("MEDIA:/a/memo.m4a"));
        Assert.Single(AttachmentHydration.ReplyParts("```\nMEDIA:/a/b.png\n```"));
        Assert.Single(AttachmentHydration.ReplyParts("MEDIA:out/b.png"));
        Assert.IsType<AttachmentPart>(Assert.Single(AttachmentHydration.ReplyParts("MEDIA:/fixture/media/clip.mov")));
    }

    private static JsonObject Row(long id, string role, JsonNode? content, Action<JsonObject>? more = null)
    {
        var r = new JsonObject { ["id"] = id, ["role"] = role, ["content"] = content, ["timestamp"] = 1790852400 + id };
        more?.Invoke(r);
        return r;
    }

    [Fact]
    public void HistoryFoldDrawsAttachmentsAndGeneratedImages()
    {
        var rows = new List<JsonNode?>
        {
            Row(1, "user", "Here is the chart\n@image:/fixture/media/chart.png"),
            Row(2, "assistant", "Got it."),
            Row(3, "user", "Draw a fox"),
            Row(4, "assistant", "", r => r["tool_calls"] = JsonNode.Parse("""
                [{"id":"gen-fox","type":"function","function":{"name":"image_generate","arguments":"{\"prompt\":\"a red fox\",\"aspect_ratio\":\"square\"}"}}]
                """)),
            Row(5, "tool", "{\"success\": true, \"image\": \"/fixture/media/fox.png\", \"pixel_size\": \"1024x1024\"}",
                r => { r["tool_call_id"] = "gen-fox"; r["tool_name"] = "image_generate"; }),
            Row(6, "assistant", "Here's the fox."),
            Row(7, "user", "Draw another"),
            Row(8, "assistant", "", r => r["tool_calls"] = JsonNode.Parse("""
                [{"id":"gen-fail","type":"function","function":{"name":"image_generate","arguments":"{\"prompt\":\"a blue fox\"}"}}]
                """)),
            Row(9, "tool", "{\"success\": false, \"error\": \"No image backend configured\"}",
                r => { r["tool_call_id"] = "gen-fail"; r["tool_name"] = "image_generate"; }),
        };
        var m = HistoryFold.Fold(rows);
        Assert.Equal("Here is the chart", m[0].Text);
        Assert.Equal("chart.png", Assert.Single(Atts(m[0])).Name);
        var fox = m[3].Parts.OfType<GeneratedImagePart>().Single();
        Assert.Equal("gen-fox", fox.ToolId);
        Assert.Equal(GeneratedImageInfo.AspectHint.Square, fox.Image.Aspect);
        Assert.Contains("Here's the fox.", m[3].Text);
        Assert.Empty(m[5].Parts.OfType<GeneratedImagePart>());
        Assert.Equal("image_generate", Assert.Single(m[5].Tools).Name);
    }

    [Fact]
    public void LiveImageGenerateBecomesThePicture()
    {
        var t = new Transcript();
        t.Apply(new RpcEvent("message.start", "rt", new JsonObject(), null));
        t.Apply(new RpcEvent("tool.start", "rt", JsonNode.Parse("{\"name\":\"image_generate\",\"tool_id\":\"g1\",\"args\":{\"aspect_ratio\":\"portrait\"}}"), null));
        Assert.IsType<ToolPart>(t.Messages[^1].Parts[^1]);
        t.Apply(new RpcEvent("tool.complete", "rt", JsonNode.Parse(
            "{\"name\":\"image_generate\",\"tool_id\":\"g1\",\"args\":{\"aspect_ratio\":\"portrait\"},\"result\":{\"success\":true,\"image\":\"/m/fox.png\"}}"), null));
        var g = Assert.IsType<GeneratedImagePart>(t.Messages[^1].Parts[^1]);
        Assert.Equal(GeneratedImageInfo.AspectHint.Portrait, g.Image.Aspect);
    }

    [Fact]
    public void CacheKeepsRefsNeverLocalCopies()
    {
        var cache = new FileTranscriptCache(Directory.CreateTempSubdirectory().FullName);
        var gateway = new MessageAttachment(AttachmentKind.Image, new AttachmentSource.Gateway("/m/a.png"), "a.png", 10, 20, 300);
        var local = new MessageAttachment(AttachmentKind.File, new AttachmentSource.Local("D", @"C:\tmp\r.pdf"), "r.pdf");
        var uploaded = local with { UploadedPath = "/u/r.pdf" };
        var gen = new GeneratedImagePart("g", new GeneratedImageInfo("/m/fox.png", 5, 6, GeneratedImageInfo.AspectHint.Square, true, new HashSet<string>()));
        cache.Write("acct", "default", "s1", [new ChatMessage("stored-row-1-user", Role.User,
            [new AttachmentPart(gateway), new AttachmentPart(local), new AttachmentPart(uploaded), new TextPart("hi")]),
            new ChatMessage("stored-row-2-assistant", Role.Assistant, [gen])]);
        var back = cache.Read("acct", "default", "s1")!;
        var atts = back[0].Attachments.ToList();
        Assert.Equal(2, atts.Count);
        Assert.Equal(gateway, atts[0]);
        Assert.Equal(new AttachmentSource.Gateway("/u/r.pdf"), atts[1].Source);
        Assert.Equal("hi", back[0].Text);
        var g = Assert.IsType<GeneratedImagePart>(Assert.Single(back[1].Parts));
        Assert.Equal("/m/fox.png", g.Image.Source);
    }

    [Fact]
    public void DraftAttachmentsRoundTrip()
    {
        var a = new DraftAttachment("ID", DraftKind.Image, "photo.jpg", @"C:\s\ID\photo.jpg", 9, 3, 4,
            new UploadState.Uploaded("/u/.dispatch-attachments/F/photo.jpg", "/u/.dispatch-attachments/F"));
        Assert.Equal(a, AttachmentCenter.FromJson(JsonNode.Parse(AttachmentCenter.ToJson(a).ToJsonString())));
        var f = a with { Upload = new UploadState.Failed("Your gateway has no folder for uploads.", false) };
        Assert.True(AttachmentCenter.FromJson(JsonNode.Parse(AttachmentCenter.ToJson(f).ToJsonString()))!.OffersRetry);
        Assert.True((a with { Kind = DraftKind.File, Name = "m.m4a" }).DefersUpload);
    }
}

public class MediaLayoutTests
{
    [Theory]
    [InlineData(320, 4032, 3024, 260, 195)]      // landscape: 260 wide
    [InlineData(320, 1179, 2556, 150, 320)]      // a tall screenshot: 320 tall, at least 150 wide
    [InlineData(320, 3000, 200, 260, 100)]       // a strip: at least 100 tall
    [InlineData(200, null, null, 200, 195)]      // unknown size
    public void SinglePhotoFrames(double maxW, int? pw, int? ph, double w, double h)
    {
        var (fw, fh) = MediaLayout.Single(maxW, pw, ph);
        Assert.Equal(w, Math.Round(fw));
        Assert.Equal(h, Math.Round(fh));
    }

    [Fact]
    public void GridsOfSquares()
    {
        var two = MediaLayout.Grid(320, 2);
        Assert.Equal(2, two.Tiles.Count);
        Assert.Equal(156, two.Tiles[0].Width);
        Assert.Equal(164, two.Tiles[1].X);
        var three = MediaLayout.Grid(320, 3);
        Assert.Equal(320, three.Tiles[0].Width);
        Assert.Equal(156, three.Tiles[0].Height);
        Assert.Equal(164, three.Tiles[2].Y);
        var seven = MediaLayout.Grid(320, 7);
        Assert.Equal(4, seven.Tiles.Count);
        Assert.Equal(3, seven.More);
        Assert.Equal(320, MediaLayout.GridHeight(320, 4));
        Assert.Equal(520, MediaLayout.Grid(900, 2).Tiles[1].X + MediaLayout.Grid(900, 2).Tiles[1].Width); // never over 520
    }
}
