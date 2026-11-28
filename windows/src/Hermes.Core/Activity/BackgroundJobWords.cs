using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Model;

namespace Hermes.Core.Activity;

// Port of HermesKit/Push/BackgroundTaskText.swift and HermesKit/Chat/BackgroundJobWords.swift:
// What a running background job is FOR, in words. A row is named, in order, by:
//   1. the command's leading `# comment` (the bot named the job itself);
//   2. the bot's own sentence just before the terminal call that started it, in this chat's transcript;
//   3. a coding agent's prompt ("Claude Code: Fix the four goal set-up issues");
//   4. the program it runs and its folder (BackgroundTaskText.Title).
// Under the name: the agent and folder ("Claude Code · goals-2"). Then the newest output line, or an honest quiet line.

/// Words for a background process command: `# comment`, program, folder, quiet redirect target, and alert summary.
/// Port of HermesKit/Push/BackgroundTaskText.swift.
public static class BackgroundTaskText
{
    private static readonly HashSet<string> LeadingWrappers = new(StringComparer.Ordinal)
    {
        "do", "then", "else", "nohup", "time", "exec", "{", "(",
    };

    private static readonly HashSet<string> SetupWords = new(StringComparer.Ordinal)
    {
        "export", "source", ".", "set", "unset", "true", "echo", "sleep", "popd", "umask", "ulimit",
        "for", "while", "until", "if", "elif", "case", "done", "fi", "esac", "}", ")", "[", "[[", "test", "wait", "printf",
    };

    private static readonly char[] RedirectTrimChars = ['"', '\'', ';', '&', '|', ')'];
    private static readonly char[] PathTrimChars = ['"', '\'', ' '];

    public static bool Failed(int? exitCode) => (exitCode ?? 0) != 0;

    public static string Line(string? command, string? status, int? exitCode, string? tail)
    {
        _ = status;
        var head = Title(command);
        if (exitCode is { } code) head += $" (exit {code})";
        var tailLines = (tail ?? "")
            .Replace("\r\n", "\n", StringComparison.Ordinal)
            .Split(['\n', '\r'], StringSplitOptions.RemoveEmptyEntries)
            .Select(l => l.Trim(' ', '\t'))
            .Where(l => l.Length > 0)
            .TakeLast(3)
            .ToList();
        var title = Failed(exitCode) ? "Background task failed" : "Background task finished";
        var all = new List<string>(1 + tailLines.Count) { $"{title}: {head}" };
        all.AddRange(tailLines);
        var joined = string.Join("\n", all);
        return joined.Length > 240 ? joined[..240] : joined;
    }

    /// A readable name for a background command: "Archiving Mac build 42" for `# Archiving Mac build 42\n…`,
    /// "python3 scripts/ship.py archive · ship-42-mac" for `cd …/ship-42-mac && BUILD=42 python3 scripts/ship.py archive > log`.
    public static string Title(string? command)
    {
        if (Comment(command) is { } comment) return comment;
        var (run, folder) = Parts(command);
        if (run is not null) return folder is not null ? $"{run} · {folder}" : run;
        if (folder is not null) return $"cd {folder}";
        foreach (var line in Lines(command))
            if (!line.StartsWith('#')) return line;
        return "background process";
    }

    /// The bot's own name for the job: a `# comment` before its first command (not a `#!` shebang line).
    public static string? Comment(string? command)
    {
        var lines = Lines(command);
        if (lines.Count == 0) return null;
        var first = lines[0];
        if (!first.StartsWith('#') || first.StartsWith("#!", StringComparison.Ordinal)) return null;
        var words = first.TrimStart('#').Trim(' ', '\t');
        return words.Length == 0 ? null : words;
    }

    /// The first real program it runs ("python3 scripts/ship.py archive"), past setup steps.
    public static string? Program(string? command) => Parts(command).Run;

    /// The folder it moved into before that program (the last path component of its `cd`).
    public static string? Folder(string? command) => Parts(command).Folder;

