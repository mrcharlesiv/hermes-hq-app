// [onboarding] The hard cap on one read of the gateway's version (docs/spec/3x-onboarding.md §5.14): whatever the
// transport does, the answer is `.unknown` once the cap passes, and `.unknown` never blocks. A late answer is dropped
// and the read behind it cancelled.

import Foundation

enum CompatibilityCap {
    static let standard: Duration = .seconds(GatewayCompatibility.checkSeconds)

    static func run(_ cap: Duration = standard, _ read: @escaping () async -> GatewayCompatibility) async -> GatewayCompatibility {
        final class Once { var done = false }
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<GatewayCompatibility, Never>) in
            let finish: (GatewayCompatibility) -> Void = { answer in
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: answer)
            }
            let reader = Task { finish(await read()) }
            // The cap wins: the read is cancelled too, so a capped read never runs on beside the next Check Again.
            Task { try? await Task.sleep(for: cap); finish(.unknown); reader.cancel() }
        }
    }
}

/// How a successful sign-in goes on: into the app, or to "Update Hermes on Your Gateway" first.
enum SignInOutcome: Equatable {
    case enter
    case update(OutdatedGateway)
}
