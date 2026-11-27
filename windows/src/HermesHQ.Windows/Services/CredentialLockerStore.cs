using Hermes.Core.Auth;
using Windows.Security.Credentials;

namespace HermesHQ.Services;

/// The SavedAccounts JSON in the Windows Credential Locker: per user, encrypted by Windows, roams nowhere.
/// The twin of HermesKit's Keychain item (service ai.hermes.hqnative.gateway, account primary).
///
/// A Locker entry holds at most 2,560 bytes, and several gateways' sessions (a Nous pair is over a kilobyte) outgrow
/// that: a long list is kept in parts, "primary" then saying "parts:N" and "primary.1"…"primary.N" holding the text.
public sealed class CredentialLockerStore : ITokenStore
{
    private const string Resource = "ai.hermes.hqwindows.gateway";
    private const string User = "primary";
    private const string PartsPrefix = "parts:";
    private const int PartSize = 1000; // characters: UTF-16 in the Locker, so 2,000 bytes
    private const int ElementNotFound = unchecked((int)0x80070490);
    private readonly PasswordVault _vault = new();

    public string? Read()
    {
        var head = ReadOne(User);
        if (head == null || !head.StartsWith(PartsPrefix, StringComparison.Ordinal)) return head;
        if (!int.TryParse(head[PartsPrefix.Length..], out var n) || n is < 1 or > 64)
            throw new TokenStoreUnavailableException("The saved sign-in's parts are unreadable.");
        var parts = new string[n];
        for (var i = 0; i < n; i++)
            parts[i] = ReadOne($"{User}.{i + 1}") ?? throw new TokenStoreUnavailableException("A part of the saved sign-in is missing.");
        return string.Concat(parts);
    }

    /// Null when nothing is saved under `user`; throws TokenStoreUnavailableException when the Locker can't be read.
    private string? ReadOne(string user)
    {
        try
        {
            var c = _vault.Retrieve(Resource, user);
            c.RetrievePassword();
            return c.Password;
        }
        catch (Exception e) when (e.HResult == ElementNotFound) { return null; }
        catch (Exception e) { throw new TokenStoreUnavailableException("The Credential Locker couldn't be read.", e); }
    }

    public void Write(string json)
    {
        Delete();
        if (json.Length <= PartSize)
        {
            _vault.Add(new PasswordCredential(Resource, User, json));
            return;
        }
        var n = (json.Length + PartSize - 1) / PartSize;
        for (var i = 0; i < n; i++)
            _vault.Add(new PasswordCredential(Resource, $"{User}.{i + 1}", json.Substring(i * PartSize, Math.Min(PartSize, json.Length - i * PartSize))));
        _vault.Add(new PasswordCredential(Resource, User, PartsPrefix + n));
    }

    public void Delete()
    {
        try
        {
            foreach (var c in _vault.FindAllByResource(Resource)) _vault.Remove(c);
        }
        catch (Exception) { } // "Element not found" when nothing is saved
    }
}
