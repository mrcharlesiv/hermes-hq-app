using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using Hermes.Core.Bots;
using Hermes.Core.Groups;
using Hermes.Core.Model;

namespace Hermes.Core.Transcripts;

// [updates] Background updates & bot exchanges folding (port of App/Chat/UpdateGroups.swift):
// folds bot-to-bot talks ("With <Bot> · N messages"), finished background work, superseded recurring cron runs,
// and system notes between real user/assistant messages while keeping voice chat transcripts, human messages,
// interactive prompts, and the bot's final answers to you outside the group.

public enum UpdateMarkKind { Glyph, Face }

public sealed record UpdateMark(UpdateMarkKind Kind, StepGlyph Glyph = StepGlyph.Other, ChatSender? Face = null)
{
    public static UpdateMark OfGlyph(StepGlyph glyph) => new(UpdateMarkKind.Glyph, Glyph: glyph);
    public static UpdateMark OfFace(ChatSender face) => new(UpdateMarkKind.Face, Face: face);
}

public sealed record UpdatesGroup(
    IReadOnlyList<UpdateMark> Marks,
    string? Tail,
    int Count,
    bool Opens,
    IReadOnlyList<string> Titles,
    bool HelperDetails = false);

public sealed record UpdateMemberRow(
    string Id,
    string MessageId,
    UpdateMark Mark,
    string Title,
    DateTimeOffset? Time,
    string? Day,
    string Preview,
    string Full,
    bool Process = false,
    bool Notice = false,
    IReadOnlyList<ToolCall>? Steps = null,
    string? Thought = null);

public sealed record UpdatesOpened(
    string Title,
    string Subtitle,
    IReadOnlyList<UpdateMemberRow> Members,
    int Fingerprint = 0);

public enum UpdateRowKind
{
    Bubble,
    BackgroundResult,
    ToolRun,
    Notice,
    Prompt,
    Error,
}

/// Lightweight per-row projection of a `ChatMessage` used by `UpdateGroups` and `BotSaidRules`.
public sealed record UpdateRow(
    string Id,
    string MessageId,
    UpdateRowKind Kind,
    string Title = "",
    string Text = "",
    bool Mine = false,
    ChatSender? Sender = null,
    bool Delivery = false,
    bool SentTo = false,
    bool ReplyToOurDM = false,
    bool Cron = false,
    bool Voice = false,
    bool Process = false,
    bool Aside = false,
    bool Expanded = false,
    bool Live = false,
    StepGlyph Glyph = StepGlyph.Other,
    IReadOnlyList<ToolCall>? Tools = null,
    string? Thought = null)
{
    public bool IsBubble => Kind == UpdateRowKind.Bubble;
}

public static class UpdateGroups
{
    /// The bot's first reply after your message stays when long enough to be the answer itself.
    public const int AnswerLength = 600;
    /// How far past a range the run search reaches each way.
    public const int Reach = 160;
    public const string LineSuffix = "|grp";
    public const string MemberSuffix = "|in";

    private static readonly Regex VoiceHeaderRx = new(
        @"^\[Voice chat transcript(?: · ([0-9:]{1,9}))?\][ \t]*(?:\r?\n|$)",
        RegexOptions.Compiled);
    private static readonly Regex HelperFinishedRx = new(
        @"^(?:\d+ )?[Hh]elpers? (?:finished|failed|stopped early|cancelled|interrupted|timed out|stalled)\b",
        RegexOptions.Compiled);
    private static readonly Regex FromToPrefixRx = new(@"^(?:From|To) ", RegexOptions.Compiled);
    private static readonly Regex DigitSpaceRx = new(@"(\d) ", RegexOptions.Compiled);
    private static readonly Regex WhitespaceRx = new(@"\s+", RegexOptions.Compiled);
    private static readonly CultureInfo EnUs = CultureInfo.GetCultureInfo("en-US");

    /// SHARED CONTRACT: true when `text` is a saved voice chat transcript (`[Voice chat transcript…]`),
    /// which stands alone as the person's own conversation and never folds into an update group or bot preview.
    public static bool IsVoiceTranscript(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return false;
        var trimmed = text.TrimStart();
        return trimmed.StartsWith("[Voice chat transcript", StringComparison.Ordinal)
            && (VoiceHeaderRx.IsMatch(trimmed) || trimmed.StartsWith("[Voice chat transcript", StringComparison.Ordinal));
    }

    public readonly record struct Member(int Message, int Row);

    public sealed record Group(IReadOnlyList<Member> Members)
    {
        public Member Head => Members[0];
        public int StartMessage => Members[0].Message;
        public int EndMessage => Members[^1].Message;
    }

