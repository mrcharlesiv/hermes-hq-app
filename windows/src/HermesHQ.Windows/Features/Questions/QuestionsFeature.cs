using System.ComponentModel;
using Hermes.Core;
using Hermes.Core.Questions;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Dispatching;

namespace HermesHQ.Features.Questions;

/// Approvals, clarify questions and password / secret / sudo prompts (spec 1x-questions; Mac: App/Questions,
/// App/Asks). The account's QuestionCenter (Hermes.Core) holds the requests; every open chat gets a QuestionsChat that
/// draws the approval card and the question note at the transcript's newest end, the question dock in the message
/// box's place, the password sheets and their chip, and "Approval needed" over the transcript.
public static class QuestionsFeature
{
    /// Which bots wait on the user, for the sidebar's bot rows ("Waiting for your approval" / "Waiting for your reply").
    public static WaitingBots WaitingBots { get; } = new();

    public static void Register()
    {
        WaitingBots.Start(DispatcherQueue.GetForCurrentThread());
        // [questions] A settled clarify call draws its Q&A card in place, with Answer Now on a question left unanswered.
        ChatExtensions.ToolRenderers["clarify"] = QuestionsChat.SettledCard;
        ChatExtensions.OnOpen.Add(ctx =>
        {
            if (AppState.Client is { } client) _ = new QuestionsChat(ctx, client);
        });
    }

    internal static void StopForQuit() => WaitingBots.StopForQuit();
}

/// The Bots rows' "Waiting…" (spec 1x §3.6, HermesKit `NeedsInput`): what each bot's chats wait on, by profile and
/// stored session id. Changed and PropertyChanged ("Item[]") are raised on the UI thread. The lists feature reads it:
/// `QuestionsFeature.WaitingBots.StatusText(bot.Name, bot.Canonical?.OpenId)` ranks above "Working…" and is drawn in
/// orange, as the Mac's row (it never shows the command).
public sealed class WaitingBots : INotifyPropertyChanged
{
    private readonly Dictionary<string, (string Profile, string? StoredId, NeedsInput Kind)> _byRuntime = [];
    private DispatcherQueue? _ui;
    private QuestionCenter? _center;
    private readonly Action<string, string, string?, NeedsInput?> _handler;

    public event Action? Changed;
    public event PropertyChangedEventHandler? PropertyChanged;

    public WaitingBots() => _handler = (runtime, profile, stored, kind) => Post(() => Set(runtime, profile, stored, kind));

    internal void Start(DispatcherQueue? ui)
    {
        _ui = ui;
        AppState.ClientChanged += Watch;
        Watch(AppState.Client);
    }

    internal void StopForQuit()
    {
        AppState.ClientChanged -= Watch;
        if (_center != null) _center.NeedsInputChanged -= _handler;
        _center = null;
        _ui = null;
        _byRuntime.Clear();
    }

    private void Watch(HermesClient? client)
    {
        if (AppShutdown.Stopping) return;
        Post(() =>
        {
            if (AppShutdown.Stopping) return;
            if (_center != null) _center.NeedsInputChanged -= _handler;
            _center = client?.Questions;
            _byRuntime.Clear();
            if (_center != null) _center.NeedsInputChanged += _handler;
            Raise();
        });
    }

    private void Post(Action a)
    {
        if (AppShutdown.Stopping) return;
        if (_ui == null || _ui.HasThreadAccess) a();
        else _ui.TryEnqueue(() => { if (!AppShutdown.Stopping) a(); });
    }

    private void Set(string runtime, string profile, string? storedId, NeedsInput? kind)
    {
        if (kind is { } k) _byRuntime[runtime] = (profile, storedId, k);
        else if (!_byRuntime.Remove(runtime)) return;
        Raise();
    }

    private void Raise()
    {
        Changed?.Invoke();
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs("Item[]"));
    }

    /// What a bot waits on (approval ranks over reply). With `storedId`, only that chat counts (the Mac's Bots row asks
    /// for the bot's own chat, its canonical session).
    public NeedsInput? For(string profile, string? storedId = null)
    {
        NeedsInput? best = null;
        foreach (var (p, s, k) in _byRuntime.Values)
        {
            if (p != profile || (storedId != null && s != storedId)) continue;
            if (best == null || Rank(k) > Rank(best.Value)) best = k;
        }
        return best;
    }

    /// "Waiting for your approval", "Waiting for your reply", or null.
    public string? StatusText(string profile, string? storedId = null) => For(profile, storedId)?.StatusText();

    /// Every profile that waits now.
    public IReadOnlyCollection<string> Profiles => _byRuntime.Values.Select(v => v.Profile).Distinct().ToList();

    private static int Rank(NeedsInput k) => k switch { NeedsInput.Approval => 3, NeedsInput.Reply => 2, _ => 1 };
}
