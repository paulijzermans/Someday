import SwiftUI

// =============================================================================
// AIAssistantSettingsView — user-tunable guardrails for the chat assistant
// =============================================================================
//
// Form-style page reachable from Profile → "AI assistant". Mutations
// write through to UserDefaults via `AISettingsStore.shared`, so any
// chat request fired after this page closes picks up the new values
// automatically (the iOS side passes the snapshot into `ChatContext`,
// the Edge Function templates it into the system prompt).
//
// Keep this tight. Each field is also a sentence the model has to
// honour, so a too-busy form == a confused assistant.

struct AIAssistantSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    /// Bound directly to the shared store so toggles persist live.
    /// `@Bindable` because `AISettingsStore` is `@Observable`.
    @Bindable private var store = AISettingsStore.shared

    /// Confirmation state for the destructive "Reset" action — modeled
    /// as alert state rather than an inline toggle so the user can't
    /// nuke their settings with a single tap.
    @State private var showResetConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                toneSection
                recommendationsSection
                replyShapeSection
                customInstructionsSection
                resetSection
            }
            .scrollContentBackground(.hidden)
            .background(SomedayColors.anthropicWhite)
            .navigationTitle("AI assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(SomedayColors.charcoal)
                            .frame(width: 32, height: 32)
                            .background(Color.white)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
                    }
                }
            }
            .alert("Reset AI settings?", isPresented: $showResetConfirm) {
                Button("Reset", role: .destructive) {
                    store.resetToDefaults()
                    Haptics.soft()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This restores the default tone, recommendation rules, and clears your custom instructions.")
            }
        }
    }

    // MARK: - Tone

    private var toneSection: some View {
        Section {
            Picker("Tone", selection: $store.settings.tone) {
                ForEach(AIAssistantTone.allCases) { tone in
                    Text(tone.displayName).tag(tone)
                }
            }
            .pickerStyle(.segmented)

            Text(store.settings.tone.blurb)
                .font(.system(size: 12))
                .foregroundColor(SomedayColors.grayMedium)
        } header: {
            sectionHeader("Tone")
        } footer: {
            Text("Sets the rough length and style of every reply.")
                .font(.system(size: 12))
                .foregroundColor(SomedayColors.grayMedium)
        }
    }

    // MARK: - Recommendations

    private var recommendationsSection: some View {
        Section {
            Toggle(isOn: $store.settings.allowExternalRecommendations) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Suggest new places")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Recommend real venues you haven't saved yet, labelled as suggestions.")
                        .font(.system(size: 12))
                        .foregroundColor(SomedayColors.grayMedium)
                }
            }

            Toggle(isOn: $store.settings.anchorOnSelectedPin) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Anchor on selected pin")
                        .font(.system(size: 15, weight: .semibold))
                    Text("\"Around here\" means around the pin you have open — not the map centre.")
                        .font(.system(size: 12))
                        .foregroundColor(SomedayColors.grayMedium)
                }
            }
        } header: {
            sectionHeader("Recommendations")
        }
    }

    // MARK: - Reply shape

    private var replyShapeSection: some View {
        Section {
            Stepper(value: $store.settings.maxPlacesPerAnswer, in: 3...10) {
                HStack {
                    Text("Max places per answer")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("\(store.settings.maxPlacesPerAnswer)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(SomedayColors.primary)
                        .monospacedDigit()
                }
            }
        } header: {
            sectionHeader("Reply shape")
        } footer: {
            Text("Hard ceiling on how many places get listed in a single reply.")
                .font(.system(size: 12))
                .foregroundColor(SomedayColors.grayMedium)
        }
    }

    // MARK: - Custom instructions

    private var customInstructionsSection: some View {
        Section {
            TextEditor(text: $store.settings.customInstructions)
                .frame(minHeight: 90)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    // Placeholder — TextEditor doesn't ship with one.
                    if store.settings.customInstructions.isEmpty {
                        Text("e.g. \"I'm vegetarian — flag meat-heavy places.\"")
                            .font(.system(size: 14))
                            .foregroundColor(SomedayColors.grayMedium.opacity(0.7))
                            .padding(.top, 8)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                }
                // Hard cap so the user can't blow the system-prompt
                // budget. Trim is non-destructive — we just drop trailing
                // characters as they type past the limit.
                .onChange(of: store.settings.customInstructions) { _, newValue in
                    if newValue.count > 280 {
                        store.settings.customInstructions = String(newValue.prefix(280))
                    }
                }

            HStack {
                Spacer()
                Text("\(store.settings.customInstructions.count) / 280")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(SomedayColors.grayMedium)
                    .monospacedDigit()
            }
        } header: {
            sectionHeader("Custom instructions")
        } footer: {
            Text("Added to every reply's system prompt. Keep it specific — \"prefer quiet spots\" beats \"be helpful\".")
                .font(.system(size: 12))
                .foregroundColor(SomedayColors.grayMedium)
        }
    }

    // MARK: - Reset

    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                showResetConfirm = true
            } label: {
                HStack {
                    Image(systemName: "arrow.counterclockwise")
                    Text("Reset to defaults")
                        .font(.system(size: 15, weight: .semibold))
                }
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(SomedayColors.grayMedium)
            .textCase(.uppercase)
    }
}