    public sealed class Plan
    {
        public List<Group> Groups { get; } = [];
        public Dictionary<Member, int> ByMember { get; } = [];
        public Group? GroupOf(Member m) => ByMember.TryGetValue(m, out var idx) ? Groups[idx] : null;
    }

    public sealed class Input
    {
        public required IReadOnlyList<ChatMessage> Messages { get; init; }
        public string BotName { get; init; } = "Hermes";
        public IReadOnlyList<DeliveryMessages.Seat> Bots { get; init; } = [];
        public ChatSender? OwnFace { get; init; }
        public bool IsRoom { get; init; }
        public bool FewerTimes { get; init; } = true;
        public DateTimeOffset Now { get; init; } = DateTimeOffset.UtcNow;
    }

    /// Projects each `ChatMessage` into the `UpdateRow`s it draws alone, then computes folding verdicts
    /// (`WritesToBot`, `Interim`, `AnswersYou`, `SupersededCron`, `Small`).
    public sealed class Rows
    {
        public Input Input { get; }
        private readonly Dictionary<int, IReadOnlyList<UpdateRow>> _made = [];
        private readonly Dictionary<Member, bool> _interims = [];
        private readonly Dictionary<Member, bool> _cronSuperseded = [];
        private readonly Dictionary<int, bool> _toBot = [];

        public Rows(Input input) => Input = input;

        public IReadOnlyList<UpdateRow> At(int index)
        {
            if (_made.TryGetValue(index, out var cached)) return cached;
            var built = BuildMessageRows(Input.Messages[index], Input);
            _made[index] = built;
            return built;
        }

        public bool Small(Member m)
        {
            var row = At(m.Message)[m.Row];
            return IsSmall(row) || Interim(m) || SupersededCron(m);
        }

        /// Earlier non-silent reply to a recurring scheduled job when a newer run of the exact same job already replied
        /// later with no human turn between them.
        public bool SupersededCron(Member m)
        {
            if (_cronSuperseded.TryGetValue(m, out var cached)) return cached;
            var found = FindSupersededCron(m);
            _cronSuperseded[m] = found;
            return found;
        }

        private static string? CronJobKey(UpdateRow row)
        {
            if (row.Kind != UpdateRowKind.BackgroundResult || !row.Cron) return null;
            var name = Head(row.Title).Trim().ToLowerInvariant();
            return name.Length == 0 ? null : name;
        }

        private bool FindSupersededCron(Member m)
        {
            if (Input.IsRoom || !IsBotsReply(At(m.Message)[m.Row])) return false;
            string? jobKey = null;
            var minBack = Math.Max(0, m.Message - 8);
            for (var back = m.Message - 1; back >= minBack; back--)
            {
                var rows = At(back);
                for (var r = rows.Count - 1; r >= 0; r--)
                {
                    var row = rows[r];
                    if (CronJobKey(row) is { } key) { jobKey = key; goto FoundJob; }
                    if (IsSmall(row)) continue;
                    return false;
                }
            }
        FoundJob:
            if (jobKey == null) return false;
            var sawLaterSameJob = false;
            var maxAhead = Math.Min(Input.Messages.Count, m.Message + Reach + 1);
            for (var i = m.Message + 1; i < maxAhead; i++)
            {
                foreach (var row in At(i))
                {
                    if (EndsTalk(row)) return false;
                    if (CronJobKey(row) is { } key && key == jobKey) { sawLaterSameJob = true; continue; }
                    if (sawLaterSameJob && IsBotsReply(row)) return true;
                }
            }
            return false;
        }

        /// One of this bot's replies inside a talk with another bot (or background work finishing).
        public bool Interim(Member m)
        {
            if (_interims.TryGetValue(m, out var cached)) return cached;
            var found = FindInterim(m);
            _interims[m] = found;
            return found;
        }

        private bool FindInterim(Member m)
        {
            if (Input.IsRoom || !IsBotsReply(At(m.Message)[m.Row])) return false;
            if (WritesToBot(m.Message)) return true;
            if (AnswersYou(m)) return false;

            var talked = false;
            var answered = false;
            var maxAhead = Math.Min(Input.Messages.Count, m.Message + Reach + 1);
            for (var i = m.Message; i < maxAhead; i++)
            {
                var own = At(i);
                for (var r = 0; r < own.Count; r++)
                {
                    if (i == m.Message && r <= m.Row) continue;
                    var row = own[r];
                    if (EndsTalk(row)) goto DoneAhead;
                    if (IsTalk(row)) talked = true;
                    if (talked && IsBotsReply(row) && !WritesToBot(i)) { answered = true; goto DoneAhead; }
                }
            }
        DoneAhead:
            if (!answered) return false;

            var minBack = Math.Max(0, m.Message - Reach);
            for (var i = m.Message; i >= minBack; i--)
            {
                var own = At(i);
                var upper = i == m.Message ? m.Row : own.Count;
                for (var r = upper - 1; r >= 0; r--)
                {
                    var row = own[r];
                    if (EndsTalk(row)) return false;
                    if (IsTalk(row)) return true;
                }
            }
            return false;
        }

