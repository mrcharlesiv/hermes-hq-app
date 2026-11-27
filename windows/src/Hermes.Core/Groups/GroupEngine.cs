namespace Hermes.Core.Groups;

// [groups] The round engine of one account's rooms (HermesKit/Groups/GroupRounds.swift; docs/spec/3x-groups.md §6):
// your send, the drive queue, up to three rounds per thread, holds, Stop, resume and the late-reply harvest. A port of
// `HB/group-rounds.ts:574-720`, `HB/group-round-members.ts` and `sendToGroupChat` / `queueGroupChatDrive`. It lives with
// the account, not with a screen: a round goes on after you leave the room.
//
// Threading: like the Mac's main actor, every call (and every continuation, through the captured synchronization
// context) runs on one thread, the app's UI thread. Only GroupSignals is fired from the socket's read thread.
// [hosted] Rooms Hermes runs itself (`groups.*`) are not driven here yet: a send to one is Ignored.

/// What became of your send.
public abstract record GroupSendOutcome
{
    public sealed record Sent(string EntryId) : GroupSendOutcome;
    public sealed record Refused(RoomSendRefusal Refusal) : GroupSendOutcome;
    public sealed record Ignored : GroupSendOutcome
    {
        public static readonly Ignored Instance = new();
    }
}

public sealed class GroupEngine
{
    public GroupStore Store { get; }
    public IGroupGateway Client { get; }
    public GroupSignals Signals { get; } = new();
    public GroupTurn Turn { get; }
    /// The room is on screen (its replies are read as they arrive).
    public Func<string, bool> IsFocused { get; set; } = _ => false;
    /// A member's reply was posted (notifications).
    public Action<GroupRoom, GroupMessage, GroupSeat?>? OnReply { get; set; }
    /// A member's hidden session is live for its turn: the room's questions and approvals come from it (D6).
    /// (room key, runtime id, profile, stored id)
    public Action<string, string, string, string?>? OnRuntime { get; set; }
    /// A retry ended undelivered again: (room key, entry id, reason) (the "Couldn’t Deliver" alert).
    public Action<string, string, string>? OnRetryFailed { get; set; }

    /// Entry ids of sends being tried again (`Sending…` under the bubble).
    private readonly HashSet<string> retrying = [];
    public IReadOnlySet<string> Retrying => retrying;
    /// Sends being tried again (the gateway rooms' join these when hosted rooms arrive).
    public IReadOnlySet<string> AllRetrying => retrying;

    private readonly Dictionary<Guid, List<string>> pending = [];
    private readonly Dictionary<Guid, Task> drives = [];
    private readonly Dictionary<Guid, HashSet<string>> failed = [];
    private readonly Dictionary<Guid, (Task Task, CancellationTokenSource Cancel)> harvests = [];
    private HashSet<string> heldNoted = [];
    /// The account was torn down (Sign Out, another gateway): no round is current any more and nothing is written.
    private bool closed;

    public GroupEngine(GroupStore store, IGroupGateway client, GroupTiming? timing = null)
    {
        Store = store;
        Client = client;
        Turn = new GroupTurn(client, Signals, timing ?? GroupTiming.Standard);
        Signals.Start(client);
    }

    /// The account is leaving (`handleSessionsGatewayTransition`): every round ends here. Each room's epoch moves on so
    /// a turn that is waiting sees it is no longer current; nothing is interrupted on the gateway.
    public void Shutdown()
    {
        closed = true;
        foreach (var h in harvests.Values) h.Cancel.Cancel();
        drives.Clear(); harvests.Clear(); pending.Clear(); failed.Clear(); retrying.Clear();
        Store.EndAllRounds();
        Signals.Stop();
    }

    private bool IsCurrent(Guid uid, int epoch) => !closed && Store.Room(uid)?.Epoch == epoch;

    private static double NowMs => Math.Round((double)DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());

    public bool IsDriving(string key) => Store.Room(key) is { } room && drives.ContainsKey(room.Uid);

