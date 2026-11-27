using System.Net;
using System.Net.Sockets;
using System.Text.Json.Nodes;
using Hermes.Core.Net;

namespace Hermes.Core.Artifacts;

/// What the Artifacts page reads from the gateway: the sessions listing, a transcript's pages, a picture's bytes and a
/// file (HermesKit/Pages/ArtifactsStore.swift, ArtifactFiles.swift). Tests give a stand-in.
public interface IArtifactSource
{
    Task<JsonNode> ListSessionsAsync(string profile, int limit, CancellationToken ct);
    Task<string> TranscriptPageAsync(ArtifactSessionRow session, int limit, int offset, CancellationToken ct);
    /// `/api/fs/read-data-url` for a gateway file: its data URL.
    Task<string> DataUrlAsync(ArtifactRecord record, CancellationToken ct);
    /// `/api/fs/download` into `file` (never into memory). Past the REST ceiling: GatewayException "too-large".
    Task DownloadAsync(ArtifactRecord record, string file, CancellationToken ct);
}

/// The real source: the signed-in gateway's REST.
public sealed class GatewayArtifactSource(GatewaySession session) : IArtifactSource
{
    public const string SessionsPath = "/api/profiles/sessions";
    private static readonly TimeSpan Minute = TimeSpan.FromSeconds(60);

    private async Task<string> GetAsync(string path, IEnumerable<KeyValuePair<string, string>> query, TimeSpan timeout, CancellationToken ct)
    {
        var answer = await session.SendAsync(HttpMethod.Get, path, query, null, timeout, ct: ct).ConfigureAwait(false);
        if (!answer.Ok) throw GatewaySession.HttpError(answer);
        return answer.Body;
    }

    public async Task<JsonNode> ListSessionsAsync(string profile, int limit, CancellationToken ct)
    {
        var text = await GetAsync(SessionsPath, [
            new("limit", limit.ToString()), new("offset", "0"), new("min_messages", "1"), new("archived", "exclude"),
            new("order", "recent"), new("profile", profile),
        ], Minute, ct).ConfigureAwait(false);
        return J.Parse(text) ?? throw new ArtifactReadException("The gateway’s answer couldn’t be read.");
    }

    public Task<string> TranscriptPageAsync(ArtifactSessionRow s, int limit, int offset, CancellationToken ct) =>
        GetAsync($"/api/sessions/{Uri.EscapeDataString(s.Id)}/messages", [
            new("profile", s.Profile ?? "default"), new("limit", limit.ToString()), new("offset", offset.ToString()),
            new("order", "oldest"), new("include_compacted", "true"),
        ], Minute, ct);

    public async Task<string> DataUrlAsync(ArtifactRecord record, CancellationToken ct)
    {
        var json = J.Parse(await GetAsync("/api/fs/read-data-url", ArtifactFiles.Query(record), Minute, ct).ConfigureAwait(false));
        return json.Str("dataUrl") ?? json.Str("data_url") ?? throw new ArtifactReadException("This image could not be read.");
    }

    public async Task DownloadAsync(ArtifactRecord record, string file, CancellationToken ct)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(TimeSpan.FromSeconds(120));
        try
        {
            await session.DownloadToFileAsync("/api/fs/download", ArtifactFiles.Query(record), file, ArtifactFiles.FileLimit, ct: cts.Token)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new GatewayException("timeout", "The gateway took too long to answer.");
        }
    }
}

/// Reading an artifact's bytes (`ArtifactFiles.imageData` / `download`).
public static class ArtifactReads
{
    /// An image's bytes: a data URL as is; a gateway file through `read-data-url`; a hosted image only over https from a
    /// public host, without gateway credentials (`RemoteImageFetch`).
    public static async Task<byte[]> ImageAsync(IArtifactSource source, ArtifactRecord record, CancellationToken ct = default)
    {
        if (record.Value.StartsWith("data:", StringComparison.Ordinal)) return ArtifactFiles.DecodeDataUrl(record.Value);
        if (ArtifactFiles.IsHosted(record)) return await RemoteImageFetch.FetchAsync(record.Value, ct).ConfigureAwait(false);
        return ArtifactFiles.DecodeDataUrl(await source.DataUrlAsync(record, ct).ConfigureAwait(false));
    }

    /// Reads one session's artifacts.
    public static Task<List<ArtifactRecord>> SessionAsync(IArtifactSource source, ArtifactSessionRow session, CancellationToken ct) =>
        ArtifactCollector.LoadSessionAsync(session, (s, limit, offset, c) => source.TranscriptPageAsync(s, limit, offset, c), ct: ct);
}