        /// The reply is written to the bot whose message it answers, not to you.
        public bool WritesToBot(int messageIndex)
        {
            if (_toBot.TryGetValue(messageIndex, out var cached)) return cached;
            var found = FindWritesToBot(messageIndex);
            _toBot[messageIndex] = found;
            return found;
        }

        private bool MessageAsksUser(int messageIndex)
        {
            var m = Input.Messages[messageIndex];
            if (m.Role != Role.Assistant) return false;
            if (At(messageIndex).Any(r => r.Kind == UpdateRowKind.Prompt)) return true;
            return m.Tools.Any(c => c.Name is "clarify" or "ask_user" or "draft_message");
        }

        private bool FindWritesToBot(int messageIndex)
        {
            var msg = Input.Messages[messageIndex];
            if (msg.IsStreaming || MessageAsksUser(messageIndex)) return false;
            var firstReply = At(messageIndex).FirstOrDefault(IsBotsReply);
            if (firstReply == null) return false;

            var minBack = Math.Max(0, messageIndex - 8);
            for (var i = messageIndex - 1; i >= minBack; i--)
            {
                var own = At(i);
                for (var r = own.Count - 1; r >= 0; r--)
                {
                    var row = own[r];
                    if (row.Kind != UpdateRowKind.BackgroundResult || !IsBotTalk(row))
                    {
                        if (IsSmall(row) && !EndsTalk(row)) continue;
                        return false;
                    }
                    if (row.SentTo) return false;
                    // #601: `bot_mode_dm.py --run-delivery` is the other bot's reply to our own `message_agent`.
                    if (row.ReplyToOurDM) return false;
                    if (row.Sender is { } bot && !Asked(bot, new Member(i, r))) return true;
                    var title = Head(row.Title);
                    var names = new List<string>();
                    if (row.Sender?.Name is { Length: > 0 } sn) names.Add(sn);
                    if (row.Sender?.Profile is { Length: > 0 } sp) names.Add(sp);
                    if (title.StartsWith("From ", StringComparison.Ordinal)) names.Add(title["From ".Length..]);
                    return BotDMs.SpeaksTo(names, firstReply.Text) || BotDMs.IsInternalAck(firstReply.Text);
                }
            }
            return false;
        }

        private bool Asked(ChatSender bot, Member before)
        {
            var minBack = Math.Max(0, before.Message - Reach);
            for (var i = before.Message; i >= minBack; i--)
            {
                var own = At(i);
                var upper = i == before.Message ? before.Row : own.Count;
                for (var r = upper - 1; r >= 0; r--)
                {
                    var row = own[r];
                    if (EndsTalk(row)) return false;
                    if (row.Kind == UpdateRowKind.BackgroundResult && row.SentTo && row.Sender is { } face && SameBot(face, bot))
                        return true;
                }
            }
            return false;
        }

        /// True when the bot's first reply after your message is long enough (`AnswerLength`) to stand as your answer.
        public bool AnswersYou(Member m)
        {
            var row = At(m.Message)[m.Row];
            if (row.Kind != UpdateRowKind.Bubble || row.Text.Length < AnswerLength) return false;
            var minBack = Math.Max(0, m.Message - Reach);
            for (var i = m.Message; i >= minBack; i--)
            {
                var own = At(i);
                var upper = i == m.Message ? m.Row : own.Count;
                for (var r = upper - 1; r >= 0; r--)
                {
                    var prev = own[r];
                    if (EndsTalk(prev)) return true;
                    if (IsBotsReply(prev)) return false;
                }
            }
            return false;
        }
    }

