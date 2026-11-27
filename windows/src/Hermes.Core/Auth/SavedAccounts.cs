using System.Text.Json;
using System.Text.Json.Serialization;

namespace Hermes.Core.Auth;

/// What survives a restart. The JSON matches HermesKit's SavedAccounts (HermesKit/Net/SavedAccounts.swift) field for
/// field, so the shape is one thing to learn. The password is never stored.
public sealed record SavedCookie(string Name, string Value, string Domain, string Path, double? Expires, bool Secure,
    bool? HttpOnly = null, string? SameSite = null);

public sealed record NousTokens(string AccessToken, string RefreshToken, double ExpiresAt, string UserId,
    double? ObtainedAt = null)
{
    /// Spec 01 §7.1 / D6. Blocking renew when past max(lifetime-60, lifetime/2) of the pair's life.
    public bool NeedsRenewal(DateTimeOffset now)
    {
        var t = now.ToUnixTimeMilliseconds() / 1000.0;
        if (ExpiresAt <= 0) return false;
        if (ObtainedAt is not { } got) return ExpiresAt - t < 60;
        var life = ExpiresAt - got;
        if (life <= 0) return false;
        return t >= got + Math.Max(life - 60, life / 2);
    }

    /// Background renew alongside the request once half the lifetime has passed.
    public bool RenewsAlongside(DateTimeOffset now)
    {
        if (ExpiresAt <= 0 || ObtainedAt is not { } got) return false;
        var life = ExpiresAt - got;
        return life > 0 && now.ToUnixTimeMilliseconds() / 1000.0 >= got + life / 2;
    }
}

public sealed record StoredAccount(string Url, string Username, List<SavedCookie>? Cookies = null,
    string? Provider = null, string? Label = null, NousTokens? Nous = null)
{
    [JsonIgnore] public string Key => Url + "\n" + Username;
    [JsonIgnore] public bool IsSignedIn => Nous != null || Cookies is { Count: > 0 };
    [JsonIgnore] public bool IsNous => Nous != null || Username.StartsWith("nous:", StringComparison.Ordinal);
    /// What a refused session leaves behind: the prefilled sign-in form's address and username.
    [JsonIgnore] public StoredAccount WithoutSession => this with { Cookies = null, Nous = null };
}

/// The Credential Locker could not be read right now (as the Keychain's "unavailable"): not the same as nothing saved.
public sealed class TokenStoreUnavailableException(string message, Exception? inner = null) : Exception(message, inner);

public sealed class SavedAccounts
{
    public string? Current { get; set; }
    public List<StoredAccount> Accounts { get; set; } = [];

    [JsonIgnore] public StoredAccount? CurrentAccount =>
        Accounts.FirstOrDefault(a => a.Key == Current) ?? Accounts.FirstOrDefault();

    /// Saved (or updated) and made current, first in the list (most recently used first). A save that names no label
    /// keeps the old one (HermesKit `SavedAccounts.save`).
    public void Upsert(StoredAccount account)
    {
        if (account.Label == null && Accounts.FirstOrDefault(a => a.Key == account.Key)?.Label is { } kept)
            account = account with { Label = kept };
        Accounts.RemoveAll(a => a.Key == account.Key);
        Accounts.Insert(0, account);
        Current = account.Key;
    }

    public StoredAccount? Find(string key) => Accounts.FirstOrDefault(a => a.Key == key);

    /// Changed in place (order and Current untouched); false when not saved.
    public bool Update(string key, Func<StoredAccount, StoredAccount> change)
    {
        var i = Accounts.FindIndex(a => a.Key == key);
        if (i < 0) return false;
        Accounts[i] = change(Accounts[i]);
        return true;
    }

    /// Made current (a switch) and moved first; false for an account that isn't saved.
    public bool Select(string key)
    {
        var i = Accounts.FindIndex(a => a.Key == key);
        if (i < 0) return false;
        var a = Accounts[i];
        Accounts.RemoveAt(i);
        Accounts.Insert(0, a);
        Current = key;
        return true;
    }

    /// Removed; removing the current account makes the most recently used other one current (none when it was last).
    public StoredAccount? Remove(string key)
    {
        var i = Accounts.FindIndex(a => a.Key == key);
        if (i < 0) return null;
        var removed = Accounts[i];
        Accounts.RemoveAt(i);
        if (Current == key) Current = Accounts.FirstOrDefault()?.Key;
        return removed;
    }

    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public string ToJson() => JsonSerializer.Serialize(this, Options);
    /// False when there is text that isn't the saved list (the store's "unreadable").
    public static bool TryFromJson(string? json, out SavedAccounts saved)
    {
        saved = new SavedAccounts();
        if (string.IsNullOrWhiteSpace(json)) return true;
        try { saved = JsonSerializer.Deserialize<SavedAccounts>(json, Options) ?? new SavedAccounts(); return true; }
        catch (JsonException) { return false; }
    }

    public static SavedAccounts FromJson(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return new SavedAccounts();
        try { return JsonSerializer.Deserialize<SavedAccounts>(json, Options) ?? new SavedAccounts(); }
        catch (JsonException) { return new SavedAccounts(); }
    }
}

/// Secure storage for the SavedAccounts JSON. On Windows: the Credential Locker (PasswordVault), resource
/// "ai.hermes.hqwindows.gateway", user "primary". Tests use the in-memory store.
public interface ITokenStore
{
    string? Read();
    void Write(string json);
    void Delete();
}

public sealed class MemoryTokenStore : ITokenStore
{
    private string? _json;
    public string? Read() => _json;
    public void Write(string json) => _json = json;
    public void Delete() => _json = null;
}