    /// What a quiet job's row says under its name: "Writing to archive.log" when its output goes to a file,
    /// else "No output yet".
    public static string QuietLine(string? command)
    {
        var words = (command ?? "").Split([' ', '\n', '\r'], StringSplitOptions.RemoveEmptyEntries);
        for (var i = 0; i < words.Length; i++)
        {
            var word = words[i];
            string? target = null;
            if (word is ">" or ">>" or "&>" or "1>")
                target = i + 1 < words.Length ? words[i + 1] : null;
            else if (word.StartsWith(">>", StringComparison.Ordinal)
                || word.StartsWith("&>", StringComparison.Ordinal)
                || word.StartsWith("1>", StringComparison.Ordinal))
                target = word[2..];
            else if (word.StartsWith('>') && !word.StartsWith(">&", StringComparison.Ordinal))
                target = word[1..];

            var path = target?.Trim(RedirectTrimChars);
            if (string.IsNullOrEmpty(path) || path.StartsWith('&') || path == "/dev/null") continue;
            var name = LastPathComponent(path) ?? path;
            return $"Writing to {name}";
        }
        return "No output yet";
    }

    private static List<string> Lines(string? command)
    {
        if (string.IsNullOrEmpty(command)) return [];
        var normalized = command.Replace("\r\n", "\n", StringComparison.Ordinal);
        var result = new List<string>();
        foreach (var raw in normalized.Split(['\n', '\r']))
        {
            var trimmed = raw.Trim(' ', '\t');
            if (trimmed.Length > 0) result.Add(trimmed);
        }
        return result;
    }

    private static (string? Run, string? Folder) Parts(string? command)
    {
        string? folder = null;
        foreach (var line in Lines(command))
        {
            if (line.StartsWith('#')) continue;
            foreach (var segment in Segments(line))
            {
                if (ChangedDirectory(segment) is { } dir)
                {
                    folder = dir;
                    continue;
                }
                if (ExtractProgram(segment) is { } run) return (run, folder);
            }
        }
        return (null, folder);
    }

    private static List<string> Segments(string line)
    {
        var parts = new List<string> { line };
        foreach (var sep in new[] { "&&", "||", ";" })
        {
            var next = new List<string>();
            foreach (var p in parts) next.AddRange(p.Split(sep, StringSplitOptions.None));
            parts = next;
        }
        var cleaned = new List<string>(parts.Count);
        foreach (var p in parts)
        {
            var t = p.Trim(' ', '\t');
            if (t.Length > 0) cleaned.Add(t);
        }
        return cleaned;
    }

    private static string? ChangedDirectory(string segment)
    {
        var words = segment.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (words.Length == 0 || words[0] is not ("cd" or "pushd")) return null;
        var path = string.Join(" ", words[1..]).Trim(PathTrimChars);
        var last = LastPathComponent(path) ?? path;
        return last.Length == 0 || last == "~" ? "home" : last;
    }

    private static string? ExtractProgram(string segment)
    {
        var words = new List<string>(segment.Split(' ', StringSplitOptions.RemoveEmptyEntries));
        while (words.Count > 0 && LeadingWrappers.Contains(words[0])) words.RemoveAt(0);
        if (words.Count == 0 || SetupWords.Contains(words[0])) return null;
        // `s=$(wc -l < f)` captures a value; it isn't the job.
        if (IsAssignment(words[0]) && (words[0].Contains("$(", StringComparison.Ordinal) || words[0].Contains('`')))
            return null;
        while (words.Count > 0 && IsAssignment(words[0])) words.RemoveAt(0);
        if (words.Count > 0 && words[0] == "env")
        {
            words.RemoveAt(0);
            while (words.Count > 0 && IsAssignment(words[0])) words.RemoveAt(0);
        }
        var kept = new List<string>(words.Count);
        foreach (var word in words)
        {
            if (word is "|" or "&"
                || word.StartsWith('>')
                || word.StartsWith("2>", StringComparison.Ordinal)
                || word.StartsWith("&>", StringComparison.Ordinal)
                || word.StartsWith('<'))
                break;
            kept.Add(word);
        }
        var run = string.Join(" ", kept);
        return run.Length == 0 || run.StartsWith('-') ? null : run;
    }

