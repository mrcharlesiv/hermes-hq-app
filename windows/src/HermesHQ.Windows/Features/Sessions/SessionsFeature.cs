using HermesHQ.Pages;
using HermesHQ.Shell;

namespace HermesHQ.Features.Sessions;

/// Sessions (docs/spec/3x-sessions.md): the place's page is Pages/SessionsPage; its data is Hermes.Core.Sessions through
/// `ListsHub`.
public static class SessionsFeature
{
    public static void Register() => Places.Register("sessions", typeof(SessionsPage));
}
