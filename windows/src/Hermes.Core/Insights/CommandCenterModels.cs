namespace Hermes.Core.Insights;

// The pages' models that hold no UI: Recent Logs and Usage. Status & Maintenance's own model is in the app
// (Features/Insights/CommandCenterModel.cs): it follows the socket and the Update sheet.

/// Recent Logs' model (App/Pages/More/CommandCenter/CommandCenterLogs.swift, CommandCenterLogsModel): the last 200 lines,
/// newest first, at a level.
public sealed class CommandCenterLogsModel(CommandCenterApi api)
{
    public abstract record Load
    {
        public sealed record Loading : Load;
        public sealed record Ready : Load;
        public sealed record Failed(string Reason) : Load;
    }

    /// Newest first.
    public List<string> Lines { get; private set; } = [];
    public Load State { get; private set; } = new Load.Loading();
    public bool RefreshFailed { get; private set; }
    public bool Busy { get; private set; }
    public LogLevelFilter ShownLevel { get; private set; } = LogLevelFilter.All;
    public LogLevelFilter Level { get; private set; } = LogLevelFilter.All;
    public event Action? Changed;
    private int _serial;

    public void SetLevel(LogLevelFilter level)
    {
        if (level == Level) return;
        Level = level;
        Changed?.Invoke();
        _ = ReadAsync();
    }

    public async Task ReadAsync()
    {
        var mine = ++_serial;
        var asked = Level;
        Busy = true;
        Changed?.Invoke();
        try
        {
            var answer = await api.LogsAsync(asked);
            if (mine != _serial) return;
            answer.Reverse();
            Lines = answer;
            ShownLevel = asked;
            State = new Load.Ready();
            RefreshFailed = false;
        }
        catch (Exception e)
        {
            if (mine != _serial) return;
            if (State is Load.Ready) RefreshFailed = true; else State = new Load.Failed(InsightsWire.Reason(e));
        }
        finally
        {
            if (mine == _serial) { Busy = false; Changed?.Invoke(); }
        }
    }

    public void Retry()
    {
        if (State is not Load.Ready) { State = new Load.Loading(); Changed?.Invoke(); }
        _ = ReadAsync();
    }

    public string RefreshFailedText => LogLines.RefreshFailedText(ShownLevel, Level);
    public string EmptyText => LogLines.EmptyText(ShownLevel);
    /// The lines as the gateway wrote them (oldest first), for Share.
    public string Text => string.Join("\n", Enumerable.Reverse(Lines));
}

/// Usage's model (App/Pages/More/CommandCenter/CommandCenterUsage.swift, UsagePageModel): the gateway's usage over 7,
/// 30 or 90 days, every bot together. The newest period asked wins, whatever order the answers land in.
public sealed class UsagePageModel(CommandCenterApi api)
{
    public abstract record Load
    {
        public sealed record Loading : Load;
        public sealed record Ready : Load;
        public sealed record Failed(string Reason) : Load;
    }

    public int Days { get; private set; } = 30;
    /// The period the numbers on screen are for.
    public int ShownDays { get; private set; } = 30;
    public UsageReport? Usage { get; private set; }
    public Load State { get; private set; } = new Load.Loading();
    public bool Busy { get; private set; }
    public bool RefreshFailed { get; private set; }
    public event Action? Changed;
    private int _serial;
    private bool _appeared;

    public void Appear()
    {
        // Opened again after a first read failed, it reads again instead of keeping "Couldn't Load Usage".
        if (_appeared && State is Load.Failed) { Retry(); return; }
        if (_appeared) return;
        _appeared = true;
        _ = ReadAsync();
    }

    public void SetDays(int days)
    {
        if (days == Days) return;
        Days = days;
        Changed?.Invoke();
        _ = ReadAsync();
    }

    public async Task ReadAsync()
    {
        var serial = ++_serial;
        var asked = Days;
        Busy = true;
        Changed?.Invoke();
        try
        {
            var report = await api.UsageAsync(asked);
            if (serial != _serial) return;
            Usage = report;
            ShownDays = asked;
            State = new Load.Ready();
            RefreshFailed = false;
        }
        catch (Exception e)
        {
            if (serial != _serial) return;
            if (Usage == null) State = new Load.Failed(InsightsWire.Reason(e)); else RefreshFailed = true;
        }
        finally
        {
            if (serial == _serial) { Busy = false; Changed?.Invoke(); }
        }
    }

    public string RefreshFailedText => UsageFormat.RefreshFailedText(ShownDays, Days);

    public void Retry()
    {
        if (Usage == null) { State = new Load.Loading(); Changed?.Invoke(); }
        _ = ReadAsync();
    }
}