    private static bool IsAssignment(string word)
    {
        var eq = word.IndexOf('=');
        if (eq <= 0) return false;
        for (var i = 0; i < eq; i++)
        {
            var c = word[i];
            if (!(c == '_' || char.IsLetterOrDigit(c))) return false;
        }
        return true;
    }

    internal static string? LastPathComponent(string path)
    {
        if (string.IsNullOrEmpty(path)) return null;
        var parts = path.Split(['/', '\\'], StringSplitOptions.RemoveEmptyEntries);
        return parts.Length > 0 ? parts[^1] : null;
    }
}

/// Purpose naming, agent detection, transcript matching, and friendly labels for running background commands.
/// Port of HermesKit/Chat/BackgroundJobWords.swift.
public static class BackgroundJobWords
{
    /// A coding agent run headless: its name and the prompt it was given.
    public sealed record AgentInfo(string Name, string? Prompt);

    /// What the chat's transcript knows about the `terminal` call that started `command`.
    public sealed record TranscriptMatch(
        string? BotWords,
        string? FullBotWords,
        string? BotNote,
        string? FullCommand);

    private static readonly (string Binary, string Name, HashSet<string> Triggers)[] KnownAgents =
    [
        ("claude", "Claude Code", new HashSet<string>(StringComparer.Ordinal) { "-p", "--print" }),
        ("codex", "Codex", new HashSet<string>(StringComparer.Ordinal) { "exec", "e" }),
        ("gemini", "Gemini CLI", new HashSet<string>(StringComparer.Ordinal) { "-p", "--prompt" }),
        ("opencode", "OpenCode", new HashSet<string>(StringComparer.Ordinal) { "run" }),
        ("cursor-agent", "Cursor Agent", new HashSet<string>(StringComparer.Ordinal) { "-p", "--print" }),
    ];

    private static readonly HashSet<string> ValuedAgentFlags = new(StringComparer.Ordinal)
    {
        "-m", "--model", "-c", "--config", "-C", "--cd", "-s", "--sandbox", "--permission-mode",
        "--allowedTools", "--allowed-tools", "--disallowedTools", "--max-turns", "--output-format",
        "--profile", "-p", "--prompt", "--append-system-prompt", "--add-dir",
    };

    private static readonly string[] LeadIns =
    [
        "i'm starting a worker on ", "i'm starting a worker to ", "starting a worker on ", "starting a worker to ",
        "i'm kicking off ", "i'm starting ", "i'm running ", "i'm launching ", "i'll run ", "i'll start ",
        "let me run ", "let me start ", "now running ", "now starting ", "now ", "running ", "starting ", "kicking off ",
        "launching ",
    ];

    /// Detects coding agents that run headless (`claude -p`, `codex exec`, `gemini -p`, `opencode run`, `cursor-agent -p`).
    public static AgentInfo? Agent(string command, int? promptLimit = 80)
    {
        var words = ShellWords(command);
        for (var index = 0; index < words.Count; index++)
        {
            var word = words[index];
            var program = BackgroundTaskText.LastPathComponent(word) ?? word;
            (string Binary, string Name, HashSet<string> Triggers)? hit = null;
            foreach (var k in KnownAgents)
            {
                if (string.Equals(k.Binary, program, StringComparison.Ordinal)) { hit = k; break; }
            }
            if (hit is not { } known) continue;

            var triggerAt = -1;
            for (var i = index + 1; i < words.Count; i++)
            {
                if (known.Triggers.Contains(words[i])) { triggerAt = i; break; }
            }
            if (triggerAt < 0) continue;

            string? prompt = null;
            var skip = false;
            for (var i = triggerAt + 1; i < words.Count; i++)
            {
                var arg = words[i];
                if (skip) { skip = false; continue; }
                if (arg.StartsWith('-'))
                {
                    skip = ValuedAgentFlags.Contains(arg) && !arg.Contains('=');
                    continue;
                }
                prompt = FirstSentence(arg, promptLimit);
                break;
            }
            return new AgentInfo(known.Name, string.IsNullOrEmpty(prompt) ? null : prompt);
        }
        return null;
    }