    /// Converts one `ChatMessage` into the `UpdateRow`s `UpdateGroups` classifies.
    public static IReadOnlyList<UpdateRow> BuildMessageRows(ChatMessage m, Input input)
    {
        var list = new List<UpdateRow>();
        if (m.Role == Role.System)
        {
            var text = m.Text.Trim();
            if (text.Length == 0) return list;
            if (m.Error != null)
            {
                list.Add(new UpdateRow($"{m.Id}|err", m.Id, UpdateRowKind.Error, Text: text));
                return list;
            }
            if (m.Job != null || TimelineNotes.IsScheduledWake(text))
            {
                var wakeTitle = m.Job ?? TimelineNotes.ScheduledWake(text)?.Title ?? text;
                list.Add(new UpdateRow($"{m.Id}|bg", m.Id, UpdateRowKind.BackgroundResult, Title: wakeTitle, Text: text, Cron: true));
                return list;
            }
            if (CronDeliveries.ProcessNote(text) is { } procWords)
            {
                var split = TimelineNotes.ProcessHeadline(procWords);
                var title = split?.Headline ?? "Background task finished";
                var body = split?.Detail ?? procWords;
                list.Add(new UpdateRow($"{m.Id}|bg", m.Id, UpdateRowKind.BackgroundResult, Title: title, Text: body, Process: true));
                return list;
            }
            if (TimelineNotes.ProcessHeadline(text) is { } ph)
            {
                list.Add(new UpdateRow($"{m.Id}|bg", m.Id, UpdateRowKind.BackgroundResult, Title: ph.Headline, Text: ph.Detail, Process: true));
                return list;
            }
            if (HelperFinishedRx.IsMatch(text))
            {
                list.Add(new UpdateRow($"{m.Id}|bg", m.Id, UpdateRowKind.BackgroundResult, Title: text, Text: text, Glyph: StepGlyph.Subagent));
                return list;
            }
            var note = TimelineNotes.Note(text);
            if (note.Kind == TimelineNoteKind.Hidden) return list;
            list.Add(new UpdateRow($"{m.Id}|note", m.Id, UpdateRowKind.Notice, Title: note.Text, Text: note.Text));
            return list;
        }

        if (m.Role == Role.User)
        {
            var text = m.Text.Trim();
            if (IsVoiceTranscript(text))
            {
                list.Add(new UpdateRow($"{m.Id}|voice", m.Id, UpdateRowKind.BackgroundResult, Title: "Voice chat", Text: text, Voice: true));
                return list;
            }
            if (m.Job != null || CronDeliveries.MayBeCron(text))
            {
                var parsed = CronDeliveries.Parse(text);
                var job = m.Job ?? parsed?.Job ?? "Scheduled job";
                var body = parsed?.Body ?? text;
                list.Add(new UpdateRow($"{m.Id}|bg", m.Id, UpdateRowKind.BackgroundResult, Title: job, Text: body, Cron: true, Sender: m.Sender));
                return list;
            }
            if (m.Sender != null)
            {
                list.Add(new UpdateRow($"{m.Id}|bg", m.Id, UpdateRowKind.BackgroundResult,
                    Title: $"From {m.Sender.Name}", Text: text, Sender: m.Sender, Delivery: true, ReplyToOurDM: m.ReplyToOurDM));
                return list;
            }
            if (TimelineNotes.IsScheduledWake(text) && TimelineNotes.ScheduledWake(text) is { } wake)
            {
                list.Add(new UpdateRow($"{m.Id}|bg", m.Id, UpdateRowKind.BackgroundResult, Title: wake.Title, Text: wake.Detail, Cron: true));
                return list;
            }
            list.Add(new UpdateRow($"{m.Id}|u", m.Id, UpdateRowKind.Bubble, Text: text, Mine: true));
            return list;
        }

        // Assistant turn: tools (message_agent -> SentTo rows, clarify -> Prompt, other tools -> ToolRun) and reply bubble.
        var nonDmTools = new List<ToolCall>();
        string? thought = null;
        var dmIndex = 0;
        foreach (var part in m.Parts)
        {
            switch (part)
            {
                case ReasoningPart rp when !string.IsNullOrWhiteSpace(rp.Text):
                    thought = thought == null ? rp.Text.Trim() : thought + "\n\n" + rp.Text.Trim();
                    break;
                case ToolPart tp:
                    var call = tp.Call;
                    if (call.Name == BotDMs.Tool)
                    {
                        var args = ToolArgs.Of(call);
                        var target = ToolArgs.FirstString(args, "target", "profile", "agent", "to", "recipient");
                        var body = ToolArgs.FirstString(args, "message", "text", "content", "prompt");
                        var face = target.Length > 0 ? BotDMs.Sender(target, input.Bots) : null;
                        var toTitle = face != null ? $"To {face.Name}" : (target.Length > 0 ? $"To {target}" : "To another bot");
                        list.Add(new UpdateRow($"{m.Id}|dm{dmIndex++}", m.Id, UpdateRowKind.BackgroundResult,
                            Title: toTitle, Text: body, Sender: face, SentTo: true));
                    }
                    else if (call.Name is "clarify" or "ask_user" or "draft_message")
                    {
                        list.Add(new UpdateRow($"{m.Id}|prompt-{call.Id}", m.Id, UpdateRowKind.Prompt, Title: call.Name, Text: call.ArgsText ?? ""));
                    }
                    else if (!RunSummary.Hidden(call))
                    {
                        nonDmTools.Add(call);
                    }
                    break;
            }
        }
        if (nonDmTools.Count > 0)
        {
            var live = m.IsStreaming || nonDmTools.Any(t => t.State == ToolState.Running);
            var summary = RunSummary.Summarize(nonDmTools, live);
            list.Add(new UpdateRow($"{m.Id}|tools", m.Id, UpdateRowKind.ToolRun, Title: summary, Text: summary,
                Live: live, Glyph: RunSummary.GlyphFor(summary), Tools: nonDmTools, Thought: thought));
        }

        var replyText = m.Text.Trim();
        if (replyText.Length > 0 && !TimelineNotes.IsSilentWords(replyText))
        {
            if (IsVoiceTranscript(replyText))
                list.Add(new UpdateRow($"{m.Id}|voice", m.Id, UpdateRowKind.BackgroundResult, Title: "Voice chat", Text: replyText, Voice: true));
            else if (CronDeliveries.MayBeCron(replyText) && CronDeliveries.Parse(replyText) is { } cronReply)
                list.Add(new UpdateRow($"{m.Id}|bg", m.Id, UpdateRowKind.BackgroundResult, Title: cronReply.Job, Text: cronReply.Body, Cron: true, Sender: m.Sender));
            else
                list.Add(new UpdateRow($"{m.Id}|a", m.Id, UpdateRowKind.Bubble, Title: input.BotName, Text: replyText, Mine: false, Sender: m.Sender));
        }
        if (m.Error != null)
            list.Add(new UpdateRow($"{m.Id}|err", m.Id, UpdateRowKind.Error, Text: m.Error));
        return list;
    }

