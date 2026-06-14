import Foundation
import OSLog
import Supabase

// =============================================================================
// Cross-surface observability (iOS half)
// =============================================================================
//
// One trace id per user action, propagated to the backend via the `X-Trace-Id`
// header so the iOS app and every Edge Function it touches share a single id in
// the `debug_log` table. The AI agent then reads one request's whole journey
// across surfaces with `read_debug_log` (see migration 20260614100000 +
// _shared/observe.ts). These primitives live here, in an already-compiled file,
// because `Observability` needs the shared `SupabaseClient` below — and because
// the project has no synchronized file groups, so a brand-new .swift file would
// need a manual pbxproj entry (see CLAUDE.md §10).

/// A trace id for one user action. Generate at the start of an action and
/// `inject` into every outbound `URLRequest` so the backend can correlate.
struct Trace {
    let id: String
    static func start() -> Trace { Trace(id: UUID().uuidString) }
    /// Adds the `X-Trace-Id` header the Edge Functions read via `extractTraceId`.
    func inject(into request: inout URLRequest) {
        request.setValue(id, forHTTPHeaderField: "X-Trace-Id")
    }
}

/// OSLog category registry — one subsystem (the bundle id, so rows group in
/// Console.app), one category per surface. Use instead of bare `print(...)`.
enum AppLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.paulijzermans.someday"
    static let chat = Logger(subsystem: subsystem, category: "chat")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let extraction = Logger(subsystem: subsystem, category: "extraction")
    static let ui = Logger(subsystem: subsystem, category: "ui")
}

/// Best-effort breadcrumb writer into the unified `debug_log` table.
///
/// Live mode only: it needs a configured `SupabaseClient` AND an authenticated
/// session (the table's only client-facing RLS policy allows an authenticated
/// user to INSERT its own `surface='ios'` rows — it can never read the table
/// back). Fire-and-forget on a background task: it never throws and never
/// blocks the UI, exactly like the Edge Functions' swallow-on-error logger.
/// In demo/mock mode (`SupabaseConfig.isConfigured == false`) it's a no-op.
enum Observability {
    /// A row the iOS client is allowed to insert (surface pinned to "ios",
    /// user_id pinned to the caller — both enforced again by the RLS policy).
    private struct Breadcrumb: Encodable {
        let trace_id: String?
        let surface = "ios"
        let level: String
        let event: String
        let user_id: String
        let message: String?
        let data: [String: String]?
    }

    static func breadcrumb(
        _ event: String,
        level: String = "info",
        trace: Trace?,
        message: String? = nil,
        data: [String: String]? = nil
    ) {
        guard SupabaseConfig.isConfigured else { return }
        Task.detached(priority: .background) {
            do {
                let client = SupabaseClientProvider.shared
                // RLS pins user_id = auth.uid(); without a session the insert
                // can't pass the policy, so skip rather than spend a round-trip.
                guard let userID = try? await client.auth.session.user.id else { return }
                let row = Breadcrumb(
                    trace_id: trace?.id,
                    level: level,
                    event: event,
                    user_id: userID.uuidString,
                    message: message,
                    data: data
                )
                _ = try await client.from("debug_log").insert(row).execute()
            } catch {
                // Telemetry must never break UX — swallow every failure.
            }
        }
    }
}

/// Single shared `SupabaseClient` for the app.
///
/// Construction is deferred until `SupabaseConfig.isConfigured` is true (i.e. a
/// valid `Secrets.plist` is present). If you reach `shared` without configuring,
/// that's a programmer error — `ServiceContainer` only wires the live stack when
/// `isConfigured` is true, so the force-unwrap can never fire in practice.
enum SupabaseClientProvider {
    /// Custom URL scheme used as the OAuth redirect target. Must match the
    /// `CFBundleURLSchemes` entry registered in the app target and the redirect
    /// URL whitelisted in the Supabase dashboard (Auth → URL Configuration).
    static let redirectURL = URL(string: "someday://auth-callback")!

    static let shared: SupabaseClient = {
        guard let url = SupabaseConfig.url, let anonKey = SupabaseConfig.anonKey else {
            preconditionFailure("SupabaseClientProvider.shared accessed before Secrets.plist was configured.")
        }
        return SupabaseClient(
            supabaseURL: url,
            supabaseKey: anonKey,
            options: SupabaseClientOptions(
                auth: SupabaseClientOptions.AuthOptions(
                    redirectToURL: redirectURL,
                    flowType: .pkce
                )
            )
        )
    }()
}
