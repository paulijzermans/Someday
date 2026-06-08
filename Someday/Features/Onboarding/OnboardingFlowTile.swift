import SwiftUI
import CoreLocation
import Contacts

/// First-run, in-map onboarding overlay. Replaces the standalone
/// `OnboardingView` carousel. Rendered as a large floating tile that
/// sits over the map and walks the user through four bite-sized steps:
///
///   1. Maps     — "Import from Google Maps"
///   2. Socials  — "Drop a Reel / TikTok / Facebook link"
///   3. Lists    — Inline AI-bordered textbox: paste any list of place
///                 names, hit "Find places", watch each pin land one by
///                 one inside this very tile.
///   4. Friends  — "Add the people who matter — and only them"
///
/// While the overlay is up, the map's external `ImportSummaryCardView`
/// is suppressed (`MapHomeView.importSummaryLayer` checks
/// `appState.isOnboarding`). Result rows for any import — sheet-based
/// (Maps / Socials) or inline (Lists) — surface inside the tile.
struct OnboardingFlowTile: View {
    let appState: AppState
    @Bindable var vm: MapViewModel

    /// 0…3 — index into `OnboardingStep.all`.
    @State private var step: Int = 0
    /// True for ~1.4s after a sheet-based import succeeds: shows the
    /// celebratory "Awesome — next step" panel, hides the regular
    /// CTAs, then auto-advances. Not used for the inline list step,
    /// which has its own staggered reveal.
    @State private var celebrating: Bool = false
    /// Snapshot of `vm.places.count` taken when each step appears.
    /// Used to detect "a sheet-based import landed during this step"
    /// without callbacks from the import flows.
    @State private var placesAtStepStart: Int = 0
    /// True after the user explicitly opens an import sheet on the
    /// current step. The `.onChange(of: vm.places.count)` handler only
    /// fires the celebrate path while this is true, so async place loads
    /// happening on first launch — which would otherwise look like an
    /// import landed — can't auto-advance past step 0.
    @State private var awaitingImport: Bool = false

    // --- Inline list step (#2) state ---

    /// Raw text the user pasted in the list step's AI-bordered editor.
    @State private var listText: String = ""
    /// True while the per-line geocoder is running. Disables the CTA.
    @State private var isExtractingList: Bool = false
    /// Places the geocoder has produced so far, in the order they came
    /// back. Each one is appended with a haptic + spring transition so
    /// the user sees them pop in.
    @State private var extractedPlaces: [Place] = []

    // --- Friends step (#3) state ---

    /// Loading lifecycle for the friend-discovery flow.
    @State private var friendsState: FriendsStepState = .idle
    /// Matched profiles surfaced by the Edge Function.
    @State private var matches: [MatchedContact] = []
    /// Profile IDs the user has already tapped "Add" on this session,
    /// so the row stays in a sent state even after the request lands.
    @State private var sentRequestIDs: Set<String> = []

    private enum FriendsStepState: Equatable {
        case idle
        case requestingPermission
        case scanning
        case noMatches
        case denied
        case showingMatches
        case errored(String)
    }

    // --- AI gradient border state (matches aiChatBar) ---

    @State private var aiBorderStart: UnitPoint = .topLeading
    @State private var aiBorderEnd: UnitPoint = .bottomTrailing
    @State private var aiBorderOpacity: Double = 0.55

