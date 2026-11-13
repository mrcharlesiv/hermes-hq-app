// Sign in with Nous, the browser half (spec 01 §6.1 steps 3–8, §19.3): PKCE + state, a loopback listener started
// before the browser opens, Portal's page in ASWebAuthenticationSession (sharing Safari's cookies), the gateway's
// redirect caught on 127.0.0.1 (never a URL scheme another app could claim), state compared in constant time.

import Foundation
import ObjectiveC
import UIKit

/// Where the authorize URL is shown. The system sheet in the app; a URLSession driver in tests.
@MainActor protocol NousBrowser: AnyObject, Sendable {
    /// Opens `url`. `userCancelled` runs if the person closes it before the gateway answered. False: couldn't open.
    func open(_ url: URL, userCancelled: @escaping @MainActor () -> Void) -> Bool
    /// The loopback relay caught the redirect: close the sheet.
    func close()
}

/// ASWebAuthenticationSession with the `hermeshq-native` callback scheme (D5). The callback never fires: the gateway
/// redirects to loopback and the relay closes the sheet.
///
/// AuthenticationServices is loaded only here, when Sign in with Nous opens its sheet, and driven through the
/// Objective-C runtime. Linking it made dyld load ~1,080 more images before any app code ran: 1.3 s of a 1.7 s launch on
/// the simulator (verification round 2 measured a minimal app at 0.42 s, and the same app linking AuthenticationServices
/// at 1.72 s).
@MainActor final class WebAuthBrowser: NSObject, NousBrowser {
    private var session: NSObject?
    private let provider: WebAuthAnchorProvider
    /// [nous-different-account] Starts with none of Safari's saved logins (`NousSheetLogin`).
    private let isPrivate: Bool
    /// [cf-access] The gateway's Cloudflare Access token: the sheet's first page is the gateway's own
    /// `/auth/native/authorize`, which Access would otherwise answer with its own sign-in. Access then keeps the
    /// sheet's later visits to the gateway signed in with the cookie it sets on that first answer.
    private let headers: [String: String]

    init(anchor: UIWindow?, isPrivate: Bool = false, headers: [String: String] = [:]) {
        provider = WebAuthAnchorProvider(anchor: anchor)
        self.isPrivate = isPrivate
        self.headers = headers
        super.init()
    }

    func open(_ url: URL, userCancelled: @escaping @MainActor () -> Void) -> Bool {
        // Explicitly @Sendable (not main-actor): AuthenticationServices doesn't say which queue runs the handler, so a
        // main-actor closure would trip Swift 6's isolation check when it runs elsewhere. It hops to the main actor.
        let handler: @convention(block) @Sendable (NSURL?, NSError?) -> Void = { _, error in
            guard error != nil else { return }
            Task { @MainActor in userCancelled() }
        }
        guard let session = WebAuthRuntime.makeSession(url: url, customScheme: AppIdentity.current.urlScheme, handler: handler) else { return false }
        session.setValue(provider, forKey: "presentationContextProvider")
        // Safari's cookies are shared, so a phone already signed in to Nous Portal isn't asked again. A private sheet
        // keeps none, so Nous asks who you are.
        session.setValue(isPrivate, forKey: "prefersEphemeralWebBrowserSession")
        if !headers.isEmpty, session.responds(to: NSSelectorFromString("setAdditionalHeaderFields:")) {
            session.setValue(headers, forKey: "additionalHeaderFields")
        }
        AppLog.trace("auth", "sign-in sheet opened (\(isPrivate ? "private" : "shared"))")
        self.session = session
        return WebAuthRuntime.start(session)
    }

    func close() {
        if let session { WebAuthRuntime.cancel(session) }
        session = nil
    }
}

/// [nous-different-account] Whether a Nous sign-in sheet borrows Safari's saved logins (tester 2026-11-02:
/// "I signed into the wrong nous account in app and I can't seem to clear cookies to sign into the right one"). The
/// sheet shares Safari's cookies, so a phone already signed in to Nous isn't asked again, but then every sign-in lands
/// in whichever account Safari holds, and no app can clear Safari's cookies. A private sheet starts with none.
@MainActor enum NousSheetLogin {
    enum Mode: String {
        /// Safari's saved login.
        case shared
        /// After a gateway's Sign Out: private until a Nous sign-in finishes.
        case once
        /// After Use Another Nous Account or Sign Out of Nous Portal: private, and `always` once a sign-in finishes.
        case choose
        /// Another account than Safari's was picked: a shared sheet would land in Safari's again.
        case always
    }

    private static let key = "nous.sheet.login"

