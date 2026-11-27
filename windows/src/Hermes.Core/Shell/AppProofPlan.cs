using System.Text.Json.Nodes;

namespace Hermes.Core.Shell;

/// The scoped CI runner can drive these app walks only; reject the whole plan before any sign-in.
public static class AppProofPlan
{
    private static readonly (string Tag, string Url, string[] Walks)[] Suites =
    [
        ("composer", "http://127.0.0.1:9750", ["open-quickly", "chat-find"]),
        ("settings", "http://127.0.0.1:9830", ["settings-file"]),
        ("groups", "http://127.0.0.1:9831", ["group-room"]),
        ("sessions", "http://127.0.0.1:9771", ["new-chat-here"]),
        ("keyboard-only", "http://127.0.0.1:9862", ["keyboard-only"]),
        ("a11y-audit", "http://127.0.0.1:9861", ["a11y-audit"])
    ];

    public static bool Accepts(JsonNode? extras)
    {
        if (extras is not JsonArray entries || entries.Count != Suites.Length) return false;
        for (int i = 0; i < entries.Count; i++)
        {
            var expected = Suites[i];
            var entry = entries[i];
            if (entry.Str("tag") != expected.Tag || entry.Str("url") != expected.Url ||
                entry.Arr("places") is not { Count: 0 } || entry.Arr("walks") is not { } walks ||
                !walks.Select(J.AsString).SequenceEqual(expected.Walks)) return false;
        }
        return true;
    }
}