    var body: some View {
        tileBody
            .floatingTile(size: .large, onDismiss: {
                // Onboarding can't be casually dismissed — tapping the
                // scrim shouldn't bail the user out mid-flow. The
                // floating-tile container hands us an `onDismiss`
                // callback we just no-op, so the scrim is decorative
                // only. The final step's CTA is the only exit.
            })
            .onAppear {
                placesAtStepStart = vm.places.count
                startBorderAnimation()
                // Pre-create the auto-bucket list so the first import
                // can drop into it without an additional round-trip.
                // Idempotent — picks up an existing row if onboarding
                // was previously partially completed.
                vm.ensureOnboardingFirstList()
            }
            // Sheet-based steps (Maps / Socials) — when the import
            // sheet completes, `vm.places` grows. We pick that up
            // here, bucket the new pins into the "My first places"
            // list, and celebrate + advance.
            //
            // The `awaitingImport` guard is critical: without it, the
            // very first `vm.loadData()` async result (which fills
            // `places` from 0 to N on cold launch) would look like a
            // freshly-completed import and auto-advance the user past
            // step 0 before they ever see it.
            //
            // Inline list step (#2) buckets directly from its own
            // extraction Task and never sets `awaitingImport`.
            .onChange(of: vm.places.count) { oldCount, newCount in
                guard awaitingImport else {
                    // Loose tracking: keep the baseline in lockstep with
                    // any non-import place growth so a later import
                    // measures from the right point.
                    placesAtStepStart = newCount
                    return
                }
                guard step == 0 || step == 1 else { return }
                guard newCount > placesAtStepStart, !celebrating else { return }
                // Take the newest pins (everything added since the step
                // started) and bucket them into the auto-list. `vm.places`
                // appends new pins at the end of the array, so the tail
                // slice is what just arrived.
                let added = Array(vm.places.suffix(newCount - placesAtStepStart))
                vm.addToOnboardingFirstList(added)
                awaitingImport = false
                celebrate()
            }
    }

    // MARK: - Big-tile body

    private var tileBody: some View {
        VStack(spacing: 0) {
            // Top: progress + step icon + skip
            VStack(spacing: 16) {
                topBar
                stepIcon
            }
            .padding(.top, 22)
            .padding(.horizontal, 22)

            // Middle: scrolling step content fills the tile vertically.
            ScrollView {
                if celebrating {
                    celebrationContent
                        .padding(.top, 28)
                } else {
                    stepContent
                        .padding(.horizontal, 22)
                        .padding(.top, 20)
                        .padding(.bottom, 28)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: step)
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: celebrating)
        }
    }

    // MARK: - Top bar (progress + skip)

