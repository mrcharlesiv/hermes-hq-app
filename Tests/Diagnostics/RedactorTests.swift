import Foundation
import Testing
@testable import HermesHQNative

/// Every vector of the web app's `src/diagnostics-redact.test.ts` that exercises the redactor itself
/// (docs/spec/3x-diagnostics.md §5, acceptance D8).
@Suite struct RedactorTests {
    static let fixture = "FAKE-private-value"

    static var planted: [(String, String)] {
        let fixture = Self.fixture
        var out: [(String, String)] = []
        let keys = ["password", "passwd", "pwd", "passphrase", "secret", "client_secret", "token", "access_token", "refresh_token",
                    "id_token", "auth_token", "api_key", "apiKey", "api-key", "x-api-key", "private_key", "credential", "credentials",
                    "signature", "sig", "ticket", "otp", "hermes_session", "session", "sessionid", "sid", "Authorization",
                    "Proxy-Authorization", "Cookie", "Set-Cookie"]
        for key in keys {
            out += [("\(key)=\(fixture)", fixture), ("\(key): \(fixture)", fixture), ("\"\(key)\":\"\(fixture)\"", fixture),
                    ("'\(key)': '\(fixture)'", fixture), ("\(key)=\"\(fixture) with spaces\"", "\(fixture) with spaces"),
                    ("\"\(key)\":\n\"\(fixture)\"", fixture)]
        }
        for header in ["Authorization", "Proxy-Authorization", "Cookie", "Set-Cookie"] {
            out.append(("\(header): first=\(fixture); second=FAKE-cookie-two", fixture))
        }
        for scheme in ["Bearer", "Basic", "Token"] { out.append(("Error: \(scheme) \(fixture)", fixture)) }
        for scheme in ["https", "http", "wss", "ws", "capacitor", "custom+app"] {
            out.append(("\(scheme)://gateway.example:9119/api/ws?ticket=\(fixture)&search=FAKE-search#FAKE-fragment", fixture))
            out.append(("\(scheme)://user:\(fixture)@gateway.example/api", fixture))
            out.append(("\(scheme)://\(fixture)@gateway.example/api", fixture))
        }
        out.append(("prefix_FAKE0123456789abcdef012345_suffix", "FAKE0123456789abcdef012345"))
        out.append(("/api/fs/download?path=/Users/x/Private.pdf&profile=inbox", "/Users/x/Private.pdf"))
        out.append(("https://gateway.example/api#FAKE-fragment", "FAKE-fragment"))
        let suffix = "FAKE0123456789abcdefFAKE0123456789abcdef"
        for prefix in ["sk-", "sk-ant-", "sk_live_", "sk_test_", "rk_live_", "rk_test_", "xai-", "gsk_", "pplx-", "r8_", "hf_", "ghp_",
                       "gho_", "ghu_", "ghs_", "ghr_", "github_pat_", "glpat-", "xoxa-", "xoxb-", "xoxp-", "xoxr-", "xoxs-"] {
            out.append(("Failed with \(prefix + suffix)", prefix + suffix))
        }
        for value in ["AIza" + "FAKE0123456789abcdefFAKE0123456789abc", "AKIAFAKE0123456789AB", "ASIAFAKE0123456789AB",
                      "eyJhbGciOiJGQUtFIn0.eyJzdWIiOiJGQUtFIn0.FAKEsignature", "AbCdEfGhIjKlMnOpQrStUv12",
                      "abcdefabcdefabcdefabcdefabcdefab", "12345678901234567890123456789012", "12345678-abcd-4abc-8abc-123456789abc"] {
            out.append(("Error: \(value)", value))
        }
        for type in ["", "RSA ", "EC ", "ENCRYPTED "] {
            out.append(("-----BEGIN \(type)PRIVATE KEY-----\nFAKE-PRIVATE-MATERIAL\n-----END \(type)PRIVATE KEY-----", "FAKE-PRIVATE-MATERIAL"))
        }
        let chat = String(repeating: "This is made-up private chat text. ", count: 4)
        for (open, close) in [("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}"), ("\u{2018}", "\u{2019}"), ("`", "`")] {
            out.append(("Error: echoed \(open)\(chat)\(close)", chat))
        }
        for key in ["text", "content", "body", "prompt", "transcript", "delta", "input", "output", "arguments"] {
            out.append(("{\"\(key)\":\"FAKE chat \\\"quoted\\\" text\"}", "FAKE chat"))
            out.append(("{'\(key)':'FAKE short chat'}", "FAKE short chat"))
        }
        return out
    }