    public static bool IsSmall(UpdateRow row) => row.Kind switch
    {
        UpdateRowKind.BackgroundResult => true,
        UpdateRowKind.Notice => true,
        UpdateRowKind.ToolRun => !row.Live,
        _ => false,
    };

    public static bool EndsTalk(UpdateRow row) => row.Kind switch
    {
        UpdateRowKind.Bubble => row.Mine,
        UpdateRowKind.BackgroundResult => row.Cron,
        UpdateRowKind.Prompt => true,
        _ => false,
    };

    public static bool IsBotsReply(UpdateRow row) => row.Kind == UpdateRowKind.Bubble && !row.Mine && row.Sender == null;

    public static bool IsBotTalk(UpdateRow row) =>
        row.Kind == UpdateRowKind.BackgroundResult && (row.SentTo || (row.Delivery && !row.Cron));

    public static bool IsWorkFinished(UpdateRow row) =>
        row.Kind == UpdateRowKind.BackgroundResult
        && !row.Delivery && !row.Cron && !row.Aside && !row.Voice && !row.SentTo
        && (row.Process || HelperFinishedRx.IsMatch(row.Title));

    public static bool IsTalk(UpdateRow row) => IsBotTalk(row) || IsWorkFinished(row);

    public static bool SameBot(ChatSender a, ChatSender b) =>
        a.Key == b.Key || string.Equals(a.Name.Trim(), b.Name.Trim(), StringComparison.OrdinalIgnoreCase);

    /// A voice chat transcript or an open `/btw` stands alone and never folds into an update group.
    public static bool StandsAlone(UpdateRow row) =>
        row.Kind == UpdateRowKind.BackgroundResult && (row.Voice || (row.Aside && row.Expanded));

    public static bool FailedYours(Member m, Rows rows)
    {
        var row = rows.At(m.Message)[m.Row];
        if (row.Kind != UpdateRowKind.Notice || !TimelineNotes.IsFailedTurn(row.Text)) return false;
        var minScan = Math.Max(0, m.Message - 8);
        for (var scan = m.Message - 1; scan >= minScan; scan--)
        {
            var before = rows.Input.Messages[scan];
            if (before.Role == Role.User) return before.Sender == null && before.Job == null;
            if (before.Role == Role.Assistant) return false;
        }
        return false;
    }

    private static bool JoinsRun(Member m, Rows rows) =>
        rows.Small(m) && !StandsAlone(rows.At(m.Message)[m.Row]) && !FailedYours(m, rows);

