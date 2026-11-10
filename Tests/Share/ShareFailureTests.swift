// [share] docs/spec/3x-share.md §7.8 check 1: every sentence the sheet can show, character for character.

import Foundation
import Testing
@testable import HermesHQNative

@Suite struct ShareFailureTests {
    @Test func sentences() {
        let table: [(ShareFailure, String)] = [
            (.signedOut, "Open Hermes HQ and sign in to your gateway, then share again."),
            (.locked, "Unlock your iPhone to share."),
            (.keychain(-25291), "Hermes HQ couldn’t read your sign-in. Open Hermes HQ, then share again."),
            (.needsApp, "Open Hermes HQ once to finish updating, then share again."),
            (.noRoster, "Open Hermes HQ once so your bots appear here, then share again."),
            (.otherAccount, "Hermes HQ switched gateways. Open Hermes HQ so your bots appear here, then share again."),
            (.sessionEnded, "Your gateway ended this iPhone’s session. Open Hermes HQ to sign in again."),
            (.tailscaleOff, "Turn on Tailscale to reach the computer running Hermes."),
            (.timedOut, "Your gateway took too long to answer. It may be busy — try again."),
            (.gateway(429), "Your gateway is busy. Try again in a minute."),
            (.gateway(500), "Your gateway had a problem with this share. Try again in a minute."), // no HTTP status (D8 amendment)
            (.gateway(302), "Your gateway had a problem with this share. Try again in a minute."),
            (.noChat, "Open this bot in Hermes HQ once, then share to it."),
            (.tooLarge("big.bin"), "“big.bin” is larger than your attachment limit."),
            (.unreadable("broken.mov"), "Hermes HQ couldn’t read “broken.mov”."),
            (.nothingToSend, "There’s nothing to send."),
            (.refused(""), "Your gateway didn’t accept this share."),
            (.refused("Share at most 10 photos and 10 files at a time."), "Share at most 10 photos and 10 files at a time."),
            (.unconfirmed, "Hermes HQ couldn’t confirm the share arrived. Check the chat before sending again."),
            (.cancelled, "Sending was cancelled."),
        ]
        for (failure, sentence) in table { #expect(failure.message == sentence, "\(failure.name)") }
    }

    @Test func transportSentences() {
        let reach = "Can’t reach the computer running Hermes. Check that you’re online and that Tailscale or your VPN is on, then try again."
        let table: [(Int, String)] = [
            (-1001, "Your gateway took too long to answer. It may be busy — try again."),
            (-1003, reach), (-1004, reach), (-1005, reach), (-1009, reach),
            (-999, "The connection changed before your gateway answered. Try again."),
            (-1200, "This device doesn’t trust your gateway’s HTTPS certificate."),
            (-1202, "This device doesn’t trust your gateway’s HTTPS certificate."),
            (-1206, "This device doesn’t trust your gateway’s HTTPS certificate."),
            (-1022, "This gateway address needs https://."),
            (-1006, "Can’t reach the computer running Hermes right now. Try again."),
            (-1018, "Can’t reach the computer running Hermes right now. Try again."),
            (-1020, "Can’t reach the computer running Hermes right now. Try again."),
            (-1011, "Your gateway couldn’t complete that request. Try again."),
            (-1017, "Your gateway couldn’t complete that request. Try again."),
        ]
        for (code, sentence) in table {
            #expect(ShareFailure.transport(NSURLErrorDomain, code).message == sentence, "\(code)")
            #expect(ShareReach.failureMessage(domain: NSURLErrorDomain, code: code) == sentence, "\(code)")
            #expect(!sentence.contains(String(code)))               // the number never goes in the sentence
        }
        #expect(ShareFailure.transport(NSPOSIXErrorDomain, 57).message == "Your gateway couldn’t complete that request. Try again.")
        #expect(ShareFailure.transport("kCFErrorDomainCFNetwork", 2).message == "Your gateway couldn’t complete that request. Try again.")
    }

    @Test func errorsBecomeFailures() async {
        // A connection the SYSTEM dropped (-999 with nobody having pressed Cancel) is a transport failure with its own
        // sentence and Try Again, never a silent return to the ready sheet…
        let dropped = ShareFailure.transport(URLError(.cancelled))
        #expect(dropped == .transport(NSURLErrorDomain, NSURLErrorCancelled))
        #expect(dropped.message == "The connection changed before your gateway answered. Try again.")
        #expect(dropped.retryable && !dropped.blocksSheet)
        // …and the same error inside a share the person cancelled is their Cancel.
        let cancelled = await Task.detached { () -> ShareFailure in
            withUnsafeCurrentTask { $0?.cancel() }
            return ShareFailure.transport(URLError(.cancelled))
        }.value
        #expect(cancelled == .cancelled)
        #expect(ShareFailure.transport(CancellationError()) == .cancelled)
        #expect(ShareFailure.transport(ShareFailure.cancelled) == .cancelled)             // the socket's own record of Cancel
        #expect(ShareFailure.transport(URLError(.timedOut)) == .timedOut)
        #expect(ShareFailure.transport(URLError(.cannotConnectToHost)) == .transport(NSURLErrorDomain, -1004))
        #expect(ShareFailure.transport(URLError(.networkConnectionLost)) == .transport(NSURLErrorDomain, -1005))
        #expect(ShareFailure.transport(NSError(domain: NSPOSIXErrorDomain, code: 57)) == .transport(NSPOSIXErrorDomain, 57))
        #expect(ShareFailure.transport(ShareFailure.sessionEnded) == .sessionEnded)       // already one: unchanged
    }

    @Test func retryableAndBlockingSets() {
        let all: [ShareFailure] = [
            .signedOut, .needsApp, .noRoster, .sessionEnded, .otherAccount, .locked, .keychain(1), .tailscaleOff, .noChat, .tooLarge("a"),
            .unreadable("a"), .nothingToSend, .refused("x"), .gateway(500), .transport(NSURLErrorDomain, -1004), .timedOut, .cancelled, .unconfirmed,
        ]
        #expect(Set(all.map(\.name)).count == 18)
        #expect(Set(all.filter(\.retryable).map(\.name)) == ["tailscaleOff", "gateway", "transport", "timedOut", "locked"])
        #expect(Set(all.filter(\.blocksSheet).map(\.name)) == ["signedOut", "needsApp", "noRoster", "sessionEnded", "otherAccount"])
        // A share that may have arrived is never a plain Try Again.
        #expect(!ShareFailure.unconfirmed.retryable && !ShareFailure.unconfirmed.blocksSheet)
        // Nothing both blocks the sheet and offers Try Again.
        #expect(all.allSatisfy { !($0.retryable && $0.blocksSheet) })
    }

    @Test func namesRoundTrip() {
        for name in ["signedOut", "needsApp", "noRoster", "sessionEnded", "otherAccount", "locked", "keychain", "tailscaleOff", "noChat",
                     "tooLarge", "unreadable", "nothingToSend", "refused", "gateway", "transport", "timedOut", "unconfirmed"] {
            #expect(ShareFailure.named(name)?.name == name, "\(name)")
        }
        #expect(ShareFailure.named("nonsense") == nil && ShareFailure.named("") == nil)
        #expect(ShareFailure.named("cancelled") == nil)          // never shown, so never forced
    }

    @Test func gatewayRefusalsInPlainWords() {
        #expect(ShareFailure.rpcCopy(code: 4001, message: "session not found")
                == "Your gateway couldn’t find this bot’s chat. Open it in Hermes HQ, then share again.")
        #expect(ShareFailure.rpcCopy(code: 4009, message: "busy") == "This bot is busy. Try again in a moment.")
        #expect(ShareFailure.rpcCopy(code: 4000, message: "invalid params") == "Your gateway said: invalid params")
        #expect(ShareFailure.rpcCopy(code: -32000, message: "  first line  \nTraceback (most recent call last):\n  File …") == "Your gateway said: first line")
        #expect(ShareFailure.rpcCopy(code: 5000, message: "") == "Your gateway didn’t accept this share.")
        #expect(ShareFailure.rpcCopy(code: 5000, message: " \n ") == "Your gateway didn’t accept this share.")
        #expect(ShareFailure.rpcCopy(code: 5000, message: String(repeating: "x", count: 160)) == "Your gateway said: " + String(repeating: "x", count: 160))
        #expect(ShareFailure.rpcCopy(code: 5000, message: String(repeating: "x", count: 161)) == "Your gateway didn’t accept this share.")
    }

