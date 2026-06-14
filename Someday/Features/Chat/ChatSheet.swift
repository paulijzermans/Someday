import SwiftUI

// =============================================================================
// ChatSheet — full-screen modal chat with context-aware AI
// =============================================================================
//
// Triggered from the aiChatBar's sparkles icon in MapHomeView. Slides up
// as a `.sheet(...)` modal so it sits above everything (map, tiles, the
// AI Availability bar) without fighting them for z-order.
//
// State lives on `ChatViewModel`: messages, in-flight flag, the input
// field's text. The VM owns the `ChatService` reference and builds a
// fresh `ChatContext` for every send via the closure the parent passes
// in — that closure reads the latest `MapViewModel.places / customLists /
// friends` so the model always gets the user's current data.
//
// V1 is blocking (no streaming) and ephemeral (no persistence): close the
// sheet and the conversation is gone. Both are easy to upgrade later.

struct ChatSheet: View {
    @State var viewModel: ChatViewModel
    let onDismiss: () -> Void
    /// Optional message to auto-send when the sheet first appears.
    /// Used when the user types a question into the top-right AI search
    /// bar and hits Return — the sheet opens and immediately starts
    /// answering, instead of dropping them on an empty input.
    var initialPrompt: String? = nil

    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if viewModel.messages.isEmpty {
                    emptyState
                } else {
                    messageList
                }
                inputBar
            }
            .background(SomedayColors.anthropicWhite.ignoresSafeArea())
            .navigationTitle("Ask Someday")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onDismiss) {
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
        }
        .onAppear {
            // Auto-send a prompt passed in from the launcher (e.g. the
            // top-right AI search bar). Done before focusing the input
            // so the keyboard doesn't pop up during the AI's reply.
            if let prompt = initialPrompt,
               !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               viewModel.messages.isEmpty {
                viewModel.inputText = prompt
                Task { await viewModel.send() }
            } else {
                inputFocused = true
            }
        }
    }

    // MARK: - Empty state

    /// Shown when the chat is brand new — gives the user starter
    /// suggestions so they don't face a blank screen.
    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [
                            Color(red: 0.55, green: 0.45, blue: 1.0).opacity(0.20),
                            SomedayColors.primary.opacity(0.20),
                            Color(red: 1.0, green: 0.45, blue: 0.80).opacity(0.20)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 88, height: 88)
                Image(systemName: "sparkles")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(aiGradient)
            }
            VStack(spacing: 6) {
                Text("Ask anything about your map")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(SomedayColors.charcoal)
                Text("I know all your saved places, your lists, and your friends' picks.")
                    .font(.system(size: 13))
                    .foregroundColor(SomedayColors.grayMedium)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            // Suggestion chips — taps fill the input with a starter
            // question. Cheap discovery for "what can I ask?".
            VStack(spacing: 8) {
                suggestion("What's the best coffee spot I've saved?")
                suggestion("Which places are in my Hidden gems list?")
                suggestion("Compare De Kas and Pllek")
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func suggestion(_ text: String) -> some View {
        Button {
            viewModel.inputText = text
            inputFocused = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkle")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(aiGradient)
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(SomedayColors.charcoal)
                    .multilineTextAlignment(.leading)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white)
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(SomedayColors.anthropicTan, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.messages) { msg in
                        bubble(for: msg).id(msg.id)
                    }
                    if viewModel.isThinking {
                        thinkingIndicator.id("thinking")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            // Auto-scroll to the bottom whenever messages change or the
            // thinking indicator appears. Without this the user has to
            // manually scroll down to see the assistant's reply.
            .onChange(of: viewModel.messages.count) { _, _ in
                if let last = viewModel.messages.last {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: viewModel.isThinking) { _, isOn in
                if isOn {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo("thinking", anchor: .bottom)
                    }
                }
            }
        }
    }

    /// One message bubble. User bubbles right-align in primary;
    /// assistant bubbles left-align in white. Same metaphor as iMessage
    /// so it reads instantly.
    @ViewBuilder
    private func bubble(for msg: ChatMessage) -> some View {
        HStack {
            if msg.role == .user { Spacer(minLength: 40) }
            Text(msg.content)
                .font(.system(size: 15))
                .foregroundColor(msg.role == .user ? .white : SomedayColors.charcoal)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(msg.role == .user
                            ? AnyShapeStyle(SomedayColors.primary)
                            : AnyShapeStyle(Color.white))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(msg.role == .user ? 0.0 : 0.04), radius: 3, y: 1)
                .frame(maxWidth: .infinity, alignment: msg.role == .user ? .trailing : .leading)
            if msg.role == .assistant { Spacer(minLength: 40) }
        }
    }

    /// Three pulsing dots while the AI is generating. Matches the
    /// "AI thinking" visual vocabulary used elsewhere (aiChatBar's
    /// sparkles pulse, the AvailabilityBar's gradient border).
    private var thinkingIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { i in ThinkingDot(delay: Double(i) * 0.15) }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 80)
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask about your map…", text: $viewModel.inputText, axis: .vertical)
                .font(.system(size: 15))
                .lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit { submit() }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.white)
                .cornerRadius(18)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(SomedayColors.anthropicTan, lineWidth: 1)
                )

            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(canSend ? SomedayColors.primary : SomedayColors.grayMedium.opacity(0.4))
                    .clipShape(Circle())
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.white.opacity(0.7))
    }

    private var canSend: Bool {
        !viewModel.isThinking &&
        !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canSend else { return }
        Task { await viewModel.send() }
    }

    private var aiGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.55, green: 0.45, blue: 1.0),
                SomedayColors.primary,
                Color(red: 1.0, green: 0.45, blue: 0.80)
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}

