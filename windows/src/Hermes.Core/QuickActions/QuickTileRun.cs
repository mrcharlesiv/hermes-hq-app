using Hermes.Core.Chat;
using Hermes.Core.Jobs;
using Hermes.Core.Net;

namespace Hermes.Core.QuickActions;

// [quick-actions] What a Send a Message or Run Job tile does when it runs, as QuickActionsRouter.run does it at
// 93f984bb1: Run Job is Run Now's calls without waiting (RunJobIntent.run(record, wait: false), App/Intents/
// TaskAndJobIntents.swift), Send a Message with Open the Chat off is the background send to the bot's own chat
// (AskBotIntent.send(…, wait: false), App/Intents/AskBotIntent.swift), and with it on the bot's chat opens and the
// words go as typed words do (NewChatRouter.send(_:inBotChatOf:) → deliver, App/Intents/NewChatIntent.swift). Each goes
// through the Windows call that already does that work: JobsApi.RunOnceAsync and ChatSession.SendAsync.

/// What a background tile said (QuickActionsRouter.Said): the page shows "✓ " + Done's words, or Failed's for 4 s.
public abstract record QuickTileSaid
{
    public sealed record Done(string Words) : QuickTileSaid;
    public sealed record Failed(string Words) : QuickTileSaid;
}

public static class QuickTileRun
{
    /// The trigger's wait when nothing waits for the result (RunJobIntent.run: `timeout: wait ? runWait : 15`).
    public static readonly TimeSpan JobTimeout = TimeSpan.FromSeconds(15);

    /// QuickActionsRouter.words' fallback: a failure with no words of its own.
    public const string DidNotGoThrough = "That didn’t go through. Try again.";

    /// AskBotError.words(.refused("")).
    public const string MessageRefused = "Your gateway didn’t accept the message.";

    /// AskBotError.words(.unconfirmed).
    public static string MessageUnconfirmed(string bot) =>
        $"Hermes HQ couldn’t confirm the message arrived. Check {(bot.Length == 0 ? "this bot" : bot)}’s chat before running the shortcut again.";

    /// The CURRENT gateway's jobs for QuickTileWorld (the Mac's JobShortcutCatalog keys; null while not known, and
    /// when the list holds one bot's jobs only, so a tile for another bot's job is never called missing).
    public static IReadOnlySet<string>? WorldJobs(IReadOnlyList<CronJob>? jobs, string scope = "all")
    {
        if (jobs == null || scope != "all" || jobs.Count == 0) return null;
        return jobs.Select(j => j.Key).ToHashSet();
    }

    /// The job a Run Job tile names (`<owner>|<id>`, CronJob.Key): from the list when it is known (null: not on it,
    /// "“name” isn’t on this gateway."), else from the key itself (the job read that Run Now makes first then says
    /// whether it is there).
    public static (string Owner, string Id)? Job(string key, IReadOnlyList<CronJob>? jobs)
    {
        if (jobs != null) return jobs.FirstOrDefault(j => j.Key == key) is { } job ? (job.Owner, job.Id) : null;
        var cut = key.IndexOf('|');
        if (cut <= 0 || cut == key.Length - 1) return null;
        return (key[..cut], key[(cut + 1)..]);
    }

    /// Run Job: Run Now's calls (read the job, trigger it, a paused job paused again) with the 15 s wait. Answered, or
    /// still running when the wait ran out: "Running <name>". Refused: the gateway's words (ShortcutGateway.refusal).
    public static async Task<QuickTileSaid> RunJobAsync(JobsApi api, string owner, string id, string name,
        TimeSpan? timeout = null, CancellationToken ct = default)
    {
        try { await api.RunOnceAsync(id, owner, timeout ?? JobTimeout, ct: ct).ConfigureAwait(false); }
        catch (RestorePauseException) { /* the Mac's re-pause is `try?`: the run itself started */ }
        catch (GatewayException e) when (e.Code == "timeout") { /* no wait: a trigger still out has started */ }
        catch (GatewayException e) { return new QuickTileSaid.Failed(Refusal(e, "the job")); }
        return new QuickTileSaid.Done($"Running {name}");
    }

