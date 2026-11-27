using Hermes.Core.Model;

namespace Hermes.Core.Transcripts;

/// [WIN-STEPS-AFTER-REPLY] The inspector's Steps: the latest turn's tool calls, in order (App/Chat/Activity/
/// ChatActivityController.swift `turnSteps(endingAt: nil)`, which `makeStepsList` feeds MacInspector's Steps). Read from
/// the chat's messages as they stand, so a finished reply keeps its steps for as long as its messages hold them: the
/// live turn's parts while it runs, then the stored turn the turn-end read brings (HermesKit TranscriptMerge.graft lets
/// the stored copy win, as Transcript.ReplaceWithHistory does here). A silent step shows only when it failed.
public static class LatestSteps
{
    /// StepSheets.swift `updateEmptyLine`, the inspector's (live) panel: whose steps these are and where earlier ones are.
    public const string EmptyTitle = "No Steps in the Latest Reply";
    public const string EmptyHint =
        "The tools a bot runs for its latest reply are listed here as it works. An earlier reply’s steps stay with that reply in the chat.";

    /// Every assistant message after the last prompt (or the whole chat when it has none), its visible tool calls.
    public static List<(ChatMessage Message, ToolCall Call)> Of(IReadOnlyList<ChatMessage> messages)
    {
        var o = new List<(ChatMessage, ToolCall)>();
        var end = messages.Count - 1;
        if (end < 0) return o;
        var start = end;
        while (start > 0 && messages[start - 1].Role != Role.User) start--;
        for (var i = start; i <= end; i++)
            if (messages[i].Role == Role.Assistant)
                foreach (var call in messages[i].Tools.Where(c => !RunSummary.Hidden(c))) o.Add((messages[i], call));
        return o;
    }
}
