import SwiftUI

/// Generic "paste a link → we import the places" sheet used for both the
/// Google Maps and Instagram import flows. The two flows are visually
/// identical apart from header copy / tint, so we share the view and let
/// the parent inject a `LinkImportSource` describing the surface.
struct LinkImportView: View {
    let source: LinkImportSource
    /// URL handed in from outside (Share Extension, deep link) — pre-fills
    /// the field so the user just has to tap Import.
    var prefilledURL: String? = nil
    let onImport: ([Place]) -> Void
    let parseURL: (String) async throws -> [Place]

    @State private var urlText: String
    @State private var isLoading = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldFocused: Bool

    init(
        source: LinkImportSource,
        prefilledURL: String? = nil,
        onImport: @escaping ([Place]) -> Void,
        parseURL: @escaping (String) async throws -> [Place]
    ) {
        self.source = source
        self.prefilledURL = prefilledURL
        self.onImport = onImport
        self.parseURL = parseURL
        // Seed the text field directly from the prefilled URL — this fires
        // when the sheet first constructs the view, well before `onAppear`,
        // so external URLs (Share Extension, deep links) are always there
        // before the user sees the field.
        _urlText = State(initialValue: prefilledURL ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                header
                inputField
                ctaButton

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                        .padding(.horizontal, 4)
                }

                Spacer()
            }
            .padding(20)
            .background(SomedayColors.grayLight)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(SomedayColors.charcoal)
                            .frame(width: 32, height: 32)
                            .background(.white)
                            .clipShape(Circle())
                    }
                }
            }
            .onAppear { fieldFocused = true }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(source.tint.opacity(0.16))
                    .frame(width: 56, height: 56)
                Image(systemName: source.symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(source.tint)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(source.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(SomedayColors.charcoal)
                Text(source.subtitle)
                    .font(.system(size: 14))
                    .foregroundColor(SomedayColors.grayMedium)
            }
            Spacer()
        }
    }

    private var inputField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Share link")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(SomedayColors.grayMedium)
                .textCase(.uppercase)

            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 14))
                    .foregroundColor(SomedayColors.grayMedium)
                TextField(source.placeholder, text: $urlText, axis: .vertical)
                    .lineLimit(2)
                    .font(.system(size: 14))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .focused($fieldFocused)
                if !urlText.isEmpty {
                    Button { urlText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(SomedayColors.grayMedium)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.white)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(.systemGray5), lineWidth: 1)
            )
        }
    }

    private var ctaButton: some View {
        Button {
            Task { await runImport() }
        } label: {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .semibold))
                }
                Text(isLoading ? source.loadingLabel : "Import")
                    .font(.system(size: 16, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(canSubmit ? source.tint : SomedayColors.grayMedium.opacity(0.4))
            .foregroundColor(.white)
            .cornerRadius(12)
        }
        .disabled(!canSubmit || isLoading)
    }

    private var canSubmit: Bool {
        !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Pull the first URL out of arbitrary pasted text. Tolerates "Check
    /// this out: <url>" share-copy prefixes, bare domains without scheme.
    private func extractURL(from text: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        if let match = detector.firstMatch(in: text, range: range), let url = match.url {
            return url.absoluteString
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"^[\w.-]+\.[a-z]{2,}/"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return "https://\(trimmed)"
        }
        return nil
    }

    @MainActor
    private func runImport() async {
        guard let url = extractURL(from: urlText) else {
            errorMessage = "Couldn't find a URL in that text. Paste a share link."
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let parsed = try await parseURL(url)
            guard !parsed.isEmpty else {
                errorMessage = source.emptyMessage
                return
            }
            dismiss()
            try? await Task.sleep(nanoseconds: 250_000_000)
            onImport(parsed)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Source config

struct LinkImportSource {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let placeholder: String
    let loadingLabel: String
    let emptyMessage: String

    static let googleMaps = LinkImportSource(
        title: "Import from Google Maps",
        subtitle: "Paste a Google Maps share link.",
        symbol: "map.fill",
        tint: SomedayColors.accentGreen,
        placeholder: "https://maps.app.goo.gl/...",
        loadingLabel: "Extracting places…",
        emptyMessage: "No places found at that link."
    )

    static let instagram = LinkImportSource(
        title: "Import from Instagram",
        subtitle: "Paste a Reel or post link.",
        symbol: "camera.fill",
        tint: SomedayColors.coral,
        placeholder: "https://www.instagram.com/reel/...",
        loadingLabel: "Reading the caption…",
        emptyMessage: "No location was found — maybe you can find it in the comments. Paste that URL here."
    )
}