    /// The app came back, or the socket did: read the waiting sessions now instead of at the next poll.
    public void Wake()
    {
        Signals.WakeAll();
        CollectLateReplies();
    }

    /// Rooms that still have a timed-out turn to collect (after a relaunch, or a round that ended first).
    public void CollectLateReplies()
    {
        foreach (var room in Store.Rooms.ToList())
            if (!room.IsHosted && room.Stranded.Count > 0 && !room.Running && !harvests.ContainsKey(room.Uid)) StartHarvest(room.Uid);
    }

    public void RoomRemoved(GroupRoom room)
    {
        pending.Remove(room.Uid);
        failed.Remove(room.Uid);
        if (harvests.Remove(room.Uid, out var h)) h.Cancel.Cancel();
        Signals.WakeAll();   // its drive sees the room is gone and ends
    }

    // ---- Your send (`sendToGroupChat`)

    public GroupSendOutcome Send(string raw, string key, string? replyThread = null, string? entryId = null)
    {
        var text = raw.Trim();
        if (closed || text.Length == 0 || Store.Room(key) == null) return GroupSendOutcome.Ignored.Instance;
        if (Store.Room(key)!.IsHosted) return GroupSendOutcome.Ignored.Instance;   // [hosted] not in this slice
        if (GroupPrompt.IsSlashCommand(text)) return new GroupSendOutcome.Refused(new RoomSendRefusal.SlashCommand());
        Store.RefreshDescriptors(key);
        if (Store.Room(key) is not { } room) return GroupSendOutcome.Ignored.Instance;
        var seats = Store.Seated(room);
        if (!seats.Any(s => s.CanDrive)) return new GroupSendOutcome.Refused(new RoomSendRefusal.NoMembers(room.Name));
        var thread = string.IsNullOrEmpty(replyThread) ? GroupKeys.NewThreadId() : replyThread;
        var entry = new GroupMessage(entryId ?? GroupKeys.NewEntryId(), NowMs, GroupAuthor.You, GroupPrompt.Compact(text, GroupLimits.HistoryLineChars).Text, thread);
        var mentions = GroupMentions.Parse(text, seats);
        var stamp = new GroupHold(entry.At, entry.Id, thread);
        Store.Update(key, r =>
        {
            r.Log.Add(entry);
            var next = GroupHolds.Apply(r.Holds, mentions, text, stamp, [.. seats.Select(s => s.Key)]);
            if (r.HoldDetection) r.Holds = next;
            // Detection off: no new holds, but a release still releases, so Resume (`@all resume`) is never a dead
            // button (audit 14-9).
            else if (r.Holds.Count > 0) r.Holds = r.Holds.Where(kv => next.ContainsKey(kv.Key)).ToDictionary(kv => kv.Key, kv => kv.Value);
        });
        // The drive first (a new one starts a new turn's Activity list), so "You sent a message" is that list's first line.
        QueueDrive(room.Uid, thread);
        Store.Record(GroupActivityKind.Queued, key, thread: thread);
        return new GroupSendOutcome.Sent(entry.Id ?? "");
    }

    /// The paused capsule's Resume (`@all resume`, §6.8), in the thread that was stopped.
    public void ResumeAll(string key)
    {
        if (Store.Room(key) is not { IsHosted: false } room) return;
        var thread = room.Holds.Values.OrderByDescending(h => h.At).Select(h => h.Thread).OfType<string>().FirstOrDefault()
            ?? (room.Log.Count > 0 ? room.Log[^1].Thread : null);
        Send("@all resume", key, thread);
    }

    /// Try Again under an undelivered send: the same entry, asked again.
    public void Retry(string entryId, string key)
    {
        if (closed || Store.Room(key) is not { IsHosted: false } room || room.Log.FirstOrDefault(e => e.Id == entryId) is not { } entry
            || retrying.Contains(entryId)) return;
        retrying.Add(entryId);
        Store.Update(key, r => r.Undelivered.Remove(entryId), sync: false);
        QueueDrive(room.Uid, entry.ThreadKey);
        Store.Record(GroupActivityKind.Queued, key, thread: entry.ThreadKey);
    }