    /// ShortcutGateway.refusal: the gateway's `detail` (or `detail.message`, or `error`), else a sentence for the
    /// status. A failure with no status (offline, timed out) is the Jobs page's own words for it.
    public static string Refusal(GatewayException e, string what)
    {
        if (e.Status == 0) return JobErrors.Reason(e);
        if (e.Status == 404) return $"Your gateway doesn’t have {what}. Update the Hermes HQ add-on, or open Hermes HQ to check.";
        if (e.Body is { } body && J.Parse(body) is { } value)
        {
            if (value.Str("detail") is { Length: > 0 } detail) return detail;
            if (value.Get("detail").Str("message") is { Length: > 0 } message) return message;
            if (value.Str("error") is { Length: > 0 } error) return error;
        }
        if (e.Status == 409) return "That’s already running.";
        return $"Your gateway didn’t accept {what} ({e.Status}).";
    }

    /// Send a Message, Open the Chat off: the words to the bot's own chat (`chatId` finds or makes it, as opening it
    /// does), no wait for the reply. Accepted: "Sent to <name>".
    public static async Task<QuickTileSaid> SendInBackgroundAsync(HermesClient client, string profile, string name,
        Func<CancellationToken, Task<string>> chatId, string words, CancellationToken ct = default)
    {
        string id;
        try { id = await chatId(ct).ConfigureAwait(false); }
        catch (OperationCanceledException) { throw; }
        catch (Exception) { return new QuickTileSaid.Failed(DidNotGoThrough); }
        await using var chat = client.OpenChat(profile, id, name);
        return await chat.SendAsync(words, ct).ConfigureAwait(false) switch
        {
            SendOutcome.Accepted => new QuickTileSaid.Done($"Sent to {name}"),
            SendOutcome.Unconfirmed => new QuickTileSaid.Failed(MessageUnconfirmed(name)),
            _ => new QuickTileSaid.Failed(MessageRefused),
        };
    }

    /// Set Up's Job choices (QuickActionDraft.jobs): the list's jobs (key, title as Jobs shows it) each once, then the
    /// tile's own job when the list doesn't hold it (named as it was saved), so it stays chosen.
    public static IReadOnlyList<(string Key, string Name)> JobChoices(QuickTile tile, IEnumerable<(string Key, string Name)> jobs)
    {
        var seen = new HashSet<string>();
        var out_ = jobs.Where(j => seen.Add(j.Key)).ToList();
        if (tile.Job is { Length: > 0 } job && !seen.Contains(job)) out_.Add((job, tile.JobName ?? tile.Name));
        return out_;
    }

    /// Set Up's Job picker (QuickActionDraft.job): the job and its name; the tile's name follows it until a name is
    /// typed. A new Run Job tile starts on the first job, named for it.
    public static QuickTile PickJob(QuickTile tile, string? key, IReadOnlyList<(string Key, string Name)> jobs, bool nameTouched)
    {
        var job = string.IsNullOrEmpty(key) ? null : key;
        var name = jobs.FirstOrDefault(j => j.Key == job).Name;
        return tile with { Job = job, JobName = name, Name = !nameTouched && name != null ? name : tile.Name };
    }

    /// NewChatRouter.deliver: once the chat is the one on show, the words go as typed words do. Tries every `step`
    /// (100 ms) up to `tries` times (80: 8 s); `deliver` answers whether the chat was there to take them.
    public static async Task<bool> DeliverAsync(Func<bool> deliver, int tries = 80, TimeSpan? step = null, CancellationToken ct = default)
    {
        for (var i = 0; i < tries; i++)
        {
            // On the caller's context (no ConfigureAwait(false)): `deliver` reads the chat page, which only the UI
            // thread may touch. [WIN-33] CI run 44989322637: off it, the read threw and the tile sent nothing.
            await Task.Delay(step ?? TimeSpan.FromMilliseconds(100), ct);
            if (deliver()) return true;
        }
        return false;
    }
}