    @Test func nothingAPersonReadsSaysDispatch() {
        var words: [String] = []
        let failures: [ShareFailure] = [
            .signedOut, .needsApp, .noRoster, .sessionEnded, .otherAccount, .locked, .keychain(1), .tailscaleOff, .noChat, .tooLarge("a"),
            .unreadable("a"), .nothingToSend, .refused(""), .gateway(429), .gateway(500), .timedOut, .cancelled, .unconfirmed,
        ]
        words += failures.map(\.message)
        words += [-1001, -1003, -999, -1200, -1022, -1006, 0].map { ShareReach.failureMessage(domain: NSURLErrorDomain, code: $0) }
        words += [4001, 4009, 1].map { ShareFailure.rpcCopy(code: $0, message: "") }
        words += [ShareSheetState.preparing, ShareSheetState.noBots, ShareSheetState.noChat, ShareSheetState.botChat, ShareSheetState.photoPrivacy,
                  ShareSheetState.blockedTitle, ShareSheetState.tryAgain, ShareSheetState.title, ShareSheetState.placeholder, ShareSheetState.sendTo,
                  ShareSheetState.label(.connecting), ShareSheetState.label(.uploading(1, 1)), ShareSheetState.label(.uploading(2, 5)),
                  ShareSheetState.label(.sending), ShareSheetState.sent(to: "Ivy"), ShareSheetState.oversized("a", limit: 1), ShareRules.defaultQuestion,
                  ShareItemLoader.namelessItem]
        #expect(words.count > 40)
        for sentence in words {
            #expect(!sentence.localizedCaseInsensitiveContains("dispatch"), "\(sentence)")
            #expect(!sentence.contains("'") && !sentence.contains("\"") && !sentence.contains("..."), "\(sentence)")    // curly quotes, real ellipses
        }
        #expect(ShareSheetState.title == "Hermes HQ")
    }

