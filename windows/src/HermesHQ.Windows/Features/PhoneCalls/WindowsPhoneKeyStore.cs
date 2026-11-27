using System.Security.Cryptography;
using System.Text;
using Hermes.Core.PhoneCalls;
using Windows.Security.Credentials;

namespace HermesHQ.Features.PhoneCalls;

/// Windows Credential Locker secret store for per-account samplehost API keys (mirroring `PhoneKeychain` on macOS).
internal sealed class WindowsPhoneKeyStore : IPhoneKeyStore
{
    private const string Resource = "ai.hermes.hqwindows.phone.samplehost";
    private const int ElementNotFound = unchecked((int)0x80070490);
    private PasswordVault? _vault;

    private PasswordVault? Vault()
    {
        if (_vault != null) return _vault;
        try { return _vault = new PasswordVault(); }
        catch (Exception) { return null; }
    }

    private static string UserFor(string accountId) =>
        "samplehost-" + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(accountId)))[..24];

    public string? ReadKey(string accountId)
    {
        try
        {
            if (Vault() is not { } vault) return null;
            var cred = vault.Retrieve(Resource, UserFor(accountId));
            cred.RetrievePassword();
            return string.IsNullOrWhiteSpace(cred.Password) ? null : cred.Password;
        }
        catch (Exception ex) when (ex.HResult == ElementNotFound)
        {
            return null;
        }
        catch (Exception)
        {
            return null;
        }
    }

    public void SaveKey(string accountId, string apiKey)
    {
        DeleteKey(accountId);
        var clean = apiKey.Trim();
        if (clean.Length == 0) return;
        Vault()?.Add(new PasswordCredential(Resource, UserFor(accountId), clean));
    }

    public void DeleteKey(string accountId)
    {
        try
        {
            if (Vault() is not { } vault) return;
            var cred = vault.Retrieve(Resource, UserFor(accountId));
            vault.Remove(cred);
        }
        catch (Exception)
        {
            // Nothing stored or vault unavailable.
        }
    }
}
