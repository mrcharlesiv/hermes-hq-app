namespace HermesHQ.Shell;

/// A place's page with a refresh of its own (App/Root/KeyCommands.swift `KeyRefreshing`, or a list's refresh control
/// pulled): View › Refresh (Ctrl+R, F5) runs it while the page is on show (Hermes.Core.Shell.RefreshKeys). A page without
/// one leaves the key off, as the Mac dims ⌘R there.
public interface IKeyRefreshing
{
    void KeyRefresh();
}
