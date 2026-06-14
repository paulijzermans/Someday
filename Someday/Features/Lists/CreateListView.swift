import SwiftUI
import PhotosUI

/// Floating tile for creating a new list. The user picks a cover photo
/// (optional) and types a name, then taps Create to add it to their
/// collection. Uses `TileSize.half` so the bottom-half slide-up feels
/// closer to a sheet than a full-screen takeover.
struct CreateListView: View {
    /// Called when the user commits — `imageData` is JPEG/PNG bytes if a
    /// cover photo was picked, nil otherwise. The parent creates the
    /// list but does NOT dismiss this view: the user can still tap
    /// "Share list" afterwards. Dismissal flows through `onDismiss`.
    let onCreate: (_ name: String, _ imageData: Data?) -> Void
    /// Called when the user closes the view (× / tap-outside / scrim).
    /// The bool is true when the list was created during this session —
    /// parent uses that to decide whether to drop the user back on the
    /// Lists grid (true) or fully cancel out (false).
    let onDismiss: (_ didCreate: Bool) -> Void

    @State private var name: String = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var imageData: Data?
    @FocusState private var nameFocused: Bool
    /// Latched true once "Create list" is tapped. Drives the disabled
    /// state of Create (one-shot) and the lime/disabled state of Share
    /// (greyed until creation lands).
    @State private var hasCreated: Bool = false

    /// "Create list" is tappable when the name is non-empty AND we
    /// haven't already pressed it. Post-tap the CTA goes grey so the
    /// user knows the action is done while the view stays open for
    /// the Share affordance.
    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasCreated
    }

    /// Share is gated entirely by creation — until the user has tapped
    /// Create, the share text would describe a list that doesn't exist
    /// in the user's grid yet.
    private var canShare: Bool { hasCreated }

    /// What ShareLink hands to the OS share sheet. Plain text for now;
    /// adding a deep link later means tweaking this string.
    private var shareText: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Check out my '\(trimmed)' list on Someday!"
    }

    var body: some View {
        // The tile's tap-outside-to-dismiss path lives inside
        // `floatingTile`; we wrap it so the dismiss callback can report
        // whether the user already created a list before closing.
        tile.floatingTile(size: .large) { onDismiss(hasCreated) }
    }

    private var tile: some View {
        VStack(spacing: 16) {
            header
            coverPicker
            nameField
            Spacer(minLength: 4)
            // Two stacked CTAs: Create (primary, lime once name typed)
            // and Share (secondary, lime once create has been tapped).
            // Stacking lets each button keep full width, which makes the
            // active/disabled morph more visible than two side-by-side
            // pills.
            VStack(spacing: 10) {
                createButton
                shareButton
            }
        }
        .padding(20)
        // Glass + shadow + frame applied by `.floatingTile(size: .large)`.
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("New list")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(SomedayColors.charcoal)
            Spacer()
            Button { onDismiss(hasCreated) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(SomedayColors.grayMedium)
                    .frame(width: 28, height: 28)
                    .background(SomedayColors.grayLight)
                    .clipShape(Circle())
            }
        }
    }

    // MARK: - Cover photo

    /// Tappable rounded rectangle that opens the photo picker. Once an
    /// image is chosen the rectangle becomes a preview of the photo.
    private var coverPicker: some View {
        PhotosPicker(selection: $pickerItem, matching: .images) {
            ZStack {
                if let imageData, let uiImage = UIImage(data: imageData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 120)
                        .clipped()
                        .overlay(alignment: .bottomTrailing) {
                            // Small "edit" cue so users know the picker can be reopened.
                            Image(systemName: "pencil")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(SomedayColors.charcoal)
                                .frame(width: 28, height: 28)
                                .background(SomedayColors.anthropicWhite)
                                .clipShape(Circle())
                                .padding(10)
                        }
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundColor(SomedayColors.grayMedium)
                        Text("Add a cover photo")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(SomedayColors.grayMedium)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
                    .background(SomedayColors.grayLight)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(
                                SomedayColors.grayMedium.opacity(0.35),
                                style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                            )
                    )
                }
            }
            .cornerRadius(14)
        }
        .onChange(of: pickerItem) { _, newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self) {
                    imageData = data
                }
            }
        }
    }

    // MARK: - Name input

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Name")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(SomedayColors.grayMedium)
                .textCase(.uppercase)

            TextField("e.g. Hidden gems", text: $name)
                .font(.system(size: 16))
                .focused($nameFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(SomedayColors.anthropicWhite)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(SomedayColors.grayMedium.opacity(0.25), lineWidth: 1)
                )
        }
        .onAppear { nameFocused = true }
    }

    // MARK: - CTA

    /// Primary CTA that morphs through three states:
    ///   • Empty name      → "Create list", grey, disabled.
    ///   • Name typed      → "Create list", lime, taps fire `onCreate`.
    ///   • After create    → "Continue →", lime, taps fire `onDismiss(true)`
    ///                       so the user can skip the Share step and
    ///                       land back on the Lists grid.
    /// The morph keeps the same slot — one button, three meanings —
    /// rather than introducing a third row that would compete with
    /// Share visually.
    private var createButton: some View {
        let isPrimary = canCreate || hasCreated
        return Button {
            if hasCreated {
                // Continue mode: dismiss without sharing. Parent treats
                // `didCreate: true` as "land on Lists grid".
                onDismiss(true)
            } else {
                guard canCreate else { return }
                // Create mode: parent creates the list; we latch
                // `hasCreated` so this CTA flips to Continue and Share
                // wakes up in the same tap.
                onCreate(name, imageData)
                withAnimation(.easeInOut(duration: 0.25)) {
                    hasCreated = true
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(hasCreated ? "Continue" : "Create list")
                    .font(.system(size: 16, weight: .semibold))
                if hasCreated {
                    // Forward chevron makes "Continue" feel like a
                    // proceed-to-next-screen action rather than a
                    // generic confirm.
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .bold))
                }
            }
            .foregroundColor(isPrimary ? SomedayColors.charcoal : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(isPrimary ? SomedayColors.lime : SomedayColors.grayMedium.opacity(0.4))
            .cornerRadius(14)
        }
        // Disabled only when the name is empty AND we haven't created
        // yet — once hasCreated flips on, the button is always tappable
        // (it's now "Continue").
        .disabled(!isPrimary)
        .animation(.easeInOut(duration: 0.25), value: hasCreated)
    }

    /// "Share list" — uses SwiftUI's `ShareLink` so the OS share sheet
    /// pops directly on tap without us threading a separate sheet state
    /// through MapViewModel. The link is greyed and non-tappable until
    /// `hasCreated == true`, mirroring the Create CTA's pre-tap state.
    private var shareButton: some View {
        ShareLink(item: shareText) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .bold))
                Text("Share list")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(canShare ? SomedayColors.charcoal : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(canShare ? SomedayColors.lime : SomedayColors.grayMedium.opacity(0.4))
            .cornerRadius(14)
        }
        // SwiftUI honours `.disabled()` on ShareLink — the label is
        // still drawn but tapping is a no-op.
        .disabled(!canShare)
        // Belt-and-braces: even if SwiftUI changes its mind on .disabled
        // semantics for ShareLink, killing hit-testing guarantees the
        // pre-create state can't accidentally fire the share sheet.
        .allowsHitTesting(canShare)
        .animation(.easeInOut(duration: 0.25), value: canShare)
    }
}