    /// The bot's words and full command from the `terminal` call that started `command`, in the same turn.
    /// `command` may be cut short (`process.list` sends its first 200 characters).
    public static TranscriptMatch? Match(string command, IReadOnlyList<ChatMessage> messages)
    {
        var wanted = command.Trim();
        if (wanted.Length == 0) return null;
        for (var i = messages.Count - 1; i >= 0; i--)
        {
            var message = messages[i];
            if (message.Role != Role.Assistant) continue;
            string? before = null;
            foreach (var part in message.Parts)
            {
                switch (part)
                {
                    case TextPart text when !string.IsNullOrWhiteSpace(text.Text):
                        before = text.Text;
                        break;
                    case ToolPart { Call: { Name: "terminal" } call }:
                    {
                        var ran = TerminalCommand(call.ArgsJson) ?? TerminalCommand(call.ArgsText);
                        if (ran is null) continue;
                        var trimmedRan = ran.Trim();
                        if (!trimmedRan.StartsWith(wanted, StringComparison.Ordinal)) continue;
                        var words = before is null ? null : LastSentence(before, 90);
                        var fullWords = before is null ? null : LastSentence(before, null);
                        var note = before is null ? null : ContextParagraph(before, fullWords ?? words);
                        var full = trimmedRan.Length > wanted.Length ? ran : null;
                        return new TranscriptMatch(words, fullWords, note, full);
                    }
                    case ReasoningPart:
                        continue;
                }
            }
        }
        return null;
    }

    /// The bot's words about the job: the last sentence of its text just before the terminal call that ran `command`.
    public static string? BotWords(string command, IReadOnlyList<ChatMessage> messages) =>
        Match(command, messages)?.BotWords;

    /// The `command` argument of a terminal call's JSON arguments.
    public static string? TerminalCommand(string? argsText)
    {
        if (string.IsNullOrWhiteSpace(argsText)) return null;
        return J.Parse(argsText) is JsonObject obj ? ActivityJson.StrOrNull(obj["command"]) : null;
    }

    /// The row's name: `# comment` → bot words → agent prompt → program & folder.
    public static string Headline(string command, string? botWords)
    {
        if (BackgroundTaskText.Comment(command) is { } comment) return comment;
        if (!string.IsNullOrEmpty(botWords)) return botWords;
        if (Agent(command) is { } agent) return agent.Prompt ?? agent.Name;
        var name = BackgroundTaskText.Title(command);
        return name == "background process" ? "Background command" : name;
    }

    /// The detail page's unclipped name: keeps the full sentence or agent prompt without the row's 80/90-char cap (`ba08fcdd4`).
    public static string FullHeadline(string command, string? fullBotWords, string? botWords)
    {
        if (BackgroundTaskText.Comment(command) is { } comment) return comment;
        if (!string.IsNullOrEmpty(fullBotWords)) return fullBotWords;
        if (!string.IsNullOrEmpty(botWords)) return botWords;
        if (Agent(command, promptLimit: null) is { } agent) return agent.Prompt ?? agent.Name;
        var name = BackgroundTaskText.Title(command);
        return name == "background process" ? "Background command" : name;
    }

