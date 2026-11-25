# 3x Threads in a bot's chat

2026-11-17. The owner: "Is there any way to allow multiple threads in the same bot chat so that the bots can carry
multiple convos at the same time like grok bot does? I hate when the bot is doing something and I can't message it..."
He approved the mockup boards in `~/Projects/hermes-hq-share/2026-11-17-bot-threads/` ("No I like it. Go.").

## 1. What a thread is

Hermes runs one turn at a time in a session, and a bot's chat is one session (the hidden "Bot Chat"). A message sent
while the bot works therefore joins the running reply (`session.redirect`) or waits in the queue. A **thread** is a
second session of the same bot (same profile), started from inside the bot's chat, so its reply runs beside the main
one. The bot chat draws the thread in place, and the thread has a chat of its own.

A thread is an ordinary chat on the gateway: it lists under Sessions, other clients show it as a chat with that bot,
and nothing about it needs the add-on.

## 2. Starting one

- **Automatically while the bot is busy (§9)**: when the main chat is held by another run or background task, sending
  normally from the composer routes straight into a thread (with the `Sending to Thread · Use Main` strip above the
  composer). There is no separate thread button next to Send; Dictate stays in its normal slot.
- **Any time**: hold a message › **Reply in Thread** (`message.thread`). A banner over the field ("Reply in Thread",
  one line of that message, ✕) marks the next send; that send starts the thread under the held message and opens the
  thread's own chat.
- Available in bot chats and regular session chats (never nested inside a thread itself, and never in rooms or hidden
  task/goal/tile chats). On regular sessions, only explicitly recorded `BotThreadLink` threads are shown inline so
  manual "Branch in New Chat" sessions stay separate.

## 3. What a thread starts out knowing (`ThreadSeed`)

`session.create {profile, messages, cwd, follow_profile_config, idempotency_key}`:

- **No `parent_session_id` alongside `messages`**: real Hermes gateways route `parent_session_id + messages` into
  `_seed_branch_row` (Desktop `/branch`), which titles the child `"Bot Chat #2"` (locking out auto-titling) and persists
  the seed with `copy_fields=()`, stripping `display_kind: "hidden"`. Omitting `parent_session_id` hits `_seed_row`,
  which preserves `display_kind: "hidden"` and lets Hermes auto-title the thread from its first message. The thread's
  link to its parent Bot Chat (`BotThreadLink`) is kept in `SessionStore` device state and synced across devices via
  `GatewaySync`.
- `messages`: the newest part of the bot chat as seed rows, every one `display_kind: "hidden"` (the model reads them,
  no client draws them; Hermes `_coerce_seed_history`). At most 24 rows after merging neighbours of one role, 16,000
  characters in all, 4,000 per row (start and end kept). Yours and the bot's words only: no steps, no thoughts, no
  notices, no side answers, not the reply still arriving.
- The seed ends with a note in the bot's voice. While the main chat works: "(I am still working on that in the main
  chat. This is a side thread of the same chat: here I answer only what is asked in this thread, and I leave that job
  to the main chat.)". Otherwise: "(This is a side thread of the main chat above: …)". It keeps the roles alternating
  and keeps the thread from starting the main job a second time.
- The note carries `[thread anchor: row N]`: the stored row of the message the thread hangs under, so every device
  draws it at the same place.
- `cwd`: the bot chat's folder.

After that the two chats do not see each other's messages. The bot's saved memory is shared, as between any two chats.

## 4. Keeping it alive (`ThreadStore`)

The thread's first message is sent with no screen: `LiveChatSession.listenOffScreen()` opens the chat and hears the
gateway without becoming the focused chat (`threadHold`, beside `voiceHold`; the app model holds it in `awayChats`, so
opening it from Sessions gives the same chat). Every change reaches the bot chat through `onThreadChange`.

A thread is known three ways: started here this run (live), listed by the gateway (a Sessions row whose
`parent_session_id` is one of the bot chat's ids: read once over REST, again when its row moves), or opened (the chat
its screen uses, kept live). A running thread always stays live; of the idle ones the newest four do.

A thread's reply raises no alert while the bot chat drawing it is the chat on screen, and a thread standing open there
is marked read in place (`SessionStore.markReadInPlace`), so Sessions shows no dot for a reply already read.

## 5. In the bot chat (`ThreadRows`, `ChatThreadCell`)

- **Where**: under the message it hangs under (`ThreadRules.anchorIndex`): the message this device started it under,
  else the stored anchor row, else your newest message from before it began.