    public static string Key(Group group, Rows rows)
    {
        var own = rows.At(group.Head.Message);
        var messageId = rows.Input.Messages[group.Head.Message].Id;
        var splits = false;
        for (var r = 0; r < group.Head.Row; r++)
            if (rows.Small(new Member(group.Head.Message, r))) { splits = true; break; }
        return splits ? own[group.Head.Row].Id + LineSuffix : messageId + LineSuffix;
    }

    public static Plan BuildPlan(Input input, int startIndex = 0, int? count = null, Rows? existingRows = null)
    {
        var messages = input.Messages;
        var len = count ?? (messages.Count - startIndex);
        if (len <= 0 || startIndex < 0 || startIndex + len > messages.Count) return new Plan();
        var rows = existingRows ?? new Rows(input);
        var endExclusive = startIndex + len;

        bool EndsSmall(int i)
        {
            var list = rows.At(i);
            return list.Count == 0 || JoinsRun(new Member(i, list.Count - 1), rows);
        }
        bool StartsSmall(int i)
        {
            var list = rows.At(i);
            return list.Count == 0 || JoinsRun(new Member(i, 0), rows);
        }

        var start = startIndex;
        while (start > 0 && startIndex - start < Reach && EndsSmall(start - 1) && StartsSmall(start)) start--;
        var end = endExclusive - 1;
        while (end + 1 < messages.Count && end - (endExclusive - 1) < Reach && EndsSmall(end) && StartsSmall(end + 1)) end++;

        var plan = new Plan();
        var run = new List<Member>();
        void Close()
        {
            if (run.Count == 0) return;
            var groupIndex = plan.Groups.Count;
            foreach (var member in run) plan.ByMember[member] = groupIndex;
            plan.Groups.Add(new Group([.. run]));
            run.Clear();
        }

        for (var i = start; i <= end; i++)
        {
            var own = rows.At(i);
            for (var r = 0; r < own.Count; r++)
            {
                var m = new Member(i, r);
                var row = own[r];
                if (StandsAlone(row) || FailedYours(m, rows))
                {
                    Close();
                    run.Add(m);
                    Close();
                }
                else if (rows.Small(m))
                {
                    run.Add(m);
                }
                else
                {
                    Close();
                }
            }
        }
        Close();
        return plan;
    }

    private sealed record GroupItem(string Id, UpdateRow Original, int MessageIndex, string Title, UpdateMark Mark, int Rank);

    public static int Rank(UpdateRow row) => row.Kind switch
    {
        UpdateRowKind.BackgroundResult => row.SentTo ? 4 : row.Delivery ? 5 : row.Cron ? 2 : 3,
        UpdateRowKind.ToolRun => 1,
        _ => 0,
    };

    private static List<GroupItem> Items(Group group, Rows rows)
    {
        var out_ = new List<GroupItem>();
        foreach (var member in group.Members)
        {
            var row = rows.At(member.Message)[member.Row];
            switch (row.Kind)
            {
                case UpdateRowKind.BackgroundResult:
                    out_.Add(new GroupItem(row.Id, row, member.Message, row.Title,
                        row.Sender != null ? UpdateMark.OfFace(row.Sender) : UpdateMark.OfGlyph(row.Glyph), Rank(row)));
                    break;
                case UpdateRowKind.ToolRun:
                    out_.Add(new GroupItem(row.Id, row, member.Message, row.Title, UpdateMark.OfGlyph(row.Glyph), 1));
                    break;
                case UpdateRowKind.Notice:
                    out_.Add(new GroupItem(row.Id, row, member.Message, row.Title, UpdateMark.OfGlyph(StepGlyph.Other), 0));
                    break;
                case UpdateRowKind.Bubble:
                    out_.Add(new GroupItem(row.Id, row, member.Message, rows.Input.BotName,
                        rows.Input.OwnFace != null ? UpdateMark.OfFace(rows.Input.OwnFace) : UpdateMark.OfGlyph(StepGlyph.Other), -1));
                    break;
            }
        }
        return out_;
    }

    private static string? TalkedWith(IReadOnlyList<GroupItem> all)
    {
        if (!all.Any(i => i.Original.IsBubble)) return null;
        var names = new List<string>();
        foreach (var item in all)
        {
            if (!IsBotTalk(item.Original)) continue;
            var name = item.Original.Sender?.Name?.Trim()
                ?? FromToPrefixRx.Replace(Head(item.Title), "").Trim();
            if (name.Length > 0 && !names.Contains(name, StringComparer.Ordinal)) names.Add(name);
        }
        return names.Count switch
        {
            0 => null,
            1 => $"With {names[0]}",
            2 => $"With {names[0]} and {names[1]}",
            _ => $"With {names.Count} bots",
        };
    }