    /// The line under the name: who runs it and where ("Claude Code · goals-2", "python3 scripts/ship.py · ship-mac").
    /// Null when the name already says all of it.
    public static string? Detail(string command, string? cwd, string headline)
    {
        var folder = Folder(command, cwd);
        var parts = new List<string>(2);
        if (Agent(command) is { } agent)
        {
            parts.Add(agent.Name);
        }
        else if (BackgroundTaskText.Program(command) is { } program && !headline.StartsWith(program, StringComparison.Ordinal))
        {
            var label = FriendlyProgram(program);
            parts.Add(label.Length > 48 ? label[..47] + "…" : label);
        }
        if (folder is not null && !headline.Contains(folder, StringComparison.Ordinal)) parts.Add(folder);
        return parts.Count == 0 ? null : string.Join(" · ", parts);
    }

    /// The folder the job runs in: from its `cd` command, else the last path component of `cwd`.
    public static string? Folder(string command, string? cwd = null) =>
        BackgroundTaskText.Folder(command) ?? (cwd is null ? null : LastComponent(cwd));

    /// Turns opaque stdin/inline-script commands (`python3 -`, `bash -c …`, `node -e …`) into plain labels,
    /// leaving named scripts (`python3 scripts/ship.py archive`) untouched.
    public static string FriendlyProgram(string program)
    {
        var words = ShellWords(program);
        if (words.Count == 0) return program;
        var bin = (BackgroundTaskText.LastPathComponent(words[0]) ?? words[0]).ToLowerInvariant();
        var second = words.Count > 1 ? words[1] : null;
        if (bin is "python" or "python3" || bin.StartsWith("python3.", StringComparison.Ordinal))
        {
            if (second is null or "-" or "-c" || (second == "-u" && (words.Count == 2 || words[2] is "-" or "-c")))
                return "Python script";
        }
        if (bin is "bash" or "sh" or "zsh")
        {
            if (second is null or "-" or "-c" or "-s" or "-lc" or "-ec") return "Shell script";
        }
        if (bin is "node" or "bun" && second is null or "-" or "-e" or "--eval")
            return bin == "bun" ? "Bun script" : "Node script";
        if (bin == "ruby" && second is null or "-" or "-e") return "Ruby script";
        if (bin == "osascript" && second is null or "-" or "-e") return "AppleScript";
        return program;
    }

    /// The line while it has printed nothing: where its output goes, what an agent does, or how long it has been quiet.
    public static string QuietLine(string command, int? uptimeSeconds)
    {
        var file = BackgroundTaskText.QuietLine(command);
        if (file != "No output yet") return file;
        if (Agent(command) is not null) return "Quiet until it's done";
        if (uptimeSeconds is >= 60) return $"No output for {BackgroundProcess.FormatDuration(uptimeSeconds.Value)}";
        return "No output yet";
    }

    /// Last non-empty path component of a folder path.
    public static string? LastComponent(string path) => BackgroundTaskText.LastPathComponent(path);

    /// Plain words: markdown marks gone, spaces collapsed.
    public static string Plain(string text)
    {
        var s = text
            .Replace("**", "", StringComparison.Ordinal)
            .Replace("__", "", StringComparison.Ordinal)
            .Replace("`", "", StringComparison.Ordinal)
            .Replace("~~", "", StringComparison.Ordinal);
        var parts = s.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        return string.Join(" ", parts);
    }

    public static string FirstSentence(string text, int? limit)
    {
        var s = Plain(text);
        var sentences = SplitSentences(s);
        var cut = sentences.Count > 0 ? sentences[0] : s;
        return Clip(cut, limit);
    }

    /// The last sentence of the last paragraph: a bot's lead-in to a call ("Now the app's own test gate.").
    public static string? LastSentence(string text, int? limit)
    {
        var normalized = text.Replace("\r\n", "\n", StringComparison.Ordinal);
        var paragraphs = normalized.Split('\n')
            .Select(p => p.Trim(' ', '\t'))
            .Where(p => p.Length > 0)
            .ToList();
        if (paragraphs.Count == 0) return null;
        var s = StripLeadingMarkers(Plain(paragraphs[^1]));
        var sentences = SplitSentences(s);
        if (sentences.Count == 0 || sentences[^1].Length < 3) return null;
        return Clip(WithoutLeadIn(sentences[^1]), limit);
    }