// =============================================================================
// ChatViewModel
// =============================================================================

@Observable
final class ChatViewModel {
    var messages: [ChatMessage] = []
    var inputText: String = ""
    var isThinking: Bool = false
    var errorMessage: String?

    private let chatService: ChatService
    /// Rebuilt on every send so the assistant always sees the user's
    /// current places / lists / friends — no stale snapshots.
    private let contextProvider: () -> ChatContext
    /// Applies a chat-driven mutation (create_list, delete_place, …) by
    /// routing it through `MapViewModel` for the optimistic local
    /// update + Supabase write. Optional — non-mutating chat surfaces
    /// (the demo build / unit tests) can leave this nil and the
    /// `.mutation` events become silent no-ops.
    private let mutationApplier: ((ChatMutation) -> Void)?

    init(
        chatService: ChatService,
        contextProvider: @escaping () -> ChatContext,
        mutationApplier: ((ChatMutation) -> Void)? = nil
    ) {
        self.chatService = chatService
        self.contextProvider = contextProvider
        self.mutationApplier = mutationApplier
    }

    @MainActor
    func send() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking else { return }

        // 1. Append the user message, then pre-allocate an empty
        //    assistant message we mutate in place as events arrive.
        //    This is what makes the UI feel live: text appears one
        //    delta at a time, step rows pop in above as they happen.
        messages.append(ChatMessage(role: .user, content: text))
        inputText = ""
        errorMessage = nil
        isThinking = true
        Haptics.tap()

        // History sent to the server: everything BEFORE the assistant
        // placeholder we're about to append (i.e. ends on the user's
        // turn). Important — sending the empty placeholder would break
        // Anthropic's user/assistant alternation requirement.
        let history = messages
        let assistantIndex = messages.endIndex
        messages.append(ChatMessage(role: .assistant, content: ""))

        do {
            let context = contextProvider()
            for try await event in chatService.stream(history: history, context: context) {
                // The placeholder may have been removed by a `clear`
                // mid-stream (rare); bail out safely if so.
                guard assistantIndex < messages.count,
                      messages[assistantIndex].role == .assistant else { break }
                switch event {
                case .step(let id, let icon, let label, let chips):
                    messages[assistantIndex].steps.append(
                        ChatStep(id: id, icon: icon, label: label, chips: chips)
                    )
                case .stepDone(let id):
                    if let idx = messages[assistantIndex].steps.firstIndex(where: { $0.id == id }) {
                        messages[assistantIndex].steps[idx].done = true
                    }
                case .textDelta(let delta):
                    messages[assistantIndex].content += delta
                case .selection(let req):
                    // The agent asked for structured input. Attach it to this
                    // message so the bubble renders the interactive option
                    // picker; the turn ends right after (we wait for the tap).
                    messages[assistantIndex].selectionRequest = req
                case .mutation(let m):
                    // Side-effecting change the server's agent decided to
                    // make. Apply locally + persist via the closure the
                    // host screen wired up (typically MapHomeView →
                    // MapViewModel). Fire-and-forget — we don't wait for
                    // the persist before continuing to stream the reply.
                    mutationApplier?(m)
                case .done:
                    break
                }
            }
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            // Server-unreachable gets its own clean message; anything
            // else falls back to the generic "couldn't think that
            // through" wrapper so the user still sees what went wrong.
            let bubble: String
            if let chatErr = error as? ChatServiceError {
                bubble = chatErr.localizedDescription
            } else {
                bubble = "Sorry — I couldn't think that through. (\(error.localizedDescription))"
            }
            if assistantIndex < messages.count,
               messages[assistantIndex].role == .assistant {
                // Replace the (possibly empty) placeholder with the
                // error so we don't leave a blank bubble behind.
                messages[assistantIndex] = ChatMessage(role: .assistant, content: bubble)
            } else {
                messages.append(ChatMessage(role: .assistant, content: bubble))
            }
            Haptics.error()
        }
        isThinking = false
    }
}

// =============================================================================
// ThinkingDot — single dot of the three-dot typing indicator
// =============================================================================

private struct ThinkingDot: View {
    let delay: Double
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(SomedayColors.grayMedium)
            .frame(width: 7, height: 7)
            .scaleEffect(pulse ? 1.0 : 0.55)
            .opacity(pulse ? 1.0 : 0.4)
            .animation(
                .easeInOut(duration: 0.6).repeatForever(autoreverses: true).delay(delay),
                value: pulse
            )
            .onAppear { pulse = true }
    }
}
