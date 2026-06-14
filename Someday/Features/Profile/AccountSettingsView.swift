import SwiftUI

// =============================================================================
// AccountSettingsView — display name, contact info, and map preferences
// =============================================================================
//
// Two distinct kinds of state live on this screen:
//
//   • Profile fields (name, phone, email) — server-stored on the
//     `profiles` table. Edits flow through `UserService.updateProfile`.
//     Phone is the field that, when populated, unlocks the phone-half of
//     contact-discovery — the DB trigger hashes the new value on write so
//     the user becomes discoverable to contacts who have their number.
//
//   • Map preferences (type, default zoom, traffic, POI) — local-only,
//     stored in `SomedayPreferences` (UserDefaults). These don't need to
//     follow the user across devices.
//
// The screen is a plain Form so the platform takes care of grouping,
// keyboard avoidance, and the readonly/editable affordance distinction.

struct AccountSettingsView: View {
    @Bindable var appState: AppState
    @Environment(SomedayPreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss

    // Local working copies — only pushed up to `currentUser` on Save so
    // an in-progress edit can be cancelled cleanly. Initialised from
    // `currentUser` in `.onAppear`.
    @State private var nameDraft: String = ""
    @State private var phoneDraft: String = ""

    @State private var isSaving = false
    @State private var saveError: String?

    @FocusState private var focusedField: Field?
    private enum Field { case name, phone }

    var body: some View {
        NavigationStack {
            // `@Environment(_:)` bag → grab a Bindable copy so the toggles
            // / pickers below can two-way bind into prefs directly.
            @Bindable var prefs = preferences

            Form {
                profileSection
                mapSection(prefs: prefs)
                signOutSection
            }
            // Cream canvas so the Form's grouped sections read as the same
            // clean white tiles as the Profile page (TileStyle.swift), not
            // the stock grey grouped-list background.
            .scrollContentBackground(.hidden)
            .background(SomedayColors.anthropicWhite)
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onAppear(perform: loadDrafts)
            .alert("Couldn't save", isPresented: errorAlertBinding) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    // MARK: - Sections

    private var profileSection: some View {
        Section {
            HStack {
                Text("Display name")
                    .foregroundColor(SomedayColors.grayMedium)
                Spacer()
                TextField("Your name", text: $nameDraft)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
                    .focused($focusedField, equals: .name)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .phone }
            }

            HStack {
                Text("Phone")
                    .foregroundColor(SomedayColors.grayMedium)
                Spacer()
                TextField("+31 6 12 34 56 78", text: $phoneDraft)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .focused($focusedField, equals: .phone)
            }

            HStack {
                Text("Email")
                    .foregroundColor(SomedayColors.grayMedium)
                Spacer()
                Text(appState.currentUser?.email ?? "—")
                    .foregroundColor(SomedayColors.charcoal)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } header: {
            Text("Profile")
        } footer: {
            Text("Adding a phone number lets friends who have your number find you on Someday. Your number is hashed on this device — the server never sees it in the clear.")
        }
    }

    private func mapSection(prefs: SomedayPreferences) -> some View {
        Section {
            Picker("Map type", selection: Binding(
                get: { prefs.mapType },
                set: { prefs.mapType = $0 }
            )) {
                ForEach(SomedayPreferences.MapType.allCases, id: \.self) { value in
                    Text(value.displayName).tag(value)
                }
            }

            Picker("Default zoom", selection: Binding(
                get: { prefs.defaultZoom },
                set: { prefs.defaultZoom = $0 }
            )) {
                ForEach(SomedayPreferences.DefaultZoom.allCases, id: \.self) { value in
                    Text(value.displayName).tag(value)
                }
            }

            Toggle("Show traffic", isOn: Binding(
                get: { prefs.showTraffic },
                set: { prefs.showTraffic = $0 }
            ))

            Toggle("Show nearby places", isOn: Binding(
                get: { prefs.showPOI },
                set: { prefs.showPOI = $0 }
            ))
        } header: {
            Text("Map")
        } footer: {
            Text("Nearby places adds Apple's points of interest underneath your own pins. Off keeps the map focused on what you and your friends curated.")
        }
    }

    private var signOutSection: some View {
        Section {
            Button(role: .destructive) {
                appState.signOut()
                dismiss()
            } label: {
                HStack {
                    Spacer()
                    Text("Sign out")
                        .fontWeight(.semibold)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task { await save() }
            } label: {
                if isSaving {
                    ProgressView()
                } else {
                    Text("Save").fontWeight(.semibold)
                }
            }
            .disabled(isSaving || !hasChanges)
        }
    }

    // MARK: - Drafts / save

    private var hasChanges: Bool {
        let originalName = appState.currentUser?.name ?? ""
        return nameDraft != originalName || !phoneDraft.isEmpty
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )
    }

    private func loadDrafts() {
        if let user = appState.currentUser {
            nameDraft = user.name
        }
        // Phone isn't on UserProfile (it's a server-only field used for
        // hashing). Left blank by default — if the user types one we'll
        // ship it on save.
    }

    private func save() async {
        guard let user = appState.currentUser else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            let updated = try await appState.services.users.updateProfile(
                userID: user.id,
                name: nameDraft,
                phone: phoneDraft.isEmpty ? nil : phoneDraft
            )
            appState.currentUser = updated
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