- **Open** while it is the newest thing in the chat, that is until the bot has finished saying something in the main
  chat after it; a thread still answering stays open wherever it is. One row (`…|th:<key>`): a header (the mark,
  "Thread" or its own short title, "· N messages" when it holds more than it shows, a caret), then your last message
  in it and what the bot answered, drawn by the chat's own bubble cells, beside a 1.5 pt line in the bot's colour
  (`Bot.chatsTint`'s rule). While its reply has nothing to show: its own "… is thinking…" line.
- **Folded** afterwards: one centred line like the chat's other grouped lines, "Flight on Friday · 4 messages ›"
  (`…|thf:<key>`).
- A tap on either opens the thread's own chat. The bubble above a thread ends its run (it keeps its tail).

## 6. The thread's own chat

A full chat with the same bot: the bot's face stays in the bar beside the thread's title (its own short title once
it has one), with the bot's name under it. Its hidden seed draws nothing.

- **iPhone, iPad**: pushed over the bot chat; Back returns to it.
- **Mac**: it fills the pane beside the chat (where Info, Steps, Files and Helpers live), under its title, so the
  main chat stays in view; ✕ brings the tabs back, and so does opening another chat. In a window too narrow for the
  pane it is pushed over the chat instead. While both are on screen the thread is the focused chat; the bot chat
  beside it raises no alert for its own reply, and is the focused chat again when the pane closes.

## 7. Not in this version

- A thread and the main chat are not told what the other did after the thread began.
- Threads older than the newest 50 Sessions rows are not listed by the gateway's sidebar, so their folded lines are
  not drawn on a device that did not start them this run.
- No "Threads" list of its own: a bot's threads are its chats under Sessions.

## 8. Checking it

- Unit: `Tests/Chat/ThreadsTests.swift` (seed, anchor, open/folded, rows, layout); `Tests/Chat/ThreadBusySendTests.swift`
  (§9: the wait, the hand-over, Stop, a chat with no threads, the words coming back).
- No gateway: `-HQDemoChat 12 -HQDemoAutoOpen -HQDemoThreads [later]` with `-HQDemoSend <request> -HQDemoHoldStep
  -HQDemoDraft <question> -HQDemoThreadTap <s>` and `-HQDemoThreadOpen <s>` (`App/Chat/Threads/ThreadsDemo.swift`).
- Stand-in gateway: `scripts/fixtures/sessions-gateway.py` keeps a new chat's parent and seed, and
  `/__fixture/mode {"prompts":"hold","threads":"reply","answer":"…"}` holds the main reply while a thread answers;
  the app: `-HQDebugOpenBot default -HQDebugSend <request> -HQDebugThread <question> [-HQDebugThreadOpen <s>]`.
- §9 in the app: `UITests/sessions/SessionsTests+BusyThread.swift` on that stand-in with `{"owned":true}` (every chat
  that is not a thread refuses prompts as one held by a scheduled job does).

## 9. Words a busy chat cannot take

2026-11-23. The owner: "We need a solution for when a bot is busy and a user needs to send a message to the bot. The
bot must be able to handle multiple threads at the same time and should never reject a message." Asked which way Send
should go while the bot works, he left the choice to the app ("I have no idea! I need your help!"). DECISION: Send
still joins the running reply (Steer or Queue, as Send While Replying says), because words sent mid-reply are most
often about the job in hand and a thread does not see what the main chat does after it began. A thread starts by
itself only where the words would otherwise have come back, or waited behind a run the person cannot see.

In a bot's own chat (`LiveChatSession.onBusyThreadSend` / `shouldRouteToBusyThread`, set by `AppModel.chat(for:)`),
messages go on in a thread when:

- **Proactively (0 ms wait)**: the app already knows the main chat is unavailable (`externalWorking == true`, or an
  active auto-thread is latched for the current busy stretch) and the user hasn't tapped **Use Main** on the calm
  routing strip over the composer (`ComposerEditBanner.busyThread`). No main-chat bubble is created or removed.
- **Another run holds the chat** (`4090 SESSION_NOT_OWNED` / `SESSION_OWNER_BUSY`: a scheduled job, a background
  delivery, another window, a gateway turn whose queue could not take them). The first refusal waits a brief
  `threadAfter` grace window (1.5 s, `ThreadRules.busyOwnerGrace`), then hands off to a thread. Photos refused with
  `SESSION_OWNER_BUSY` detach from the main runtime and go on in the thread too.
- **The gateway says busy** (`4009`) past `threadBusyWindow` (2.5 s).
- **Offline outbox on reconnect**: a message queued while the link was away (`QueuedMessage.queuedOffline`) routes into
  a thread if the main chat is held by another run when the link returns.

What happens then (`ThreadStore.takeBusySend`, `LiveChatSession.sendWentToThread`):

- On reactive hand-off, the bubble leaves the main chat (no Couldn’t Send card, nothing back in the message box) and
  any burst messages typed during the brief grace wait drain into the **same** thread in FIFO order instead of being
  trapped in Queue Paused.
- The thread hangs under the newest thing said in the chat (`ThreadRules.busyAnchor`), or at a dedicated empty-chat
  footer slot (`ThreadRows.emptyAnchorId`) when the main chat has no messages yet, so it always stands open in view.
  Its seed carries the exact unavailability reason (`ThreadSeed.rows(..., busyReason:)`), even when the last visible
  row is an assistant reply.
- The same thread takes follow-up sends (`ThreadRules.takesNextBusySend`) — reopening by `storedId` if `trim()` evicted
  its idle live session — until the main chat accepts a send, external work ends, a newer finished assistant reply lands
  in the main chat (`onMainReplyLanded`), a `4009` availability probe sees `hermes serve` go idle, the user taps
  **Use Main**, or the 15-minute staleness TTL (`ThreadRules.busyThreadTTL`) expires. When it auto-unlatches while the
  chat is on screen, a quiet notice says `"<Bot> is back in the main chat."`.
- When settled auto-threads exist and the user later sends a normal message in the main chat, a compact context summary
  (`ThreadContextNote`) rides on that prompt so the main chat remembers what happened in the side thread (`SentTitles`
  strips the note from the visible bubble everywhere).
- If the thread cannot open or send off-screen (`acceptedSends == 0`), the empty failed entry is removed and the words
  come back to the main chat's message box (`threadSendCameBack`): refused, never lost. Once the thread accepts a send
  or opens on screen, its errors stay in the thread and never overwrite the main chat's draft.

Unchanged, on purpose:

- Voice memos, live voice turns, Edit / Regenerate / Rewind, and normal user-queued sends (`⌘Return` / Queue behind
  your own turn) keep their existing behaviour.
- A chat the gateway has locked (`profile_mismatch`) keeps its problem card and Continue in New Chat.
- Sessions, rooms and task chats have no threads (§2), so they keep the long wait.
- `SESSION_OWNER_UNCONFIRMED` and a lost link after the send may have gone out stay "Delivery unconfirmed": the
  gateway may hold the words already, and a thread would run them twice.
