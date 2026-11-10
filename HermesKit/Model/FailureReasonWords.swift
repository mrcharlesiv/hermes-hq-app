// The sentence a "Couldn’t …" alert shows for an error that isn't a BotWriteError (UX study 2026-10-19 #99): a few
// common network failures in plain words, else the error's own description. Never the Swift debug text
// ("URLError(_nsError: Error Domain=NSURLErrorDomain Code=-1004 …)"), which stays behind Show Details. Pure, so the
// choice is unit-tested without UIKit.

import Foundation

nonisolated enum FailureReasonWords {
    static let offline = "You’re offline. Check your connection, then try again."
    static let unreachable = "Couldn’t reach your gateway. Check that it’s running, then try again."
    static let timedOut = "Your gateway took too long to answer. Try again."
    static let unknown = "Something went wrong. Try again."

    static func reason(for error: any Error) -> String {
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff: return offline
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed: return unreachable
            case .timedOut: return timedOut
            default: break
            }
        }
        if let described = (error as? LocalizedError)?.errorDescription, !described.isEmpty { return described }
        // An error with no sentence of its own reads "The operation couldn’t be completed. (NSURLErrorDomain error
        // -1011.)": that is debug text too.
        let ns = error as NSError, described = ns.localizedDescription
        return described.isEmpty || described.contains("\(ns.domain) error \(ns.code).") ? unknown : described
    }
}
