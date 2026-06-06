import UIKit

// =============================================================================
// Haptics — one-line helpers for tactile feedback across the app
// =============================================================================
//
// Wraps `UIImpactFeedbackGenerator`, `UINotificationFeedbackGenerator`, and
// `UISelectionFeedbackGenerator` so call sites stay terse:
//
//     Haptics.tap()       // light impact — button taps, pin selection
//     Haptics.soft()      // soft impact  — "thing lands" moments (pin stagger)
//     Haptics.success()   // notification — actions that committed (import done)
//     Haptics.warning()
//     Haptics.error()
//     Haptics.select()    // selection tick — segmented controls, tab switches
//
// Each call is fire-and-forget: the generator is created, fires immediately,
// and is released by ARC. Apple recommends pre-preparing for very latency-
// sensitive cases — none of ours qualify (tap-driven, not animation-driven),
// so we skip the prepare()/cache dance and keep the API trivial.
//
// On simulator + Mac Catalyst these calls are silent no-ops; on a real iPhone
// they produce the expected Taptic Engine feedback.

enum Haptics {
    /// Light tactile thud — default for button presses, pin selection,
    /// and other "I touched something" confirmations.
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Softer thud — used when something arrives on screen rather than
    /// the user actively pressing. Each pin in the import stagger fires
    /// one of these as it lands.
    static func soft() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    /// Medium confirmation — between `.tap()` and `.heavy()`. Useful
    /// when you want a noticeable bump without going as loud as `.heavy()`.
    static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Heavy single beat — the strongest single-shot impact iOS exposes.
    /// Reserved for "loading finished, here are the results" moments
    /// where the app wants the user to physically feel the payoff.
    static func heavy() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }

    /// Two-beat success notification — fires when an AI lookup
    /// finishes, an import lands, or a list is created. Distinct from
    /// `.tap()` so users learn "this means something completed".
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Two-beat warning notification — for soft-fails (e.g. nothing
    /// extracted from a Reel).
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    /// Three-beat error notification — for hard fails (network down,
    /// AI errored, save failed).
    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    /// Picker-wheel tick — for tab swaps, pill segmented controls, and
    /// any "discrete option changed" moment.
    static func select() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// Aggressive "importing now" burst — three back-to-back heavy
    /// impacts ~55ms apart. Used the moment an import (Instagram, Maps,
    /// shared list) starts so the user *physically* feels the app
    /// reaching out to grab the places. Distinct from `.heavy()`
    /// (single beat = "done") so users learn:
    ///     burst   → "we're going"
    ///     heavy   → "we're done"
    ///     success → "and you committed it"
    static func importBurst() {
        // Cache one generator so the three taps fire from the same
        // engine state — feels like one continuous rumble rather than
        // three loose pulses. ARC keeps it alive across the dispatched
        // closures because each captures `gen` strongly.
        let gen = UIImpactFeedbackGenerator(style: .heavy)
        gen.prepare()
        gen.impactOccurred(intensity: 1.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.055) {
            gen.impactOccurred(intensity: 1.0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.110) {
            gen.impactOccurred(intensity: 1.0)
        }
    }

    /// Per-item "feeding in" tap — fired while the import-summary tile
    /// reveals each result row in sequence. Pitched between `.soft()`
    /// (too gentle to feel rhythmic) and `.medium()` (too heavy for
    /// fast cadence) by using a `.medium` generator at reduced
    /// intensity — feels like a typewriter clack on each new row.
    static func importTick() {
        let gen = UIImpactFeedbackGenerator(style: .medium)
        gen.impactOccurred(intensity: 0.7)
    }
}
