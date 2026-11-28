using Hermes.Core;
using Hermes.Core.Insights;
using Hermes.Core.Rpc;
using HermesHQ.Features.Bots;
using HermesHQ.Features.Jobs;
using HermesHQ.Pages;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Dispatching;

namespace HermesHQ.Features.Insights;

/// Status & Maintenance's model (App/Pages/More/CommandCenter/CommandCenter.swift, CommandCenterModel): the gateway's
/// status and update check, Restart Gateway, the maintenance actions, and whether the gateway is connected or read-only.
/// Lives on the UI thread; `Changed` redraws the page.
public sealed class CommandCenterModel
{
    public abstract record Load
    {
        public sealed record Loading : Load;
        public sealed record Ready : Load;
        public sealed record Failed(string Reason) : Load;
    }

    private readonly DispatcherQueue _ui;
    private readonly Func<bool>? _readOnlyOverride;
    public HermesClient Client { get; }
    public CommandCenterApi Api { get; }
    public bool Online { get; private set; }
    public GatewayStatusReport? Status { get; private set; }
    public Load StatusLoad { get; private set; } = new Load.Loading();
    public bool StatusRefreshFailed { get; private set; }
    public HermesUpdateCheck? Update { get; private set; }
    public bool UpdateChecked { get; private set; }
    public GatewayActionRun Restart { get; }
    public GatewayActionRun Maintenance { get; }
    public MaintenanceAction? MaintenanceAction { get; private set; }
    public event Action? Changed;
    private bool _appeared;

    public CommandCenterModel(HermesClient client, DispatcherQueue ui, Func<bool>? readOnlyOverride = null)
    {
        Client = client;
        _ui = ui;
        _readOnlyOverride = readOnlyOverride;
        Api = new CommandCenterApi(client.Session);
        Online = client.Rpc.State == ConnectionState.Open;
        Restart = new GatewayActionRun(Api.Actions);
        Maintenance = new GatewayActionRun(Api.Actions) { Interval = TimeSpan.FromMilliseconds(1200) }; // the web's ACTION_POLL_MS
        Restart.Changed += Notify;
        Maintenance.Changed += Notify;
        Restart.OnFinish = ok => OnUi(() => _ = LoadStatusAsync());
    }

    private void OnUi(Action a) { if (_ui.HasThreadAccess) a(); else _ui.TryEnqueue(() => a()); }
    private void Notify() => OnUi(() => Changed?.Invoke());

    /// Reads the live gateway's read-only status (matching Mac `MorePages.Context.readOnly` / `pages.readOnlyGateway`):
    /// gateway.ready payload flags, store read-only state, and debug read-only switches (`HQPagesReadOnly` / `HQW_READ_ONLY`).
    public static bool IsReadOnlyGateway(HermesClient? client)
    {
        if (IsTruthyEnv("HQPagesReadOnly") || IsTruthyEnv("HQW_READ_ONLY")) return true;
        if (client?.Rpc.ReadyPayload is { } ready)
        {
            if (ready.Bool("read_only") == true
                || ready.Bool("readOnly") == true
                || ready.Bool("read_only_gateway") == true
                || ready.Obj("permissions")?.Bool("read_only") == true
                || ready.Obj("capabilities")?.Bool("read_only") == true)
            {
                return true;
            }
        }
        if (ListsHub.Current is { } hub && (client == null || hub.Client == client) && (hub.Sessions.ReadOnly || hub.Bots.ReadOnly))
            return true;
        if ((client == null || ReferenceEquals(AppState.Client, client)) && JobsServices.Store?.ReadOnlyGateway == true)
            return true;
        return false;
    }

    private static bool IsTruthyEnv(string name)
    {
        var value = Environment.GetEnvironmentVariable(name)?.Trim();
        return !string.IsNullOrEmpty(value)
            && (value == "1"
                || string.Equals(value, "true", StringComparison.OrdinalIgnoreCase)
                || string.Equals(value, "yes", StringComparison.OrdinalIgnoreCase));
    }

    public bool ReadOnly => _readOnlyOverride?.Invoke() ?? IsReadOnlyGateway(Client);
    public string AccountKey => Client.AccountId;
    /// This gateway's update in the Update sheet, while it runs or until its ending is seen.
    public HermesUpdate? UpdateRun => HermesUpdateCenter.Shared.Run(AccountKey);
    public bool Updating => UpdateRun?.IsRunning ?? false;
    public bool AnyActionBusy => Restart.IsBusy || Updating;
    /// Restart and Update wait for a maintenance action, and a maintenance action waits for them.
    public bool CanStartAction => !ReadOnly && Online && !AnyActionBusy && !Maintenance.IsBusy;
    public bool CanStartMaintenance => CanStartAction;

    // ------------------------------------------------------------------ lifecycle

