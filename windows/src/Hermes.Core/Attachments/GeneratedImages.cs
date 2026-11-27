using System.Text.Json.Nodes;
using Hermes.Core.Model;

namespace Hermes.Core.Attachments;

/// image_generate results become a picture in place of their tool row (spec 1x-attachments §7.7): from the stored tool
/// row in history, and from tool.complete while the reply streams. A failed generation, or one that settled without an
/// image, keeps its ordinary tool row.
public static class GeneratedImages
{
    public const string ToolName = "image_generate";

    /// History: the tool row `r` was just paired with its call; when that call is an image_generate that made an image,
    /// its tool part becomes the picture.
    public static void Apply(List<ChatPart> turn, JsonObject r, IReadOnlyDictionary<string, JsonNode?> args)
    {
        var callId = r.Text("tool_call_id");
        var name = r.Text("tool_name") ?? r.Text("name");
        for (var i = 0; i < turn.Count; i++)
        {
            if (turn[i] is not ToolPart { Call: var call } || call.Name != ToolName) continue;
            if (callId != null ? call.Id != callId : name != ToolName) continue;
            if (GeneratedImageInfo.From(args.GetValueOrDefault(call.Id), r.Get("content"), running: false) is { } info)
                turn[i] = new GeneratedImagePart(call.Id, info);
            return;
        }
    }

    /// Live: tool.complete's payload for a call named `name`; the picture, or null to keep the tool row.
    public static GeneratedImagePart? FromComplete(string id, string name, JsonNode? payload, bool failed) =>
        name == ToolName && !failed && GeneratedImageInfo.From(payload.Get("args"), payload.Get("result"), running: false) is { } info
            ? new GeneratedImagePart(id, info)
            : null;
}
