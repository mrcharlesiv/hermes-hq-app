namespace Hermes.Core.Tests;

// The same synthetic runner projection for the probe and the linked foreground predicate. No process environment.
internal static class ToastQuietRunner
{
    internal const string Repo = "mrcharlesiv/hermes-hq-windows", Ref = "refs/heads/feat/windows";
    internal const string Sha = "0123456789abcdef0123456789abcdef01234567";
    internal static Dictionary<string, string?> Push() => new()
    {
        ["GITHUB_ACTIONS"] = "true", ["RUNNER_OS"] = "Windows", ["RUNNER_ENVIRONMENT"] = "github-hosted",
        ["GITHUB_SERVER_URL"] = "https://github.com", ["GITHUB_EVENT_NAME"] = "push", ["GITHUB_REPOSITORY"] = Repo,
        ["GITHUB_REF"] = Ref, ["GITHUB_WORKFLOW"] = "windows", ["GITHUB_WORKFLOW_REF"] = Repo + "/.github/workflows/windows.yml@" + Ref,
        ["GITHUB_JOB"] = "build", ["GITHUB_SHA"] = Sha, ["GITHUB_WORKFLOW_SHA"] = Sha,
        ["HQW_QUIET_PUSH"] = $"{Repo}|true|false|{Ref}|{Sha}|false",
        ["GITHUB_RUN_ID"] = "28", ["GITHUB_RUN_ATTEMPT"] = "2", ["HQW_PRIVATE_MIRROR"] = "true", ["HQW_DESKTOP_PROOF"] = "1",
    };
}
