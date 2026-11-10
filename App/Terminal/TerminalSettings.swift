// [terminal] What the Terminal page keeps on this device (docs/spec/terminal.md): whether the person turned it on for a
// computer (asked the first time, per account), whether opening it asks for Face ID (on at first), the text size and
// font, and the shells this device has open there, one per tab (32-hex names; a new one after New Shell or once a shell
// has ended), with the names given to the tabs.

import CoreText
import LocalAuthentication
import SwiftTerm
import UIKit

@MainActor enum TerminalSettings {
    private static var defaults: UserDefaults { .standard }

    static func allowed(_ account: String) -> Bool { defaults.bool(forKey: "hq.terminal.allowed." + account) }

    static func setAllowed(_ on: Bool, account: String) {
        defaults.set(on, forKey: "hq.terminal.allowed." + account)
        AppLog.note("terminal", on ? "turned on for this computer" : "turned off for this computer")
    }

    /// Face ID (or the passcode) each time the page opens. On at first.
    static var requiresUnlock: Bool {
        get { defaults.object(forKey: "hq.terminal.lock") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "hq.terminal.lock") }
    }

    // MARK: Text size

    static let sizes: ClosedRange<CGFloat> = 8...32
    /// About 55 columns across an iPhone. The Mac draws the iPad layout at 77%, so its 16 reads as Terminal.app's 12.
    static var defaultSize: CGFloat {
        #if targetEnvironment(macCatalyst)
        16
        #else
        UIDevice.current.userInterfaceIdiom == .phone ? 12 : 13
        #endif
    }

    static var fontSize: CGFloat {
        get {
            let saved = defaults.double(forKey: "hq.terminal.fontSize")
            return saved > 0 ? min(max(CGFloat(saved), sizes.lowerBound), sizes.upperBound) : defaultSize
        }
        set { defaults.set(Double(min(max(newValue, sizes.lowerBound), sizes.upperBound)), forKey: "hq.terminal.fontSize") }
    }

    // MARK: Font

    /// ⋯ › Font (a tester 2026-11-05: "Hack nerd font (or option to choose a font)"). Hack Nerd Font Mono ships in
    /// the app (App/Resources/Fonts, regular and bold) so prompts drawn with Powerline and Nerd Font icons (starship,
    /// oh-my-posh, powerlevel10k) show their symbols rather than boxes.
    enum Face: String, CaseIterable {
        case system, menlo, hack

        var title: String {
            switch self {
            case .system: "SF Mono"
            case .menlo: "Menlo"
            case .hack: "Hack Nerd Font"
            }
        }

        /// The PostScript names of its regular and bold, nil for the system's.
        var names: (regular: String, bold: String)? {
            switch self {
            case .system: nil
            case .menlo: ("Menlo-Regular", "Menlo-Bold")
            case .hack: ("HackNFM-Regular", "HackNFM-Bold")
            }
        }
    }

    static var face: Face {
        get { defaults.string(forKey: "hq.terminal.font").flatMap(Face.init) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "hq.terminal.font") }
    }

    static func font(size: CGFloat = fontSize, face: Face = TerminalSettings.face, bold: Bool = false) -> UIFont {
        if face == .hack { registerHack() }
        if let names = face.names, let font = UIFont(name: bold ? names.bold : names.regular, size: size) { return font }
        return .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    /// The chosen face at the chosen size on a screen. SwiftTerm finds the system's and Menlo's bold and italic by trait;
    /// Hack gets its own bold by name (the app has no Hack italic: italic text stays upright).
    static func applyFont(to view: TerminalView, size: CGFloat = fontSize) {
        let normal = font(size: size)
        guard face == .hack else { view.font = normal; return }
        let bold = font(size: size, bold: true)
        view.setFonts(normal: normal, bold: bold, italic: normal, boldItalic: bold)
    }

    private static var hackRegistered = false

    /// Hack is registered for this run the first time it is asked for, not at launch (2.8 MB a face).
    private static func registerHack() {
        guard !hackRegistered else { return }
        hackRegistered = true
        for name in ["HackNerdFontMono-Regular", "HackNerdFontMono-Bold"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else {
                AppLog.note("terminal", "font \(name) is missing from the app")
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                AppLog.note("terminal", "font \(name) didn't register: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
            }
        }
    }

    // MARK: The shells

    /// The most tabs a page opens: the add-on holds 8 shells per computer, across every device.
    static let maxTabs = 8

    /// The shells this device has open on `account`'s computer, one per tab, in tab order (the first made on first use).
    /// A device from before tabs had one, under the old key: it becomes the first tab.
    static func sessions(_ account: String) -> [String] {
        let saved = (defaults.stringArray(forKey: sessionsKey(account)) ?? []).filter(TerminalWire.isSession)
        if !saved.isEmpty { return Array(saved.prefix(maxTabs)) }
        let first = defaults.string(forKey: sessionKey(account)).flatMap { TerminalWire.isSession($0) ? $0 : nil } ?? TerminalWire.newSession()
        setSessions([first], account: account)
        return [first]
    }

    static func setSessions(_ sessions: [String], account: String) {
        defaults.set(Array(sessions.prefix(maxTabs)), forKey: sessionsKey(account))
        defaults.removeObject(forKey: sessionKey(account))
    }

    /// What the person named each tab (hold a tab › Rename…, a tester 2026-11-05), in tab order beside `sessions`: "" for
    /// one named by what runs in it. Kept by position, not by shell, so a name stays with its tab through New Shell.
    static func tabNames(_ account: String) -> [String] {
        Array((defaults.stringArray(forKey: "hq.terminal.names." + account) ?? []).prefix(maxTabs))
    }

    static func setTabNames(_ names: [String], account: String) {
        let names = Array(names.prefix(maxTabs))
        if names.allSatisfy(\.isEmpty) {
            defaults.removeObject(forKey: "hq.terminal.names." + account)
        } else {
            defaults.set(names, forKey: "hq.terminal.names." + account)
        }
    }

    /// The tab that was in front when the page was last open.
    static func selectedTab(_ account: String) -> Int { defaults.integer(forKey: "hq.terminal.tab." + account) }

    static func setSelectedTab(_ index: Int, account: String) { defaults.set(index, forKey: "hq.terminal.tab." + account) }

    /// The shell this device has on `account`'s computer: the first tab's.
    static func session(_ account: String) -> String { sessions(account)[0] }

    private static func sessionKey(_ account: String) -> String { "hq.terminal.session." + account }
    private static func sessionsKey(_ account: String) -> String { "hq.terminal.sessions." + account }
}

/// Face ID, Touch ID or the device passcode before a shell opens.
@MainActor enum TerminalUnlock {
    enum Answer: Equatable { case unlocked, refused, unavailable }

    /// The lock's name in the ⋯ menu ("Require Face ID"). [mac] Audit 2026-11-02 #6: a Mac has no Face ID. The same
    /// `.deviceOwnerAuthentication` there asks for Touch ID when the Mac has it, else the Mac's login password, so the
    /// words name what it actually asks.
    /// [duo] An iPhone with Touch ID (iPhone Duo's side button, iPhone SE's Home button) says Touch ID.
    static var name: String {
        #if targetEnvironment(macCatalyst)
        hasTouchID ? "Touch ID" : "Password"
        #else
        hasTouchID ? "Touch ID" : "Face ID"
        #endif
    }

    /// The menu item's symbol, beside `name`.
    static var symbol: String {
        #if targetEnvironment(macCatalyst)
        hasTouchID ? "touchid" : "lock"
        #else
        hasTouchID ? "touchid" : "faceid"
        #endif
    }

    /// What unlocks it, inside a sentence ("Unlock with … to open the shell").
    static var means: String {
        #if targetEnvironment(macCatalyst)
        hasTouchID ? "Touch ID or your Mac’s password" : "your Mac’s password"
        #else
        hasTouchID ? "Touch ID or your passcode" : "Face ID or your passcode"
        #endif
    }

    /// Asked once a launch: the device's sensor is Touch ID. [mac] A MacBook's key or a Magic Keyboard with it; without
    /// it the Mac asks for its login password. iOS reports the sensor even when no finger or face is enrolled yet.
    private static let hasTouchID: Bool = {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType == .touchID
    }()

    /// The lock is on (⋯ › Require Face ID). DEBUG's `-HQTerminalNoLock YES` (UI tests, MacShots) leaves it off.
    static var isRequired: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "HQTerminalNoLock") { return false }
        #endif
        return TerminalSettings.requiresUnlock
    }

    static func unlock() async -> Answer {
        guard isRequired else { return .unlocked }
        return await ask("Unlock the Terminal")
    }

    /// Audit 09-1: turning Require Face ID off asks for Face ID (or the passcode) first. Otherwise whoever held the
    /// device at the locked page could cancel Face ID, untick it in ⋯ and tap Unlock. A device that can't check at all
    /// may still turn it off (the locked page says so); turning it on asks nothing.
    static func mayTurnOff() async -> Bool {
        guard isRequired else { return true }
        return await ask("Turn off Require \(name) for the Terminal") != .refused
    }

    private static func ask(_ reason: String) async -> Answer {
        #if DEBUG
        // Pictures of the lock without a real prompt on the machine: every ask passes, as a right finger would.
        if UserDefaults.standard.bool(forKey: "HQTerminalFakeUnlock") { return .unlocked }
        #endif
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode on this device at all: there is nothing to unlock with, as for the device itself.
            if error?.code == LAError.passcodeNotSet.rawValue { return .unlocked }
            AppLog.note("terminal", "unlock unavailable: \(error?.localizedDescription ?? "unknown")")
            return .unavailable
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? .unlocked : .refused
        } catch {
            AppLog.note("terminal", "unlock refused: \((error as NSError).code)")
            return .refused
        }
    }
}