    @Test func theSheetsOwnSourceNeverSaysDispatchToAPerson() throws {
        // Every quoted string in the extension's three files and in ShareKit, apart from the storage names of spec D10.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let allowed: Set<String> = ["Library/Application Support/Dispatch Share", ".dispatch-attachments", "dispatch-share-"]
        var checked = 0
        for folder in ["ShareKit", "ShareExtension"] {
            for file in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            where file.pathExtension == "swift" {
                for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
                    let code = line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line)
                    let parts = code.components(separatedBy: "\"")
                    for index in stride(from: 1, to: parts.count, by: 2) {
                        checked += 1
                        let literal = parts[index]
                        guard literal.localizedCaseInsensitiveContains("dispatch") else { continue }
                        #expect(allowed.contains(literal), "\(file.lastPathComponent): \(literal)")
                    }
                }
            }
        }
        #expect(checked > 200)
        // The plist's display name and the activation rule.
        let plist = try #require(NSDictionary(contentsOf: root.appendingPathComponent("ShareExtension/Info.plist")) as? [String: Any])
        // "Hermes HQ" in the shipped identity (the only one that embeds the extension): the app's own display name.
        #expect(plist["CFBundleDisplayName"] as? String == "$(HQ_DISPLAY_NAME)")
        #expect(AppIdentity.original.displayName == "Hermes HQ")
        let rule = try #require(((plist["NSExtension"] as? [String: Any])?["NSExtensionAttributes"] as? [String: Any])?["NSExtensionActivationRule"] as? [String: Any])
        #expect(rule.count == 5)
        #expect(rule["NSExtensionActivationSupportsText"] as? Bool == true)
        #expect(rule["NSExtensionActivationSupportsWebURLWithMaxCount"] as? Int == 1)
        #expect(rule["NSExtensionActivationSupportsImageWithMaxCount"] as? Int == ShareRules.maxImages)
        #expect(rule["NSExtensionActivationSupportsMovieWithMaxCount"] as? Int == 10)
        #expect(rule["NSExtensionActivationSupportsFileWithMaxCount"] as? Int == ShareRules.maxFiles)
    }
}