    static let safe = [
        "Error: Your gateway took too long to answer. It may be busy — try again. [timeout, NSURLErrorDomain -1001]",
        "Error: Gateway connection failed (code -1001). The request timed out.",
        "TypeError: undefined is not an object (evaluating 'state.sessions.find')",
        "Gateway HTTP 404: Session not found", "Error: Load failed", "Address: 100.101.102.103:9119",
        "https://gateway.example.ts.net:9119/api/sessions", "2026-09-27T04:03:00.000Z",
        "socket.handshake", "auth.restore", "native.loaded", "Connected in 360 ms", "Failed: no connection ticket after 8.0 s",
        "Voice is paused (interrupted)", "Audio session unavailable (iOS error 561017449)",
        "NotAllowedError: The request is not allowed by the user agent or the platform in the current context",
    ]

    private func redact(_ text: String) -> String { DiagnosticRedactor.redact(text) }

    @Test func removesEveryPlantedValue() {
        #expect(Self.planted.count > 250)
        for (input, secret) in Self.planted {
            let output = redact(input)
            #expect(!output.contains(secret), "\(input) → \(output)")
            #expect(output.contains("[redacted]"), "\(input) → \(output)")
            #expect(redact(output) == output, "not idempotent: \(input) → \(output) → \(redact(output))")
        }
    }

