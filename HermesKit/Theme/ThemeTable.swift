// desktoplook: the resolved theme, readable from any thread (SwiftUI resolves dynamic colours off main: see
// HQPalette.swift). Colour providers look their tokens up by the generation number their trait collection carries.

import Foundation
import os

nonisolated enum ThemeTable {
    private struct Storage {
        var generation = 0
        var current = ThemeResolver.resolve(.default)
        /// The last few generations: a view that still carries an older trait resolves to its own set until it is
        /// told the new number. Anything older resolves to the current set.
        var recent: [Int: ThemeSet] = [:]
        /// [perf] `current.state.desktopLook`, kept beside the set so `Theme.isDesktop` (read per item by the list
        /// layouts) need not copy the whole set out of the lock for one Bool. Written with the set in `install`.
        var desktopLook = false
        /// `current.state.appliedBubbleCorners`, for the same reason (read for every bubble outline).
        var bubbleCorners = ThemeState.defaultBubbleCorners
        /// `current.state.appliedBubbleStyle`, for the same reason (read for every bubble's fill).
        var bubbleStyle = ThemeState().appliedBubbleStyle
    }
    private static let lock = OSAllocatedUnfairLock(initialState: Storage())
    private static let keep = 4

    #if DEBUG
    /// Tests only: the theme for the current task and its children, so a test can run in a look without changing the
    /// one table the tests running beside it read (`ThemeTable.$testSet.withValue(…) { … }`).
    @TaskLocal static var testSet: ThemeSet?
    #endif

    static var current: ThemeSet {
        #if DEBUG
        if let testSet { return testSet }
        #endif
        return lock.withLock { $0.current }
    }
    static var generation: Int { lock.withLock { $0.generation } }

    /// The current set's `state.desktopLook`, without copying the set.
    static var desktopLook: Bool {
        #if DEBUG
        if let testSet { return testSet.state.desktopLook }
        #endif
        return lock.withLock { $0.desktopLook }
    }

    /// The current set's `state.appliedBubbleCorners`, without copying the set.
    static var bubbleCorners: Int {
        #if DEBUG
        if let testSet { return testSet.state.appliedBubbleCorners }
        #endif
        return lock.withLock { $0.bubbleCorners }
    }

    /// [glass-bubbles] [tinted-bubbles] The current set's `state.appliedBubbleStyle`, without copying the set.
    static var bubbleStyle: BubbleStyle {
        #if DEBUG
        if let testSet { return testSet.state.appliedBubbleStyle }
        #endif
        return lock.withLock { $0.bubbleStyle }
    }
    /// [glass-bubbles] The current set's `state.appliedGlassBubbles`.
    static var glassBubbles: Bool { bubbleStyle == .glass }

    /// Registers `set` as the current theme; returns its generation number.
    @discardableResult static func install(_ set: ThemeSet) -> Int {
        lock.withLock { storage in
            storage.generation += 1
            storage.current = set
            storage.desktopLook = set.state.desktopLook
            storage.bubbleCorners = set.state.appliedBubbleCorners
            storage.bubbleStyle = set.state.appliedBubbleStyle
            storage.recent[storage.generation] = set
            for key in storage.recent.keys where key <= storage.generation - keep { storage.recent[key] = nil }
            return storage.generation
        }
    }

    /// Generation 0 is "no trait set yet" (a view outside a window): the current set.
    static func tokens(generation: Int, dark: Bool) -> ThemeTokens {
        #if DEBUG
        if let testSet { return testSet.tokens(dark: dark) }
        #endif
        return lock.withLock { storage in
            (generation == 0 ? storage.current : storage.recent[generation] ?? storage.current).tokens(dark: dark)
        }
    }

    /// The whole set a trait collection's generation belongs to (generation 0: the current one).
    static func set(generation: Int) -> ThemeSet {
        #if DEBUG
        if let testSet { return testSet }
        #endif
        return lock.withLock { storage in generation == 0 ? storage.current : storage.recent[generation] ?? storage.current }
    }

    /// [perf] Reads the set a generation belongs to inside the lock, so a colour resolve takes the one token it
    /// needs instead of copying the whole set. `body` must not call back into `ThemeTable`.
    static func withSet<T>(generation: Int, _ body: (ThemeSet) -> T) -> T {
        #if DEBUG
        if let testSet { return body(testSet) }
        #endif
        // Unchecked: `body` runs here, on the calling thread, while the lock is held; nothing escapes it.
        return lock.withLockUnchecked { storage in
            if generation != 0, let set = storage.recent[generation] { return body(set) }
            return body(storage.current)
        }
    }

    /// Appended to layout cache keys: empty for the standard look, so those keys are what they always were.
    static var layoutTag: String {
        let state = current.state
        let standard = !state.desktopLook && state.scale == 1 && state.bubbleCorners == ThemeState.defaultBubbleCorners
        return standard ? "" : "#look\(state.layoutSignature)"
    }

    static var retained: Int { lock.withLock { $0.recent.count } }
}
