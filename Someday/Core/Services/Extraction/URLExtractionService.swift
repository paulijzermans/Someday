import Foundation

// =============================================================================
// URLExtractionService — single contract for "URL → [Place]"
// =============================================================================
//
// This module is intentionally **standalone**: it owns the URL-extraction
// concern end-to-end and does not depend on anything in `Core/Services/Supabase`
// for Pipeline 2. Pipeline 1 reuses the legacy Edge Function path via the
// existing `PlaceServiceProtocol` purely as a fallback adapter.
//
// The dispatcher (`ExtractionRouter`) decides which pipeline runs each call
// based on a single UserDefaults key — see `ExtractionPipelineSelector`. That
// makes it trivial to flip between implementations at runtime without
// rebuilding, and to A/B them side-by-side without code changes.
//
// IMPORTANT: the returned `[Place]` is **not yet persisted**. The caller (the
// import preview sheet) decides whether to commit to Supabase.

/// The single entry point the rest of the app uses to turn a share URL into
/// a list of `Place` objects ready for the preview/import flow.
protocol URLExtractionService: Sendable {
    /// Pull places out of an Instagram Reel / post URL. The active pipeline
    /// (Pipeline 1 — Supabase Edge Function, or Pipeline 2 — Erik's Railway
    /// extractor) is chosen at call time by the router.
    func extractFromInstagram(url: String, ownerID: String) async throws -> [Place]

    /// Pull places out of a Google Maps share URL. Pipeline 2 doesn't support
    /// Maps (it's a video pipeline), so this always routes through Pipeline 1
    /// regardless of the toggle.
    func extractFromGoogleMaps(url: String, ownerID: String) async throws -> [Place]
}

/// Errors surfaced by the extraction module. UI shows `localizedDescription`
/// directly to the user, so phrase them in plain English.
enum ExtractionError: LocalizedError {
    case notConfigured(String)
    case timeout
    case serverError(String)
    case decodingFailed(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let what):
            return "Pipeline 2 isn't configured — \(what)."
        case .timeout:
            return "Extraction took too long — try again."
        case .serverError(let msg):
            return msg
        case .decodingFailed(let msg):
            return "Couldn't read the extractor response: \(msg)"
        case .unsupported(let msg):
            return msg
        }
    }
}
