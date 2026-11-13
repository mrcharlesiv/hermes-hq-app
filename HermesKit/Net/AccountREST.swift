// One authenticated REST call made with a saved account's own session, without opening its socket: a gateway the app
// just left (Add Gateway signed in elsewhere, so its client is already gone) still has this phone removed from its push
// list. A renewed session is written back to the vault as the account's own client would.

import Foundation

nonisolated enum AccountREST {
    /// (HTTP status, body); 0 when there was no answer (offline, a refused session, a timeout).
    static func call(_ stored: StoredAccount, vault: AccountVault = .app, method: String, path: String, body: Data?,
                     timeout: TimeInterval = 15, persisted: Bool = true) async -> (status: Int, data: Data?) {
        guard let base = URL(string: stored.url), let url = try? GatewayAddress.endpoint(base: base, path: path, query: []) else { return (0, nil) }
        let transport = HTTPTransport(cookies: !stored.isNous, headers: stored.accessHeaders)
        let auth = GatewayAuth(stored: stored, base: base, transport: transport, vault: vault, verified: false, persisted: persisted)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let began = ContinuousClock.now
        let answer: (Int, Data?)
        do {
            let (data, response) = try await auth.send(request)
            answer = (response.statusCode, data)
            AppLog.trace("net", "account REST \(method) \(AppLog.path(url)): \(answer.0), \(AppLog.ms(since: began))ms")
        } catch {
            answer = (0, nil)
            AppLog.note("net", "account REST \(method) \(AppLog.path(url)): no answer, \(AppLog.ms(since: began))ms")
        }
        // A renewal started alongside the call finishes before the transport goes (`GatewayAuth.settleRenewal`).
        Task {
            await auth.settleRenewal()
            await auth.close()
            transport.invalidate()
        }
        return answer
    }
}