/// A picture on another site (HermesKit/Net/RemoteImageFetch.swift): https only, from a public host, no gateway
/// credentials or cookies, an image, 16 MiB at most, five https redirects at most. Anything else is refused and the
/// tile offers Open.
public static class RemoteImageFetch
{
    public const int MaxRedirects = 5;
    public const int MaxBytes = 16 << 20;
    private static readonly HttpClient Http = new(new SocketsHttpHandler
    {
        AllowAutoRedirect = false, UseCookies = false, ConnectTimeout = TimeSpan.FromSeconds(15),
    }) { Timeout = TimeSpan.FromSeconds(30) };

    public static async Task<byte[]> FetchAsync(string raw, CancellationToken ct = default)
    {
        if (!Uri.TryCreate(raw, UriKind.Absolute, out var url) || url.Scheme != "https") throw new RemoteImageRefusedException("not https");
        for (var hops = 0; ; hops++)
        {
            if (!await IsPublicAsync(url, ct).ConfigureAwait(false)) throw new RemoteImageRefusedException("not a public host");
            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            request.Headers.Accept.ParseAdd("image/*");
            HttpResponseMessage response;
            try { response = await Http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false); }
            catch (HttpRequestException e) { throw new RemoteImageRefusedException(e.Message); }
            catch (TaskCanceledException) when (!ct.IsCancellationRequested) { throw new RemoteImageRefusedException("timed out"); }
            using (response)
            {
                if ((int)response.StatusCode is >= 300 and < 400 && response.Headers.Location is { } next)
                {
                    url = next.IsAbsoluteUri ? next : new Uri(url, next);
                    if (hops + 1 > MaxRedirects || url.Scheme != "https") throw new RemoteImageRefusedException("redirect refused");
                    continue;
                }
                if (!response.IsSuccessStatusCode) throw new RemoteImageRefusedException($"status {(int)response.StatusCode}");
                var type = response.Content.Headers.ContentType?.MediaType ?? "";
                if (!type.StartsWith("image/", StringComparison.OrdinalIgnoreCase)) throw new RemoteImageRefusedException("not an image");
                if (response.Content.Headers.ContentLength > MaxBytes) throw new RemoteImageRefusedException("too large");
                await using var stream = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
                using var memory = new MemoryStream();
                var buffer = new byte[81920];
                int read;
                while ((read = await stream.ReadAsync(buffer, ct).ConfigureAwait(false)) > 0)
                {
                    memory.Write(buffer, 0, read);
                    if (memory.Length > MaxBytes) throw new RemoteImageRefusedException("too large");
                }
                return memory.ToArray();
            }
        }
    }

    /// The host is on the public internet: every address it resolves to is (no loopback, private, link-local or
    /// carrier-grade NAT addresses: a picture never reaches into the owner's own network).
    public static async Task<bool> IsPublicAsync(Uri url, CancellationToken ct = default)
    {
        IPAddress[] addresses;
        if (IPAddress.TryParse(url.IdnHost.Trim('[', ']'), out var literal)) addresses = [literal];
        else
        {
            if (url.IdnHost.Equals("localhost", StringComparison.OrdinalIgnoreCase) || !url.IdnHost.Contains('.')) return false;
            try { addresses = await Dns.GetHostAddressesAsync(url.IdnHost, ct).ConfigureAwait(false); }
            catch (SocketException) { return false; }
        }
        return addresses.Length > 0 && addresses.All(IsPublic);
    }

    public static bool IsPublic(IPAddress address)
    {
        if (address.IsIPv4MappedToIPv6) address = address.MapToIPv4();
        if (IPAddress.IsLoopback(address)) return false;
        if (address.AddressFamily == AddressFamily.InterNetworkV6)
            return !(address.IsIPv6LinkLocal || address.IsIPv6SiteLocal || address.IsIPv6Multicast || address.Equals(IPAddress.IPv6None)
                     || (address.GetAddressBytes()[0] & 0xFE) == 0xFC);
        var b = address.GetAddressBytes();
        return !(b[0] == 0 || b[0] == 10 || b[0] == 127 || (b[0] == 169 && b[1] == 254) || (b[0] == 172 && b[1] is >= 16 and <= 31)
                 || (b[0] == 192 && b[1] == 168) || (b[0] == 100 && b[1] is >= 64 and <= 127) || b[0] >= 224);
    }
}