    /// Delete on an undelivered send: the entry leaves the log (and, with the next publish, the mirror).
    public void DeleteEntry(string entryId, string key)
    {
        if (Store.Room(key) is not { IsHosted: false }) return;
        Store.Update(key, r =>
        {
            var index = r.Log.FindIndex(e => e.Id == entryId);
            if (index < 0) return;
            // Remembered, so the copy already in the mirror is not merged back in and the next publish drops it.
            r.Removed = [.. r.Removed.Append(GroupSnapshot.EntryKey(r.Log[index])).TakeLast(GroupLimits.RemovedMax)];
            r.Log.RemoveAt(index);
            foreach (var (mark, value) in r.Watermarks.ToList()) if (value > index) r.Watermarks[mark] = value - 1;
            r.Undelivered.Remove(entryId);
            foreach (var (member, ids) in r.HeldMessages.ToList()) r.HeldMessages[member] = [.. ids.Where(id => id != entryId)];
            r.SyncRevision += 1;
        });
    }

    // ---- The drive queue (`queueGroupChatDrive`)

    private void QueueDrive(Guid uid, string thread)
    {
        failed[uid] = [];
        var list = pending.TryGetValue(uid, out var l) ? l : pending[uid] = [];
        if (!list.Contains(thread)) list.Add(thread);
        if (closed || drives.ContainsKey(uid) || Store.Key(uid) is not { } key) return;
        if (harvests.Remove(uid, out var h)) h.Cancel.Cancel();
        Store.SetRuntime(key, r => r.Epoch += 1);
        drives[uid] = DriveAsync(uid);
    }

    private async Task DriveAsync(Guid uid)
    {
        await Task.Yield();   // as a Swift Task: the caller's send returns first
        while (!closed && pending.TryGetValue(uid, out var list) && list.Count > 0)
        {
            var thread = list[0];
            list.RemoveAt(0);
            if (Store.Key(uid) is not { } key || Store.Room(key) is not { } room) break;
            var epoch = room.Epoch;
            Store.SetRuntime(key, r => r.Running = true);
            await RoundsAsync(uid, thread, epoch);
        }
        if (closed) return;
        drives.Remove(uid);
        if (Store.Key(uid) is { } k && Store.Room(k) is { } now)
        {
            // A stopped drive leaves the room idle already; a finished one is idle now.
            if (now.Running && (!pending.TryGetValue(uid, out var p) || p.Count == 0)) Store.SetRuntime(k, r => { r.Running = false; r.Turn = null; });
            if (now.Stranded.Count > 0) StartHarvest(uid);
        }
        // A send that arrived while this drive was ending.
        if (pending.TryGetValue(uid, out var rest) && rest.Count > 0) QueueDrive(uid, rest[0]);
    }

    private sealed class Tally
    {
        public int Posted;
        public int Took;        // a member took the message (accepted, held)
        public int Attempted;
        public int Failures;    // a member was asked and its turn failed
        public string Reason = "";
    }

    private enum MemberResult { Spoke, Silent, Aborted }

    /// `resolveGroupResponders`: everyone, or only the members @-mentioned since the thread's last message of yours.
    public static List<GroupSeat> Responders(IReadOnlyList<GroupMessage> log, IReadOnlyList<GroupSeat> seats)
    {
        var last = -1;
        for (var i = log.Count - 1; i >= 0; i--) if (log[i].From.Kind == GroupAuthorKind.User) { last = i; break; }
        var mentioned = new HashSet<string>();
        var everyone = false;
        if (last >= 0)
            foreach (var entry in log.Skip(last))
            {
                var parsed = GroupMentions.Parse(entry.Text, seats);
                if (parsed.Everyone) everyone = true;
                mentioned.UnionWith(parsed.Mentioned);
            }
        if (everyone || mentioned.Count == 0) return [.. seats];
        return [.. seats.Where(s => mentioned.Contains(s.Key))];
    }

