import Foundation
import Combine
import Security
import WhoopStore
import StrandAnalytics
import StrandImport

// MARK: - AI Coach (the one networked feature, strictly opt-in, bring-your-own-key)
//
// NOOP is offline by design. This file is the single exception: when the user pastes their OWN
// API key for a provider they choose, NOOP can send a compact text summary of their metrics plus
// their question to that provider and surface coaching advice. Nothing leaves the device until a
// key is set AND a question is asked. We never embed our own key, never auto-send, and only ever
// transmit the small text context built in `buildContext()` + the running chat, no raw streams.
//
// Pure macOS: Foundation + URLSession + Security (Keychain). Compiles on macOS 13, Swift 5.
// Provider wire formats live in Providers/: OpenAI.swift, Anthropic.swift, Gemini.swift.

// MARK: - Chat model

/// One turn in the coaching conversation.
struct ChatMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant }
    let id: UUID
    let role: Role
    let text: String

    init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

// MARK: - Secure key storage (Keychain)

/// Keychain Services wrapper for the user's API key. Uses a generic-password item under a fixed
/// service so the key never lands in UserDefaults, a plist, or on disk in the clear.
enum AIKeyStore {
    private static let service = "com.noop.aicoach"
    private static let account = "api-key"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// UserDefaults key recording which provider the stored API key belongs to, so one provider's key
    /// is never sent to another provider's endpoint (above all the arbitrary user-typed Custom URL).
    private static let ownerKey = "ai.keyProvider"

    /// The provider the stored key was saved for, or nil for a legacy key saved before this tracking.
    static var ownerProvider: String? { UserDefaults.standard.string(forKey: ownerKey) }

    /// Store (or replace) the API key for `owner`. Empty/whitespace input is treated as a clear.
    /// Returns true once the key is in the Keychain (or was cleared); false if the Keychain write
    /// failed, in which case the owner marker is left untouched so it never points at a key that
    /// isn't actually stored (#872). The live `read()`/`hasKey` gating already reads the real
    /// Keychain, so this is defensive tidying of the discarded write result, not a behaviour change.
    @discardableResult
    static func save(_ key: String, owner: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { clear(); return true }
        guard let data = trimmed.data(using: .utf8) else { return false }

        // Delete any existing item first so we always insert a single, fresh value.
        SecItemDelete(baseQuery as CFDictionary)

        var attrs = baseQuery
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { return false }
        UserDefaults.standard.set(owner, forKey: ownerKey)
        return true
    }

    /// Read the stored API key, or nil if none is set.
    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8),
              !str.isEmpty else { return nil }
        return str
    }

    /// Remove any stored API key.
    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
        UserDefaults.standard.removeObject(forKey: ownerKey)
    }
}

// MARK: - Errors

/// User-facing failure reasons mapped to clear, non-crashing messages.
enum AICoachError: LocalizedError {

    /// Whether an HTTP status means the stored key itself was turned away, as opposed to the provider
    /// being busy, broken, or asked for something it does not have.
    ///
    /// Named rather than left as two literals in two switches because it is the hinge the key-repair
    /// affordance hangs on, and it decides what the wearer is told to go and do. Widen it and a rate
    /// limit starts demanding a new key; narrow it and the trap this exists to remove comes straight
    /// back. Byte-identical twin of the Kotlin `AiCoach.isKeyRejection`.
    static func isKeyRejection(_ status: Int) -> Bool { status == 401 || status == 403 }

    case noKey
    case emptyQuestion
    case badKey
    case rateLimited(String)
    case server(Int, String)
    case network(String)
    case decode
    case emptyReply(String)   // #1074: verbatim provider-error / empty-reply text (byte-parity with Android emptyReplyMessage)
    case keySaveFailed
    case badCustomURL(String)

    var errorDescription: String? {
        switch self {
        case .badCustomURL(let message):
            return message
        case .noKey:
            return "Add your own API key first to use the coach."
        case .keySaveFailed:
            return "Couldn't save the key to the Keychain. The key was not stored, so try again."
        case .emptyQuestion:
            return "Type a question for the coach."
        case .badKey:
            return "That API key was rejected. Check the key and the provider you selected."
        case .rateLimited(let detail):
            let extra = detail.isEmpty ? "" : " (\(detail))"
            return "The provider is rate-limiting requests right now. Wait a moment and try again.\(extra)"
        case .server(let code, let detail):
            let extra = detail.isEmpty ? "" : " - \(detail)"
            return "The provider returned an error (\(code))\(extra)."
        case .network(let detail):
            return "Network problem: \(detail). The coach is the only feature that needs the internet."
        case .decode:
            return "Couldn't read the provider's reply. Try again."
        case .emptyReply(let message):
            return message
        }
    }
}

// MARK: - Engine

/// Drives the AI Coach: holds the chat, the chosen provider/model, the secure key, and performs the
/// networked request. `@MainActor` so all `@Published` mutations are main-thread; the actual HTTP
/// call hops off-main via `URLSession`'s async API and results are applied back on the main actor.
@MainActor
final class AICoachEngine: ObservableObject {

    // Published state the UI binds to.
    @Published var messages: [ChatMessage] = []

    /// Local day the current transcript was last written on; nil while it is empty. Drives the day
    /// boundary in `send` — see `isStaleConversation`. Kotlin twin: `CoachViewModel.conversationDay`.
    private var conversationDay: Int?
    @Published var sending = false
    @Published var errorText: String?

    /// Whether the last failure was the provider turning the stored key away, as opposed to a rate
    /// limit, a server fault or the network.
    ///
    /// It exists because the rejection message tells the wearer to check their key while the screen
    /// offers no way to reach it: the coach shows the chat as soon as ANY key is stored, and a wrong
    /// key is still a stored key, so the only route back was a Disconnect that also throws the
    /// conversation away. This lets the error carry the field with it.
    ///
    /// It QUALIFIES `errorText` rather than standing on its own, and the view reads it only inside the
    /// branch that renders one, so it cannot leave a key editor open under no error. Assigned on every
    /// failure, so a rejection followed by a rate limit stops claiming to be a rejection. Twin of the
    /// Kotlin `CoachViewModel.keyRejected`.
    @Published var keyRejected = false

