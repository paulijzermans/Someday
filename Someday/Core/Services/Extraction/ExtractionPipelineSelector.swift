import Foundation

// =============================================================================
// ExtractionPipelineSelector — the single switch between Pipeline 1 and 2
// =============================================================================
//
// We deliberately keep this as a UserDefaults-backed enum (no SwiftUI binding,
// no observable) so the toggle has zero impact on the rest of the app's state.
// The router reads `.current` lazily on every call, so flipping the key takes
// effect immediately for the next extraction.
//
// To flip pipelines at runtime (e.g. via lldb breakpoint, debug console, or a
// future debug menu):
//
//     ExtractionPipelineSelector.current = .pipeline2
//
// or the equivalent raw write:
//
//     UserDefaults.standard.set("pipeline_2", forKey: "extraction.pipeline")
//
// Default is `.pipeline1` so the app behaves exactly as before until the
// switch is flipped.

enum ExtractionPipeline: String, CaseIterable {
    /// Existing Supabase Edge Functions (`parse-instagram`, `parse-gmaps`)
    /// followed by on-device CLGeocoder. Default — proven and shipping.
    case pipeline1 = "pipeline_1"

    /// Erik's video-extraction service: yt-dlp → ffmpeg → Gemini → Google
    /// Places. Hosted on Railway, talked to over plain REST.
    case pipeline2 = "pipeline_2"

    var displayName: String {
        switch self {
        case .pipeline1: return "Pipeline 1 (Edge Functions)"
        case .pipeline2: return "Pipeline 2 (Railway extractor)"
        }
    }
}

enum ExtractionPipelineSelector {
    /// The UserDefaults key we read/write. Kept namespaced so we don't collide
    /// with anything else stashed in standard defaults.
    static let key = "extraction.pipeline"

    /// The currently-active pipeline. Reads from UserDefaults each access, so
    /// any external write is picked up by the very next extraction call.
    static var current: ExtractionPipeline {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key),
                  let p = ExtractionPipeline(rawValue: raw) else {
                return .pipeline1
            }
            return p
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