    public static List<GroupSeat> Rotate(IReadOnlyList<GroupSeat> seats, int round)
    {
        if (seats.Count <= 1) return [.. seats];
        var shift = round % seats.Count;
        return [.. seats.Skip(shift), .. seats.Take(shift)];
    }

    /// `unaddressedGroupMentions`: members another member cited who have not posted since.
    public static List<string> Unaddressed(IReadOnlyList<GroupMessage> log, IReadOnlyList<GroupSeat> seats)
    {
        var citedAt = new Dictionary<string, int>();
        var order = new List<string>();
        var lastPost = new Dictionary<string, int>();
        for (var index = 0; index < log.Count; index++)
        {
            var entry = log[index];
            if (entry.From.Kind != GroupAuthorKind.Member) continue;
            var speaker = seats.FirstOrDefault(s => s.Name == entry.From.Name)?.Key;
            foreach (var key in GroupMentions.Parse(entry.Text, seats).Mentioned)
            {
                if (speaker == null || speaker == key) continue;
                if (!citedAt.ContainsKey(key)) order.Add(key);
                citedAt[key] = index;
            }
            if (speaker != null) lastPost[speaker] = index;
        }
        return [.. order.Where(key => citedAt.TryGetValue(key, out var cited) && (!lastPost.TryGetValue(key, out var answered) || answered <= cited))];
    }

    /// `runGroupChatRounds` for one thread.
    private async Task RoundsAsync(Guid uid, string thread, int epoch)
    {
        var tally = new Tally();
        var continuations = 0;
        var exit = GroupActivityKind.Settled;
        var cancelled = false;
        bool Current() => IsCurrent(uid, epoch);

        for (var round = 0; round < GroupLimits.MaxRounds; round++)
        {
            if (!Current()) { cancelled = true; break; }
            await HarvestOnceAsync(uid);
            if (!Current() || Store.Room(uid) is not { } room) { cancelled = true; break; }
            var all = Store.Seated(room);
            var log = room.Log.Where(e => e.ThreadKey == thread).ToList();
            var responders = Rotate(Responders(log, all).Where(s => s.CanDrive).ToList(), round).Where(s => !room.Stranded.ContainsKey(s.Key)).ToList();
            var spoke = 0;
            var stopRounds = false;
            foreach (var seat in responders)
            {
                if (!Current()) { cancelled = true; stopRounds = true; break; }
                if (tally.Posted >= GroupLimits.MaxMessages) { exit = GroupActivityKind.Capped; stopRounds = true; break; }
                switch (await MemberAsync(uid, thread, seat, epoch, tally))
                {
                    case MemberResult.Spoke: tally.Posted++; spoke++; break;
                    case MemberResult.Aborted: cancelled = true; stopRounds = true; break;
                }
                if (stopRounds) break;
            }
            if (stopRounds) break;
            if (spoke == 0)
            {
                if (Store.Room(uid) is not { } now) { cancelled = true; break; }
                var seats = Store.Seated(now);
                var owed = Unaddressed(now.Log.Where(e => e.ThreadKey == thread).ToList(), seats);
                continuations++;
                if (owed.Count > 0 && continuations <= GroupLimits.MaxContinuations && tally.Posted < GroupLimits.MaxMessages)
                {
                    foreach (var seat in seats.Where(s => s.CanDrive && owed.Contains(s.Key) && !now.Stranded.ContainsKey(s.Key)))
                    {
                        if (!Current() || tally.Posted >= GroupLimits.MaxMessages) break;
                        var result = await MemberAsync(uid, thread, seat, epoch, tally);
                        if (result == MemberResult.Spoke) { tally.Posted++; spoke++; }
                        else if (result == MemberResult.Aborted) { cancelled = true; stopRounds = true; break; }
                    }
                    if (stopRounds) break;
                }
                if (spoke == 0)
                {
                    if (owed.Count > 0 && (continuations > GroupLimits.MaxContinuations || tally.Posted >= GroupLimits.MaxMessages)) exit = GroupActivityKind.Capped;
                    break;
                }
            }
            if (round == GroupLimits.MaxRounds - 1) exit = GroupActivityKind.Capped;
        }

        if (closed || Store.Key(uid) is not { } key) return;
        var sends = (Store.Room(key)?.Log ?? []).Where(e => e.ThreadKey == thread && e.From.Kind == GroupAuthorKind.User).Select(e => e.Id).OfType<string>().ToList();
        if (cancelled || !Current())
        {
            if (Store.Room(key)?.StoppedEpoch != Store.Room(key)?.Epoch) Store.Record(GroupActivityKind.Cancelled, key, thread: thread);
            retrying.ExceptWith(sends);
            return;
        }
        Store.Record(exit, key, thread: thread);
        // Your send no member took (`undeliveredSend`): the newest of yours in this thread says so.
        if (sends.Count > 0)
        {
            var newest = sends[^1];
            var wasRetry = retrying.Contains(newest);
            // Only when a member was asked and failed: a send whose only addressee is still working on a late reply,
            // or sits on another gateway, did not fail.
            if (tally.Took == 0 && tally.Failures > 0)
            {
                Store.Update(key, r => r.Undelivered[newest] = tally.Reason, sync: false);
                if (wasRetry) OnRetryFailed?.Invoke(key, newest, tally.Reason);
            }
            else if (tally.Took == 0)
            {
                // Nobody was asked: nothing to say under the bubble (a late reply, if one is owed, still arrives).
            }
            else if (Store.Room(key)?.Undelivered.Count > 0)
                Store.Update(key, r => { foreach (var id in sends) r.Undelivered.Remove(id); }, sync: false);
        }
        retrying.ExceptWith(sends);
        if (!pending.TryGetValue(uid, out var p) || p.Count == 0) Store.SetRuntime(key, r => { r.Running = false; r.Turn = null; });
    }