    private static string? CronRunTitle(IReadOnlyList<GroupItem> all)
    {
        var cronItems = all.Where(i => i.Original.Kind == UpdateRowKind.BackgroundResult && i.Original.Cron).ToList();
        var cronReplies = all.Count(i => i.Original.IsBubble);
        if (cronItems.Count == 0 || cronReplies == 0) return null;
        var keys = cronItems.Select(i => Head(i.Title).Trim().ToLowerInvariant()).ToHashSet();
        return keys.Count == 1 ? Head(cronItems[0].Title) : null;
    }

    private static (string Tail, string Whole) Counts(IReadOnlyList<GroupItem> all, string? talk)
    {
        var titles = all.Select(i => Head(i.Title).Split(" · ")[0]).ToList();
        var sameBot = all.All(i => i.Rank >= 4) && titles.Distinct(StringComparer.Ordinal).Count() == 1;
        var said = all.Count(i => i.Original.IsBubble || IsBotTalk(i.Original));
        if (talk != null) return ($"{said} messages", $"{said} messages");
        if (CronRunTitle(all) != null)
        {
            var cronReplies = all.Count(i => i.Original.IsBubble);
            var label = cronReplies == 1 ? "1 earlier run" : $"{cronReplies} earlier runs";
            return (label, label);
        }
        if (sameBot) return ($"{all.Count} messages", $"{all.Count} messages");
        return ($"{all.Count - 1} more", $"{all.Count} updates");
    }

    /// Summary line label for a folded multi-member group: e.g. `"With Otto · 4 messages"`, `"From Hermes · 2 messages"`.
    public static (string Line, UpdatesGroup Group)? Summary(Group group, Rows rows)
    {
        var all = Items(group, rows);
        if (all.Count <= 1) return null;
        var ordered = all.Select((item, idx) => (item, idx))
            .OrderByDescending(x => x.item.Rank)
            .ThenByDescending(x => x.idx)
            .Select(x => x.item)
            .ToList();
        var talk = TalkedWith(all);
        var cronTitle = talk == null ? CronRunTitle(all) : null;
        var marks = new List<UpdateMark>();
        foreach (var item in ordered)
        {
            if (marks.Count >= 3) break;
            if ((talk != null || cronTitle != null) && item.Original.IsBubble) continue;
            if (!marks.Any(m => SameMark(m, item.Mark))) marks.Add(item.Mark);
        }
        var lead = Short(talk ?? cronTitle ?? Head(ordered[0].Title));
        var (tail, _) = Counts(all, talk);
        var titles = all.Select(i => Head(i.Title).Split(" · ")[0]).ToList();
        var ug = new UpdatesGroup(marks, tail, all.Count, true, titles);
        return ($"{lead} · {tail}", ug);
    }

    /// Builds the `UpdatesOpened` sheet model for a multi-member group (using `m.LatestTimestamp ?? m.Timestamp`).
    public static UpdatesOpened? Opened(Group group, Rows rows)
    {
        var all = Items(group, rows);
        if (all.Count <= 1) return null;
        var talk = TalkedWith(all);
        var cronTitle = talk == null ? CronRunTitle(all) : null;
        var titles = all.Select(i => Head(i.Title).Split(" · ")[0]).Distinct(StringComparer.Ordinal).ToList();
        var sameBot = all.All(i => i.Rank >= 4) && titles.Count == 1;
        var title = talk ?? (cronTitle != null ? Short(cronTitle) : (sameBot ? Short(Head(all[0].Title)) : "Updates"));

        var times = group.Members
            .Select(m => rows.Input.Messages[m.Message] is var msg ? (msg.LatestTimestamp ?? msg.Timestamp) : null)
            .Where(t => t.HasValue)
            .Select(t => t!.Value)
            .ToList();
        var dated = times.Count >= 2 && LocalDay(times.Min()) != LocalDay(times.Max());
        var members = all.Select(item => BuildMember(item, dated, rows.Input)).ToList();

        var (_, whole) = Counts(all, talk);
        var subtitle = whole;
        if (times.Count > 0) subtitle += " · " + Span(times.Min(), times.Max(), rows.Input.Now);

        var hash = new HashCode();
        hash.Add(title);
        hash.Add(subtitle);
        foreach (var mem in members)
        {
            hash.Add(mem.Id);
            hash.Add(mem.Title);
            hash.Add(mem.Full);
            hash.Add(mem.Time);
        }
        return new UpdatesOpened(title, subtitle, members, hash.ToHashCode());
    }

