import Foundation
import SwiftUI

// =============================================================================
// AISettings — user-configurable guardrails for the chat assistant
// =============================================================================
//
// Settings live client-side in UserDefaults so they're cheap to toggle
// and survive relaunches without a server round-trip. They're shipped
// with every chat request inside `ChatContext.aiSettings`; the Edge
// Function templates them into the system prompt that goes to Claude.
//
// Keep this small and meaningful — every knob the user can twiddle is
// also a knob the model has to interpret, and too many of them blur the
// product's voice. Five is the current ceiling.

enum AIAssistantTone: String, Codable, CaseIterable, Identifiable, Sendable {
    case concise   // 1–2 sentence answers, no preamble.
    case balanced  // Default — short paragraphs, a touch of personality.
    case detailed  // Full context, suggested follow-ups, longer answers.

    var id: String { rawValue }

    /// Human label shown in the Picker.
    var displayName: String {
        switch self {
        case .concise:  return "Concise"
        case .balanced: return "Balanced"
        case .detailed: return "Detailed"
        }
    }

    /// One-liner shown under the Picker so the user knows what they're
    /// picking without having to A/B-test in the chat.
    var blurb: String {
        switch self {
        case .concise:  return "Short, direct answers. No preamble."
        case .balanced: return "A few sentences with a touch of personality."
        case .detailed: return "Longer answers with context and follow-ups."
        }
    }
}

/// All chat-assistant knobs the user can configure. Codable so the
/// whole struct can be persisted to UserDefaults and shipped to the
/// Edge Function as one blob.
///
/// Any new field MUST have a default that matches the current behaviour
/// — old builds shouldn't see a behavioural shift when this struct
/// gains a new knob; it should only show up after they update the app
/// AND visit the settings page.
struct AISettings: Codable, Equatable, Sendable {
    /// Verbosity / formality. Default `.balanced` mirrors what the
    /// system prompt encoded before this knob existed.
    var tone: AIAssistantTone = .balanced

    /// When ON (default), Claude may suggest real places from world
    /// knowledge for "what's fun nearby?"-type questions, clearly
    /// labelled as suggestions. When OFF, the assistant only talks
    /// about places the user has actually saved.
    var allowExternalRecommendations: Bool = true

    /// Hard ceiling on places listed in a single answer. Defaults to 5
    /// to keep replies skimmable; bumping to 10 is for power users who
    /// want full sweeps.
    var maxPlacesPerAnswer: Int = 5

    /// When ON (default), "around here" / "nearby" anchors on the
    /// selected pin's neighbourhood first. When OFF, the assistant
    /// uses the viewport centre.
    var anchorOnSelectedPin: Bool = true

    /// Free-form additions to the system prompt. Capped at 280 chars
    /// in the UI so the user can't blow up the prompt budget. Empty
    /// string means "no custom instructions".
    var customInstructions: String = ""

    /// Out-of-the-box behaviour. Used as the seed when nothing's been
    /// persisted yet, and as the "Reset" target in the UI.
    static let `default` = AISettings()
}

// MARK: - Persistence

/// Tiny UserDefaults-backed store. Reads on init, writes on every
/// mutation. The single shared instance is fine — settings are tiny
/// and writes are user-initiated, not on the hot path.
@Observable
final class AISettingsStore {
    static let shared = AISettingsStore()

    private static let key = "ai_assistant_settings_v1"

    /// Mutating this property re-encodes and writes through to
    /// UserDefaults synchronously. `@Observable` notifies any SwiftUI
    /// view bound to it, so the settings page updates immediately.
    var settings: AISettings {
        didSet { persist() }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(AISettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = .default
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    /// Restores out-of-the-box behaviour. Triggered by the
    /// "Reset to defaults" button on the settings page.
    func resetToDefaults() {
        settings = .default
    }
}
