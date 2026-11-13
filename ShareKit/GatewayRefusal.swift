// [kept-session] Who wrote a refusal. A 400, 401 or 403 ends a saved sign-in only when Hermes itself wrote it. The same
// status can come from whatever stands in front of Hermes at the saved address: a reverse proxy, Cloudflare (an Access
// page, a bot challenge, a firewall rule), a filter on the network the phone happens to be on. Those say nothing about
// the session, so the sign-in is kept and the app keeps trying (public issue #39: signed out each time the gateway
// could not be reached for a while). Compiled into the app and the Share extension.

import Foundation

nonisolated enum GatewayRefusal {
    /// True when `body` is a refusal Hermes writes: a JSON object with an `error` word (the session gate, the native
    /// refresh, the Nous edge) or a `detail` (every other route's `{"detail": …}`). Hermes never refuses with a page,
    /// plain text or an empty body. Cloudflare's own JSON errors carry `cloudflare_error` and are not Hermes.
    static func isHermes(_ body: Data) -> Bool {
        guard !body.isEmpty, let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return false }
        if object["cloudflare_error"] != nil { return false }
        return object["error"] is String || object["detail"] != nil
    }
}
