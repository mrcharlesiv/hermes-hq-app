using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Gateways;
using Hermes.Core.Net;

namespace Hermes.Core.Tests;

/// Regression tests for Nous cloud gateway auto sign-out fixes (4261493f8) and H10 expired-rotated-token guard:
/// - GatewayRefusal.IsHermes: proxy/Cloudflare HTML 4xx pages never sign out; Hermes JSON 4xx refusals do.
/// - 503 refresh_pending bounded retry collection honoring retry_after.
/// - Process-wide NousRenewals full-chain walk (> 16 hops, cycle guard) + cross-instance FlightKey single-flight.
/// - H10: rotated token that is already expired triggers fresh renewal instead of returning stale expired token.
/// - SettleRenewalAsync waits for in-flight renewals before transport disposal (and honors short deadlines without cancelling).
/// - priorUnsaved CAS retry when ITokenStore transiently refuses writes.
/// - NousSessionKeepAlive.RefreshDue 4 h cadence and GatewayHub sweep across single-gateway & 0-chat Nous accounts.
public sealed class NousKeepAliveAndRenewalTests
{
    private sealed class StubHandler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> handle) : HttpMessageHandler
    {
        public int Requests;
        public List<string> Paths { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Interlocked.Increment(ref Requests);
            lock (Paths) Paths.Add(request.RequestUri?.AbsolutePath ?? "");
            return await handle(request, cancellationToken);
        }
    }

    private sealed class FlakyTokenStore : ITokenStore
    {
        private readonly object _lock = new();
        private string? _json;
        public volatile bool RefuseWrites;
        public volatile bool RefuseReads;

        public string? Read()
        {
            if (RefuseReads) throw new TokenStoreUnavailableException("locked");
            lock (_lock) return _json;
        }

        public void Write(string json)
        {
            if (RefuseWrites) throw new TokenStoreUnavailableException("locked");
            lock (_lock) _json = json;
        }

        public void Delete()
        {
            lock (_lock) _json = null;
        }

        public string? PeekRaw()
        {
            lock (_lock) return _json;
        }
    }

    private static HttpResponseMessage Response(int status, string body, string mediaType = "application/json", string? retryAfter = null)
    {
        var msg = new HttpResponseMessage((HttpStatusCode)status)
        {
            Content = new StringContent(body, Encoding.UTF8, mediaType),
        };
        if (retryAfter != null) msg.Headers.TryAddWithoutValidation("Retry-After", retryAfter);
        return msg;
    }

    private static NousTokens Pair(int n, DateTimeOffset now, double expiresIn = 900, double obtainedAgo = 0, string user = "u1")
    {
        var t = now.ToUnixTimeMilliseconds() / 1000.0;
        return new NousTokens($"at-{n}", $"rt-{n}", t + expiresIn, user, t - obtainedAgo);
    }

    private static string RefreshBody(int n, DateTimeOffset now, double expiresIn = 900, string user = "u1")
    {
        var exp = now.ToUnixTimeMilliseconds() / 1000.0 + expiresIn;
        return new JsonObject
        {
            ["access_token"] = $"at-{n}",
            ["refresh_token"] = $"rt-{n}",
            ["user_id"] = user,
            ["provider"] = "nous",
            ["expires_at"] = exp,
        }.ToJsonString();
    }

    private static StoredAccount SavedNous(string url, NousTokens tokens, string user = "u1") =>
        new(url, "nous:" + user, Nous: tokens);

    private static ITokenStore StoreWith(params StoredAccount[] accounts)
    {
        var store = new MemoryTokenStore();
        var saved = new SavedAccounts();
        foreach (var a in Enumerable.Reverse(accounts)) saved.Upsert(a);
        store.Write(saved.ToJson());
        return store;
    }

    // ------------------------------------------------------------------ GatewayRefusal & RetryAfter

    [Fact]
    public void GatewayRefusalRecognizesOnlyHermesJsonBodies()
    {
        foreach (var hermes in new[]
        {
            """{"error":"session_expired","detail":"Unauthorized","reason":"invalid_or_expired_session"}""",
            """{"error":"unauthenticated"}""",
            """{"error":"not_authorized"}""",
            """{"detail":"Unauthorized"}""",
            """{"detail":"Not authenticated"}""",
            """{"detail":[{"loc":["body"],"msg":"field required"}]}""",
        })
        {
            Assert.True(GatewayRefusal.IsHermes(hermes), hermes);
        }

        foreach (var foreign in new[]
        {
            null,
            "",
            "   ",
            "Forbidden",
            "<!doctype html><title>Just a moment...</title>",
            "<html><h1>403 Forbidden</h1><hr>nginx</html>",
            "error code: 1020",
            "[]",
            "\"Unauthorized\"",
            "{}",
            """{"message":"Forbidden"}""",
            """{"error":123}""",
            """{"detail":null}""",
            """{"cloudflare_error":true,"error_code":1020,"detail":"Access denied","title":"Error 1020"}""",
        })
        {
            Assert.False(GatewayRefusal.IsHermes(foreign), foreign ?? "<null>");
        }
    }

    [Fact]
    public void RefreshPendingAndRetryAfterParseHeaderAndBodySafely()
    {
        var pendingBody = """{"error":"refresh_pending","detail":"in progress","retry_after":3}""";
        Assert.True(NousProtocol.IsRefreshPending(503, pendingBody));
        Assert.False(NousProtocol.IsRefreshPending(502, pendingBody));
        Assert.False(NousProtocol.IsRefreshPending(503, """{"error":"other"}"""));
        Assert.False(NousProtocol.IsRefreshPending(503, "<html>503 Service Unavailable</html>"));

        var now = new DateTimeOffset(2026, 11, 28, 12, 0, 0, TimeSpan.Zero);
        Assert.Equal(TimeSpan.FromSeconds(7), NousProtocol.RetryAfter("7", pendingBody, now));
        Assert.Equal(TimeSpan.FromSeconds(3), NousProtocol.RetryAfter(null, pendingBody, now));
        Assert.Equal(TimeSpan.FromSeconds(15), NousProtocol.RetryAfter(now.AddSeconds(15).ToString("r"), null, now));

        foreach (var bad in new[] { "", "0", "-5", "inf", "Infinity", "NaN", "not-a-date" })
            Assert.Null(NousProtocol.ParseRetryAfterHeader(bad, now));
    }

    // ------------------------------------------------------------------ Non-Hermes 4xx vs Hermes JSON 4xx

    [Theory]
    [InlineData(400)]
    [InlineData(401)]
    [InlineData(403)]
    public async Task NonHermesProxyHtml4xxNeverCallsEndSession(int status)
    {
        var now = DateTimeOffset.UtcNow;
        var initial = Pair(1, now, expiresIn: -10, obtainedAgo: 910);
        var account = SavedNous("https://cloud.example.com", initial);
        var store = StoreWith(account);
        var renewals = new NousRenewals();
        var html = "<!doctype html><html><title>Just a moment...</title><body>Checking your browser</body></html>";
        var handler = new StubHandler((_, _) => Task.FromResult(Response(status, html, "text/html")));

        await using var session = new GatewaySession(GatewayAddress.Validated(account.Url), account, store, handler, renewals, () => now);
        var ended = 0;
        session.Ended += () => ended++;

        // 1. Refresh hitting Cloudflare/proxy HTML 400/401/403 must NOT sign out.
        var refreshed = await session.RefreshAsync(initial, CancellationToken.None, force: true);
        Assert.False(refreshed);
        Assert.Equal(0, ended);
        Assert.Equal("rt-1", session.Account.Nous?.RefreshToken);
        Assert.Equal("rt-1", SavedAccounts.FromJson(store.Read()).Find(account.Key)?.Nous?.RefreshToken);

        // 2. MintTicket hitting HTML 401/403 with a fresh token must throw "blocked" (not "session-ended"),
        //    must NOT call EndSession, and must NOT send /auth/native/refresh to the proxy wall.
        if (status is 401 or 403)
        {
            var fresh = Pair(2, now, expiresIn: 800, obtainedAgo: 100);
            var acct2 = SavedNous("https://cloud2.example.com", fresh);
            var store2 = StoreWith(acct2);
            var handler2 = new StubHandler((_, _) => Task.FromResult(Response(status, html, "text/html")));
            await using var session2 = new GatewaySession(GatewayAddress.Validated(acct2.Url), acct2, store2, handler2, new NousRenewals(), () => now);
            var ended2 = 0;
            session2.Ended += () => ended2++;

            var ex = await Assert.ThrowsAsync<GatewayException>(() => session2.MintTicketAsync(TimeSpan.FromSeconds(5), CancellationToken.None));
            Assert.Equal("blocked", ex.Code);
            Assert.Equal(0, ended2);
            Assert.DoesNotContain("/auth/native/refresh", handler2.Paths);
            Assert.Equal("rt-2", SavedAccounts.FromJson(store2.Read()).Find(acct2.Key)?.Nous?.RefreshToken);
        }
    }

    [Theory]
    [InlineData("""{"error":"session_expired","detail":"Refresh token invalid"}""")]
    [InlineData("""{"detail":"Unauthorized"}""")]
    public async Task HermesJson401CallsEndSession(string body)
    {
        var now = DateTimeOffset.UtcNow;
        var initial = Pair(1, now, expiresIn: -10, obtainedAgo: 910);
        var account = SavedNous("https://cloud.example.com", initial);
        var store = StoreWith(account);
        var handler = new StubHandler((_, _) => Task.FromResult(Response(401, body)));

        await using var session = new GatewaySession(GatewayAddress.Validated(account.Url), account, store, handler, new NousRenewals(), () => now);
        var ended = 0;
        session.Ended += () => ended++;

        var ok = await session.RefreshAsync(initial, CancellationToken.None, force: true);
        Assert.False(ok);
        Assert.Equal(1, ended);
        Assert.Null(session.Account.Nous);
        Assert.Null(SavedAccounts.FromJson(store.Read()).Find(account.Key)?.Nous);
    }

    // ------------------------------------------------------------------ 503 refresh_pending

    [Fact]
    public async Task RefreshPendingRetriesAndSucceeds()
    {
        var now = DateTimeOffset.UtcNow;
        var initial = Pair(1, now, expiresIn: -10, obtainedAgo: 910);
        var account = SavedNous("https://cloud.example.com", initial);
        var store = StoreWith(account);
        var attempts = 0;
        var handler = new StubHandler((req, _) =>
        {
            if (req.RequestUri!.AbsolutePath == "/auth/native/refresh")
            {
                var n = Interlocked.Increment(ref attempts);
                if (n <= 2)
                {
                    return Task.FromResult(Response(503,
                        """{"error":"refresh_pending","detail":"still rotating","retry_after":0.02}""",
                        retryAfter: "0.02"));
                }
                return Task.FromResult(Response(200, RefreshBody(2, now)));
            }
            return Task.FromResult(Response(404, """{"detail":"Not Found"}"""));
        });

        await using var session = new GatewaySession(GatewayAddress.Validated(account.Url), account, store, handler, new NousRenewals(), () => now)
        {
            PendingRetryFloor = TimeSpan.FromMilliseconds(15),
        };
        var ended = 0;
        session.Ended += () => ended++;

        var ok = await session.RefreshAsync(initial, CancellationToken.None, force: true);
        Assert.True(ok);
        Assert.Equal(3, attempts);
        Assert.Equal(0, ended);
        Assert.Equal("rt-2", session.Account.Nous?.RefreshToken);
        Assert.Equal("rt-2", SavedAccounts.FromJson(store.Read()).Find(account.Key)?.Nous?.RefreshToken);
    }

    [Fact]
    public async Task RefreshPendingStopsAtPendingMaxAttemptsWithoutSigningOut()
    {
        var now = DateTimeOffset.UtcNow;
        var initial = Pair(1, now, expiresIn: -10, obtainedAgo: 910);
        var account = SavedNous("https://cloud.example.com", initial);
        var store = StoreWith(account);
        var attempts = 0;
        var handler = new StubHandler((_, _) =>
        {
            Interlocked.Increment(ref attempts);
            return Task.FromResult(Response(503, """{"error":"refresh_pending","retry_after":0.01}"""));
        });

        await using var session = new GatewaySession(GatewayAddress.Validated(account.Url), account, store, handler, new NousRenewals(), () => now)
        {
            PendingRetryFloor = TimeSpan.FromMilliseconds(10),
        };
        var ended = 0;
        session.Ended += () => ended++;

        var ok = await session.RefreshAsync(initial, CancellationToken.None, force: true);
        Assert.False(ok);
        Assert.Equal(1 + GatewaySession.PendingMaxAttempts, attempts);
        Assert.Equal(0, ended);
        Assert.Equal("rt-1", session.Account.Nous?.RefreshToken);
    }

    // ------------------------------------------------------------------ Process-wide NousRenewals chain & single-flight

    [Fact]
    public async Task ProcessWideRenewalsWalkPastSixteenHopsAndDeduplicateCrossInstanceFlights()
    {
        var now = DateTimeOffset.UtcNow;
        var launchPair = Pair(0, now, expiresIn: 900, obtainedAgo: 0);
        var launchStored = SavedNous("https://cloud.example.com", launchPair);
        var store = StoreWith(launchStored);
        var renewals = new NousRenewals();

        var gate = new object();
        var current = 0;
        var expiredStep = 0;
        var spent = new HashSet<string>(StringComparer.Ordinal);
        var posted = new List<string>();
        var revoked = false;

        HttpMessageHandler MakeHandler() => new StubHandler(async (req, ct) =>
        {
            var path = req.RequestUri!.AbsolutePath;
            if (path == "/auth/native/refresh")
            {
                var body = await req.Content!.ReadAsStringAsync(ct);
                var rt = J.Parse(body).Str("refresh_token") ?? "";
                lock (gate)
                {
                    posted.Add(rt);
                    if (revoked || spent.Contains(rt) || rt != $"rt-{current}")
                    {
                        revoked = true;
                        return Response(401, """{"error":"session_expired","detail":"reused"}""");
                    }
                    spent.Add(rt);
                    current++;
                    return Response(200, RefreshBody(current, now));
                }
            }
            if (path == "/api/sessions/s1")
            {
                var auth = req.Headers.Authorization?.ToString() ?? "";
                lock (gate)
                {
                    if (auth == $"Bearer at-{current}" && current == expiredStep && current < 25)
                        return Response(401, """{"error":"session_expired","detail":"expired"}""");
                    if (auth != $"Bearer at-{current}")
                        return Response(401, """{"error":"session_expired","detail":"unauthorized"}""");
                    return Response(200, """{"id":"s1","last_active":100,"message_count":2}""");
                }
            }
            return Response(404, """{"detail":"Not Found"}""");
        });

        // 25 sequential sessions all created from the stale launch-time snapshot (`rt-0`) walk past the former 16-hop cap.
        for (var step = 1; step <= 25; step++)
        {
            lock (gate) expiredStep = step - 1;
            await using var s = new GatewaySession(GatewayAddress.Validated(launchStored.Url), launchStored, store, MakeHandler(), renewals, () => now);
            var answer = await s.SendAsync(HttpMethod.Get, "/api/sessions/s1");
            Assert.True(answer.Ok, $"step {step} failed with {answer.Status}");
            Assert.Equal($"rt-{step}", SavedAccounts.FromJson(store.Read()).Find(launchStored.Key)?.Nous?.RefreshToken);
        }

        // 26th session created from stale `rt-0` adopts fresh `rt-25` in-process and sends zero refresh POSTs.
        await using (var s26 = new GatewaySession(GatewayAddress.Validated(launchStored.Url), launchStored, store, MakeHandler(), renewals, () => now))
        {
            var answer = await s26.SendAsync(HttpMethod.Get, "/api/sessions/s1");
            Assert.True(answer.Ok);
        }

        Assert.False(revoked);
        Assert.Equal(Enumerable.Range(0, 25).Select(i => $"rt-{i}"), posted);

        // Cross-instance concurrent single-flight + FlightKey isolation (H9).
        var singleFlightRenewals = new NousRenewals();
        var oldPair = Pair(0, now, expiresIn: -10, obtainedAgo: 910);
        var freshSignInPair = Pair(100, now, expiresIn: -10, obtainedAgo: 910);
        var oldAcct = SavedNous("https://single.example.com", oldPair);
        var freshAcct = SavedNous("https://single.example.com", freshSignInPair);
        var sfStore = StoreWith(oldAcct);

        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var oldPosts = 0;
        var freshPosts = 0;

        HttpMessageHandler SfHandler() => new StubHandler(async (req, ct) =>
        {
            var body = await req.Content!.ReadAsStringAsync(ct);
            var rt = J.Parse(body).Str("refresh_token");
            if (rt == "rt-0")
            {
                Interlocked.Increment(ref oldPosts);
                entered.TrySetResult();
                await release.Task.WaitAsync(ct);
                return Response(200, RefreshBody(1, now));
            }
            if (rt == "rt-100")
            {
                Interlocked.Increment(ref freshPosts);
                return Response(200, RefreshBody(101, now));
            }
            return Response(401, """{"error":"session_expired"}""");
        });

        await using var instA = new GatewaySession(GatewayAddress.Validated(oldAcct.Url), oldAcct, sfStore, SfHandler(), singleFlightRenewals, () => now);
        await using var instB = new GatewaySession(GatewayAddress.Validated(oldAcct.Url), oldAcct, sfStore, SfHandler(), singleFlightRenewals, () => now);
        await using var instFresh = new GatewaySession(GatewayAddress.Validated(freshAcct.Url), freshAcct, sfStore, SfHandler(), singleFlightRenewals, () => now);

        var tA = instA.RefreshAsync(oldPair, CancellationToken.None, force: true);
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var tB = instB.RefreshAsync(oldPair, CancellationToken.None, force: true);

        // Fresh sign-in replaces the stored pair on disk while rt-0's flight is still in progress (H9):
        // different refresh token on the SAME accountKey must NOT join rt-0's slow flight.
        instFresh.Save();
        Assert.True(await instFresh.RefreshAsync(freshSignInPair, CancellationToken.None, force: true));
        Assert.Equal("rt-101", instFresh.Account.Nous?.RefreshToken);
        Assert.Equal(1, freshPosts);

        release.SetResult();
        Assert.True(await tA);
        Assert.True(await tB);
        Assert.Equal(1, oldPosts);
        Assert.Equal("rt-1", instA.Account.Nous?.RefreshToken);
        Assert.Equal("rt-1", instB.Account.Nous?.RefreshToken);
    }

    [Fact]
    public async Task RenewalsCycleGuardNeverInfiniteLoops()
    {
        var now = DateTimeOffset.UtcNow;
        var renewals = new NousRenewals();
        var p0 = Pair(0, now, expiresIn: -10, obtainedAgo: 910);
        // Misbehaving server echoes rt-0 back as its own successor.
        _ = await renewals.RenewAsync("k", p0, _ => Task.FromResult<NousRenewals.Outcome>(new NousRenewals.Outcome.Tokens(p0)), (_, _) => true, () => now);
        var latest = renewals.Latest(p0);
        Assert.Equal("rt-0", latest.RefreshToken);
        Assert.True(renewals.IsSpent(p0));
    }

    // ------------------------------------------------------------------ H10: Expired rotated token

    [Fact]
    public async Task H10ExpiredRotatedTokenTriggersFreshRenewalInsteadOfReturningStale()
    {
        var now = DateTimeOffset.UtcNow;
        var staleSent = Pair(0, now, expiresIn: -900, obtainedAgo: 1800);
        var expiredRotated = Pair(1, now, expiresIn: -30, obtainedAgo: 930);
        var account = SavedNous("https://h10.example.com", expiredRotated);
        var store = StoreWith(account);

        var postedTokens = new List<string>();
        var handler = new StubHandler(async (req, ct) =>
        {
            if (req.RequestUri!.AbsolutePath == "/auth/native/refresh")
            {
                var body = await req.Content!.ReadAsStringAsync(ct);
                postedTokens.Add(J.Parse(body).Str("refresh_token") ?? "");
                return Response(200, RefreshBody(2, now, expiresIn: 900));
            }
            return Response(404, """{"detail":"Not Found"}""");
        });

        await using var session = new GatewaySession(GatewayAddress.Validated(account.Url), account, store, handler, new NousRenewals(), () => now);

        // Account.Nous holds rt-1 (different from sent rt-0), but rt-1 is ALREADY expired -> must renew rt-1 -> rt-2!
        var ok = await session.RefreshAsync(staleSent, CancellationToken.None);
        Assert.True(ok);
        Assert.Equal(["rt-1"], postedTokens);
        Assert.Equal("at-2", session.Account.Nous?.AccessToken);
        Assert.Equal("rt-2", session.Account.Nous?.RefreshToken);

        // Now Account.Nous holds fresh rt-2 (expiresIn: +900): calling RefreshAsync with older sent rt-1 must NOT POST again.
        var okFresh = await session.RefreshAsync(expiredRotated, CancellationToken.None);
        Assert.True(okFresh);
        Assert.Single(postedTokens);
    }

    // ------------------------------------------------------------------ SettleRenewalAsync & priorUnsaved CAS

    [Fact]
    public async Task SettleRenewalWaitsForInFlightRenewalAndShortDeadlineDoesNotCancelIt()
    {
        var now = DateTimeOffset.UtcNow;
        // 300 s of 900 s left -> triggers alongside renewal on GET /api/sessions/s1.
        var initial = Pair(1, now, expiresIn: 300, obtainedAgo: 600);
        var account = SavedNous("https://settle.example.com", initial);
        var store = StoreWith(account);
        var refreshStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseRefresh = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        var handler = new StubHandler(async (req, ct) =>
        {
            if (req.RequestUri!.AbsolutePath == "/api/sessions/s1")
                return Response(200, """{"id":"s1","last_active":100,"message_count":1}""");
            if (req.RequestUri!.AbsolutePath == "/auth/native/refresh")
            {
                refreshStarted.TrySetResult();
                await releaseRefresh.Task.WaitAsync(ct);
                return Response(200, RefreshBody(2, now));
            }
            return Response(404, """{"detail":"Not Found"}""");
        });

        await using var session = new GatewaySession(GatewayAddress.Validated(account.Url), account, store, handler, new NousRenewals(), () => now);
        var res = await session.SendAsync(HttpMethod.Get, "/api/sessions/s1");
        Assert.True(res.Ok);
        await refreshStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));

        // 1. Short deadline returns promptly WITHOUT cancelling the underlying refresh POST (M1).
        var sw = System.Diagnostics.Stopwatch.StartNew();
        await session.SettleRenewalAsync(TimeSpan.FromMilliseconds(40));
        sw.Stop();
        Assert.True(sw.Elapsed < TimeSpan.FromMilliseconds(500), $"SettleRenewalAsync waited {sw.Elapsed}");

        // 2. Full SettleRenewalAsync waits until the in-flight renewal finishes and persists rt-2.
        var settleTask = session.SettleRenewalAsync(TimeSpan.FromSeconds(5));
        Assert.False(settleTask.IsCompleted);
        releaseRefresh.SetResult();
        await settleTask.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal("rt-2", SavedAccounts.FromJson(store.Read()).Find(account.Key)?.Nous?.RefreshToken);
    }

    [Fact]
    public async Task SessionParkedReaderDisposeAsyncSettlesInFlightRenewalBeforeDisposingTransport()
    {
        var now = DateTimeOffset.UtcNow;
        var initial = Pair(1, now, expiresIn: 300, obtainedAgo: 600);
        var account = SavedNous("https://parked.example.com", initial);
        var store = StoreWith(account);
        var refreshAttempts = 0;

        var handler = new StubHandler(async (req, ct) =>
        {
            if (req.RequestUri!.AbsolutePath == "/api/sessions/s1")
                return Response(200, """{"id":"s1","last_active":100,"message_count":1}""");
            if (req.RequestUri!.AbsolutePath == "/auth/native/refresh")
            {
                var n = Interlocked.Increment(ref refreshAttempts);
                if (n == 1)
                    return Response(503, """{"error":"refresh_pending","retry_after":0.02}""");
                await Task.Delay(25, ct);
                return Response(200, RefreshBody(2, now));
            }
            return Response(404, """{"detail":"Not Found"}""");
        });

        var session = new GatewaySession(GatewayAddress.Validated(account.Url), account, store, handler, new NousRenewals(), () => now)
        {
            PendingRetryFloor = TimeSpan.FromMilliseconds(15),
        };
        await using (var reader = new SessionParkedReader(session))
        {
            var answer = await reader.ReadAsync("s1", null, CancellationToken.None);
            Assert.IsType<ParkedAnswer.Session>(answer);
        }
        // After SessionParkedReader.DisposeAsync(), the alongside refresh + 503 refresh_pending retry has persisted rt-2.
        Assert.Equal(2, refreshAttempts);
        Assert.Equal("rt-2", SavedAccounts.FromJson(store.Read()).Find(account.Key)?.Nous?.RefreshToken);
    }

    [Fact]
    public async Task HermesClientDisposeAsyncAwaitsInFlightRenewalBeforeClosingTransport()
    {
        var now = DateTimeOffset.UtcNow;
        // 300 s of 900 s left -> triggers alongside renewal when RpcConnection requests /api/auth/ws-ticket.
        var initial = Pair(1, now, expiresIn: 300, obtainedAgo: 600);
        var account = SavedNous("https://client-settle.example.com", initial);
        var store = StoreWith(account);
        var refreshStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseRefresh = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        var handler = new StubHandler(async (req, ct) =>
        {
            if (req.RequestUri!.AbsolutePath == "/api/auth/ws-ticket")
                return Response(503, """{"detail":"restarting"}""");
            if (req.RequestUri!.AbsolutePath == "/auth/native/refresh")
            {
                refreshStarted.TrySetResult();
                await releaseRefresh.Task.WaitAsync(ct);
                return Response(200, RefreshBody(2, now));
            }
            return Response(404, """{"detail":"Not Found"}""");
        });

        var session = new GatewaySession(GatewayAddress.Validated(account.Url), account, store, handler, new NousRenewals(), () => now);
        var client = new HermesClient(session);

        await refreshStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var disposeTask = client.DisposeAsync().AsTask();
        await Task.Delay(50);
        Assert.False(disposeTask.IsCompleted);

        releaseRefresh.SetResult();
        await disposeTask.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal("rt-2", SavedAccounts.FromJson(store.Read()).Find(account.Key)?.Nous?.RefreshToken);
    }

    [Fact]
    public async Task MultipleUnsavedRotationsPreservePriorUnsavedCasBaseline()
    {
        var now = DateTimeOffset.UtcNow;
        var p0 = Pair(0, now, expiresIn: -10, obtainedAgo: 910);
        var p1 = Pair(1, now, expiresIn: -10, obtainedAgo: 910);
        var p2 = Pair(2, now, expiresIn: 900, obtainedAgo: 0);
        var account = SavedNous("https://unsaved.example.com", p0);
        var store = new FlakyTokenStore();
        var saved = new SavedAccounts();
        saved.Upsert(account);
        store.Write(saved.ToJson());

        var nextPair = 1;
        var handler = new StubHandler((_, _) =>
        {
            var pair = nextPair++ == 1 ? p1 : p2;
            return Task.FromResult(Response(200, new JsonObject
            {
                ["access_token"] = pair.AccessToken,
                ["refresh_token"] = pair.RefreshToken,
                ["user_id"] = pair.UserId,
                ["provider"] = "nous",
                ["expires_at"] = pair.ExpiresAt,
            }.ToJsonString()));
        });

        var renewals = new NousRenewals();
        await using var session = new GatewaySession(GatewayAddress.Validated(account.Url), account, store, handler, renewals, () => now);

        // Two consecutive rotations while ITokenStore refuses writes.
        store.RefuseWrites = true;
        Assert.True(await session.RefreshAsync(p0, CancellationToken.None, force: true));
        Assert.True(await session.RefreshAsync(p1, CancellationToken.None, force: true));
        Assert.Equal("rt-0", SavedAccounts.FromJson(store.PeekRaw()).Find(account.Key)?.Nous?.RefreshToken);

        // Store unlocks: RetryUnsaved must CAS against original rt-0 baseline and persist rt-2!
        store.RefuseWrites = false;
        renewals.RetryUnsaved();
        Assert.Equal("rt-2", SavedAccounts.FromJson(store.Read()).Find(account.Key)?.Nous?.RefreshToken);
    }

    // ------------------------------------------------------------------ NousSessionKeepAlive 4h cadence & GatewayHub sweep

    [Fact]
    public void NousSessionKeepAliveRefreshDueFollowsFourHourCadence()
    {
        Assert.Equal(TimeSpan.FromHours(4), NousSessionKeepAlive.DefaultInterval);

        var now = new DateTimeOffset(2026, 11, 28, 12, 0, 0, TimeSpan.Zero);
        var fresh = Pair(1, now, expiresIn: 900, obtainedAgo: TimeSpan.FromHours(3.9).TotalSeconds);
        var atFourHours = Pair(2, now, expiresIn: -13500, obtainedAgo: TimeSpan.FromHours(4).TotalSeconds);
        var idleFiveHours = Pair(3, now, expiresIn: -17100, obtainedAgo: TimeSpan.FromHours(5).TotalSeconds);
        var noRefreshToken = new NousTokens("at", "", now.ToUnixTimeSeconds() - 100, "u1", now.AddHours(-6).ToUnixTimeSeconds());
        var noObtainedExpired = new NousTokens("at", "rt", now.AddSeconds(-1).ToUnixTimeSeconds(), "u1", null);
        var noObtainedValid = new NousTokens("at", "rt", now.AddSeconds(600).ToUnixTimeSeconds(), "u1", null);

        Assert.False(NousSessionKeepAlive.RefreshDue(fresh, now: now));
        Assert.True(NousSessionKeepAlive.RefreshDue(atFourHours, now: now));
        Assert.True(NousSessionKeepAlive.RefreshDue(idleFiveHours, now: now));
        Assert.False(NousSessionKeepAlive.RefreshDue(noRefreshToken, now: now));
        Assert.True(NousSessionKeepAlive.RefreshDue(noObtainedExpired, now: now));
        Assert.False(NousSessionKeepAlive.RefreshDue(noObtainedValid, now: now));
    }

    [Fact]
    public async Task GatewayHubKeepAliveSweepCoversSingleGatewayAndZeroChatParkedNousAccounts()
    {
        var now = DateTimeOffset.UtcNow;

        // 1. Single saved Nous gateway (IsShown == false), idle >= 5 h -> CheckAsync still rotates it.
        var singleIdle = SavedNous("https://only.example.com", Pair(1, now, expiresIn: -14000, obtainedAgo: 5 * 3600));
        var singleStore = StoreWith(singleIdle);
        var singleRenewals = new NousRenewals();
        var singleRefreshes = 0;
        var singleHub = new GatewayHub(singleStore, new MemoryParkedRosters(),
            makeReader: a =>
            {
                var h = new StubHandler((_, _) =>
                {
                    Interlocked.Increment(ref singleRefreshes);
                    return Task.FromResult(Response(200, RefreshBody(2, now)));
                });
                return new SessionParkedReader(new GatewaySession(GatewayAddress.Validated(a.Url), a, singleStore, h, singleRenewals, () => now));
            },
            renewals: singleRenewals)
        {
            CurrentKey = singleIdle.Key,
            Now = () => now,
        };

        Assert.False(singleHub.IsShown);
        await singleHub.CheckAsync(force: false);
        Assert.Equal(1, singleRefreshes);
        Assert.Equal("rt-2", SavedAccounts.FromJson(singleStore.Read()).Find(singleIdle.Key)?.Nous?.RefreshToken);

        // 2. Parked Nous gateway with 0 parked chats + idle >= 5 h, alongside an active password gateway -> rotated by CheckAsync.
        var currentPw = new StoredAccount("https://main.example.com", "qa", [new SavedCookie("sid", "v1", "main.example.com", "/", null, true)]);
        var parkedNous = SavedNous("https://parked-nous.example.com", Pair(10, now, expiresIn: -14000, obtainedAgo: 5 * 3600));
        var multiStore = StoreWith(currentPw, parkedNous);
        var multiRenewals = new NousRenewals();
        var parkedRefreshes = 0;
        var multiHub = new GatewayHub(multiStore, new MemoryParkedRosters(),
            makeReader: a =>
            {
                var h = new StubHandler((_, _) =>
                {
                    Interlocked.Increment(ref parkedRefreshes);
                    return Task.FromResult(Response(200, RefreshBody(11, now)));
                });
                return new SessionParkedReader(new GatewaySession(GatewayAddress.Validated(a.Url), a, multiStore, h, multiRenewals, () => now));
            },
            renewals: multiRenewals)
        {
            CurrentKey = currentPw.Key,
            Now = () => now,
        };

        await multiHub.CheckAsync(force: false);
        Assert.Equal(1, parkedRefreshes);
        Assert.Equal("rt-11", SavedAccounts.FromJson(multiStore.Read()).Find(parkedNous.Key)?.Nous?.RefreshToken);
        Assert.True(multiHub.HasUsableSession(parkedNous));
    }

    [Fact]
    public async Task NousSessionKeepAliveRefreshDueAsyncRenewsIdleAndSkipsFreshOrLocked()
    {
        var now = DateTimeOffset.UtcNow;
        var idle = SavedNous("https://idle.example.com", Pair(1, now, expiresIn: -14000, obtainedAgo: 5 * 3600, user: "u1"), user: "u1");
        var fresh = SavedNous("https://fresh.example.com", Pair(10, now, expiresIn: 600, obtainedAgo: 300, user: "u2"), user: "u2");

        var store = new FlakyTokenStore();
        var saved = new SavedAccounts();
        saved.Upsert(fresh);
        saved.Upsert(idle);
        store.Write(saved.ToJson());

        var renewals = new NousRenewals();
        var refreshes = 0;

        GatewaySession MakeSession(StoredAccount a)
        {
            var h = new StubHandler((_, _) =>
            {
                Interlocked.Increment(ref refreshes);
                return Task.FromResult(Response(200, RefreshBody(2, now, user: "u1")));
            });
            return new GatewaySession(GatewayAddress.Validated(a.Url), a, store, h, renewals, () => now);
        }

        // Locked store: touches nothing.
        store.RefuseReads = true;
        Assert.Equal(0, await NousSessionKeepAlive.RefreshDueAsync(store, now: () => now, renewals: renewals, makeSession: MakeSession));
        Assert.Equal(0, refreshes);

        // Unlocked: only the 5 h idle account refreshes; 5 min fresh account is untouched.
        store.RefuseReads = false;
        Assert.Equal(1, await NousSessionKeepAlive.RefreshDueAsync(store, now: () => now, renewals: renewals, makeSession: MakeSession));
        Assert.Equal(1, refreshes);
        Assert.Equal("rt-2", SavedAccounts.FromJson(store.Read()).Find(idle.Key)?.Nous?.RefreshToken);
        Assert.Equal("rt-10", SavedAccounts.FromJson(store.Read()).Find(fresh.Key)?.Nous?.RefreshToken);
    }
}
