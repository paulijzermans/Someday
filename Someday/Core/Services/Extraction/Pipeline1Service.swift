import Foundation

// =============================================================================
// Pipeline1Service — adapter around the existing Supabase Edge Functions
// =============================================================================
//
// Pipeline 1 is the proven flow that's been shipping:
//   • Instagram URL → `parse-instagram` Edge Function → name + address →
//     on-device CLGeocoder → [Place]
//   • Google Maps URL → `parse-gmaps` Edge Function → coordinates → [Place]
//
// This file is *just* an adapter: it implements the new
// `URLExtractionService` contract by delegating to the existing
// `PlaceServiceProtocol`. No behavioural change vs the legacy path — it
// exists so the router can hold a uniform reference to "the Pipeline 1
// implementation" alongside Pipeline 2.

struct Pipeline1Service: URLExtractionService {
    let placeService: PlaceServiceProtocol

    func extractFromInstagram(url: String, ownerID: String) async throws -> [Place] {
        try await placeService.importFromInstagram(url: url, ownerID: ownerID)
    }

    func extractFromGoogleMaps(url: String, ownerID: String) async throws -> [Place] {
        try await placeService.importFromGoogleMaps(url: url, ownerID: ownerID)
    }
}
