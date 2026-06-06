import Foundation

// =============================================================================
// Pipeline2Service — REST client for Erik's Railway extractor
// =============================================================================
//
// Talks to the Flask + Gunicorn service in the `etij/someday` repo
// (`extractor-test-app/server.py`). API contract:
//
//   POST /run          { "url": "..." }  → { "run_id": "<uuid>" }
//   GET  /result/{id}                    → { status, places, error }
//   GET  /health                         → { "status": "ok" }
//
// All authed endpoints require `X-Api-Key: <key>` matching the `API_KEY`
// env var on the server.
//
// We deliberately use **polling** (not SSE) because Swift's URLSession has no
// built-in SSE parser and pulling in `swift-eventsource` for v1 is overkill.
// Poll cadence is 1.5s, capped at 90 attempts (~135s wall-clock) — generous
// enough for a long reel, plus a one-shot retry on transient network errors.
//
// Self-contained: this struct talks raw HTTP and depends on nothing in the
// app outside `ExtractorConfig` (env) and the `Place` model (output shape).

struct Pipeline2Service: URLExtractionService {
    /// `URLSession` injected so tests can stub the network. Production
    /// callers leave it nil and we use `.shared`.
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Protocol

    func extractFromInstagram(url: String, ownerID: String) async throws -> [Place] {
        try await runPipeline(url: url, source: .instagram, ownerID: ownerID)
    }

    /// Pipeline 2 is video-only — yt-dlp can't pull places out of a Google
    /// Maps share link. We bail loudly so the router can route the call to
    /// Pipeline 1 instead.
    func extractFromGoogleMaps(url: String, ownerID: String) async throws -> [Place] {
        throw ExtractionError.unsupported(
            "Pipeline 2 doesn't handle Google Maps URLs — only video links (Reels, TikToks)."
        )
    }

    // MARK: - Core orchestration
    //
    // The three sub-steps are kept in a single function so the lifecycle of
    // `runID` is obvious from a single read-through. Each sub-step is a thin
    // helper below.

    private func runPipeline(url: String, source: PlaceSource, ownerID: String) async throws -> [Place] {
        guard ExtractorConfig.isConfigured,
              let baseURL = ExtractorConfig.url,
              let apiKey = ExtractorConfig.apiKey else {
            throw ExtractionError.notConfigured(
                "set EXTRACTOR_URL and EXTRACTOR_API_KEY in Secrets.plist"
            )
        }

        let runID = try await startRun(url: url, baseURL: baseURL, apiKey: apiKey)
        let result = try await pollUntilDone(runID: runID, baseURL: baseURL, apiKey: apiKey)
        // The original Reel URL we sent is the same for every returned
        // place. Stamp it onto each so the source badge in PlaceCardSheet
        // can tap-through to the actual Instagram / TikTok post.
        let origin = URL(string: url)
        return result.compactMap { row in
            row.toPlace(source: source, ownerID: ownerID, sourceURL: origin)
        }
    }

    // MARK: - POST /run

    private struct RunRequest: Encodable { let url: String }
    private struct RunResponse: Decodable { let run_id: String }

    private func startRun(url: String, baseURL: URL, apiKey: String) async throws -> String {
        let endpoint = baseURL.appendingPathComponent("run")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        req.httpBody = try JSONEncoder().encode(RunRequest(url: url))
        req.timeoutInterval = 15

        let (data, response) = try await session.data(for: req)
        try Self.assertOK(data: data, response: response, step: "start run")
        do {
            return try JSONDecoder().decode(RunResponse.self, from: data).run_id
        } catch {
            throw ExtractionError.decodingFailed("run_id missing in /run response")
        }
    }

    // MARK: - GET /result/{id} (polling)

    private struct ResultResponse: Decodable {
        let status: String          // "pending" | "done" | "error"
        let places: [Pipeline2PlaceDTO]?
        let error: String?
    }

    /// 1.5s × 90 = up to ~135s of polling. The server's own step timeouts add
    /// up to ~108s worst case (download 30 + transcode 30 + gemini 30 + places
    /// 15 + a few seconds of overhead), so 135s is generous but bounded.
    private static let pollInterval: UInt64 = 1_500_000_000     // 1.5s in nanos
    private static let maxPollAttempts = 90