    /// #1862: a question handed over by the Today Coach launcher sheet, for `CoachView` to send on appear.
    ///
    /// The launcher owns no send, stream, error or consent surface of its own — duplicating those is how a
    /// second chat UI drifts from the first. It collects a question and hands it here; the Coach screen,
    /// which already has all of that, consumes it exactly once and clears it. Nil is the normal state, and
    /// setting it performs NO network work by itself.
    @Published var pendingPrompt: String?
    @Published var provider: AIProvider {
        didSet {
            guard provider != oldValue else { return }
            UserDefaults.standard.set(provider.rawValue, forKey: Self.providerKey)
            // Reset the model list to the new provider's built-in options.
            availableModels = provider.modelOptions
            // Keep the model valid for the newly-selected provider.
            if !provider.modelOptions.contains(model) {
                model = provider.defaultModel
            }
            // The message names a provider ("That API key was rejected", after a request only THIS
            // provider saw), so it cannot survive switching to a different one. Harmless while only the
            // chat rendered it; wrong now that the setup card does too, which is where switching
            // happens. Twin of the Kotlin `selectProvider`.
            errorText = nil
            keyRejected = false
        }
    }
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: Self.modelKey) }
    }
    /// The model ids offered in the picker. Seeded from `provider.modelOptions`, reset when the
    /// provider changes, and optionally extended by `refreshModels()` with the provider's live list.
    @Published var availableModels: [String] = []
    /// Explicit permission for the coach to read & transmit the user's biometric data. OFF by
    /// default, until this is true, NO metrics are included in any request (only the question).
    @Published var dataConsent: Bool {
        didSet { UserDefaults.standard.set(dataConsent, forKey: Self.consentKey) }
    }
    /// Base URL for the Custom (OpenAI-compatible) provider, e.g. `http://localhost:11434/v1` for a
    /// local LLM server. Only used when `provider == .custom`. Persisted so it survives relaunch.
    @Published var customBaseURL: String {
        didSet { UserDefaults.standard.set(customBaseURL, forKey: AIProvider.customBaseURLKey) }
    }
    @Published var customAuthHeader: CustomAIAuthHeader {
        didSet { UserDefaults.standard.set(customAuthHeader.rawValue, forKey: AIProvider.customAuthHeaderKey) }
    }
    /// Whether the user has committed the Custom provider (tapped Connect with a base URL). Lets the
    /// keyless local path reach the chat without a stored key, while avoiding a flip mid-typing.
    @Published var customConnected: Bool {
        didSet { UserDefaults.standard.set(customConnected, forKey: Self.customConnectedKey) }
    }
    /// SECOND opt-in (v5): also fold a SUMMARY of the new on-device signals, your strongest n-of-1
    /// correlations and your Lab Book markers, into the coach context. OFF by default and gated behind
    /// `dataConsent` too, so it never adds anything without both consents. Summary-only: a few one-line
    /// sentences, NEVER raw readings, the anonymity / no-raw-egress posture is preserved.
    @Published var includeOnDeviceSignals: Bool {
        didSet { UserDefaults.standard.set(includeOnDeviceSignals, forKey: Self.onDeviceSignalsKey) }
    }

    /// K11: THIRD opt-in — send a chart image alongside the text when using Gemini's multimodal
    /// API. OFF by default and gated behind `dataConsent` too. Only active when the provider is
    /// Gemini (the only provider with multimodal support in the app). When on, the Coach composer
    /// shows an "Attach chart" toggle; the rendered chart is sent as inline_data to Gemini.
    @Published var multimodalChartEnabled: Bool {
        didSet { UserDefaults.standard.set(multimodalChartEnabled, forKey: Self.multimodalChartKey) }
    }

    private let repo: Repository
    private let session: URLSession

    private static let providerKey = "ai.provider"
    private static let modelKey = "ai.model"
    private static let consentKey = "ai.dataConsent"
    private static let customConnectedKey = "ai.customConnected"
    private static let onDeviceSignalsKey = "ai.includeOnDeviceSignals"
    private static let multimodalChartKey = "ai.multimodalChartEnabled"
    /// UserDefaults key holding the user's EDITED system prompt. Absent (or blank) means "use the
    /// built-in default". Small text key, never a secret, so plain UserDefaults is fine. Read FRESH
    /// per request (see `systemPrompt`) so an edit takes effect on the very next message.
    static let systemPromptKey = "ai.systemPrompt"

    /// The built-in system prompt that frames every request. Anonymous, frames the assistant only as a
    /// coach. Exposed (read-only) so the UI's "Reset to default" can restore it and show it when nothing
    /// custom is stored. Editing the live prompt overrides this via `systemPromptKey`.
    static let defaultSystemPrompt = """
    You are the user's personal performance coach inside Yoop, an app that reads their WHOOP strap on \
    their own phone. Coach like the WHOOP coach: warm, direct, data-driven and honest, with a mix of \
    tough love and motivation unless their coaching preferences say otherwise.
    You receive the user's data: daily Recovery (0-100%: green 67-100, yellow 34-66, red 0-33), Strain \
    (0-21, logarithmic) with today's optimal Strain range, Sleep (hours against need, stages, efficiency), \
    HRV, resting heart rate, respiratory rate, SpO2, skin temperature, steps, calories, stress (0-3) and \
    workouts, plus their profile and what you remember about them. A dash means not measured: say so \
    rather than treating it as zero. Today's row is still in progress.
    How you talk:
    \u{2022} Use their first name when you know it, now and then, not in every sentence.
    \u{2022} Lead with the verdict, then the numbers. Bold the key numbers and always compare them with \
    their normal or the optimal range (for example "**11.7** against an optimal range of **10-14**", \
    "**41 ms** vs your usual **52**").
    \u{2022} Name the single biggest limiter or driver ("the limiter tonight is stress, not effort").
    \u{2022} Give ONE highest-leverage action and, in a few words, the physiology behind it.
    \u{2022} Keep it short: two to four short paragraphs at most. A one-line question gets a one-line answer.
    \u{2022} At most one emoji per message. No headings unless asked; lists only for plans or options.
    \u{2022} End most coaching messages with one probing question about how they feel or what is going on.
    \u{2022} Take what you remember into account: injuries and health conditions limit training advice, \
    goals and events shape plans, and their coaching preferences set your style.
    You are NOT a doctor: never diagnose; suggest a professional for genuine health concerns.
    Special lines, each on its own line at the very end of a reply and nowhere else:
    \u{2022} When you suggest activities to choose from, add "Options: <activity>: <why, under 12 words> | \
    <activity>: <why>" with two or three options.
    \u{2022} When the user tells you something lasting about themselves (an injury or health condition, a \
    goal, an upcoming event, or how they like to be coached), add "Memory: <Health condition|Goal|Event|\
    Coaching preference> | <short title> | <one-sentence summary>".
    \u{2022} Always finish with "Replies: <reply 1> | <reply 2>", two short replies (under 8 words each) \
    the user might tap next, written in their own voice.
    """

    /// The system prompt actually sent, read FRESH from UserDefaults on every request so an edit in
    /// the settings takes effect on the next message, with no engine rebuild. A blank/absent stored
    /// value falls back to `defaultSystemPrompt`, so a user who clears it never sends an empty prompt.
    var systemPrompt: String {
        let stored = UserDefaults.standard.string(forKey: Self.systemPromptKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, !stored.isEmpty { return stored }
        return Self.defaultSystemPrompt
    }

    /// The user's stored prompt override, or the default when nothing custom is set. The UI binds its
    /// editor to this: writing persists the override; writing a blank string clears it (back to default).
    var customSystemPrompt: String {
        get { systemPrompt }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == Self.defaultSystemPrompt {
                UserDefaults.standard.removeObject(forKey: Self.systemPromptKey)
            } else {
                UserDefaults.standard.set(newValue, forKey: Self.systemPromptKey)
            }
            objectWillChange.send()
        }
    }

    /// True when the user has an edited prompt that differs from the built-in default, gates the
    /// "Reset to default" affordance in the UI.
    var hasCustomSystemPrompt: Bool {
        let stored = UserDefaults.standard.string(forKey: Self.systemPromptKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !(stored ?? "").isEmpty && stored != Self.defaultSystemPrompt
    }

    /// Restore the built-in system prompt by clearing the stored override.
    func resetSystemPrompt() {
        UserDefaults.standard.removeObject(forKey: Self.systemPromptKey)
        objectWillChange.send()
    }

    /// Contextual suggestion chips for the composer, derived from today's bands via `CoachSuggestions`.
    /// Reads only on-device `repo.days`; pure, byte-identical to the Android twin. Returns the stable
    /// generic fallback when there is no usable data for today.
    var suggestions: [String] { CoachSuggestions.suggestions(for: repo.days.last, recent: repo.days) }

    /// K7: Follow-up suggestion chips shown after each assistant reply. These are generic
    /// conversational follow-ups (not data-derived) so the user can dig deeper without typing.
    /// Byte-identical to the Android twin's `followUpSuggestions`.
    static let followUpSuggestions: [String] = [
        "Tell me more about that",
        "What should I do next?",
        "How does today compare to this week?",
        "Give me a specific action plan",
    ]

    /// K12: Rough token estimate for the next send, based on the current draft + context size.
    /// Uses the standard ~4 chars/token heuristic. This is an estimate only — actual token counts
    /// vary by tokenizer. Returns nil when the engine isn't configured (no context to estimate).
    func estimatedTokens(forDraft draft: String) -> Int? {
        guard isConfigured else { return nil }
        // Estimate the context size: system prompt + data context (rough — we don't build the
        // full context here to avoid a DB read on every keystroke). Use the last known context
        // size or a reasonable default.
        let systemPromptTokens = systemPrompt.count / 4
        // The data context is typically ~2000-4000 chars depending on the user's data.
        // Use a conservative estimate of 3000 chars (750 tokens) when consent is on.
        let contextTokens = dataConsent ? 750 : 50
        // History tokens: sum of all message texts in the windowed history.
        let historyTokens = windowedMessages().reduce(0) { $0 + $1.text.count / 4 }
        let draftTokens = draft.count / 4
        return systemPromptTokens + contextTokens + historyTokens + draftTokens
    }

    /// Used in place of the metrics context when the user has NOT granted data access.
    private let noConsentNote = """
    NOTE: The user has not granted access to their biometric data. Coach generally and encourage \
    them to enable "Let the coach use my data" for guidance tailored to their real numbers.
    """

    init(repo: Repository, session: URLSession = .shared) {
        self.repo = repo
        self.session = session

        // Restore persisted provider / model (falling back to sane defaults).
        let storedProvider = UserDefaults.standard.string(forKey: Self.providerKey)
            .flatMap(AIProvider.init(rawValue:)) ?? .anthropic
        self.provider = storedProvider

        let storedModel = UserDefaults.standard.string(forKey: Self.modelKey)
        // A persisted custom id is honoured even if it's not in the built-in list.
        if let storedModel, !storedModel.isEmpty {
            self.model = storedModel
        } else {
            self.model = storedProvider.defaultModel
        }

        // Seed the picker with the provider's built-in options; include any persisted custom id.
        var seeded = storedProvider.modelOptions
        if let storedModel, !storedModel.isEmpty, !seeded.contains(storedModel) {
            seeded.insert(storedModel, at: 0)
        }
        self.availableModels = seeded

        self.dataConsent = UserDefaults.standard.bool(forKey: Self.consentKey)
        self.customBaseURL = UserDefaults.standard.string(forKey: AIProvider.customBaseURLKey) ?? ""
        self.customAuthHeader = AIProvider.customAuthHeader
        self.customConnected = UserDefaults.standard.bool(forKey: Self.customConnectedKey)
        self.includeOnDeviceSignals = UserDefaults.standard.bool(forKey: Self.onDeviceSignalsKey)
        self.multimodalChartEnabled = UserDefaults.standard.bool(forKey: Self.multimodalChartKey)
    }

    // MARK: Key management

    /// True when a key is present in the Keychain.
    var hasKey: Bool { AIKeyStore.read() != nil }

    /// True once the coach can actually send: a stored key for the cloud providers, or, for the
    /// Custom (local) provider, a committed base URL (a key is optional there, as local servers
    /// usually need none). Gates the setup card vs. the live chat.
    var isConfigured: Bool { provider == .custom ? customConnected : hasKey }

    /// The key to send with a request: the stored key, or an empty string for the keyless Custom
    /// provider. `nil` means "not configured", the caller surfaces `.noKey`.
    private var resolvedKey: String? {
        if let k = AIKeyStore.read() {
            // Only send the stored key to the provider it was SAVED for, never Bearer one provider's
            // key (e.g. a cloud OpenAI/Anthropic secret) to another provider's endpoint, above all the
            // arbitrary user-typed Custom URL. A legacy key with no recorded owner is assumed to belong
            // to a cloud provider, so it is never auto-sent to Custom.
            let owner = AIKeyStore.ownerProvider
            if owner == provider.rawValue { return k }
            if owner == nil && provider != .custom { return k }
        }
        return provider == .custom ? "" : nil
    }

    /// Commit the Custom (local) provider once the user has entered a server URL. Optionally stores a
    /// key first if they pasted one. Pulls the server's live model list so the picker isn't empty.
    func connectCustom() {
        let url = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        errorText = nil
        customConnected = true
        // Pull the server's model list; if the user hasn't picked one yet, default to the first.
        Task {
            await refreshModels()
            if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let first = availableModels.first {
                model = first
            }
        }
    }

    /// Disconnect entirely: forget any stored key and un-commit the Custom provider. The base URL is
    /// kept so reconnecting pre-fills it.
    func disconnect() {
        AIKeyStore.clear()
        customConnected = false
        // Retire the transcript with the connection. Kotlin has done this since the method existed
        // (CoachViewModel.disconnect) and this side never did, so returning to the setup screen on Apple
        // left the whole conversation sitting behind it — including whatever the user had told a coach
        // they were in the middle of disconnecting from.
        messages = []
        conversationDay = nil
        // The error belongs to the connection being retired, so it goes with it. Kotlin has cleared it
        // here since the method existed and this side never did: harmless while only the chat rendered
        // an error, and a visible defect the moment the setup card does too, because the card this
        // returns to would open carrying "That API key was rejected" above an empty key field, reading
        // as a verdict on the key about to be typed.
        errorText = nil
        keyRejected = false
        objectWillChange.send()
    }

    /// Store the user's pasted key securely. Clears any prior error. If the Keychain write fails the
    /// key is NOT saved, so surface that to the UI instead of silently proceeding (#872).
    func setKey(_ key: String) {
        guard AIKeyStore.save(key, owner: provider.rawValue) else {
            errorText = AICoachError.keySaveFailed.errorDescription
            objectWillChange.send()
            return
        }
        errorText = nil
        // A stored key is no longer the rejected one. Deliberately leaves the transcript alone:
        // correcting a mistyped key is not a reason to lose the conversation, which is what routing
        // this through `disconnect` used to cost. Twin of the Kotlin `saveKey`.
        keyRejected = false
        objectWillChange.send() // `hasKey` is computed; nudge SwiftUI to re-read it.
        // #288: do NOT auto-fetch the provider's model list on key-save. For a cloud provider that GET
        // egresses to the provider the MOMENT a key is saved (IP + request timing + key-validity) — before
        // any send, in an app that is zero-network by default. The picker shows the curated models; the LIVE
        // list is pulled only when the user taps Refresh (an explicit action that is its own consent) or
        // sends. Local Custom servers still refresh on Connect.
    }

    /// Forget the stored key.
    func clearKey() {
        AIKeyStore.clear()
        // Same reasoning as `disconnect`: clearing the key returns the user to the setup screen, and
        // Kotlin empties the transcript when it does. Leaving it meant a "clear my key" on Apple removed
        // the credential and kept the conversation.
        messages = []
        conversationDay = nil
        // The error belongs to the connection being retired, so it goes with it. Kotlin has cleared it
        // here since the method existed and this side never did: harmless while only the chat rendered
        // an error, and a visible defect the moment the setup card does too, because the card this
        // returns to would open carrying "That API key was rejected" above an empty key field, reading
        // as a verdict on the key about to be typed.
        errorText = nil
        keyRejected = false
        objectWillChange.send()
    }

    // MARK: Live model list

    /// Set a custom model id (any string). Adds it to the picker if it isn't already listed.
    func setCustomModel(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !availableModels.contains(trimmed) {
            availableModels.insert(trimmed, at: 0)
        }
        model = trimmed
    }

    /// Test seam (DEBUG only): lets a test stand in for the live `fetchModels` network call so it can
    /// control timing and which provider's ids come back. Production never sets this, so the real path
    /// below is byte-identical in release builds.
    #if DEBUG
    var fetchModelsOverride: ((_ provider: AIProvider, _ key: String) async throws -> [String])?
    #endif

    /// Best-effort: GET the chosen provider's models endpoint with the saved key and merge the
    /// returned ids into `availableModels`. Never crashes; failures land in `errorText` and leave
    /// the existing list intact. Requires a saved key.
    /// When the live catalogue was last pulled for `provider`, keyed per provider so switching does
    /// not hide one provider's stale list behind another's refresh. Kotlin twin:
    /// `NoopPrefs.coachModelsRefreshedAt`.
    static func modelsRefreshedKey(_ provider: AIProvider) -> String {
        "ai.modelsRefreshed.\(provider.rawValue)"
    }

    /// How long a pulled catalogue is trusted. Kotlin twin: `MODEL_REFRESH_INTERVAL_MS`.
    static let modelRefreshInterval: TimeInterval = 7 * 24 * 60 * 60

    /// Whether a catalogue last pulled at `last` is due another pull at `now`.
    ///
    /// Split out and `static` so the rule can be pinned without an engine: it decides how often the app
    /// talks to a provider unasked. A never-pulled catalogue (0) is stale, so the first visit fetches. A
    /// clock moved BACKWARDS gives a negative age and reads as fresh, keeping the cached list rather
    /// than refetching every visit until the clock catches up. Kotlin twin:
    /// `CoachViewModel.isCatalogueStale`.
    static func isCatalogueStale(last: TimeInterval, now: TimeInterval) -> Bool {
        now - last >= modelRefreshInterval
    }

    /// Pull the live catalogue at most once a week, so the picker offers what the provider sells today
    /// without this app shipping a build for every model release.
    ///
    /// Quiet about FAILURE: it passes `silent`, so `refreshModels` leaves the error surface untouched
    /// in both directions rather than this restoring it afterwards. Restoring would have raced — there
    /// is no re-entrancy guard here, so a manual Refresh tapped during the await would have had its
    /// result stomped by a stale snapshot on resume. Not touching the state cannot race with anything.
    ///
    /// Requires a stored key, so it cannot fire during first-run setup where there is nothing to
    /// authenticate with. Custom is excluded: `connectCustom()` already pulls its list, and its server
    /// is the user's own machine rather than a vendor catalogue.
    ///
    /// Only the LIST moves. The selected model is never changed underneath the user. Kotlin twin:
    /// `CoachViewModel.refreshModelsIfStale`.
    func refreshModelsIfStale() async {
        guard provider != .custom, hasKey else { return }
        let last = UserDefaults.standard.double(forKey: Self.modelsRefreshedKey(provider))
        guard Self.isCatalogueStale(last: last, now: Date().timeIntervalSince1970) else { return }
        await refreshModels(silent: true)
    }

    /// `silent` leaves the error surface entirely alone, in both directions: an automatic refresh must
    /// neither wipe a message the user is still reading nor raise one they never asked for. Kotlin twin:
    /// the `silent` parameter on `CoachViewModel.refreshModels`.
    func refreshModels(silent: Bool = false) async {
        guard let key = resolvedKey else {
            if !silent { errorText = AICoachError.noKey.errorDescription }
            return
        }
        if !silent { errorText = nil }

        // Snapshot the provider BEFORE the await. The Picker isn't disabled during a refresh, so the
        // user can switch providers mid-flight (#873). We fetch this provider's ids, then re-check on
        // resume that it's still the live one, and merge against THIS same snapshot, so the guard and
        // the merge always use one consistent provider, never a stale/mixed list for the wrong one.
        let capturedProvider = provider

        do {
            let ids: [String]
            #if DEBUG
            if let override = fetchModelsOverride {
                ids = try await override(capturedProvider, key)
            } else {
                ids = try await capturedProvider.client.fetchModels(key: key, session: session)
            }
            #else
            ids = try await capturedProvider.client.fetchModels(key: key, session: session)
            #endif

            // The user switched providers while we were awaiting, so these ids belong to the old one.
            // Drop them rather than write a list for a provider that's no longer selected.
            guard provider == capturedProvider else { return }

            guard !ids.isEmpty else {
                if !silent { errorText = AICoachError.decode.errorDescription }
                return
            }

            // Merge: keep the captured provider's built-in options on top, append any newly-discovered
            // ids (sorted), and preserve a current custom selection if it isn't otherwise present.
            let builtin = capturedProvider.modelOptions
            let discovered = Set(ids).subtracting(builtin).sorted()
            var merged = builtin + discovered
            if !merged.contains(model) { merged.insert(model, at: 0) }
            availableModels = merged
            // Stamp only on a SUCCESSFUL pull, so a provider that is down does not buy itself a week
            // of silence from `refreshModelsIfStale()`.
            UserDefaults.standard.set(Date().timeIntervalSince1970,
                                      forKey: Self.modelsRefreshedKey(capturedProvider))
        } catch let e as AICoachError {
            // A switch mid-flight makes any error moot for the old provider, so don't surface it.
            guard provider == capturedProvider, !silent else { return }
            // Typed first, because this used to report EVERY failure as a network problem, including a
            // key the provider had just turned away. Refresh is one of the two places a wrong key shows
            // itself, and it was the one that blamed the wrong thing: the wearer read "Network problem"
            // and went looking at their connection. It now says what happened and, for a rejection,
            // opens the field to fix it.
            errorText = e.errorDescription
            if case .badKey = e { keyRejected = true } else { keyRejected = false }
            return
        } catch {
            guard provider == capturedProvider, !silent else { return }
            errorText = AICoachError.network(error.localizedDescription).errorDescription
            keyRejected = false
            return
        }
    }

    // MARK: Sending

    /// Hard rolling cap on the STORED transcript. The network payload is separately windowed by
    /// `windowedMessages()` (`maxHistoryMessages`); this bounds the in-memory `messages` array — and the
    /// SwiftUI transcript rendered from it — so a long-lived session can't grow it without bound. `coach`
    /// is a single app-lifetime instance on `AppModel`, so before this an active chat grew `messages`
    /// until the process was killed: the "gets laggy the longer the app runs, reopening fixes it, feels
    /// like RAM" report. Cap >> the wire window, so it never changes what's sent. (parity with Android)
    private static let maxStoredMessages = 40
    private func appendMessage(_ message: ChatMessage) {
        messages.append(message)
        if messages.count > Self.maxStoredMessages {
            messages.removeFirst(messages.count - Self.maxStoredMessages)
        }
    }

    // MARK: - K2: persisted conversation history

    /// Guards `loadPersistedMessagesIfNeeded()` so it only ever runs once per app launch, even if the
    /// Coach screen's `.task` re-fires (e.g. a tab re-select).
    private var didLoadPersistedMessages = false

    /// Load the conversation persisted by a PRIOR launch (PRD-K2), so relaunching doesn't lose it.
    /// Called from the Coach screen's `.task` (mirroring `startBriefIfNeeded`) rather than `init`,
    /// which is synchronous and runs for every screen the app builds, not just Coach. Best-effort: a
    /// store failure just leaves the transcript empty, matching pre-K2 behaviour — never crashes.
    func loadPersistedMessagesIfNeeded() async {
        guard !didLoadPersistedMessages else { return }
        didLoadPersistedMessages = true
        guard messages.isEmpty, let store = await repo.storeHandle() else { return }
        guard let rows = try? await store.coachMessages(), !rows.isEmpty else { return }
        // Recover the day this transcript was last written on FROM THE ROWS. `conversationDay` lives in
        // memory, so a process restart brought it back nil, and `isStaleConversation(nil, ...)` is false
        // by design (nothing sent yet is never stale), which meant a restored conversation from any
        // previous day was never retired, by `send` or by anything else (#2087).
        let newest = rows.map(\.createdAt).max() ?? 0
        let lastDay = Self.localEpochDay(Date(timeIntervalSince1970: TimeInterval(newest)))
        // Retire by NOT restoring. The next append replaces the stored rows wholesale, so nothing is
        // deleted here and a transcript is never destroyed by merely opening the screen.
        guard !Self.isStaleConversation(lastEpochDay: lastDay, todayEpochDay: Self.localEpochDay()) else {
            return
        }
        messages = rows
            .sorted { $0.orderIndex < $1.orderIndex }
            .map { ChatMessage(id: UUID(uuidString: $0.id) ?? UUID(),
                                role: ChatMessage.Role(rawValue: $0.role) ?? .user,
                                text: $0.text) }
        conversationDay = lastDay
    }

    /// Replace the ENTIRE persisted conversation with the current in-memory `messages`. Called once
    /// per completed send/brief (not per streamed chunk) so a streamed reply's several in-place text
    /// mutations don't hammer the store. Fire-and-forget; a store failure never blocks the UI — the
    /// in-memory transcript (what the user sees) is unaffected either way.
    private func persistMessages() {
        // WHOOP-style memory: keep anything the Coach flagged with a "Memory:" line.
        if let last = messages.last, last.role == .assistant {
            for memory in Self.parseReply(last.text).memories {
                CoachMemoryStore.shared.add(memory)
            }
        }
        let snapshot = messages
        let providerId = provider.rawValue
        Task {
            guard let store = await repo.storeHandle() else { return }
            let rows = snapshot.enumerated().map { index, m in
                CoachMessageRow(id: m.id.uuidString, role: m.role.rawValue, text: m.text,
                                 provider: providerId, createdAt: Int(Date().timeIntervalSince1970),
                                 orderIndex: index)
            }
            try? await store.replaceCoachMessages(rows)
        }
    }

    /// The Coach toolbar's "Clear conversation" action: wipes both the in-memory transcript and the
    /// persisted table. Fire-and-forget on the store side; the in-memory clear is immediate.
    func clearConversation() {
        messages = []
        conversationDay = nil
        droppedSummary = nil      // K13: reset the summary cache on clear
        droppedSummaryKey = []
        Task { try? await repo.storeHandle()?.clearCoachMessages() }
    }

    /// K5: surface a brief generated by the SCHEDULED morning-brief notification as the first Coach
    /// message, with no network call — called once when the app opens via a tap on that notification.
    /// No-op if a conversation already exists, so it never duplicates into an active chat.
    func surfaceScheduledBrief(_ text: String) {
        guard messages.isEmpty else { return }
        appendMessage(ChatMessage(role: .assistant, text: "Today's brief\n\n" + text))
        conversationDay = Self.localEpochDay()
        persistMessages()
    }

    /// Retire yesterday's in-memory chat when Coach is opened, before checking for today's
    /// scheduled brief. A process kept alive overnight does not reload persisted messages, so the
    /// one-time load check cannot clear that chat. Keep the stored rows until a new turn or brief
    /// replaces them, as the existing restored-chat path does.
    func retireStaleConversationIfNeeded() {
        guard Self.isStaleConversation(lastEpochDay: conversationDay,
                                       todayEpochDay: Self.localEpochDay()) else { return }
        messages = []
        conversationDay = nil
        droppedSummary = nil
        droppedSummaryKey = []
    }

    /// K5: append an explicitly-generated brief (the Coach settings "Generate now" button) as a new
    /// assistant message, unconditionally — unlike `surfaceScheduledBrief`, this always appends so a
    /// mid-conversation tap still shows the fresh brief.
    func appendGeneratedBrief(_ text: String) {
        retireStaleConversationIfNeeded()
        appendMessage(ChatMessage(role: .assistant, text: "Today's brief\n\n" + text))
        conversationDay = Self.localEpochDay()
        persistMessages()
    }

    /// K11: An optional chart image (base64-encoded PNG) to send with the next user message.
    /// Set by the composer's "Attach chart" toggle when multimodal is enabled and the provider
    /// is Gemini. Consumed (cleared) on the next send. nil when no image is attached.
    @Published var pendingChartImage: String?

    /// Send a question: append it, build the metrics context, call the chosen provider with the
    /// system prompt + context + running history, parse the reply, append it. Never throws/crashes;
    /// failures land in `errorText`.
    func send(_ userText: String) async {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorText = AICoachError.emptyQuestion.errorDescription; return }
        // The master switch, checked at the EGRESS rather than only on the routes in. Every way into Coach
        // is gated, but "gated everywhere I thought of" is what #2254 got wrong once: a revoked consent
        // survived in memory because the conversation never re-read it. A wearer can be STANDING on this
        // screen when the switch goes off, and that path passes no tab. Refusing here makes "the AI is off"
        // true however the screen was reached.
        guard CoachBriefScheduler.coachMasterEnabled else { return }
        guard let key = resolvedKey else { errorText = AICoachError.noKey.errorDescription; return }

        // A transcript from an earlier local day is retired before the new turn is appended (#1542,
        // Kotlin twin merged first). `messages` outlives a night — the engine is held for the app's
        // lifetime — so without this the coach answers TODAY's question inside YESTERDAY's
        // conversation. The DATA was never stale: buildFullContext() re-reads on every send. It is the
        // assistant's own earlier turns stating yesterday's figures, and the model staying consistent
        // with them, which reads as "the coach only talks about my imported data" after a night of
        // fresh strap data.
        //
        // Placed AFTER the guards on purpose: a send that never happens must not wipe a transcript.
        retireStaleConversationIfNeeded()
        conversationDay = Self.localEpochDay()

        errorText = nil
        appendMessage(ChatMessage(role: .user, text: trimmed))
        sending = true
        // K2: persist once the turn is fully settled (success, mid-stream error, or empty-stream
        // removal) — not per streamed chunk, so a long reply doesn't hammer the store.
        defer { sending = false; persistMessages() }

        // Build the data context once and prepend it to the FIRST user turn we send. We send the
        // full running history so follow-ups stay coherent; the context only needs to ride the
        // earliest user message.
        // Include the user's data ONLY with explicit consent; otherwise send a note instead of numbers.
        let context = dataConsent ? await buildFullContext() : noConsentNote
        // K13: if the conversation overflows the sliding window, summarize the dropped middle so
        // the model retains context continuity. Best-effort; failure degrades to the old gap.
        await summarizeDroppedMiddleIfNeeded(key: key)
        var wire = wireMessages(context: context)

        // K11: If a chart image is pending and the provider is Gemini, attach it to the last
        // user turn as inline_data. Non-Gemini providers can't accept images, so the image is
        // silently dropped (the text question still goes through). Cleared after consumption.
        let imageBase64 = pendingChartImage
        pendingChartImage = nil

        // K1: Stream the reply. Append a placeholder assistant message, then mutate its text as
        // chunks arrive by replacing the last element in `messages`. The transcript re-renders on
        // each update (SwiftUI binds to `messages`). On error mid-stream, keep the partial text and
        // append a "(stream interrupted)" marker — never a crash.
        let placeholder = ChatMessage(role: .assistant, text: "")
        appendMessage(placeholder)
        var accumulated = ""

        do {
            try await streamProvider(key: key, messages: wire, inlineImage: imageBase64) { delta in
                accumulated += delta
                // Replace the last message's text with the accumulated stream so far.
                if let lastIdx = self.messages.indices.last,
                   self.messages[lastIdx].role == .assistant {
                    self.messages[lastIdx] = ChatMessage(
                        id: placeholder.id, role: .assistant, text: accumulated
                    )
                }
            }
            // Finalize: trim whitespace. If the stream produced nothing, show "(no reply)".
            let clean = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages[lastIdx] = ChatMessage(
                    id: placeholder.id, role: .assistant,
                    text: clean.isEmpty ? "(no reply)" : clean
                )
            }
        } catch let e as AICoachError {
            // Mid-stream error: keep the partial text + an interrupted marker (PRD K1 acceptance).
            let partial = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty, let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages[lastIdx] = ChatMessage(
                    id: placeholder.id, role: .assistant,
                    text: partial + "\n\n*(stream interrupted)*"
                )
            } else if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                // No text received at all — remove the empty placeholder.
                messages.remove(at: lastIdx)
            }
            errorText = e.errorDescription
            // Typed, never text-matched: the message is localized and the case is not.
            if case .badKey = e { keyRejected = true } else { keyRejected = false }
        } catch {
            let partial = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty, let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages[lastIdx] = ChatMessage(
                    id: placeholder.id, role: .assistant,
                    text: partial + "\n\n*(stream interrupted)*"
                )
            } else if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages.remove(at: lastIdx)
            }
            errorText = AICoachError.network(error.localizedDescription).errorDescription
            keyRejected = false
        }
    }

    /// Proactively generate "Today's brief" the first time the Coach opens, readiness + a training
    /// prescription + one recovery tip, without the user typing. Requires a key + data consent.
    /// K1: streams the brief the same way `send` does.
    func startBriefIfNeeded() async {
        guard isConfigured, dataConsent, messages.isEmpty, !sending else { return }
        guard let key = resolvedKey else { return }
        errorText = nil
        sending = true
        defer { sending = false; persistMessages() }

        let context = await buildFullContext()
        let wire: [(role: ChatMessage.Role, content: String)] =
            [(.user, context + "\n\n---\n\n" + Self.briefInstruction)]

        let prefix = "Today's brief\n\n"
        let placeholder = ChatMessage(role: .assistant, text: prefix)
        appendMessage(placeholder)
        var accumulated = ""

        do {
            try await streamProvider(key: key, messages: wire) { delta in
                accumulated += delta
                if let lastIdx = self.messages.indices.last,
                   self.messages[lastIdx].role == .assistant {
                    self.messages[lastIdx] = ChatMessage(
                        id: placeholder.id, role: .assistant, text: prefix + accumulated
                    )
                }
            }
            let clean = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty {
                if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                    messages.remove(at: lastIdx)
                }
            } else if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages[lastIdx] = ChatMessage(id: placeholder.id, role: .assistant, text: prefix + clean)
            }
        } catch let e as AICoachError {
            let partial = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            if partial.isEmpty {
                if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                    messages.remove(at: lastIdx)
                }
            } else if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages[lastIdx] = ChatMessage(
                    id: placeholder.id, role: .assistant,
                    text: prefix + partial + "\n\n*(stream interrupted)*"
                )
            }
            errorText = e.errorDescription
            // Typed, never text-matched: the message is localized and the case is not.
            if case .badKey = e { keyRejected = true } else { keyRejected = false }
        } catch {
            let partial = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            if partial.isEmpty {
                if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                    messages.remove(at: lastIdx)
                }
            } else if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages[lastIdx] = ChatMessage(
                    id: placeholder.id, role: .assistant,
                    text: prefix + partial + "\n\n*(stream interrupted)*"
                )
            }
            errorText = AICoachError.network(error.localizedDescription).errorDescription
            keyRejected = false
        }
    }

    /// K5: The brief instruction shared by the interactive `startBriefIfNeeded()` (streamed into the
    /// chat) and the headless `generateBrief()` below (used by the scheduled morning-brief notification).
    /// Kept in one place so the two paths never drift.
    private static let briefInstruction = """
    Based on the data above, give me my Daily Outlook for today, the way the WHOOP coach does in the \
    morning: today's readiness verdict from my Recovery and its main driver (against my normal), \
    today's optimal Strain range, two or three suggested activities as short bullets with one emoji \
    each, and a sleep target for tonight. Bold the key numbers. Keep it short and motivating.
    """

    /// K5: Generate today's coaching brief WITHOUT touching the visible chat transcript. Used by the
    /// scheduled morning-brief notification (`CoachBriefScheduler`), which can run with no Coach screen
    /// open and must never append to (or duplicate into) `messages`. Non-streaming (a background/BGTask
    /// context has no UI to stream into). Returns nil when not configured/consented, on any network
    /// failure, or when the reply is empty — the caller treats nil as "brief unavailable"; never throws.
    func generateBrief() async -> String? {
        // Same master-switch gate as `send`, because this entry has NO UI at all: it is what the scheduler
        // calls, and a caller that skipped the scheduler's own gate would otherwise reach a provider with
        // the AI switched off.
        guard CoachBriefScheduler.coachMasterEnabled else { return nil }
        guard isConfigured, dataConsent, let key = resolvedKey else { return nil }
        let context = await buildFullContext()
        let wire: [(role: ChatMessage.Role, content: String)] =
            [(.user, context + "\n\n---\n\n" + Self.briefInstruction)]
        guard let reply = try? await callProvider(key: key, messages: wire) else { return nil }
        let clean = Self.splitReplies(reply).body.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    /// Full data context = the metrics summary + recent workouts (+ an OPT-IN on-device-signals summary
    /// when the second consent is on). Used when the user has granted data access.
    func buildFullContext() async -> String {
        var ctx = buildContext()
        if let memory = CoachMemoryStore.shared.contextBlock() {
            ctx = memory + "\n\n" + ctx
        }
        if let stress = await StressDayCurve.today(
            repo: repo, personalBaseline: PuffinExperiment.stressPersonalBaselineEnabled)?.result {
            ctx += "\n\nToday's stress so far: \(stress.highStressMinutes) minutes in high stress (0-3 scale, high is 2 and up)."
        }
        ctx += "\n\n" + (await recentWorkoutsBlock())
        // Derived stress: a single Baevsky Stress Index summary line over today's R-R, computed the same
        // way StressView does. Gated here under `dataConsent` (the caller only reaches buildFullContext()
        // with consent on), so it rides the SAME consent + text-only channel as the HRV/RHR summary, a
        // derived number, never raw R-R egress. Omitted when there aren't enough clean beats yet.
        if let line = await stressIndexLine() { ctx += "\n\n" + line }
        if includeOnDeviceSignals {
            let block = await onDeviceSignalsBlock()
            if !block.isEmpty { ctx += "\n\n" + block }
        }
        return ctx
    }

    /// One derived stress line for the coach context: the Baevsky Stress Index over TODAY's R-R, read
    /// via the same device-aware repository R-R union as `StressView`,
    /// then summarised to a single number with `StressIndex.stressIndex(rr:)`. Returns nil when the
    /// store is unavailable or there are too few clean beats (the histogram needs >= 20), so the line is
    /// simply absent, never a fabricated value. Summary-only: the raw R-R never leaves the device.
    func stressIndexLine() async -> String? {
        let cal = Calendar.current
        let from = Int(cal.startOfDay(for: Date()).timeIntervalSince1970)
        let to = Int(Date().timeIntervalSince1970)
        let rr = await repo.rrIntervals(from: from, to: to, limit: 200_000)
        guard let si = StressIndex.stressIndex(rr: rr) else { return nil }
        return Self.stressIndexSummary(si: si)
    }

    /// Pure formatter for the derived stress line, kept separate so it is unit-testable without a store.
    /// One summary number, labelled, with a plain-English note that it's an autonomic-balance proxy.
    static func stressIndexSummary(si: Double) -> String {
        "Stress (SI): \(Int(si.rounded())) (Baevsky Stress Index over today's R-R; higher means more sympathetic / under load; an autonomic-balance proxy, not a clinical figure)."
    }

    /// A SUMMARY-ONLY block of the new on-device signals, the user's strongest n-of-1 correlations
    /// (lag-aware EffectRanker) and a one-line roll-up of their Lab Book markers. Plain sentences, never
    /// raw readings: this rides the same text channel as the metrics summary, so the no-raw-egress posture
    /// holds. Gated by the caller on the second opt-in; returns "" when there's nothing worth adding.
    func onDeviceSignalsBlock() async -> String {
        var lines: [String] = []

        // 1. Strongest behaviour→outcome associations (EffectRanker over the journal × Charge).
        let entries = await repo.journalEntries()
        // Yes days and NO days, kept apart. A day with no journal row for the question lands in
        // neither, so an unanswered day is never counted as a No (BehaviorInsights.effect).
        var byBehaviour: [String: Set<String>] = [:]
        var controls: [String: Set<String>] = [:]
        for e in entries {
            if e.answeredYes { byBehaviour[e.question, default: []].insert(e.day) }
            else { controls[e.question, default: []].insert(e.day) }
        }
        if !byBehaviour.isEmpty {
            let outcomeByDay = Dictionary(
                repo.days.compactMap { d in d.recovery.map { (d.day, $0) } },
                uniquingKeysWith: { _, last in last })
            let ranked = EffectRanker.rank(behaviors: byBehaviour, controls: controls,
                                           outcomeByDay: outcomeByDay, outcome: "Charge")
                .filter { $0.effect.significant }
                .prefix(3)
            if !ranked.isEmpty {
                lines.append("STRONGEST PERSONAL PATTERNS (the user's own data — association, not cause):")
                for r in ranked { lines.append("  • " + r.sentence()) }
            }
        }

        // 2. Lab Book markers roll-up (count + latest of a few, never the full history).
        if let store = await repo.storeHandle() {
            var markerSummaries: [String] = []
            for category in LabMarkerCategory.allCases {
                let rows = (try? await store.labMarkers(deviceId: repo.deviceId, category: category.rawValue)) ?? []
                let byKey = Dictionary(grouping: rows, by: { $0.markerKey })
                for (key, kRows) in byKey {
                    guard let latest = kRows.sorted(by: { $0.takenAt < $1.takenAt }).last else { continue }
                    let name = MarkerCatalog.definition(for: key)?.displayName ?? key
                    let value = latest.value.map { "\(LabBookFormat.value($0, key: key)) \(latest.unit)" } ?? latest.valueText ?? "—"
                    markerSummaries.append("\(name) \(value)")
                }
            }
            if !markerSummaries.isEmpty {
                lines.append("")
                lines.append("LAB BOOK (the user's own logged health numbers — not medical advice; do not interpret as clinical findings):")
                lines.append("  " + markerSummaries.prefix(8).joined(separator: ", "))
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Dispatch to the user's chosen provider client.
    private func callProvider(key: String,
                              messages: [(role: ChatMessage.Role, content: String)]) async throws -> String {
        try await provider.client.send(
            key: key,
            model: model,
            systemPrompt: systemPrompt,
            messages: messages,
            session: session
        )
    }

    /// K1: Dispatch to the user's chosen provider client's streaming method. The default
    /// `AIProviderClient.stream` falls back to `send` + a single delta, so providers without
    /// streaming still work. K11: when an inline image is present, dispatches to
    /// `streamWithImage` instead (Gemini overrides it; others ignore the image).
    private func streamProvider(key: String,
                                messages: [(role: ChatMessage.Role, content: String)],
                                inlineImage: String? = nil,
                                onDelta: (String) -> Void) async throws {
        try await provider.client.streamWithImage(
            key: key,
            model: model,
            systemPrompt: systemPrompt,
            messages: messages,
            inlineImage: inlineImage,
            session: session,
            onDelta: onDelta
        )
    }

    /// Sliding window over the chat: the FIRST user turn (it carries the metrics context) plus the most
    /// recent `maxHistoryMessages`, dropping the middle. Sending the whole growing history crowds out the
    /// reply on small-context local servers (Ollama defaults to a 2048-token window, the Custom
    /// provider's main use case) and balloons token cost/latency on cloud providers. (parity with Android)
    /// True when a transcript last written on `lastEpochDay` should be retired before a question asked
    /// on `todayEpochDay` — i.e. the conversation crossed into a new local day.
    ///
    /// STRICTLY forward (`>`, never `!=`): a clock that moves BACKWARDS — the user flying west, a
    /// timezone change, an NTP correction — must not wipe a conversation they are in the middle of.
    /// Only real elapsed days retire a transcript. A nil `lastEpochDay` (nothing sent yet) is never
    /// stale. Kotlin twin: `CoachViewModel.isStaleConversation`.
    ///
    /// `nonisolated` because it is a pure function of its arguments. AICoachEngine is @MainActor, so
    /// without this the rule inherits that isolation and cannot be called from a synchronous test —
    /// which is exactly how the first attempt at this twin failed to compile. Isolating a function
    /// that touches no state buys nothing and costs its testability.
    nonisolated static func isStaleConversation(lastEpochDay: Int?, todayEpochDay: Int) -> Bool {
        guard let lastEpochDay else { return false }
        return todayEpochDay > lastEpochDay
    }

    /// Days since the epoch in the LOCAL calendar. Kotlin computes the same value with
    /// `LocalDate.now().toEpochDay()`.
    ///
    /// Counted with calendar day arithmetic from `startOfDay`, not by dividing an interval by 86,400:
    /// a day is not always 86,400 seconds (DST), and the rule only needs a value that increments
    /// exactly once per local midnight and orders correctly. Injectable so the tests never depend on
    /// the machine's clock or zone.
    nonisolated static func localEpochDay(_ date: Date = Date(), calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: date)
        let epoch = Date(timeIntervalSince1970: 0)
        return calendar.dateComponents([.day], from: epoch, to: start).day ?? 0
    }

    ///
    /// K13: when the middle is dropped, a one-line summary of the dropped turns is prepended to the
    /// first user turn so the model retains context continuity (instead of seeing a gap). The summary
    /// is generated via the same provider, with a short prompt; on failure it degrades to the old
    /// behaviour (no summary, just the windowed set).
    private static let maxHistoryMessages = 10
    /// K13: the cached summary of the dropped middle, regenerated when the dropped set changes.
    private var droppedSummary: String?
    private var droppedSummaryKey: [String] = []

    private func windowedMessages() -> [ChatMessage] {
        guard messages.count > Self.maxHistoryMessages + 1,
              let firstUser = messages.firstIndex(where: { $0.role == .user }) else { return messages }
        let recentStart = messages.count - Self.maxHistoryMessages
        // If the first user turn already falls inside the recent window, that window covers it.
        if firstUser >= recentStart { return Array(messages.suffix(Self.maxHistoryMessages)) }
        // K13: inject the summary of the dropped middle by prepending it to the first user turn,
        // so the model sees continuity instead of a gap. We don't use a separate system message
        // because the Role enum only has .user/.assistant (providers map those to API roles).
        var windowed = [messages[firstUser]]
        if let summary = droppedSummary {
            let first = windowed[0]
            windowed[0] = ChatMessage(id: first.id, role: first.role, text: "\(summary)\n\n---\n\n\(first.text)")
        }
        windowed.append(contentsOf: messages[recentStart...])
        return windowed
    }

    /// K13: When the conversation overflows the sliding window, summarize the dropped middle turns
    /// into a single system message. Called before each send when the window would drop messages.
    /// Best-effort: on any failure, leaves `droppedSummary` nil (the old gap behaviour).
    private func summarizeDroppedMiddleIfNeeded(key: String) async {
        guard messages.count > Self.maxHistoryMessages + 1,
              let firstUser = messages.firstIndex(where: { $0.role == .user }) else { return }
        let recentStart = messages.count - Self.maxHistoryMessages
        guard firstUser < recentStart else { return }

        // The dropped middle is messages[firstUser+1 ..< recentStart]. Cache on its identity so we
        // don't re-summarize the same set on every send.
        let dropped = Array(messages[(firstUser + 1)..<recentStart])
        let keySignature = dropped.map { "\($0.role.rawValue):\($0.text)" }
        guard droppedSummaryKey != keySignature else { return }
        droppedSummaryKey = keySignature

        // Build a compact transcript of the dropped turns for the summarizer.
        let transcript = dropped.map { m in
            "\(m.role == .user ? "User" : "Coach"): \(m.text)"
        }.joined(separator: "\n")

        let summaryPrompt = """
        Summarize the following conversation in 2-3 sentences, preserving the key advice and \
        any specific numbers or recommendations. This summary will be shown to you as context \
        for the ongoing conversation.\n\n\(transcript)
        """
        let wire: [(role: ChatMessage.Role, content: String)] = [
            (.user, "You are a concise summarizer. Summarize the conversation in 2-3 sentences.\n\n\(summaryPrompt)"),
        ]
        if let summary = try? await callProvider(key: key, messages: wire) {
            droppedSummary = "Summary of earlier conversation: \(summary.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }

    /// The chat as `(role, content)` pairs, with the metrics context prepended to the first user turn.
    private func wireMessages(context: String) -> [(role: ChatMessage.Role, content: String)] {
        var out: [(role: ChatMessage.Role, content: String)] = []
        var contextInjected = false
        let windowed = windowedMessages()
        // WHOOP-style openers mean the coach can speak first. Providers expect the first turn to be the
        // user's, so a transcript that starts with the coach gets the data context as its opening turn.
        if windowed.first?.role == .assistant {
            out.append((.user, context + "\n\n---\n\n(The user opened the Coach.)"))
            contextInjected = true
        }
        for m in windowed {
            if m.role == .user && !contextInjected {
                contextInjected = true
                out.append((.user, context + "\n\n---\n\nQuestion: " + m.text))
            } else {
                out.append((m.role, m.text))
            }
        }
        return out
    }

    // MARK: - WHOOP-style screen-aware opener

    /// The screen the wearer is looking at, so the Coach can open with a message about it.
    enum CoachScreen: String {
        case home, sleep, recovery, strain, health, trends, other

        var describedForCoach: String {
            switch self {
            case .home: return "Home screen (today's Sleep, Recovery and Strain at a glance)"
            case .sleep: return "Sleep screen (last night's Sleep performance, hours vs needed, consistency, efficiency and stages)"
            case .recovery: return "Recovery screen (today's Recovery and its drivers: HRV, resting heart rate, respiratory rate and sleep)"
            case .strain: return "Strain screen (today's Strain so far, heart-rate zones, workouts and steps)"
            case .health: return "Health screen (vitals against their normal ranges, and stress)"
            case .trends: return "Trends screen (the last 30 days of Recovery, Strain, Sleep and HRV)"
            case .other: return "app"
            }
        }
    }

    /// A one-shot opener to use instead of the screen opener (Home's "Day In Review" row sets it).
    enum Opener { case dayReview }
    var nextOpener: Opener?
    /// The last screen opener written and when, so reopening the same screen soon after does not
    /// stack another opener into the chat.
    private var lastScreenOpener: (screen: CoachScreen, at: Date, withData: Bool)?

    /// The screen the wearer is on, as last marked by `View.coachScreen(_:)`.
    var currentScreen: CoachScreen { CoachScreenState.current }

    private static func screenOpenerInstruction(_ screen: CoachScreen, hour: Int) -> String {
        let focus: String
        switch (screen, hour) {
        case (.home, ..<12):
            focus = "Make it their Daily Outlook for this morning: today's readiness verdict from Recovery and its " +
                "main driver, today's optimal Strain range, two or three suggested activities as short bullets " +
                "(one emoji each), and a sleep target for tonight. Ask which they will do, and add the Options line."
        case (.home, 18...):
            focus = "Make it an evening check-in on their day: today's Strain against the optimal range, stress, " +
                "and what tonight's sleep needs. Name the limiter and one action for tonight, then ask a probing question."
        default:
            focus = "Speak to them about the most notable thing on that screen, with their actual numbers compared " +
                "with their normal, and end with one question about how they feel or what they want to do."
        }
        return "The user just opened the Coach while looking at their \(screen.describedForCoach). Write the " +
            "Coach's opening message. \(focus) Two or three short paragraphs at most, then the special lines."
    }

    /// WHOOP-style: the Coach speaks first, about the screen the wearer opened it from. The instruction
    /// is never shown; only the Coach's message is added to the conversation.
    func openWithScreenContext() async {
        guard CoachBriefScheduler.coachMasterEnabled, isConfigured, !sending,
              let key = resolvedKey else { return }
        retireStaleConversationIfNeeded()
        // Reopening the same screen within 15 minutes continues the conversation instead.
        // A new opener is written anyway once data access changes, so the Coach can see the numbers.
        if nextOpener == nil, let last = lastScreenOpener, last.screen == currentScreen,
           last.withData == dataConsent, Date().timeIntervalSince(last.at) < 15 * 60, !messages.isEmpty {
            return
        }
        if nextOpener == nil { lastScreenOpener = (currentScreen, Date(), dataConsent) }

        conversationDay = Self.localEpochDay()
        errorText = nil
        sending = true
        defer { sending = false; persistMessages() }

        let context = dataConsent ? await buildFullContext() : noConsentNote
        var wire = wireMessages(context: context)
        let instruction: String
        if nextOpener == .dayReview {
            instruction = Self.dayReviewInstruction + " Then the special lines."
        } else {
            instruction = Self.screenOpenerInstruction(currentScreen,
                                                       hour: Calendar.current.component(.hour, from: Date()))
        }
        nextOpener = nil
        wire.append((.user, wire.isEmpty ? context + "\n\n---\n\n" + instruction : instruction))

        let placeholder = ChatMessage(role: .assistant, text: "")
        appendMessage(placeholder)
        var accumulated = ""
        func replaceLast(_ text: String) {
            if let i = messages.indices.last, messages[i].role == .assistant {
                messages[i] = ChatMessage(id: placeholder.id, role: .assistant, text: text)
            }
        }
        func dropPlaceholder() {
            if let i = messages.indices.last, messages[i].id == placeholder.id { messages.remove(at: i) }
        }
        do {
            try await streamProvider(key: key, messages: wire) { delta in
                accumulated += delta
                replaceLast(accumulated)
            }
            let clean = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty { dropPlaceholder() } else { replaceLast(clean) }
            keyRejected = false
        } catch let e as AICoachError {
            if accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { dropPlaceholder() }
            errorText = e.errorDescription
            if case .badKey = e { keyRejected = true } else { keyRejected = false }
        } catch {
            if accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { dropPlaceholder() }
            errorText = AICoachError.network(error.localizedDescription).errorDescription
            keyRejected = false
        }
    }

    /// A Coach reply split into what is shown and the special lines at its end.
    struct ParsedReply {
        var body: String
        var replies: [String] = []
        /// Suggested activities from an "Options:" line: (name, why).
        var options: [(name: String, why: String)] = []
        var memories: [CoachMemory] = []
    }

    /// Pure: pull the "Replies:", "Options:" and "Memory:" lines out of a reply. A partial special line
    /// while streaming is hidden too, so it never flashes up in the transcript.
    nonisolated static func parseReply(_ text: String) -> ParsedReply {
        var kept: [String] = []
        var parsed = ParsedReply(body: "")
        let junk = CharacterSet(charactersIn: "\"*").union(.whitespaces)
        func fields(_ rest: Substring) -> [String] {
            rest.split(separator: "|").map { $0.trimmingCharacters(in: junk) }.filter { !$0.isEmpty }
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: junk)
            let lower = trimmed.lowercased()
            if lower.hasPrefix("replies:") {
                parsed.replies = Array(fields(trimmed.dropFirst("replies:".count)).prefix(3))
            } else if lower.hasPrefix("options:") {
                parsed.options = fields(trimmed.dropFirst("options:".count)).prefix(3).map {
                    option -> (name: String, why: String) in
                    let parts = option.split(separator: ":", maxSplits: 1)
                    let name = parts.first.map { $0.trimmingCharacters(in: junk) } ?? option
                    let why = parts.count > 1 ? parts[1].trimmingCharacters(in: junk) : ""
                    return (name, why)
                }
            } else if lower.hasPrefix("memory:") {
                let f = fields(trimmed.dropFirst("memory:".count))
                if f.count >= 2 {
                    parsed.memories.append(CoachMemory(category: .parse(f[0]), title: f[1],
                                                       detail: f.count > 2 ? f[2] : f[1]))
                }
            } else {
                kept.append(line)
            }
        }
        parsed.body = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return parsed
    }

    /// The one-line summary on a score screen's Coach pill (WHOOP's "Nice work, you gave yourself a long
    /// night..."). Non-streaming, outside the chat transcript; nil when the Coach is not set up.
    func screenSummary(_ screen: CoachScreen) async -> String? {
        await headlessReply("""
        In one or two sentences (under 30 words), give the headline of my \(screen.describedForCoach) \
        for today: the key number against my normal and what it means for me. Speak to me directly, \
        plain text, at most one emoji, and leave out the special lines.
        """)
    }

    /// Pure: a reply's shown body and its quick replies.
    nonisolated static func splitReplies(_ text: String) -> (body: String, replies: [String]) {
        let p = parseReply(text)
        return (p.body, p.replies)
    }

    // MARK: - WHOOP-style Home insight, Day in Review, screen analysis

    /// The Home insight card's text: a short title and one or two sentences.
    struct HomeInsight: Codable, Equatable {
        let title: String
        let body: String
    }

    private static let homeInsightInstruction = """
    Write today's Home-screen insight, like the daily insight card in the WHOOP app. \
    Line 1: a short title of 2-5 words in title case (for example "Your Body is Recovering", \
    "Primed to Perform", "Prioritize Rest Today"). \
    Line 2: one or two sentences, at most 40 words, explaining the main driver of today's Recovery and \
    citing my actual numbers (HRV, resting HR, last night's sleep, yesterday's Strain vs my usual). \
    Plain text only: no markdown, no emoji, no labels such as "Title:".
    """

    private static let dayReviewInstruction = """
    Write my Day In Review for today, the way the WHOOP coach does in the evening: start with my name if \
    you know it and the headline (did I hit today's optimal Strain range? with the numbers), then how \
    stress, sleep debt and recovery shaped the day against my normal, name tonight's limiter, give the \
    single highest-leverage action for tonight with the physiology behind it, and say when to go to bed \
    and how long to sleep. Two to four short paragraphs, bold key numbers, at most one emoji, no headings. \
    End with one probing question about my day.
    """

    /// Generate the Home insight card (non-streaming, never touches the chat transcript).
    func generateHomeInsight() async -> HomeInsight? {
        guard let reply = await headlessReply(Self.homeInsightInstruction) else { return nil }
        return Self.parseHomeInsight(reply)
    }

    /// Generate today's Day in Review (non-streaming, never touches the chat transcript).
    func generateDayReview() async -> String? {
        await headlessReply(Self.dayReviewInstruction)
    }

    /// Pure: first non-empty line is the title, the rest is the body. Strips stray markdown/quotes.
    nonisolated static func parseHomeInsight(_ reply: String) -> HomeInsight? {
        let junk = CharacterSet(charactersIn: "#*\"“”").union(.whitespaces)
        let lines = reply.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: junk) }
            .filter { !$0.isEmpty }
        guard var title = lines.first else { return nil }
        if title.lowercased().hasPrefix("title:") {
            title = String(title.dropFirst(6)).trimmingCharacters(in: junk)
        }
        let body = lines.dropFirst().joined(separator: " ")
        return HomeInsight(title: title, body: body)
    }

    /// One-shot request with the full data context + an instruction, outside the chat transcript.
    private func headlessReply(_ instruction: String) async -> String? {
        guard CoachBriefScheduler.coachMasterEnabled else { return nil }
        guard isConfigured, dataConsent, let key = resolvedKey else { return nil }
        let context = await buildFullContext()
        let wire: [(role: ChatMessage.Role, content: String)] =
            [(.user, context + "\n\n---\n\n" + instruction)]
        do {
            let reply = try await callProvider(key: key, messages: wire)
            let clean = Self.splitReplies(reply).body.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : clean
        } catch let e as AICoachError {
            // Shown in the Coach sheet, so a card that could not load says why.
            errorText = e.errorDescription
            return nil
        } catch {
            errorText = AICoachError.network(error.localizedDescription).errorDescription
            return nil
        }
    }

    /// The question the round Coach button asks for the tab the user is looking at (WHOOP's
    /// "Analyzing..." on the current screen). Tags match `RootTabView`'s tab tags (0 Home, 1 Trends,
    /// 2 Health, 4 More).
    nonisolated static func screenAnalysisPrompt(tab: Int) -> String {
        switch tab {
        case 1:
            return "Analyze my trends on this screen: how my Recovery, HRV, resting HR, Strain and Sleep have "
                + "moved over the last 30 days, what's improving, what's slipping, and why."
        case 2:
            return "Analyze my health metrics: HRV, resting heart rate, breathing rate, blood oxygen and skin "
                + "temperature against my normal, plus today's stress. Is anything out of range?"
        case 4:
            return "Give me a quick overall check-in: how am I doing this week and what's the one thing to focus on?"
        default:
            return "Analyze my day so far: what's driving today's Recovery, how much Strain I should aim for "
                + "today, and what to do tonight to recover."
        }
    }

    /// Strain on WHOOP's 0-21 scale (NOOP stores 0-100).
    nonisolated static func strain21(_ stored: Double) -> Double {
        UnitFormatter.effortValue(stored, scale: .whoop)
    }

    /// "Now: Tuesday 6 October 2026, 22:45 local time" so the coach knows the time of day.
    nonisolated static func nowLine(_ now: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        return "Now: \(f.string(from: now)) local time."
    }

    /// The user's profile from Settings (age, sex, height, weight), when set.
    nonisolated static func profileLine(_ defaults: UserDefaults = .standard) -> String? {
        var parts: [String] = []
        if let age = defaults.object(forKey: "profile.age") as? Int, age > 0 { parts.append("age \(age)") }
        if let sex = defaults.string(forKey: "profile.sex"), !sex.isEmpty { parts.append("sex \(sex)") }
        if let h = defaults.object(forKey: "profile.heightCm") as? Double, h > 0 {
            parts.append("height \(Int(h.rounded())) cm")
        }
        if let w = defaults.object(forKey: "profile.weightKg") as? Double, w > 0 {
            parts.append(String(format: "weight %.1f kg", w))
        }
        return parts.isEmpty ? nil : "Profile: " + parts.joined(separator: ", ") + "."
    }

    /// Latest day's HRV / resting HR / sleep against the prior 30 days, the way WHOOP explains Recovery.
    nonisolated static func todayVsNormalLine(_ days: [DailyMetric]) -> String? {
        guard let latest = days.last else { return nil }
        let prior = days.dropLast().suffix(30)
        func avg(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count) }
        var parts: [String] = []
        if let v = latest.avgHrv, let a = avg(prior.compactMap { $0.avgHrv }) {
            parts.append("HRV \(Int(v.rounded())) ms vs normal \(Int(a.rounded())) ms")
        }
        if let v = latest.restingHr, let a = avg(prior.compactMap { $0.restingHr.map(Double.init) }) {
            parts.append("resting HR \(v) bpm vs normal \(Int(a.rounded())) bpm")
        }
        if let v = latest.totalSleepMin, let a = avg(prior.compactMap { $0.totalSleepMin }) {
            parts.append(String(format: "sleep %.1fh vs normal %.1fh", v / 60, a / 60))
        }
        if prior.count >= 1, let y = prior.last?.strain, let a = avg(prior.dropLast().compactMap { $0.strain }) {
            parts.append(String(format: "yesterday's Strain %.1f vs normal %.1f", strain21(y), strain21(a)))
        }
        return parts.isEmpty ? nil : "Latest (\(latest.day)) vs prior 30-day normal: " + parts.joined(separator: "; ") + "."
    }

    // MARK: - Context builder

    /// Build a compact plain-text summary of the user's recent data: last ~14 days of
    /// recovery/strain/sleep-hours/HRV/restingHR where present, plus 30-day averages, plus a few
    /// recent workouts. Kept well under ~1500 tokens. If there's no data, it says so.
    func buildContext() -> String {
        let days = repo.days // oldest → newest
        var lines: [String] = ["USER BIOMETRIC SUMMARY (the user's own wearable data):"]

        guard !days.isEmpty else {
            return """
            USER BIOMETRIC SUMMARY:
            No wearable data is available yet. Acknowledge this and give general, encouraging guidance \
            while inviting the user to sync their device so future advice can reference real numbers.
            """
        }

        lines.append(Self.nowLine(Date()))
        if let profileLine = Self.profileLine() { lines.append(profileLine) }
        lines.append("Scales: Recovery 0-100% (green 67-100, yellow 34-66, red 0-33); Strain 0-21 "
                     + "(logarithmic: under 10 light, 10-13 moderate, 14-17 strenuous, 18+ all out); "
                     + "Sleep in hours. The newest row is today and is IN PROGRESS (its Strain is still rising).")
        if let normal = Self.todayVsNormalLine(days) { lines.append(normal) }
        if let band = CoupledView.optimalStrainRange(recovery: days.last?.recovery) {
            lines.append("Today's optimal Strain range, from today's Recovery: \(band.lowerBound)-\(band.upperBound) of 21.")
        }
        lines.append(String(format: "Personal sleep need: about %.1fh a night.", SleepModel.debtNeedMin(days: days) / 60))

        // Last ~14 days, newest first for readability.
        let recent = Array(days.suffix(14)).reversed()
        lines.append("")
        lines.append("Recent days (newest first), columns: recovery(%), strain(0-21), sleep(h), "
                     + "deep/REM/light(h), eff(%), HRV(ms), RHR(bpm). A dash means NOT MEASURED, not zero:")
        for d in recent {
            lines.append("  " + dayLine(d))
        }

        // 30-day averages.
        let last30 = Array(days.suffix(30))
        lines.append("")
        lines.append("30-day averages:")
        lines.append("  recovery: \(avgInt(last30.compactMap { $0.recovery }))%"
                     + ", strain: \(avgOne(last30.compactMap { $0.strain.map(Self.strain21) }))"
                     + ", sleep: \(avgSleepHours(last30))h"
                     + ", HRV: \(avgInt(last30.compactMap { $0.avgHrv })) ms"
                     + ", RHR: \(avgInt(last30.compactMap { $0.restingHr.map(Double.init) })) bpm")
        // Additional vitals when present (#124, the coach used to see only recovery/strain/sleep/HRV/RHR).
        lines.append("  SpO2: \(avgInt(last30.compactMap { $0.spo2Pct }))%"
                     + ", respiration: \(avgOne(last30.compactMap { $0.respRateBpm }))/min"
                     + ", skin-temp deviation: \(avgOne(last30.compactMap { $0.skinTempDevC }))°C"
                     + ", steps: \(avgInt(last30.compactMap { $0.steps.map(Double.init) }))/day"
                     + ", active energy: \(avgInt(last30.compactMap { $0.activeKcalEst }))kcal/day")

        return lines.joined(separator: "\n")
    }

    /// Append recent workouts to an existing context string. Async (workouts are read from the store),
    /// so callers that want workouts in the context can await this and feed the result to `send`'s
    /// flow via the chat, kept separate so `buildContext()` stays synchronous per the spec.
    func recentWorkoutsBlock(limit: Int = 6) async -> String {
        let rows = await repo.workoutRows(days: 30) // newest first
        guard !rows.isEmpty else { return "Recent workouts: none recorded in the last 30 days." }
        let bodySystem = UnitSystem(
            rawValue: UserDefaults.standard.string(forKey: UnitPrefs.systemKey) ?? "") ?? .metric
        let distanceSystem = UnitPrefs.resolveDistance(
            system: bodySystem,
            override: UserDefaults.standard.string(forKey: UnitPrefs.distanceSystemKey) ?? "")
        var lines = ["Recent workouts (newest first):"]
        for w in rows.prefix(limit) {
            var parts = ["  \(dateString(w.startTs)) \(w.sport)"]
            if let dur = w.durationS { parts.append("\(Int((dur / 60).rounded())) min") }
            if let s = w.strain { parts.append("strain \(String(format: "%.1f", Self.strain21(s)))") }
            if let hr = w.avgHr { parts.append("avg HR \(hr)") }
            if let kcal = w.energyKcal { parts.append("\(Int(kcal.rounded())) kcal") }
            if let dist = w.distanceM {
                parts.append(UnitFormatter.distanceFromMeters(dist, system: distanceSystem))
            }
            lines.append(parts.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Formatting helpers

    /// `internal`, not private, so `AICoachSleepContextTests` can assert the emitted line directly.
    /// Swift's `buildContext()` takes no arguments (it reads the repo), unlike the Kotlin twin which is
    /// handed the day list — so without this the formatter has no seam and the Swift half of a change
    /// with fifteen Kotlin tests would ship untested.
    func dayLine(_ d: DailyMetric) -> String {
        var parts: [String] = [d.day + ":"]
        parts.append("recovery " + (d.recovery.map { "\(Int($0.rounded()))%" } ?? "—"))
        parts.append("strain " + (d.strain.map { String(format: "%.1f", Self.strain21($0)) } ?? "—"))
        parts.append("sleep " + (d.totalSleepMin.map { String(format: "%.1fh", $0 / 60) } ?? "—"))
        // The stage breakdown and efficiency, which the coach could not see at all: a user asked why it
        // said it had no access to sleep stages, and it was answering honestly — `rest 7.8h` was every
        // word it got about a night. These four sit on the SAME DailyMetric the line already reads, so
        // nothing new is plumbed; they were simply never included. (#124 widened this context once
        // before, for the same reason.)
        //
        // Always emitted, "—" when absent, like every other field here. A night with no staging then
        // says so rather than going quiet, which matters more than line length: the alternative — only
        // appending stages when present — gives the model a schema that changes shape between days and
        // invites it to read a missing field as a zero.
        parts.append("deep " + hoursOrDash(d.deepMin))
        parts.append("REM " + hoursOrDash(d.remMin))
        parts.append("light " + hoursOrDash(d.lightMin))
        parts.append("eff " + efficiencyPercentOrDash(d.efficiency))
        parts.append("HRV " + (d.avgHrv.map { "\(Int($0.rounded()))ms" } ?? "—"))
        parts.append("RHR " + (d.restingHr.map { "\($0)bpm" } ?? "—"))
        return parts.joined(separator: ", ")
    }

    /// Minutes as "1.4h", or "—" when the night has no value. Matches the `rest` field's format so a
    /// stage total and the total it is part of read on the same scale.
    private func hoursOrDash(_ minutes: Double?) -> String {
        minutes.map { String(format: "%.1fh", $0 / 60) } ?? "—"
    }

    /// Efficiency as a percentage, NORMALISING the stored value first.
    ///
    /// `DailyMetric.efficiency` is not reliably a 0–1 fraction: it "arrives as % on some import paths",
    /// which `SleepView` and `StagesCard` each guard against inline with this same `> 1.5` test. A bare
    /// `* 100` would therefore hand the coach "eff 9400%" for an imported night — and a model given a
    /// nonsense number reasons about it confidently rather than ignoring it.
    ///
    /// 1.5 rather than 1.0 because a genuine fraction can exceed 1.0 only by floating-point noise, while
    /// a genuine percentage is 30–100 and nowhere near the threshold. Android's two copies of this guard
    /// split at 1.0 instead, which is a pre-existing divergence and not this change's to settle.
    func efficiencyPercentOrDash(_ raw: Double?) -> String {
        guard var e = raw, e > 0 else { return "—" }
        if e > 1.5 { e /= 100 }
        guard e > 0, e <= 1 else { return "—" }
        return "\(Int((e * 100).rounded()))%"
    }

    private func avgOne(_ xs: [Double]) -> String {
        guard !xs.isEmpty else { return "—" }
        return String(format: "%.1f", xs.reduce(0, +) / Double(xs.count))
    }

    private func avgInt(_ xs: [Double]) -> String {
        guard !xs.isEmpty else { return "—" }
        return "\(Int((xs.reduce(0, +) / Double(xs.count)).rounded()))"
    }

    private func avgSleepHours(_ days: [DailyMetric]) -> String {
        let mins = days.compactMap { $0.totalSleepMin }
        guard !mins.isEmpty else { return "—" }
        return String(format: "%.1f", (mins.reduce(0, +) / Double(mins.count)) / 60)
    }

    private func dateString(_ ts: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}