    static var mode: Mode {
        get { UserDefaults.standard.string(forKey: key).flatMap(Mode.init(rawValue:)) ?? .shared }
        set {
            guard newValue != mode else { return }
            if newValue == .shared { UserDefaults.standard.removeObject(forKey: key) }
            else { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
            AppLog.note("auth", "nous sheet login: \(newValue.rawValue)")
        }
    }

    /// The next Nous sheet opens private.
    static var isPrivate: Bool { mode != .shared }

    /// Signed out of a gateway signed in with Nous: the next sign-in asks who you are.
    static func signedOut() { if mode == .shared { mode = .once } }

    /// Use Another Nous Account, or Sign Out of Nous Portal.
    static func chooseAccount() { if mode != .always { mode = .choose } }

    /// A Nous sign-in finished.
    static func finished() {
        switch mode {
        case .once: mode = .shared
        case .choose: mode = .always
        case .shared, .always: break
        }
    }
}

/// `ASWebAuthenticationPresentationContextProviding`, adopted at run time once the framework is loaded.
final class WebAuthAnchorProvider: NSObject {
    private weak var anchor: UIWindow?

    init(anchor: UIWindow?) {
        self.anchor = anchor
        super.init()
        WebAuthRuntime.adoptProviderProtocol(Self.self)
    }

    @objc(presentationAnchorForWebAuthenticationSession:)
    nonisolated func presentationAnchor(for session: AnyObject) -> UIWindow {
        MainActor.assumeIsolated {
            if let anchor { return anchor }
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
                preconditionFailure("Sign in with Nous needs a window scene")
            }
            return scene.keyWindow ?? UIWindow(windowScene: scene)
        }
    }
}

/// The few AuthenticationServices calls the sheet needs, made through the Objective-C runtime after `dlopen`.
@MainActor enum WebAuthRuntime {
    private static let loaded: Bool = {
        dlopen("/System/Library/Frameworks/AuthenticationServices.framework/AuthenticationServices", RTLD_NOW) != nil
    }()
    private static var adopted = false

    static func adoptProviderProtocol(_ cls: AnyClass) {
        guard loaded, !adopted, let proto = objc_getProtocol("ASWebAuthenticationPresentationContextProviding") else { return }
        adopted = true
        class_addProtocol(cls, proto)
    }

    /// `[[ASWebAuthenticationSession alloc] initWithURL:callback:[ASWebAuthenticationSessionCallback callbackWithCustomScheme:]
    /// completionHandler:]`.
    static func makeSession(url: URL, customScheme: String,
                            handler: @escaping @convention(block) @Sendable (NSURL?, NSError?) -> Void) -> NSObject? {
        guard loaded, let sessionClass = NSClassFromString("ASWebAuthenticationSession"),
              let callbackClass = NSClassFromString("ASWebAuthenticationSessionCallback"),
              let sessionMeta = object_getClass(sessionClass), let callbackMeta = object_getClass(callbackClass) else { return nil }
        let makeCallback = NSSelectorFromString("callbackWithCustomScheme:")
        let alloc = NSSelectorFromString("alloc")
        let initSel = NSSelectorFromString("initWithURL:callback:completionHandler:")
        guard class_respondsToSelector(callbackMeta, makeCallback), class_respondsToSelector(sessionClass, initSel),
              let callbackImp = class_getMethodImplementation(callbackMeta, makeCallback),
              let allocImp = class_getMethodImplementation(sessionMeta, alloc),
              let initImp = class_getMethodImplementation(sessionClass, initSel) else { return nil }
        typealias MakeCallback = @convention(c) (AnyClass, Selector, NSString) -> Unmanaged<AnyObject>?
        typealias Alloc = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
        typealias Init = @convention(c) (AnyObject, Selector, NSURL, AnyObject,
                                          @convention(block) @Sendable (NSURL?, NSError?) -> Void) -> Unmanaged<AnyObject>?
        guard let callback = unsafeBitCast(callbackImp, to: MakeCallback.self)(callbackClass, makeCallback, customScheme as NSString)?
            .takeUnretainedValue(),                                   // autoreleased
              let allocated = unsafeBitCast(allocImp, to: Alloc.self)(sessionClass, alloc) else { return nil }   // +1
        // `init` consumes the +1 from `alloc` and returns +1.
        let made = unsafeBitCast(initImp, to: Init.self)(allocated.takeUnretainedValue(), initSel, url as NSURL, callback, handler)
        return made?.takeRetainedValue() as? NSObject
    }