    /// `runGroupRoundMember`: one member's turn. Aborted ends the drive.
    private async Task<MemberResult> MemberAsync(Guid uid, string thread, GroupSeat seat, int epoch, Tally tally)
    {
        if (Store.Key(uid) is not { } key || Store.Room(key) is not { } room) return MemberResult.Aborted;
        if (failed.TryGetValue(uid, out var f) && f.Contains(seat.Key)) return MemberResult.Silent;
        var markKey = GroupKeys.WatermarkKey(thread, seat.Key);
        var seen = Math.Max(0, Math.Min(room.Watermarks.GetValueOrDefault(markKey), room.Log.Count));
        var delta = room.Log.Skip(seen).Where(e => e.ThreadKey == thread).ToList();
        if (delta.Count == 0) return MemberResult.Silent;

        if (room.Holds.ContainsKey(seat.Key))
        {
            var ids = delta.Select(e => e.Id).OfType<string>().ToList();
            Store.Update(key, r =>
            {
                r.Watermarks[markKey] = r.Log.Count;
                var list = r.HeldMessages.GetValueOrDefault(seat.Key) ?? [];
                foreach (var id in ids) if (!list.Contains(id)) list.Add(id);
                if (list.Count > 200) list.RemoveRange(0, list.Count - 200);
                r.HeldMessages[seat.Key] = list;
            }, sync: false);
            var note = $"{uid}|{epoch}|{seat.Key}";
            if (heldNoted.Add(note))
            {
                if (heldNoted.Count > 512) heldNoted = [note];
                Store.Record(GroupActivityKind.Held, key, seat.Key, thread: thread);
            }
            tally.Took++;
            return MemberResult.Silent;
        }

        // What it reads: the messages held back for it, then the new ones, oldest first.
        var heldIds = (room.HeldMessages.GetValueOrDefault(seat.Key) ?? []).ToHashSet();
        var held = room.Log.Take(seen).Where(e => e.ThreadKey == thread && e.Id != null && heldIds.Contains(e.Id));
        var visible = held.Concat(delta).Select((e, i) => (e, i)).OrderBy(p => p.e.At).ThenBy(p => p.i).Select(p => p.e).ToList();
        var seats = Store.Seated(room);
        var labels = Store.Labels(seats);
        var prompt = GroupPrompt.Build(room.Name, seats, seat, GroupPrompt.DeltaLines(visible, seat.Name, labels));
        // Sent only if this turn makes the member's session for the thread (each main-composer send is a new thread).
        var freshContext = GroupPrompt.FreshThreadContext(room.Log, seat.Name, labels, thread);
        var anchorId = room.Log.Count > 0 ? room.Log[^1].Id : null;
        var anchorCount = room.Log.Count;
        var sessionKey = GroupKeys.SessionKey(thread, seat.Key);
        Store.SetRuntime(key, r => r.Turn = new GroupTurnState(seat.Key, thread));
        Store.Record(GroupActivityKind.Working, key, seat.Key, thread: thread);
        tally.Attempted++;

        string? reply = null;
        var accepted = false;
        (int Before, string? Stored)? strandedBefore = null;
        try
        {
            reply = await Turn.RunAsync(room, thread, seat, prompt, freshContext,
                isCurrent: () => IsCurrent(uid, epoch),
                save: stored =>
                {
                    if (Store.Key(uid) is { } k) Store.Update(k, r => r.Sessions[sessionKey] = stored, sync: false);
                },
                onRuntime: (runtime, stored) =>
                {
                    if (Store.Key(uid) is { } k) OnRuntime?.Invoke(k, runtime, seat.Name, stored);
                },
                onAccepted: (before, stored) =>
                {
                    accepted = true;
                    // Saved while the member answers: a turn cut off by the app closing is collected at the next launch.
                    if (Store.Key(uid) is { } k)
                        Store.Update(k, r => r.Asking[seat.Key] = new GroupAsking(before, thread, NowMs, stored, markKey, anchorId, anchorCount), sync: false);
                },
                onWaiting: waiting =>
                {
                    if (Store.Key(uid) is { } k)
                        Store.SetRuntime(k, r => { if (r.Turn?.Name == seat.Key) r.Turn = r.Turn with { WaitingOnUser = waiting }; });
                });
        }
        catch (GroupTurnException e) when (e.Kind == GroupTurnFailure.Cancelled)
        {
            if (Store.Key(uid) is { } k) Store.Update(k, r => r.Asking.Remove(seat.Key), sync: false);
            return MemberResult.Aborted;
        }
        catch (GroupTurnException e) when (e.Kind == GroupTurnFailure.TimedOut)
        {
            accepted = true;
            strandedBefore = (e.Before, e.Stored);
        }
        catch (Exception error)
        {
            var reason = GroupTurn.Reason(error);
            if (Store.Key(uid) is { } k) Store.Record(GroupActivityKind.Failed, k, seat.Key, reason, thread);
            (failed.TryGetValue(uid, out var set) ? set : failed[uid] = []).Add(seat.Key);
            tally.Reason = reason;
            tally.Failures++;
            if (error is GroupTurnException { Kind: GroupTurnFailure.Failed }) accepted = true;
        }

        if (closed || Store.Key(uid) is not { } key2 || Store.Room(key2) is not { } now) return MemberResult.Aborted;
        if (now.Asking.Count > 0) Store.Update(key2, r => r.Asking.Remove(seat.Key), sync: false);   // the turn is over, however it ended
        if (now.Epoch != epoch) return MemberResult.Aborted;
        if (now.Turn?.Name == seat.Key) Store.SetRuntime(key2, r => r.Turn = null);
        if (!accepted) return MemberResult.Silent;
        tally.Took++;

        var text = (reply ?? "").Trim();
        var spoke = text.Length > 0 && !GroupPrompt.IsPass(text);
        var delivered = visible.Select(e => e.Id).OfType<string>().ToHashSet();
        GroupMessage? posted = null;
        Store.Update(key2, r =>
        {
            var byId = anchorId != null ? r.Log.FindLastIndex(e => e.Id == anchorId) : -1;
            var anchor = anchorId != null && byId >= 0 ? byId : Math.Min(anchorCount, r.Log.Count) - 1;
            r.Watermarks[markKey] = Math.Max(r.Watermarks.GetValueOrDefault(markKey), anchor + 1);
            if (r.HeldMessages.TryGetValue(seat.Key, out var list))
            {
                list = [.. list.Where(id => !delivered.Contains(id))];
                if (list.Count == 0) r.HeldMessages.Remove(seat.Key); else r.HeldMessages[seat.Key] = list;
            }
            if (strandedBefore is { } stranded) r.Stranded[seat.Key] = new GroupStranded(stranded.Before, thread, NowMs, stranded.Stored);
            if (!spoke) return;
            var entry = new GroupMessage(GroupKeys.NewEntryId(), Math.Max(NowMs, (r.Log.Count > 0 ? r.Log[^1].At : 0) + 1),
                new GroupAuthor(GroupAuthorKind.Member, seat.Name), GroupPrompt.Compact(text, GroupLimits.HistoryLineChars).Text, thread);
            if (!IsDuplicate(entry, r.Log))
            {
                r.Log.Add(entry);
                posted = entry;
            }
            // Its own lines are never news to it.
            var mark = r.Watermarks.GetValueOrDefault(markKey);
            while (mark < r.Log.Count && r.Log[mark].From.Kind == GroupAuthorKind.Member && r.Log[mark].From.Name == seat.Name && r.Log[mark].ThreadKey == thread) mark++;
            r.Watermarks[markKey] = mark;
        }, sync: spoke);
        if (strandedBefore != null)
        {
            Store.Record(GroupActivityKind.TimedOut, key2, seat.Key, thread: thread);
            return MemberResult.Silent;
        }
        if (posted != null)
        {
            Store.Record(GroupActivityKind.Replied, key2, seat.Key, thread: thread);
            Arrived(posted, key2, seat);
            return MemberResult.Spoke;
        }
        if (!(failed.TryGetValue(uid, out var fs) && fs.Contains(seat.Key))) Store.Record(GroupActivityKind.Passed, key2, seat.Key, thread: thread);
        return MemberResult.Silent;
    }