    private static UpdateMemberRow BuildMember(GroupItem item, bool dated, Input input)
    {
        var msg = input.Messages[item.MessageIndex];
        var stamp = msg.LatestTimestamp ?? msg.Timestamp;
        var day = dated && stamp is { } s ? DayName(s, input.Now) : null;
        return item.Original.Kind switch
        {
            UpdateRowKind.BackgroundResult => new UpdateMemberRow(
                item.Id + MemberSuffix, msg.Id, item.Mark, Head(item.Title), stamp, day,
                Preview(item.Original.Text, item.Original.Process), item.Original.Text,
                Process: item.Original.Process),
            UpdateRowKind.ToolRun => new UpdateMemberRow(
                item.Id + MemberSuffix, msg.Id, item.Mark, item.Title, stamp, day,
                item.Original.Tools is { Count: > 1 } tools ? Counted(RunSummary.Summarize(tools, false)) : "",
                "", Steps: item.Original.Tools, Thought: item.Original.Thought),
            UpdateRowKind.Notice => new UpdateMemberRow(
                item.Id + MemberSuffix, msg.Id, item.Mark, Head(item.Title), stamp, day, "", "", Notice: true),
            UpdateRowKind.Bubble => new UpdateMemberRow(
                item.Id + MemberSuffix, msg.Id, item.Mark, Head(item.Title), stamp, day,
                Preview(item.Original.Text), item.Original.Text),
            _ => new UpdateMemberRow(item.Id + MemberSuffix, msg.Id, item.Mark, Head(item.Title), stamp, day, "", ""),
        };
    }

    public static string Head(string title)
    {
        var colon = title.IndexOf(": ", StringComparison.Ordinal);
        return colon > 0 ? title[..colon] : title;
    }

    private static string Short(string title) => title.Length > 44 ? title[..43].TrimEnd() + "…" : title;

    private static bool SameMark(UpdateMark a, UpdateMark b) =>
        a.Kind == UpdateMarkKind.Face && b.Kind == UpdateMarkKind.Face
            ? a.Face?.Key == b.Face?.Key
            : a == b;

    /// Holds a count to its noun with a non-breaking space ("1\u00A0task", "2\u00A0commands").
    public static string Counted(string words) => DigitSpaceRx.Replace(words, "$1\u00A0");

    public static string Preview(string text, bool process = false)
    {
        var slice = text.Length > 1_200 ? text[..1_200] : text;
        var lines = slice.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries)
            .Select(l => WhitespaceRx.Replace(RosterPreview.StripMarkdown(l), " ").Trim())
            .Where(l => l.Length > 0)
            .ToList();
        if (process && lines.Any(l => !l.StartsWith('>'))) lines.RemoveAll(l => l.StartsWith('>'));
        var sb = new StringBuilder();
        foreach (var line in lines)
        {
            if (sb.Length > 0)
            {
                var last = sb[^1];
                sb.Append(".!?:;,…".Contains(last) || line.StartsWith('•') ? " " : " — ");
            }
            sb.Append(line);
        }
        return sb.ToString();
    }

    /// When a run happened: "7:15 AM", "7:02 – 7:15 AM", "Oct 31 – Yesterday".
    public static string Span(DateTimeOffset first, DateTimeOffset last, DateTimeOffset now)
    {
        if (LocalDay(first) != LocalDay(last))
            return $"{DayName(first, now)} – {DayName(last, now)}";
        var a = Clock(first);
        var b = Clock(last);
        var prefix = LocalDay(first) == LocalDay(now) ? "" : DayName(first, now) + " ";
        if (a == b) return prefix + a;
        if (a.Length > 3 && b.Length > 3 && a[^2..] == b[^2..])
            return $"{prefix}{a[..^3]} – {b}";
        return $"{prefix}{a} – {b}";
    }

    private static DateOnly LocalDay(DateTimeOffset t) => DateOnly.FromDateTime(t.LocalDateTime);
    private static string Clock(DateTimeOffset t) => t.LocalDateTime.ToString("h:mm tt", EnUs);

    private static string DayName(DateTimeOffset t, DateTimeOffset now)
    {
        var d = LocalDay(t);
        var today = LocalDay(now);
        if (d == today) return "Today";
        if (d == today.AddDays(-1)) return "Yesterday";
        return t.LocalDateTime.Year == now.LocalDateTime.Year
            ? t.LocalDateTime.ToString("MMM d", EnUs)
            : t.LocalDateTime.ToString("MMM d, yyyy", EnUs);
    }
}
