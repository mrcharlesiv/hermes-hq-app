using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core;
using Hermes.Core.Artifacts;
using HermesHQ.Services;

namespace HermesHQ.Features.Artifacts;

/// The gateway in use's Artifacts: one store (and its kept index), one picture cache, and the page's own choices
/// (the bot and the segment), per account. Made when the page first draws (never at launch), dropped when the gateway
/// in use changes (the Mac's ArtifactsStore lives on the account's PagesServices).
internal static class ArtifactsHub
{
    private static string? _account;
    private static ArtifactsStore? _store;
    private static ArtifactPreviews? _previews;

    public static string PagesRoot => Path.Combine(AppPaths.Root, "pages");

    public static string Hash(string accountId) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(accountId)))[..16];

    /// Where an account's downloaded files and pictures are kept.
    public static string CacheRoot(string accountId) => Path.Combine(AppPaths.Root, "cache", "artifacts", Hash(accountId));

    public static (ArtifactsStore Store, ArtifactPreviews Previews) For(HermesClient client)
    {
        if (_store != null && _previews != null && _account == client.AccountId) return (_store, _previews);
        _store?.Reset();
        _account = client.AccountId;
        var prefs = Prefs(client.AccountId);
        _store = new ArtifactsStore(new GatewayArtifactSource(client.Session),
            Path.Combine(PagesRoot, Hash(client.AccountId), "artifacts-index.json"),
            ArtifactHidden.Of(client.AccountId, PagesRoot), prefs.Scope)
        {
            ProfilesProvider = () => [.. (client.Bots ?? []).Select(b => b.Name)],
            DisplayName = p => client.Bots?.FirstOrDefault(b => b.Name == p)?.DisplayName ?? (p == "default" ? "Hermes" : p),
        };
        _previews = new ArtifactPreviews(_store.Source, CacheRoot(client.AccountId));
        // A session read again: its pictures are read again (the kept ones stay up meanwhile).
        _store.SessionsRead += rows => _previews.MarkStale(rows.Select(r => r.Id));
        AppLog.Note("artifacts", "store made for the gateway in use");
        return (_store, _previews);
    }

    /// The gateway in use changed: the next page starts from that account's own index.
    public static void Reset()
    {
        _store?.Reset();
        _store = null;
        _previews = null;
        _account = null;
    }

    // ---- the page's choices (the Mac's `pages.scope.<account>` and `pages.artifactsFilter.<account>`)

    public sealed record PagePrefs(string Scope, ArtifactKind? Filter);

    private static string PrefsFile(string accountId) => Path.Combine(PagesRoot, Hash(accountId), "artifacts-page.json");

    public static PagePrefs Prefs(string accountId)
    {
        try
        {
            var json = J.Parse(File.ReadAllText(PrefsFile(accountId)));
            return new PagePrefs(json.Text("scope") ?? ArtifactsStore.All, ArtifactKinds.Parse(json.Str("filter")));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return new PagePrefs(ArtifactsStore.All, null); }
    }

    public static void SavePrefs(string accountId, PagePrefs prefs)
    {
        try
        {
            var file = PrefsFile(accountId);
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            File.WriteAllText(file, new JsonObject { ["scope"] = prefs.Scope, ["filter"] = prefs.Filter?.Raw() ?? "all" }.ToJsonString());
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}