    @Test func preservesUsefulContext() {
        for input in Self.safe { #expect(redact(input) == input) }
    }

    @Test func idempotentWhenOverlappingRulesMakeAQuotedRunLonger() {
        let input = "'\(String(repeating: "x", count: 61))\"content\":\"a\"'"
        let output = redact(input)
        #expect(output == "'[redacted]'")
        #expect(redact(output) == output)
    }

    @Test func removesEveryCookiePairAndWholeQueryAndFragment() {
        #expect(redact("Cookie: first=FAKE-one; second=FAKE-two") == "Cookie: [redacted]")
        #expect(redact("Set-Cookie: first=FAKE-one; Path=/; HttpOnly") == "Set-Cookie: [redacted]")
        #expect(redact("https://user:FAKE-pass@host:9119/path?q=FAKE-query#FAKE-hash") == "https://[redacted]@host:9119/path?[redacted]")
        #expect(redact("/api/fs/download?path=/Users/x/Private.pdf&profile=inbox") == "/api/fs/download?[redacted]")
    }

    @Test func keepsWordsThatOnlyLookLikeASchemeOrKeyName() {
        for input in ["Error: Token expired", "Basic auth is not enabled on this gateway", "Token refresh failed; sign in again",
                      "Did you mean /help?", "Session setup [native session]: 12 ms", "Connection ticket [native socket.ticket]: 260 ms",
                      "max_tokens: 4096"] {
            #expect(redact(input) == input)
        }
        let fixture = Self.fixture
        for input in ["db_password=\(fixture)", "userPassword: \(fixture)", "refreshToken=\(fixture)", "ws_ticket=\(fixture)",
                      "{\\\"password\\\":\\\"\(fixture)\\\"}", "{\\\"text\\\":\\\"\(fixture) chat\\\"}", "Basic dXNlcjpGQUtFMTIz",
                      "Token FAKEabcdefGHIJKL"] {
            let output = redact(input)
            #expect(!output.contains("FAKE") && !output.contains("dXNlcjpGQUtFMTIz"), "\(input) → \(output)")
        }
        #expect(redact("{\\\"password\\\":\\\"\(fixture)\\\"}") == "{\\\"password\\\":[redacted]}")
    }

    @Test func staysFastOnPathologicalTextAndCutsLongTextFirst() throws {
        let size = 64 * 1024
        let rows = (0..<3000).map { ["id": $0, "body": "x\($0)"] as [String: Any] }
        let inner = String(decoding: try JSONSerialization.data(withJSONObject: rows), as: UTF8.self)
        let twice = String(decoding: try JSONSerialization.data(withJSONObject: [inner]), as: UTF8.self)
        let texts = [String(repeating: "-/", count: size / 2), String(repeating: "a-", count: size / 2),
                     String(repeating: "-eyJ", count: size / 4), String(repeating: "\u{201C}", count: size),
                     String(repeating: "'\\'", count: size / 3), twice,
                     String(repeating: "\u{201C}", count: 65535) + "\"", String(repeating: "\"", count: 65535),
                     String(repeating: "\u{2018}\u{201C}", count: 32767) + "`"]
        for text in texts {
            let started = Date()
            _ = redact(text)
            #expect(Date().timeIntervalSince(started) < 0.75, "slow on \(text.prefix(8))")
        }
        #expect(redact("Error: echoed \"" + String(repeating: "private chat ", count: 10_000)) == "Error: echoed \"[redacted]")
        #expect(redact("JSON Parse error: Unexpected token in \"" + String(repeating: "private chat ", count: 8)) == "JSON Parse error: Unexpected token in \"[redacted]")
        let apostrophe = "Error: Couldn't reach the gateway. Check that it is running, that Tailscale is on, and that the address is right."
        #expect(redact(apostrophe) == apostrophe)
    }

    @Test func masksACredentialWhoseQuoteWasNeverClosed() {
        for input in ["Error: password=\"hunter2", "{\"password\":\"hunter2", "token='abc123xyz", "Error: secret=\u{201C}FAKE value",
                      "{\\\"token\\\":\\\"FAKEabc"] {
            let output = redact(input)
            #expect(!output.contains("hunter2") && !output.contains("abc123xyz") && !output.contains("FAKE"), "\(input) → \(output)")
        }
    }

    @Test func masksChatInsideAContentArrayOrObject() {
        for input in ["{\"content\":[\"My private chat\"]}", "{\"arguments\":{\"query\":\"My private search\"}}",
                      "{\"content\":[{\"type\":\"text\",\"text\":\"hello ] there\"}],\"status\":\"ok\"}", "{\"input\":[\"cut off"] {
            let output = redact(input)
            #expect(!output.contains("private") && !output.contains("hello") && !output.contains("cut off"), "\(input) → \(output)")
        }
        #expect(redact("{\"content\":[\"My private chat\"],\"status\":\"error\"}") == "{\"content\":[redacted],\"status\":\"error\"}")
        #expect(redact("{\"content\":[redacted]}") == "{\"content\":[redacted]}")
    }

    @Test func findsAnOpenQuote() {
        #expect(redact("Error: \u{201C}" + String(repeating: "x", count: 100)) == "Error: \u{201C}[redacted]")
        #expect(redact("Error: \u{201C}quoted\u{201D} then \u{201C}" + String(repeating: "x", count: 100)) == "Error: \u{201C}quoted\u{201D} then \u{201C}[redacted]")
        #expect(redact("Error: \u{201C}" + String(repeating: "x", count: 10)) == "Error: \u{201C}" + String(repeating: "x", count: 10))
    }

    /// The planted error of acceptance check D7.
    @Test func plantedTicketAndBearer() {
        let output = redact("POST https://x.example/a?ticket=abc123DEF456ghi789JKL012 Authorization: Bearer sk-live-0123456789abcdef")
        #expect(output == "POST https://x.example/a?[redacted] Authorization: [redacted]")
    }
}