    /// "I'm starting a worker on the four fixes" → "The four fixes": strips generic launch lead-ins.
    public static string WithoutLeadIn(string sentence)
    {
        var lower = sentence.ToLowerInvariant();
        string? lead = null;
        foreach (var candidate in LeadIns)
        {
            if (lower.StartsWith(candidate, StringComparison.Ordinal)) { lead = candidate; break; }
        }
        if (lead is null) return sentence;
        var rest = sentence[lead.Length..].Trim(' ', '\t');
        if (rest.Length < 8) return sentence;
        return char.ToUpperInvariant(rest[0]) + rest[1..];
    }

    /// Shell words with single/double quotes honoured (`claude -p 'Read the brief' --x` → ["claude", "-p", "Read the brief", "--x"]).
    public static List<string> ShellWords(string command)
    {
        var words = new List<string>();
        var current = new StringBuilder();
        char? quote = null;
        var hasWord = false;
        foreach (var c in command)
        {
            if (quote is { } q)
            {
                if (c == q) quote = null;
                else current.Append(c);
            }
            else if (c is '\'' or '"')
            {
                quote = c;
                hasWord = true;
            }
            else if (char.IsWhiteSpace(c))
            {
                if (hasWord || current.Length > 0)
                {
                    words.Add(current.ToString());
                    current.Clear();
                    hasWord = false;
                }
            }
            else
            {
                current.Append(c);
                hasWord = true;
            }
        }
        if (hasWord || current.Length > 0) words.Add(current.ToString());
        return words;
    }

    private static string? ContextParagraph(string text, string? headline)
    {
        var normalized = text.Replace("\r\n", "\n", StringComparison.Ordinal);
        var paragraphs = normalized.Split("\n\n", StringSplitOptions.None)
            .Select(Plain)
            .Where(p => p.Length > 0)
            .ToList();
        if (paragraphs.Count == 0) return null;
        var last = StripLeadingMarkers(paragraphs[^1]);
        var clipped = last.Length > 360 ? last[..359].Trim(' ', '\t') + "…" : last;
        if (headline is not null && clipped.Length <= headline.Length + 16) return null;
        return clipped.Length >= 24 ? clipped : null;
    }

    private static string StripLeadingMarkers(string text)
    {
        var s = text;
        while (s.Length > 0 && s[0] is '-' or '*' or '#' or '>')
            s = s[1..].Trim(' ', '\t');
        return s;
    }

    private static List<string> SplitSentences(string s)
    {
        var outList = new List<string>();
        var current = new StringBuilder();
        for (var i = 0; i < s.Length; i++)
        {
            var c = s[i];
            current.Append(c);
            var next = i + 1 < s.Length ? s[i + 1] : ' ';
            if (c is '.' or '!' or '?' && next == ' ')
            {
                var piece = current.ToString().Trim(' ', '\t');
                if (piece.Length > 0) outList.Add(piece);
                current.Clear();
            }
        }
        var rest = current.ToString().Trim(' ', '\t');
        if (rest.Length > 0) outList.Add(rest);
        var cleaned = new List<string>(outList.Count);
        foreach (var item in outList)
        {
            var trimmed = item.EndsWith(':') ? item[..^1] : item;
            if (trimmed.Length > 0) cleaned.Add(trimmed);
        }
        return cleaned;
    }

    private static string Clip(string s, int? limit)
    {
        var t = s.Trim(' ', '\t');
        if (t.EndsWith('.') && !t.EndsWith("..", StringComparison.Ordinal)) t = t[..^1];
        if (limit is not { } lim || t.Length <= lim) return t;
        return t[..(lim - 1)].Trim(' ', '\t') + "…";
    }
}