    static func start(_ session: NSObject) -> Bool {
        let sel = NSSelectorFromString("start")
        guard let imp = class_getMethodImplementation(type(of: session), sel) else { return false }
        typealias Start = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(imp, to: Start.self)(session, sel)
    }

    static func cancel(_ session: NSObject) {
        let sel = NSSelectorFromString("cancel")
        guard let imp = class_getMethodImplementation(type(of: session), sel) else { return }
        typealias Cancel = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(imp, to: Cancel.self)(session, sel)
    }
}

@MainActor enum NousSignIn {
    struct Outcome: Sendable { let code: String; let verifier: String }

    private final class Flag { var closedByRelay = false }

    /// Runs the browser half; returns the one-time code and this attempt's verifier. Throws `nousCancelled` when the
    /// person closes the sheet, `nousFailed` on a missing or mismatched state, `timeout` after 10 minutes.
    static func run(gateway: URL, provider: String = NousGatewayProtocol.nous, browser: NousBrowser,
                    relay: LoopbackRelay = .shared) async throws -> Outcome {
        try await run(browser: browser, relay: relay) { redirect, challenge, state in
            NousGatewayProtocol.authorizeURL(gateway: gateway, provider: provider, challenge: challenge, redirect: redirect, state: state)
        }.outcome
    }

    /// The same browser half for any provider that redirects to loopback (Hermes Cloud's Portal login): `authorize`
    /// gets this attempt's redirect URI, PKCE challenge and state, and may register a client for that redirect first.
    /// Also returns the redirect URI, which a token exchange must repeat.
    static func run(browser: NousBrowser, relay: LoopbackRelay = .shared,
                    authorize: @MainActor (_ redirect: String, _ challenge: String, _ state: String) async throws -> URL?)
        async throws -> (outcome: Outcome, redirect: String) {
        let pkce = NousPKCE.pair(), state = NousPKCE.state()
        let flag = Flag()
        let listening: (id: String, redirectURI: String)
        do {
            listening = try await relay.listen(closeBrowser: { [weak browser] in
                Task { @MainActor in
                    flag.closedByRelay = true
                    browser?.close()
                }
            }, lifetime: 900)
        } catch {
            throw GatewayFailure.nousFailed
        }
        let id = listening.id
        // Waiting starts before the browser opens, so a fast redirect is never missed.
        let waiting = Task { await relay.wait(id, timeout: 600) }
        let made: URL?
        do { made = try await authorize(listening.redirectURI, pkce.challenge, state) }
        catch { relay.cancel(id); waiting.cancel(); throw error }
        guard let url = made else {
            relay.cancel(id)
            throw GatewayFailure.invalidURL
        }
        guard browser.open(url, userCancelled: { if !flag.closedByRelay { relay.cancel(id) } }) else {
            relay.cancel(id)
            throw GatewayFailure.nousFailed
        }
        let callback = await withTaskCancellationHandler {
            await waiting.value
        } onCancel: {
            relay.cancel(id)
        }
        if !flag.closedByRelay { browser.close() }
        if let error = callback.error {
            if error == "cancelled" { throw GatewayFailure.nousCancelled }
            throw error.hasPrefix("timeout") ? GatewayFailure.timeout : GatewayFailure.nousFailed
        }
        guard NousPKCE.sameState(callback.state, state), let code = callback.code, !code.isEmpty else {
            throw GatewayFailure.nousFailed
        }
        return (Outcome(code: code, verifier: pkce.verifier), listening.redirectURI)
    }
}

/// Hermes Cloud's Portal login (HermesKit/Cloud/PortalAuth.swift): register a client for this attempt's loopback
/// redirect, sign in in the browser sheet (Safari's cookies, so a phone already signed in to Nous isn't asked again),
/// redeem the code, save the pair.
@MainActor enum PortalSignIn {
    static func run(browser: NousBrowser, auth: PortalAuth = PortalAuth(), login: PortalLogin = .shared,
                    relay: LoopbackRelay = .shared) async throws {
        var clientId = ""
        let (outcome, redirect) = try await NousSignIn.run(browser: browser, relay: relay) { redirect, challenge, state in
            clientId = try await auth.register(redirect: redirect)
            return auth.authorizeURL(clientId: clientId, redirect: redirect, challenge: challenge, state: state)
        }
        let credentials = try await auth.redeem(code: outcome.code, verifier: outcome.verifier, redirect: redirect, clientId: clientId)
        await login.adopt(credentials)
        NousSheetLogin.finished()
        AppLog.note("auth", "portal signed in (token lifetime \(Int(max(0, credentials.expiresAt - credentials.obtainedAt))) s)")
    }
}
