namespace Hermes.Core.Notifications;

/// Quiet add-on update reminder shared across Settings, Capabilities, and Notifications
/// (port of App/Notifications/AddOnReminder.swift).
public static class AddOnReminder
{
    private static readonly object Gate = new();
    private static bool _hasUpdate;
    private static string? _targetVersion;
    private static string? _summary;

    public static bool HasUpdate
    {
        get { lock (Gate) return _hasUpdate; }
    }

    public static string? TargetVersion
    {
        get { lock (Gate) return _targetVersion; }
    }

    public static string? Summary
    {
        get { lock (Gate) return _summary; }
    }

    public static event Action? Changed;

    /// Updates reminder state from the gateway's installed add-on version and optional latest version / summary.
    /// Passing all nulls clears any active reminder.
    public static void Update(string? installedVersion, string? latestVersion = null, string? summary = null)
    {
        var installed = string.IsNullOrWhiteSpace(installedVersion) ? null : installedVersion.Trim();
        var latest = string.IsNullOrWhiteSpace(latestVersion) ? null : latestVersion.Trim();
        var note = string.IsNullOrWhiteSpace(summary) ? null : summary.Trim();

        bool nextHasUpdate;
        string? nextTarget;
        string? nextSummary;

        if (installed == null && latest == null && note == null)
        {
            nextHasUpdate = false;
            nextTarget = null;
            nextSummary = null;
        }
        else
        {
            var resolvedTarget = latest ?? AddOnChanges.PushWantedVersion;
            if (AddOnChanges.IsCommitSha(resolvedTarget))
                resolvedTarget = AddOnChanges.BestTargetVersion(null, resolvedTarget, AddOnChanges.PushPluginName) ?? AddOnChanges.PushWantedVersion;

            if (installed != null && AddOnChanges.IsValidVersion(resolvedTarget) && AddOnChanges.VersionAtLeast(installed, resolvedTarget))
            {
                nextHasUpdate = false;
                nextTarget = null;
                nextSummary = null;
            }
            else if (installed != null && !AddOnChanges.IsValidVersion(resolvedTarget) && string.Equals(installed, resolvedTarget, StringComparison.OrdinalIgnoreCase))
            {
                nextHasUpdate = false;
                nextTarget = null;
                nextSummary = null;
            }
            else
            {
                nextHasUpdate = true;
                nextTarget = resolvedTarget;
                nextSummary = note ?? AddOnChanges.FallbackSummary(
                    AddOnChanges.PushPluginName,
                    from: installed,
                    to: resolvedTarget,
                    setUp: installed == null);
            }
        }

        var changed = false;
        lock (Gate)
        {
            if (_hasUpdate != nextHasUpdate
                || !string.Equals(_targetVersion, nextTarget, StringComparison.Ordinal)
                || !string.Equals(_summary, nextSummary, StringComparison.Ordinal))
            {
                _hasUpdate = nextHasUpdate;
                _targetVersion = nextTarget;
                _summary = nextSummary;
                changed = true;
            }
        }

        if (changed) Changed?.Invoke();
    }

    /// Clears the active add-on reminder (e.g. on sign-out or after a verified update).
    public static void Clear() => Update(null, null, null);

    /// "Gym", "Gym and Ivy", "Gym, Ivy and 3 more" (AddOnReminder.swift `names`).
    public static string Names(IReadOnlyList<string> names)
    {
        if (names.Count == 0) return "";
        if (names.Count == 1) return names[0];
        if (names.Count == 2) return $"{names[0]} and {names[1]}";
        var rest = names.Count - 2;
        return $"{names[0]}, {names[1]} and {rest} more";
    }
}