    public void Appear()
    {
        Client.Rpc.StateChanged += OnState;
        Client.Rpc.Reconnected += OnReconnected;
        HermesUpdateCenter.Shared.Changed += OnUpdateCenter;
        if (_appeared) return;
        _appeared = true;
        _ = LoadStatusAsync();
        _ = CheckUpdateAsync(false);
        if (!ReadOnly) _ = ResumeActionsAsync();
    }

    public void Disappear()
    {
        Client.Rpc.StateChanged -= OnState;
        Client.Rpc.Reconnected -= OnReconnected;
        HermesUpdateCenter.Shared.Changed -= OnUpdateCenter;
    }

    private void OnReconnected(bool _) => Notify();

    private HermesUpdateEnd? _seenEnd;
    private void OnUpdateCenter(string key)
    {
        if (key != AccountKey) return;
        OnUi(() =>
        {
            // The shared run ended: what the page shows is older than the gateway.
            if (UpdateRun?.End is { } end && !ReferenceEquals(end, _seenEnd)) { _seenEnd = end; UpdateEnded(); }
            Changed?.Invoke();
        });
    }

    private void OnState(ConnectionState state) => OnUi(async () =>
    {
        var ready = state == ConnectionState.Open;
        if (ready == Online) return;
        Online = ready;
        Changed?.Invoke();
        // Back after a drop: what the page shows may be older than the gateway; a first read that failed tries again.
        var firstFailed = StatusLoad is Load.Failed;
        if (ready && (Status != null || firstFailed) && !AnyActionBusy)
        {
            if (firstFailed) { StatusLoad = new Load.Loading(); Changed?.Invoke(); await CheckUpdateAsync(false); }
            await LoadStatusAsync();
        }
    });

    public async Task RefreshAsync()
    {
        await LoadStatusAsync();
        await CheckUpdateAsync(true);
    }

    // ------------------------------------------------------------------ status

    public async Task LoadStatusAsync()
    {
        try
        {
            var status = await Api.StatusAsync();
            Status = status;
            StatusLoad = new Load.Ready();
            StatusRefreshFailed = false;
            AppLog.Note("pages", $"status & maintenance: status {status.VersionWords}, gateway {status.GatewayWords}, {status.Platforms.Count} platforms");
        }
        catch (Exception e)
        {
            if (Status == null) StatusLoad = new Load.Failed(InsightsWire.Reason(e)); else StatusRefreshFailed = !AnyActionBusy;
        }
        Changed?.Invoke();
    }

    public void RetryStatus()
    {
        StatusLoad = new Load.Loading();
        Changed?.Invoke();
        _ = Task.WhenAll(LoadStatusAsync(), CheckUpdateAsync(false));
    }

    public async Task CheckUpdateAsync(bool force)
    {
        try
        {
            var answer = await Api.UpdateCheckAsync(force);
            Update = answer;
            HermesUpdateCenter.Shared.Note(answer, AccountKey);
        }
        catch (Exception) { }
        UpdateChecked = true;
        Changed?.Invoke();
    }

    /// The shared run ended: read again.
    public void UpdateEnded() => _ = Task.WhenAll(LoadStatusAsync(), CheckUpdateAsync(true));

    /// "Couldn’t Check" asks again.
    public void RetryUpdateCheck()
    {
        UpdateChecked = false; // reads "Checking…" while it asks
        if (Update?.CouldNotCheck == true) Update = null;
        Changed?.Invoke();
        _ = CheckUpdateAsync(true);
    }

    /// An action already running when the page opened (the app was relaunched mid-restart): pick it up.
    private async Task ResumeActionsAsync()
    {
        try
        {
            if (!Restart.IsBusy && await Api.Actions.StatusAsync("gateway-restart") is { Running: true } && !Restart.IsBusy)
                Restart.Start(() => Task.FromResult("gateway-restart"));
        }
        catch (Exception) { }
        try
        {
            if (!Updating && await Api.Actions.StatusAsync("hermes-update") is { Running: true } && !Updating)
                HermesUpdateCenter.Shared.Attach(AccountKey, () => UpdateSheet.MakeRun(Client, AccountKey));
        }
        catch (Exception) { }
    }

    /// After the confirmation: restart the gateway.
    public void StartRestart()
    {
        if (!CanStartAction) return;
        AppLog.Note("command-center", "restart gateway");
        var actions = Api.Actions;
        Restart.Start(() => actions.RestartAsync());
    }

    /// Messaging is listed on Windows (its page is where a failing app is fixed).
    public static bool CanOpenMessaging => Places.Get("messaging").Page != typeof(PlaceholderPage);

    // ------------------------------------------------------------------ maintenance

    public void Run(MaintenanceAction action)
    {
        if (!CanStartMaintenance) return;
        AppLog.Note("command-center", $"maintenance {action.Id()}");
        MaintenanceAction = action;
        Maintenance.Reset();
        var actions = Api.Actions;
        Maintenance.Start(() => action.StartAsync(actions));
    }
}
