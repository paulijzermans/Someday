import Foundation

// =============================================================================
// ExtractionRouter — the actual `URLExtractionService` the app talks to
// =============================================================================
//
// Holds one instance of each pipeline and dispatches each call based on the
// **current** `ExtractionPipelineSelector.current` value. Reading the
// selector lazily on every call (instead of caching at init) means flipping
// the UserDefaults key takes effect on the very next extraction — no app
// restart, no view-model rebuild, no Service Container reload.
//
// Routing rules:
//   • Instagram URL  → follows the toggle (Pipeline 1 or Pipeline 2)
//   • Google Maps URL → ALWAYS Pipeline 1 (Pipeline 2 is video-only)
//
// If Pipeline 2 is selected but `ExtractorConfig.isConfigured == false`
// (Secrets.plist not filled in), we transparently fall back to Pipeline 1
// rather than throwing — the user shouldn't see a "not configured" error
// they can't fix from the import sheet.

struct ExtractionRouter: URLExtractionService {
    let pipeline1: URLExtractionService
    let pipeline2: URLExtractionService

    func extractFromInstagram(url: String, ownerID: String) async throws -> [Place] {
        switch ExtractionPipelineSelector.current {
        case .pipeline2 where ExtractorConfig.isConfigured:
            return try await pipeline2.extractFromInstagram(url: url, ownerID: ownerID)
        case .pipeline2:
            // Selected but not configured — fall back silently so the user
            // still gets places. Devs see the misconfiguration via Xcode logs.
            #if DEBUG
            print("[ExtractionRouter] Pipeline 2 selected but EXTRACTOR_URL/EXTRACTOR_API_KEY missing — falling back to Pipeline 1")
            #endif
            return try await pipeline1.extractFromInstagram(url: url, ownerID: ownerID)
        case .pipeline1:
            return try await pipeline1.extractFromInstagram(url: url, ownerID: ownerID)
        }
    }

    /// Google Maps always uses Pipeline 1 — Pipeline 2 is a video pipeline and
    /// can't resolve a Maps share URL. The toggle is intentionally ignored
    /// here so a user with `pipeline_2` set still gets working Maps imports.
    func extractFromGoogleMaps(url: String, ownerID: String) async throws -> [Place] {
        try await pipeline1.extractFromGoogleMaps(url: url, ownerID: ownerID)
    }
}