    /// The same member saying the same thing in the same thread within 10 minutes is one message.
    public static bool IsDuplicate(GroupMessage entry, IReadOnlyList<GroupMessage> log)
    {
        if (log.Count == 0) return false;
        var last = log[^1];
        return last.From.Kind == GroupAuthorKind.Member && last.From.Name == entry.From.Name && last.ThreadKey == entry.ThreadKey
            && last.Text == entry.Text && entry.At - last.At < 600_000;
    }

    private void Arrived(GroupMessage entry, string key, GroupSeat? seat)
    {
        if (Store.Room(key) is not { } room) return;
        if (!IsFocused(key)) Store.SetUnread(key, true);
        OnReply?.Invoke(room, entry, seat);
    }

    // ---- Stop (`stopGroupThread`, row L467)

    /// Stops the round here at once; then asks the gateway to stop the reply in flight. false = stopped here, the
    /// gateway did not confirm.
    public async Task<bool> StopAsync(string key)
    {
        if (Store.Room(key) is not { } room) return true;
        if (room.IsHosted) return true;   // [hosted] not in this slice
        var uid = room.Uid;
        var onTurn = room.Turn;
        var thread = onTurn?.Thread ?? (room.Log.Count > 0 ? room.Log[^1].Thread : null);
        pending[uid] = [];
        var seats = Store.Seated(room);
        var stamp = new GroupHold(NowMs, null, thread);
        Store.Update(key, r =>
        {
            r.Epoch += 1;
            r.StoppedEpoch = r.Epoch;
            r.Running = false;
            r.Turn = null;
            if (!r.HoldDetection) return;
            foreach (var seat in seats) r.Holds.TryAdd(seat.Key, stamp);
        }, sync: false);
        Store.Record(GroupActivityKind.Stopped, key, thread: thread);
        Signals.WakeAll();
        if (onTurn == null || seats.FirstOrDefault(s => s.Key == onTurn.Name) is not { } turnSeat) return true;
        var scoped = room.Sessions.Keys.Any(k => k.StartsWith("thread:", StringComparison.Ordinal) && k.EndsWith($"::{onTurn.Name}", StringComparison.Ordinal));
        var stored = room.Sessions.GetValueOrDefault(GroupKeys.SessionKey(onTurn.Thread, onTurn.Name)) ?? (scoped ? null : room.Sessions.GetValueOrDefault(onTurn.Name));
        // Its session was still being found: the turn sees the stop before it sends anything.
        if (stored == null) return true;
        return await GroupInterrupt.InterruptAsync(Client, turnSeat.Name, stored);
    }

