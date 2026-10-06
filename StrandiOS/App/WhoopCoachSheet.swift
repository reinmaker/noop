#if os(iOS)
import SwiftUI
import MarkdownUI
import StrandDesign

/// WHOOP-style Coach: a sheet over the current screen. The Coach speaks first about the screen the
/// wearer opened it from (`AICoachEngine.openWithScreenContext()`), offers quick replies, and takes
/// questions in an "Ask anything" box with + (suggested questions) and voice input. Setup, model and
/// privacy controls stay in NOOP's full Coach screen, reachable from the menu.
struct WhoopCoachSheet: View {
    @EnvironmentObject private var coach: AICoachEngine
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss

    @StateObject private var voice = CoachVoiceInput()
    @State private var draft = ""
    @FocusState private var composerFocused: Bool
    @State private var showFullCoach = false
    @State private var showMemory = false

    private static let starterPrompts = [
        "Why is my Recovery what it is today?",
        "How much Strain should I aim for today?",
        "How can I sleep better tonight?",
        "Plan my training for this week",
    ]

    var body: some View {
        Group {
            if coach.isConfigured {
                chat
            } else {
                NavigationStack {
                    CoachView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { dismiss() }
                            }
                        }
                }
            }
        }
        .sheet(isPresented: $showMemory) {
            WhoopCoachMemoryView()
        }
        .sheet(isPresented: $showFullCoach) {
            NavigationStack {
                CoachView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showFullCoach = false }
                        }
                    }
            }
        }
        // A question handed over by another screen (the insight card, Day in Review).
        .task(id: coach.pendingPrompt) {
            guard let prompt = coach.pendingPrompt, !prompt.isEmpty else { return }
            coach.pendingPrompt = nil
            guard coach.isConfigured else { return }
            await coach.send(prompt)
        }
    }

    // MARK: Chat

    private var chat: some View {
        VStack(spacing: 0) {
            header
            if !coach.dataConsent { consentBanner }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: NoopMetrics.space5) {
                        ForEach(coach.messages) { message in
                            messageView(message).id(message.id)
                        }
                        if coach.sending, coach.messages.last?.role != .assistant {
                            analyzing.id("analyzing")
                        }
                        if let error = coach.errorText, !error.isEmpty {
                            Text(error)
                                .font(WhoopStyle.caption)
                                .foregroundStyle(WhoopStyle.rangeAmber)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, NoopMetrics.space5)
                    .padding(.vertical, NoopMetrics.space3)
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChangeCompat(of: coach.messages.last?.text ?? "") { _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            quickReplies
            composer
        }
        .background(WhoopStyle.sheetFill.ignoresSafeArea())
    }

    private var header: some View {
        HStack(spacing: NoopMetrics.space3) {
            Image(systemName: "sparkles")
                .font(WhoopStyle.icon)
                .foregroundStyle(WhoopStyle.onGradient)
                .frame(width: 34, height: 34)
                .background(Circle().fill(WhoopStyle.coachButtonFill))
                .overlay(Circle().strokeBorder(
                    AngularGradient(colors: WhoopStyle.coachButtonRing, center: .center), lineWidth: 2))
            Text(coach.provider == .anthropic ? "Claude" : coach.provider.displayName)
                .font(WhoopStyle.smallLabel)
                .foregroundStyle(StrandPalette.textSecondary)
                .padding(.horizontal, NoopMetrics.space2)
                .padding(.vertical, NoopMetrics.space1)
                .background(Capsule().fill(WhoopStyle.ringTrack))
            Spacer()
            Button { showMemory = true } label: {
                HStack(spacing: NoopMetrics.space1) {
                    Text("Memory").font(WhoopStyle.detail)
                    Image(systemName: "lightbulb").font(WhoopStyle.detail)
                }
                .foregroundStyle(StrandPalette.textPrimary)
            }
            .buttonStyle(.plain)
            Menu {
                Button {
                    coach.clearConversation()
                } label: {
                    Label("New conversation", systemImage: "square.and.pencil")
                }
                Button {
                    showFullCoach = true
                } label: {
                    Label("Coach settings", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(WhoopStyle.icon)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(WhoopStyle.ringTrack))
            }
            .accessibilityLabel(Text("Coach options"))
        }
        .padding(.horizontal, NoopMetrics.space5)
        .padding(.top, NoopMetrics.space4)
        .padding(.bottom, NoopMetrics.space2)
    }

    private var consentBanner: some View {
        Toggle(isOn: $coach.dataConsent) {
            Text("Let the Coach read your data")
                .font(WhoopStyle.body)
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .padding(WhoopStyle.compactPadding)
        .whoopCard()
        .padding(.horizontal, NoopMetrics.space5)
    }

    @ViewBuilder
    private func messageView(_ message: ChatMessage) -> some View {
        let parts = AICoachEngine.parseReply(message.text)
        switch message.role {
        case .assistant:
            if parts.body.isEmpty {
                analyzing
            } else {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    Markdown(parts.body)
                        .markdownTheme(.strand)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if !parts.options.isEmpty && message.id == coach.messages.last?.id {
                        optionCards(parts.options)
                    }
                    HStack(spacing: NoopMetrics.space4) {
                        Button {
                            UIPasteboard.general.string = parts.body
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .accessibilityLabel(Text("Copy"))
                        ShareLink(item: parts.body) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel(Text("Share"))
                    }
                    .font(WhoopStyle.detail)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .font(WhoopStyle.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.horizontal, NoopMetrics.space4)
                    .padding(.vertical, NoopMetrics.space3)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(WhoopStyle.userBubble))
            }
        }
    }

    /// WHOOP's activity cards: each suggested activity with a Commit button that tells the Coach.
    private func optionCards(_ options: [(name: String, why: String)]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: NoopMetrics.space3) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        HStack(spacing: NoopMetrics.space2) {
                            Image(systemName: "figure.run")
                                .font(WhoopStyle.icon)
                                .frame(width: 30, height: 30)
                                .background(RoundedRectangle(cornerRadius: 8).fill(WhoopStyle.ringTrack))
                            Text(option.name.uppercased())
                                .font(WhoopStyle.smallLabel)
                                .lineLimit(1)
                        }
                        .foregroundStyle(StrandPalette.textPrimary)
                        if !option.why.isEmpty {
                            Text(option.why)
                                .font(WhoopStyle.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Button {
                            CoachPlan.commit(name: option.name, why: option.why)
                            send("I'll do \(option.name) today.")
                        } label: {
                            HStack(spacing: NoopMetrics.space1) {
                                Image(systemName: "plus").font(WhoopStyle.chevron)
                                Text("COMMIT").font(WhoopStyle.smallLabel)
                            }
                            .foregroundStyle(WhoopStyle.chipText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, NoopMetrics.space2)
                            .background(RoundedRectangle(cornerRadius: 8).fill(WhoopStyle.chipFill))
                        }
                        .buttonStyle(.plain)
                        .disabled(coach.sending)
                    }
                    .padding(WhoopStyle.compactPadding)
                    .frame(width: 230, height: 170, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 16).fill(WhoopStyle.ringTrack.opacity(0.5)))
                    .overlay(RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(WhoopStyle.reviewAccent.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
            }
        }
    }

    private var analyzing: some View {
        HStack(spacing: NoopMetrics.space2) {
            ProgressView().controlSize(.small)
            Text("Analyzing…")
                .font(WhoopStyle.body)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .padding(.horizontal, NoopMetrics.space4)
        .padding(.vertical, NoopMetrics.space2)
        .background(Capsule().fill(WhoopStyle.ringTrack))
    }

    // MARK: Quick replies

    private var replyOptions: [String] {
        guard !coach.sending else { return [] }
        if let last = coach.messages.last {
            guard last.role == .assistant else { return [] }
            let replies = AICoachEngine.splitReplies(last.text).replies
            return replies.isEmpty ? Array(AICoachEngine.followUpSuggestions.prefix(2)) : replies
        }
        return Array(coach.suggestions.prefix(3))
    }

    @ViewBuilder
    private var quickReplies: some View {
        let options = replyOptions
        if !options.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: NoopMetrics.space2) {
                    ForEach(options, id: \.self) { option in
                        Button { send(option) } label: {
                            Text(option)
                                .font(WhoopStyle.body)
                                .foregroundStyle(WhoopStyle.chipText)
                                .lineLimit(1)
                                .padding(.horizontal, NoopMetrics.space4)
                                .padding(.vertical, NoopMetrics.space2)
                                .background(Capsule().fill(WhoopStyle.chipFill))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, NoopMetrics.space5)
            }
            .padding(.bottom, NoopMetrics.space2)
        }
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: NoopMetrics.space2) {
            Menu {
                ForEach(Self.starterPrompts, id: \.self) { prompt in
                    Button(prompt) { send(prompt) }
                }
            } label: {
                Image(systemName: "plus")
                    .font(WhoopStyle.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(WhoopStyle.ringTrack))
            }
            .accessibilityLabel(Text("Suggested questions"))

            HStack(alignment: .bottom, spacing: NoopMetrics.space2) {
                TextField("Ask anything", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(WhoopStyle.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .onSubmit { send(draft) }
                    .padding(.vertical, NoopMetrics.space3)
                if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button { toggleVoice() } label: {
                        Image(systemName: voice.isRecording ? "stop.circle.fill" : "mic.fill")
                            .font(WhoopStyle.icon)
                            .foregroundStyle(voice.isRecording ? WhoopStyle.rangeAmber : StrandPalette.textSecondary)
                            .frame(width: 36, height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(coach.sending || !(voice.canUseVoice || voice.authorization == .notDetermined))
                    .accessibilityLabel(Text(voice.isRecording ? "Stop voice input" : "Voice input"))
                } else {
                    Button { send(draft) } label: {
                        Image(systemName: "arrow.up")
                            .font(WhoopStyle.icon)
                            .foregroundStyle(WhoopStyle.chipText)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(WhoopStyle.chipFill))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 6)
                    .disabled(coach.sending)
                    .accessibilityLabel(Text("Send"))
                }
            }
            .padding(.leading, NoopMetrics.space4)
            .padding(.trailing, NoopMetrics.space1)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(WhoopStyle.ringTrack))
        }
        .padding(.horizontal, NoopMetrics.space4)
        .padding(.top, NoopMetrics.space1)
        .padding(.bottom, NoopMetrics.space3)
    }

    // MARK: Actions

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !coach.sending else { return }
        draft = ""
        composerFocused = false
        Task { await coach.send(trimmed) }
    }

    private func toggleVoice() {
        if voice.isRecording {
            voice.stopTranscribing { finalText in
                let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { draft = draft.isEmpty ? trimmed : "\(draft) \(trimmed)" }
            }
        } else if voice.authorization == .notDetermined {
            voice.requestAuthorization { state in
                if state == .authorized {
                    voice.startTranscribing { partial in draft = partial }
                }
            }
        } else {
            voice.startTranscribing { partial in draft = partial }
        }
    }
}
#endif