    private var topBar: some View {
        HStack {
            progressDots
            Spacer()
            // Last step has no "Skip" — there's no further step to go to.
            if step < OnboardingStep.all.count - 1 {
                Button(action: advance) {
                    Text("Skip")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(SomedayColors.grayMedium)
                }
            }
        }
    }

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<OnboardingStep.all.count, id: \.self) { i in
                Capsule()
                    .fill(i == step ? SomedayColors.green : SomedayColors.grayMedium.opacity(0.3))
                    .frame(width: i == step ? 22 : 6, height: 6)
                    .animation(.easeInOut(duration: 0.2), value: step)
            }
        }
    }

    private var stepIcon: some View {
        let s = OnboardingStep.all[step]
        return ZStack {
            Circle()
                .fill(SomedayColors.green.opacity(0.18))
                .frame(width: 68, height: 68)
            Image(systemName: s.icon)
                .font(.system(size: 30, weight: .semibold))
                .foregroundColor(SomedayColors.greenDark)
        }
    }

    // MARK: - Step content (router)

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 0: mapsStep
        case 1: socialsStep
        case 2: listsStep
        default: friendsStep
        }
    }

    // MARK: - Steps 0 and 1 (sheet-based)

    private var mapsStep: some View {
        sheetStepContent(
            title: OnboardingStep.all[0].title,
            body: OnboardingStep.all[0].body,
            primaryCTA: OnboardingStep.all[0].primaryCTA
        ) {
            // Snapshot the current count + arm the import-detection
            // watcher right before we open the sheet — that way the
            // celebrate path knows the next place-count growth is
            // attributable to this import, not background loading.
            placesAtStepStart = vm.places.count
            awaitingImport = true
            vm.showMapsImport = true
        }
    }

    private var socialsStep: some View {
        sheetStepContent(
            title: OnboardingStep.all[1].title,
            body: OnboardingStep.all[1].body,
            primaryCTA: OnboardingStep.all[1].primaryCTA
        ) {
            placesAtStepStart = vm.places.count
            awaitingImport = true
            vm.showSocialsImport = true
        }
    }

    /// Shared layout for the two sheet-based steps. The CTA opens the
    /// matching existing import sheet (`vm.show…Import`). The big tile
    /// stays put underneath; when the sheet dismisses, `.onChange(of:
    /// vm.places.count)` picks up any new pins and celebrates.
    @ViewBuilder
    private func sheetStepContent(
        title: String,
        body: String,
        primaryCTA: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 18) {
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(SomedayColors.charcoal)
                .multilineTextAlignment(.center)
            Text(body)
                .font(.system(size: 15))
                .foregroundColor(SomedayColors.grayMedium)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 6)

            Spacer(minLength: 40)

            VStack(spacing: 10) {
                Button {
                    Haptics.tap()
                    action()
                } label: {
                    Text(primaryCTA)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(SomedayColors.green)
                        .foregroundColor(.white)
                        .cornerRadius(16)
                }
                Button("Later", action: advance)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(SomedayColors.grayMedium)
                    .padding(.vertical, 6)
            }
        }
    }

    // MARK: - Step 2 (inline list extraction)
    //
    // Embedded TextEditor wearing the same animated AI gradient border
    // as the aiChatBar. Submit triggers per-line CLGeocoder lookups;
    // each successful result is appended to `extractedPlaces` with a
    // haptic tick and a spring transition so the row pops into place.

    private var listsStep: some View {
        VStack(spacing: 16) {
            Text(OnboardingStep.all[2].title)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(SomedayColors.charcoal)
                .multilineTextAlignment(.center)
            Text("Paste any list — WhatsApp, notes, anything. One place per line.")
                .font(.system(size: 14))
                .foregroundColor(SomedayColors.grayMedium)
                .multilineTextAlignment(.center)
                .lineSpacing(2)

            aiBorderedEditor

            findPlacesButton

            // Skip out of this step without pasting anything. Mirrors
            // the "Later" affordance on the Maps / Socials steps —
            // some users genuinely don't have a list to drop and were
            // getting stuck on a screen they couldn't dismiss.
            Button("Later", action: advance)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(SomedayColors.grayMedium)
                .padding(.vertical, 6)

            // Results pop in one by one as the geocoder lands them.
            // Each row uses an asymmetric move+fade so the visual
            // matches the haptic tick.
            if !extractedPlaces.isEmpty {
                VStack(spacing: 8) {
                    ForEach(extractedPlaces, id: \.id) { place in
                        extractedRow(place)
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }
                }
            }
        }
    }

    /// TextEditor with the same animated gradient border as the
    /// aiChatBar — the "AI is listening" cue. Endpoints rotate slowly
    /// between corners; the colour set matches (violet → primary → pink).
    private var aiBorderedEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $listText)
                .font(.system(size: 16))
                .frame(minHeight: 130, maxHeight: 200)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(SomedayColors.grayLight.opacity(0.5))
                .cornerRadius(16)
            if listText.isEmpty {
                Text("Cafe de Klepel\nFoodhallen\nBar Centraal\n…")
                    .font(.system(size: 16))
                    .foregroundColor(SomedayColors.grayMedium.opacity(0.6))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 18)
                    .allowsHitTesting(false)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color(red: 0.55, green: 0.45, blue: 1.0).opacity(aiBorderOpacity),
                            SomedayColors.primary.opacity(aiBorderOpacity),
                            Color(red: 1.0, green: 0.45, blue: 0.80).opacity(aiBorderOpacity)
                        ],
                        startPoint: aiBorderStart,
                        endPoint: aiBorderEnd
                    ),
                    lineWidth: 1.8
                )
        )
    }

    /// "Find places" CTA. Disabled while extracting or while the box
    /// is empty. Sparkles glyph matches the AI motif everywhere else.
    private var findPlacesButton: some View {
        let lineCount = listText
            .split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
        let enabled = lineCount > 0 && !isExtractingList
        return Button {
            Task { await extractList() }
        } label: {
            HStack(spacing: 8) {
                if isExtractingList {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .bold))
                }
                Text(
                    isExtractingList
                        ? "Finding places…"
                        : "Find \(lineCount > 0 ? "\(lineCount) " : "")\(lineCount == 1 ? "place" : "places")"
                )
                .font(.system(size: 16, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(enabled ? SomedayColors.green : SomedayColors.grayMedium.opacity(0.5))
            .foregroundColor(.white)
            .cornerRadius(14)
        }
        .disabled(!enabled)
    }

    /// Compact row used by the inline list step to show each extracted
    /// place. Visually mirrors the ImportSummaryCardView's `placeRow`
    /// so the muscle memory is consistent.
    private func extractedRow(_ place: Place) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(SomedayColors.green.opacity(0.16))
                    .frame(width: 40, height: 40)
                Image(systemName: place.category.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SomedayColors.greenDark)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(place.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(SomedayColors.charcoal)
                    .lineLimit(1)
                Text(place.neighborhood.isEmpty ? "Found" : place.neighborhood)
                    .font(.system(size: 11))
                    .foregroundColor(SomedayColors.grayMedium)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(SomedayColors.green)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.white)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
    }

    // MARK: - Step 3 (friends — contact discovery)
    //
    // Four micro-states the user can be in:
    //   • idle             — haven't asked for permission yet. Show the
    //                         "Find friends from Contacts" CTA.
    //   • scanning         — permission granted, hashing + matching.
    //   • showingMatches   — have a list of MatchedContact rows.
    //   • noMatches/denied — empty / blocked. Show explanation + Done.
    //   • errored          — network blew up. Allow retry.

    private var friendsStep: some View {
        VStack(spacing: 20) {
            Text(OnboardingStep.all[3].title)
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(SomedayColors.charcoal)
                .multilineTextAlignment(.center)
            Text(OnboardingStep.all[3].body)
                .font(.system(size: 15))
                .foregroundColor(SomedayColors.grayMedium)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 6)

            friendsStateContent

            // "Done" is always reachable so the user is never trapped
            // on the friends step. It completes onboarding regardless
            // of whether they sent any requests.
            Button {
                Haptics.tap()
                appState.completeOnboarding()
            } label: {
                Text(friendsState == .showingMatches ? "Done" : OnboardingStep.all[3].primaryCTA)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(friendsState == .showingMatches
                                ? SomedayColors.grayMedium
                                : SomedayColors.green)
                    .foregroundColor(.white)
                    .cornerRadius(16)
            }
        }
    }

    @ViewBuilder
    private var friendsStateContent: some View {
        switch friendsState {
        case .idle:
            findFromContactsButton
                .padding(.top, 10)

        case .requestingPermission, .scanning:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .tint(SomedayColors.green)
                Text(friendsState == .requestingPermission
                     ? "Asking for permission…"
                     : "Checking your contacts…")
                    .font(.system(size: 13))
                    .foregroundColor(SomedayColors.grayMedium)
            }
            .padding(.top, 24)

        case .noMatches:
            VStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 28))
                    .foregroundColor(SomedayColors.grayMedium)
                Text("No matches yet")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(SomedayColors.charcoal)
                Text("None of your contacts are on Someday yet. Invite them — it's nicer with people.")
                    .font(.system(size: 12))
                    .foregroundColor(SomedayColors.grayMedium)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
            .padding(.top, 20)

        case .denied:
            VStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 24))
                    .foregroundColor(SomedayColors.grayMedium)
                Text("Contacts permission off")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(SomedayColors.charcoal)
                Text("You can turn it on later in Settings → Privacy → Contacts → Someday.")
                    .font(.system(size: 12))
                    .foregroundColor(SomedayColors.grayMedium)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
            .padding(.top, 20)

        case .errored(let msg):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.orange)
                Text("Couldn't load matches")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(SomedayColors.charcoal)
                Text(msg)
                    .font(.system(size: 11))
                    .foregroundColor(SomedayColors.grayMedium)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                findFromContactsButton
                    .padding(.top, 8)
            }

        case .showingMatches:
            matchesList
        }
    }

    /// Primary CTA to start the discovery flow. Same green button
    /// language as the other primary CTAs in onboarding.
    private var findFromContactsButton: some View {
        Button {
            Task { await startFriendDiscovery() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 14, weight: .bold))
                Text("Find friends from Contacts")
                    .font(.system(size: 16, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(SomedayColors.green.opacity(0.18))
            .foregroundColor(SomedayColors.greenDark)
            .cornerRadius(14)
        }
    }

    /// Vertical list of matched profiles, each with an "Add" button
    /// that sends a friend request. Once sent, the button locks into a
    /// "Sent" pill so the user can see who they've already invited.
    private var matchesList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(matches.count) on Someday")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(SomedayColors.grayMedium)
                Spacer()
                Text("Add the ones you love.")
                    .font(.system(size: 11))
                    .foregroundColor(SomedayColors.grayMedium)
            }

            VStack(spacing: 8) {
                ForEach(matches) { match in
                    matchRow(match)
                }
            }
        }
    }

    private func matchRow(_ match: MatchedContact) -> some View {
        let isSent = sentRequestIDs.contains(match.id)
        return HStack(spacing: 12) {
            AsyncImage(url: match.avatarURL) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                default:
                    Circle().fill(SomedayColors.green.opacity(0.18))
                        .overlay(
                            Text(match.name.first.map(String.init) ?? "?")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(SomedayColors.greenDark)
                        )
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(match.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(SomedayColors.charcoal)
                Text("Matched via \(match.matchedBy.rawValue)")
                    .font(.system(size: 11))
                    .foregroundColor(SomedayColors.grayMedium)
            }
            Spacer()

            Button {
                Task { await sendRequest(to: match) }
            } label: {
                Text(isSent ? "Sent" : "Add")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(isSent ? SomedayColors.grayLight : SomedayColors.green)
                    .foregroundColor(isSent ? SomedayColors.grayMedium : .white)
                    .cornerRadius(10)
            }
            .disabled(isSent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.white)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
    }

    // MARK: - Friend discovery flow

    @MainActor
    private func startFriendDiscovery() async {
        let svc = appState.services.contacts

        // Walk the permission ladder.
        switch svc.authorizationStatus() {
        case .authorized:
            await runDiscovery(svc)
        case .denied, .restricted:
            friendsState = .denied
        case .notDetermined:
            friendsState = .requestingPermission
            let newStatus = await svc.requestAuthorization()
            if newStatus == .authorized {
                await runDiscovery(svc)
            } else {
                friendsState = .denied
            }
        @unknown default:
            friendsState = .errored("Unexpected permission state.")
        }
    }

    @MainActor
    private func runDiscovery(_ svc: ContactsServiceProtocol) async {
        friendsState = .scanning
        do {
            let hashes = try await svc.collectContactHashes()
            if hashes.isEmpty {
                friendsState = .noMatches
                return
            }
            let found = try await svc.findMatches(hashes)
            if found.isEmpty {
                friendsState = .noMatches
            } else {
                matches = found
                friendsState = .showingMatches
                Haptics.success()
            }
        } catch {
            #if DEBUG
            print("[OnboardingFlowTile] runDiscovery failed: \(error)")
            #endif
            friendsState = .errored(friendlyMessage(for: error))
        }
    }

    /// Best-effort translation of the various low-level errors the
    /// discovery pipeline can throw into something a user can act on.
    private func friendlyMessage(for error: Error) -> String {
        let raw = error.localizedDescription.lowercased()
        // The Supabase functions client throws this when the user isn't
        // signed in (no JWT) or the function returns 4xx. Worth calling
        // out separately because the cause-and-fix differ.
        if raw.contains("non-2xx") || raw.contains("functionshttp") || raw.contains("invalid jwt") {
            return "We couldn't reach the matching service. Confirm your email first, then try again."
        }
        if raw.contains("not authorized") || raw.contains("not authenticated") {
            return "Please sign in again to find friends."
        }
        return error.localizedDescription
    }

    @MainActor
    private func sendRequest(to match: MatchedContact) async {
        Haptics.tap()
        sentRequestIDs.insert(match.id)
        do {
            try await appState.services.contacts.sendFriendRequest(toUserID: match.id)
        } catch {
            // Roll back the "Sent" state on failure so the user can
            // retry. Failures here are silent — surfacing each one
            // would clutter the flow.
            sentRequestIDs.remove(match.id)
            Haptics.error()
            #if DEBUG
            print("[OnboardingFlowTile] sendFriendRequest failed: \(error)")
            #endif
        }
    }

    // MARK: - Celebration

    private var celebrationContent: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(SomedayColors.green.opacity(0.18))
                    .frame(width: 88, height: 88)
                Image(systemName: "sparkles")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundColor(SomedayColors.greenDark)
            }
            Text("Awesome — next step")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(SomedayColors.charcoal)
            Text("Your pins are on the map.")
                .font(.system(size: 14))
                .foregroundColor(SomedayColors.grayMedium)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 40)
    }

    // MARK: - Actions

    /// "Skip"/"Later" path — advance silently without celebration.
    private func advance() {
        Haptics.tap()
        guard step < OnboardingStep.all.count - 1 else {
            appState.completeOnboarding()
            return
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
            step += 1
            placesAtStepStart = vm.places.count
            awaitingImport = false
            // Reset list step state when leaving it so re-entering
            // (unlikely but possible) starts clean.
            listText = ""
            extractedPlaces = []
        }
    }

    /// Sheet-import success path — celebrate then advance.
    private func celebrate() {
        Haptics.importBurst()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
            celebrating = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1400))
            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                celebrating = false
                if step < OnboardingStep.all.count - 1 {
                    step += 1
                }
                placesAtStepStart = vm.places.count
            }
        }
    }

    /// Inline list extraction. Splits the pasted text into non-empty
    /// lines, runs CLGeocoder per line, and appends successful results
    /// to `extractedPlaces` with a haptic tick. Pins are also pushed
    /// onto the map via `vm.importPlaces` so the user's actual map
    /// state grows. When done, the burst haptic fires and we advance.
    @MainActor
    private func extractList() async {
        let lines = listText
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }

        // Use Amsterdam centroid as a geocoder bias point so vague
        // names ("Foodhallen") resolve to the right city instead of
        // the global default. Future iteration: read user's current
        // map region from `vm.region` and bias to that center.
        let bias = CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: vm.region.center.latitude,
                                           longitude: vm.region.center.longitude),
            radius: 50_000,
            identifier: "onboardingBias"
        )

        isExtractingList = true
        extractedPlaces = []
        let geocoder = CLGeocoder()
        let ownerID = appState.currentUser?.id ?? ""

        for line in lines {
            do {
                let marks = try await geocoder.geocodeAddressString(line, in: bias)
                guard let mark = marks.first, let loc = mark.location else { continue }
                let place = Place(
                    name: line,
                    category: .food,
                    latitude: loc.coordinate.latitude,
                    longitude: loc.coordinate.longitude,
                    source: .manual,
                    neighborhood: mark.locality ?? mark.country ?? "",
                    isSaved: true,
                    ownerID: ownerID
                )
                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                    extractedPlaces.append(place)
                }
                Haptics.importTick()
            } catch {
                // Skip lines we can't geocode — don't surface per-line
                // errors during onboarding.
            }
        }
        isExtractingList = false

        // Push the extracted pins into the real map state AND drop them
        // into the auto-created onboarding bucket list so the user has
        // a populated list when they exit the flow.
        if !extractedPlaces.isEmpty {
            await vm.importPlaces(extractedPlaces)
            vm.addToOnboardingFirstList(extractedPlaces)
            Haptics.importBurst()
            try? await Task.sleep(for: .milliseconds(1400))
            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                if step < OnboardingStep.all.count - 1 {
                    step += 1
                }
                placesAtStepStart = vm.places.count
                listText = ""
                extractedPlaces = []
            }
        } else {
            // Nothing geocoded — quiet warning, let the user try again.
            Haptics.warning()
        }
    }

    /// Same animation as the aiChatBar's border — rotates endpoints
    /// between top-leading ↔ bottom-trailing on a slow ease-in-out
    /// repeat. Gives the "AI is alive" cue the search bar already has.
    private func startBorderAnimation() {
        withAnimation(.easeInOut(duration: 3.5).repeatForever(autoreverses: true)) {
            aiBorderStart = .bottomTrailing
            aiBorderEnd = .topLeading
            aiBorderOpacity = 0.85
        }
    }
}

// MARK: - Step model

/// Static copy for each onboarding step.
private struct OnboardingStep {
    let icon: String
    let title: String
    let body: String
    let primaryCTA: String

    static let all: [OnboardingStep] = [
        OnboardingStep(
            icon: "map.fill",
            title: "Start with Google Maps",
            body: "Bring in the places you've already saved on Google Maps. We'll pin them on your Someday map in seconds.",
            primaryCTA: "Import from Maps"
        ),
        OnboardingStep(
            icon: "square.and.arrow.up.fill",
            title: "Got Reels or TikToks saved?",
            body: "Paste a link from Instagram, TikTok or Facebook. The AI extracts the place and drops a pin for you.",
            primaryCTA: "Share something"
        ),
        OnboardingStep(
            icon: "list.bullet.rectangle.fill",
            title: "Drop a list",
            body: "",
            primaryCTA: "Find places"
        ),
        OnboardingStep(
            icon: "heart.fill",
            title: "Add the people who matter",
            body: "Your loved ones, not your acquaintances. Someday isn't a social media platform — it's a place to share with the few you really care about.",
            primaryCTA: "Let's go!"
        ),
    ]
}