    // ---- Late replies (§6.7)

    private void StartHarvest(Guid uid)
    {
        if (harvests.ContainsKey(uid)) return;
        var every = Turn.Timing.HarvestEvery;
        var tries = (int)Math.Ceiling((Turn.Timing.HardCap.TotalSeconds + 60) / Math.Max(1, every.TotalSeconds));
        var cancel = new CancellationTokenSource();
        harvests[uid] = (Loop(), cancel);

        async Task Loop()
        {
            await Task.Yield();
            for (var i = 0; i < tries; i++)
            {
                try { await Task.Delay(every, cancel.Token); } catch (OperationCanceledException) { break; }
                if (cancel.IsCancellationRequested || closed || Store.Room(uid) is not { Running: false }) break;
                await HarvestOnceAsync(uid);
                if (Store.Room(uid) is not { Stranded.Count: > 0 }) break;
            }
            if (harvests.TryGetValue(uid, out var h) && h.Cancel == cancel) harvests.Remove(uid);
        }
    }

    /// `harvestStrandedGroupReply` for every member with a marker.
    private async Task HarvestOnceAsync(Guid uid)
    {
        if (Store.Room(uid) is not { Stranded.Count: > 0 } room) return;
        var seats = Store.Seated(room);
        var expiry = (Turn.Timing.HardCap.TotalSeconds + 60) * 1000;
        foreach (var (memberKey, marker) in room.Stranded.OrderBy(kv => kv.Value.At).ToList())
        {
            if (seats.FirstOrDefault(s => s.Key == memberKey) is not { CanDrive: true } seat || NowMs - marker.At >= expiry)
            {
                if (Store.Key(uid) is { } k) Store.Update(k, r => r.Stranded.Remove(memberKey), sync: false);
                continue;
            }
            var result = await Turn.HarvestAsync(marker, seat.Name);
            if (closed || Store.Key(uid) is not { } key) return;
            switch (result.Kind)
            {
                case GroupTurn.HarvestKind.Busy:
                    continue;
                case GroupTurn.HarvestKind.Nothing:
                    Store.Update(key, r => { if (r.Stranded.GetValueOrDefault(memberKey) == marker) r.Stranded.Remove(memberKey); }, sync: false);
                    break;
                case GroupTurn.HarvestKind.Reply:
                    GroupMessage? posted = null;
                    Store.Update(key, r =>
                    {
                        // Another collection read the same marker meanwhile and posted the reply first: the marker is
                        // gone, so this one is not posted again (audit 14-13).
                        if (r.Stranded.GetValueOrDefault(memberKey) != marker) return;
                        r.Stranded.Remove(memberKey);
                        var entry = new GroupMessage(GroupKeys.NewEntryId(), Math.Max(NowMs, (r.Log.Count > 0 ? r.Log[^1].At : 0) + 1),
                            new GroupAuthor(GroupAuthorKind.Member, seat.Name), GroupPrompt.Compact(result.Text!, GroupLimits.HistoryLineChars).Text, marker.Thread);
                        if (IsDuplicate(entry, r.Log)) return;
                        r.Log.Add(entry);
                        posted = entry;
                    });
                    if (posted != null)
                    {
                        Store.Record(GroupActivityKind.Delivered, key, memberKey, thread: marker.Thread);
                        Arrived(posted, key, seat);
                    }
                    break;
            }
        }
    }
}