    private func pollUntilDone(runID: String, baseURL: URL, apiKey: String) async throws -> [Pipeline2PlaceDTO] {
        let endpoint = baseURL.appendingPathComponent("result").appendingPathComponent(runID)

        for _ in 0..<Self.maxPollAttempts {
            try? await Task.sleep(nanoseconds: Self.pollInterval)
            var req = URLRequest(url: endpoint)
            req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
            req.timeoutInterval = 10

            // Treat transient network blips during polling as "try again next
            // tick" rather than killing the run — the server is doing real
            // work and a 1-attempt blip is normal.
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: req)
            } catch {
                continue
            }
            do {
                try Self.assertOK(data: data, response: response, step: "poll result")
            } catch {
                continue
            }

            let result: ResultResponse
            do {
                result = try JSONDecoder().decode(ResultResponse.self, from: data)
            } catch {
                throw ExtractionError.decodingFailed("invalid /result payload")
            }

            switch result.status {
            case "done":
                return result.places ?? []
            case "error":
                throw ExtractionError.serverError(result.error ?? "Extraction failed.")
            default:
                continue        // "pending" — keep polling
            }
        }

        throw ExtractionError.timeout
    }

    // MARK: - Shared HTTP helper

    private static func assertOK(data: Data, response: URLResponse, step: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ExtractionError.serverError("\(step): no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            // Try to pull the server's error message out of the body —
            // the Flask app returns `{ "error": "..." }` for 4xx/5xx.
            if let body = try? JSONDecoder().decode([String: String].self, from: data),
               let msg = body["error"] {
                throw ExtractionError.serverError("\(step) failed (\(http.statusCode)): \(msg)")
            }
            throw ExtractionError.serverError("\(step) failed (HTTP \(http.statusCode))")
        }
    }
}

// =============================================================================
// Pipeline2PlaceDTO — wire shape returned by Erik's /result endpoint
// =============================================================================
//
// Source of truth: `docs/design/260531_DESIGN_extractor-pipeline.md` in
// etij/someday. Mapping rules:
//
//   place_id == nil   → Gemini saw the place but Google Places couldn't
//                        resolve it. We drop it (we'd have no coordinate).
//   primary_type     → mapped to our `PlaceCategory` via `categoryFor(...)`.
//   formatted_address → used as `neighborhood` (best-effort area label).

private struct Pipeline2PlaceDTO: Decodable {
    let place_id: String?
    let display_name: String?
    let formatted_address: String?
    let lat: Double?
    let lng: Double?
    let primary_type: String?

    /// Convert to our domain `Place`. Returns nil when there's no
    /// resolved coordinate — a place with no lat/lng is unmappable.
    /// `sourceURL` is the original Reel/TikTok URL we sent in, surfaced
    /// here so PlaceCardSheet's badge can deep-link back to the post.
    func toPlace(source: PlaceSource, ownerID: String, sourceURL: URL?) -> Place? {
        guard place_id != nil,
              let name = display_name, !name.isEmpty,
              let lat, let lng else {
            return nil
        }
        return Place(
            name: name,
            category: Self.categoryFor(primary_type),
            latitude: lat,
            longitude: lng,
            source: source,
            neighborhood: formatted_address ?? "",
            isSaved: true,
            ownerID: ownerID,
            sourceURL: sourceURL
        )
    }

    /// Map Google Places' `primary_type` (e.g. "restaurant", "bar",
    /// "cafe", "museum") to our coarser `PlaceCategory`. Anything we don't
    /// recognise lands in `.food` — the safest default for an import sheet
    /// that's overwhelmingly food/drink venues.
    private static func categoryFor(_ primary: String?) -> PlaceCategory {
        guard let p = primary?.lowercased() else { return .food }
        switch p {
        case "restaurant", "meal_takeaway", "meal_delivery",
             "bakery", "food", "italian_restaurant", "asian_restaurant",
             "japanese_restaurant", "chinese_restaurant", "thai_restaurant",
             "french_restaurant", "mexican_restaurant", "ramen_restaurant",
             "sushi_restaurant", "pizza_restaurant", "fast_food_restaurant":
            return .food
        case "bar", "night_club", "pub", "wine_bar", "cocktail_lounge",
             "liquor_store":
            return .drinks
        case "cafe", "coffee_shop":
            return .coffee
        case "museum", "art_gallery":
            return .art
        case "park", "tourist_attraction", "amusement_park",
             "stadium", "zoo", "aquarium", "campground", "hiking_area":
            return .activity
        case "lodging", "hotel", "airport", "train_station",
             "transit_station":
            return .travel
        default:
            return .food
        }
    }
}
