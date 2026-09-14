import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        TabView {
            GeneralSettingsView()
                .environment(appState)
                .tabItem { Label("General", systemImage: "gear") }
            DevicesSettingsView()
                .environment(appState)
                .tabItem { Label("Devices", systemImage: "headphones") }
            PeopleSettingsView()
                .environment(appState)
                .tabItem { Label("People", systemImage: "person.2") }
            ProviderSettingsView()
                .environment(appState)
                .tabItem { Label("Models", systemImage: "cpu") }
            PermissionsSettingsView()
                .environment(appState)
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
            ResearchSettingsView()
                .environment(appState)
                .tabItem { Label("Research", systemImage: "globe") }
            MemorySettingsView()
                .environment(appState)
                .tabItem { Label("Memory", systemImage: "brain.head.profile") }
        }
        .frame(width: 560, height: 560)
    }
}

struct DashboardShortcutRecorder: View {
    @Environment(AppState.self) private var appState
    @State private var listening = false

    var body: some View {
        HStack {
            Button(listening ? "Press new shortcut…" : "Record shortcut") {
                listening.toggle()
            }
            .observerGlassButton()
            if listening {
                Text("Click here, then press the keys")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .background {
            if listening {
                KeyCaptureView { keyCode, modifiers in
                    appState.settings.dashboardShortcutKeyCode = keyCode
                    appState.settings.dashboardShortcutModifiers = modifiers.rawValue
                    appState.installDashboardHotkey()
                    listening = false
                }
                .frame(width: 1, height: 1)
            }
        }
    }
}

/// Tiny NSView that becomes first responder to capture a key chord.
private struct KeyCaptureView: NSViewRepresentable {
    var onCapture: (UInt16, NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onCapture = onCapture
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        nsView.onCapture = onCapture
    }

    final class CaptureView: NSView {
        var onCapture: ((UInt16, NSEvent.ModifierFlags) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !mods.isEmpty else { return }
            onCapture?(event.keyCode, mods)
        }
    }
}

struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.settings
        Form {
            Section("Detection") {
                Toggle("Watch for meetings", isOn: $settings.watchForMeetings)
                    .onChange(of: settings.watchForMeetings) { _, _ in
                        appState.beginDetectionIfNeeded()
                    }
                Toggle("Sound & animation on detect", isOn: $settings.promptAlertEnabled)
                Text("Sauron looks for Zoom, Meet, Teams, FaceTime, Webex, and Slack huddles. It never joins the call.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Live panes") {
                Toggle("Hide while sharing your screen", isOn: $settings.hideLivePanesWhileSharing)
                Text("Hides the transcript and Live Assist panes when you present in a meeting, so others don't see that you're recording locally. The panes come back when you stop sharing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            CalendarSubscriptionsSection()
                .environment(appState)
            Section("Default capture") {
                Picker("Media", selection: $settings.defaultCapture) {
                    Text(CaptureMedia.videoAndAudio.title).tag(CaptureMedia.videoAndAudio)
                    Text(CaptureMedia.audioOnly.title).tag(CaptureMedia.audioOnly)
                }
                Toggle("Transcript", isOn: $settings.defaultTranscript)
                Toggle("Meeting app only", isOn: $settings.meetingAppAudioOnly)
                Text("Off captures all Mac audio. On limits remote audio to the meeting app (Zoom, Teams, etc.).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Reject speaker echo", isOn: $settings.echoCancellationEnabled)
                Text("Listens to the mic (You) and system/meeting audio (Others). When meeting audio plays from this Mac’s speakers, it is subtracted from the mic so live You captions and the mic file are just you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Storage") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recordings folder")
                        .font(.body)
                    Text(recordingsFolderDisplay(settings.recordingsFolderPath))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                    HStack {
                        Button("Choose Folder…") {
                            chooseRecordingsFolder()
                        }
                        Button("Use Default") {
                            settings.recordingsFolderPath = ""
                        }
                        .disabled(settings.recordingsFolderPath.isEmpty)
                    }
                    Text("Video and audio for each meeting are saved in a subfolder here. Existing meetings stay where they were recorded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Dashboard") {
                HStack {
                    Text("Shortcut")
                    Spacer()
                    Text(shortcutLabel(settings))
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text("Press \(shortcutLabel(settings)) anywhere to open the Dashboard. Change key in Terminal defaults or keep ⌥⌘D.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Dashboard") {
                    appState.openDashboard()
                }
                .observerGlassButton()
                DashboardShortcutRecorder()
                    .environment(appState)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func shortcutLabel(_ settings: SettingsStore) -> String {
        var parts: [String] = []
        let mods = NSEvent.ModifierFlags(rawValue: settings.dashboardShortcutModifiers)
        if mods.contains(.control) { parts.append("⌃") }
        if mods.contains(.option) { parts.append("⌥") }
        if mods.contains(.shift) { parts.append("⇧") }
        if mods.contains(.command) { parts.append("⌘") }
        parts.append(keyName(settings.dashboardShortcutKeyCode))
        return parts.joined()
    }

    private func keyName(_ code: UInt16) -> String {
        switch code {
        case 0: "A"
        case 1: "S"
        case 2: "D"
        case 3: "F"
        case 4: "H"
        case 5: "G"
        case 12: "Q"
        case 13: "W"
        case 14: "E"
        case 15: "R"
        default: "Key\(code)"
        }
    }

    private func recordingsFolderDisplay(_ path: String) -> String {
        if path.isEmpty {
            return MediaStore.defaultMeetingsRoot.path
        }
        return path
    }

    private func chooseRecordingsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose where Sauron saves meeting video and audio."
        let current = appState.settings.recordingsFolderPath
        if !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        } else {
            panel.directoryURL = MediaStore.defaultMeetingsRoot
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.settings.recordingsFolderPath = url.path
    }
}

private struct CalendarSubscriptionsSection: View {
    @Environment(AppState.self) private var appState
    @State private var calendars: [SauronCalendarInfo] = []

    var body: some View {
        Section("Calendars") {
            if !CalendarSignal.hasFullAccess {
                Text("Calendar access is off. Enable it under Settings → Permissions to show Up Next from your schedule.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if calendars.isEmpty {
                Text("No calendars found on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Up Next and meeting matching only use the calendars you select. Events are looked up from the current time forward.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(calendars) { calendar in
                    Toggle(isOn: Binding(
                        get: { appState.settings.isCalendarSubscribed(calendar.calendarIdentifier) },
                        set: { appState.settings.setCalendarSubscribed(calendar.calendarIdentifier, enabled: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(calendar.title)
                            Text(calendar.sourceTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Button("Select all") {
                        appState.settings.subscribedCalendarIDs = calendars.map(\.calendarIdentifier)
                        appState.settings.calendarSubscriptionsConfigured = true
                    }
                    Button("Select none") {
                        appState.settings.subscribedCalendarIDs = []
                        appState.settings.calendarSubscriptionsConfigured = true
                    }
                }
            }
        }
        .onAppear {
            refresh()
        }
    }

    private func refresh() {
        appState.settings.ensureCalendarSubscriptionsSeeded()
        calendars = CalendarSignal.availableCalendars()
    }
}

struct DevicesSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var devices: [AudioInputDevice] = []

    var body: some View {
        Form {
            Section("Microphone priority") {
                Text("Sauron tries #1 first. If that mic stays silent during a recording, it automatically falls through to the next device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(index == 0 ? SauronTheme.accent : .secondary)
                            .frame(width: 22, height: 22)
                            .background {
                                Circle()
                                    .fill(index == 0 ? SauronTheme.accent.opacity(0.15) : Color.primary.opacity(0.06))
                            }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                                .font(.body.weight(index == 0 ? .semibold : .regular))
                            if device.isSystemDefault {
                                Text("Always first — macOS default input")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer(minLength: 8)

                        if !device.isSystemDefault {
                            HStack(spacing: 4) {
                                Button {
                                    move(deviceID: device.id, direction: -1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .disabled(!canMoveUp(deviceID: device.id))
                                .buttonStyle(.borderless)

                                Button {
                                    move(deviceID: device.id, direction: 1)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .disabled(!canMoveDown(deviceID: device.id))
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section {
                Button("Refresh devices") {
                    refresh()
                }
                .observerGlassButton()
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { refresh() }
    }

    private func refresh() {
        devices = AudioDeviceCatalog.resolvedPriority(savedIDs: appState.settings.micPriorityIDs)
        // Persist discovered order (without rewriting system default into the array).
        appState.settings.micPriorityIDs = devices
            .filter { !$0.isSystemDefault }
            .map(\.id)
    }

    private func canMoveUp(deviceID: String) -> Bool {
        guard let index = devices.firstIndex(where: { $0.id == deviceID }) else { return false }
        return index > 1 // index 0 is System Default
    }

    private func canMoveDown(deviceID: String) -> Bool {
        guard let index = devices.firstIndex(where: { $0.id == deviceID }) else { return false }
        return index > 0 && index < devices.count - 1
    }

    private func move(deviceID: String, direction: Int) {
        guard let index = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        let target = index + direction
        guard target > 0, target < devices.count else { return }
        devices.swapAt(index, target)
        appState.settings.micPriorityIDs = devices
            .filter { !$0.isSystemDefault }
            .map(\.id)
    }
}

struct ProviderSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var models: [LLMModel] = []
    @State private var status: String = ""
    @State private var openRouterKey: String = KeychainStore.openRouterAPIKey ?? ""
    @State private var hermesKey: String = KeychainStore.hermesAPIKey ?? ""
    @State private var openClawKey: String = KeychainStore.openClawAPIKey ?? ""
    @State private var testing = false

    var body: some View {
        @Bindable var settings = appState.settings
        Form {
            Section("Provider") {
                Picker("Backend", selection: $settings.providerKind) {
                    ForEach(LLMProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                switch settings.providerKind {
                case .ollama:
                    TextField("Ollama URL", text: $settings.ollamaURL)
                case .lmStudio:
                    TextField("LM Studio URL", text: $settings.lmStudioURL)
                case .openRouter:
                    TextField("OpenRouter URL", text: $settings.openRouterURL)
                    SecureField("API key", text: $openRouterKey)
                        .onChange(of: openRouterKey) { _, value in
                            KeychainStore.openRouterAPIKey = value
                        }
                case .hermes:
                    TextField("Hermes URL", text: $settings.hermesURL)
                    SecureField("API server key", text: $hermesKey)
                        .onChange(of: hermesKey) { _, value in
                            KeychainStore.hermesAPIKey = value
                        }
                    Text("Point at Hermes API Server (default http://127.0.0.1:8642). Uses the agent’s tools for live research — Tavily is not used.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(
                        HermesMCPInstaller.isDesktopAppInstalled()
                            ? "Add Sauron Memory to Hermes"
                            : "Install Sauron Memory into Hermes CLI"
                    ) {
                        installSauronMemoryIntoHermes()
                    }
                    .observerGlassProminentButton()
                    .disabled(!settings.shouldRunMemoryMCPServer)
                    Text(
                        settings.shouldRunMemoryMCPServer
                            ? (HermesMCPInstaller.isDesktopAppInstalled()
                                ? "Opens the Hermes desktop app with a confirm dialog to install Sauron’s localhost MCP."
                                : "Hermes desktop not detected — writes mcp_servers.sauron into ~/.hermes/config.yaml and the token into ~/.hermes/.env. Restart Hermes or run /reload-mcp afterward.")
                            : "Turn on Memory → Expose memory over MCP first, then install into Hermes."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                case .openClaw:
                    TextField("OpenClaw URL", text: $settings.openClawURL)
                    SecureField("Gateway token", text: $openClawKey)
                        .onChange(of: openClawKey) { _, value in
                            KeychainStore.openClawAPIKey = value
                        }
                    Text("Point at OpenClaw Gateway OpenAI HTTP API (default http://127.0.0.1:18789). Enable chat completions on the gateway. Live research uses the agent — Tavily is not used.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField(
                    "Model",
                    text: $settings.modelID,
                    prompt: Text(settings.providerKind.suggestedModel.isEmpty ? "First available" : settings.providerKind.suggestedModel)
                )
                if settings.usesSeparateEmbeddingProvider {
                    Picker("Embeddings backend", selection: $settings.embeddingProviderKind) {
                        ForEach(LLMProviderKind.embeddingBackends) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    Text("Hermes/OpenClaw handle chat and tools. Pick a local or OpenRouter backend for meeting-memory embeddings (uses that provider’s URL and key above if configured).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField(
                    "Embedding model",
                    text: $settings.embeddingModelID,
                    prompt: Text(SettingsStore.defaultEmbeddingModel(for: settings.resolvedEmbeddingProviderKind))
                )
            }
            Section {
                Button(testing ? "Testing…" : "Test connection") {
                    Task { await test() }
                }
                .observerGlassButton()
                .disabled(testing)
                if !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !models.isEmpty {
                    Picker("Installed models", selection: $settings.modelID) {
                        Text("Automatic").tag("")
                        ForEach(models) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                }
            }
            Section {
                Text(privacyFooter(for: settings.providerKind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func privacyFooter(for kind: LLMProviderKind) -> String {
        switch kind {
        case .ollama, .lmStudio:
            "Only transcript text is sent to the selected model. Audio and video never leave this Mac. Ollama and LM Studio stay on localhost."
        case .openRouter:
            "Only transcript text is sent to OpenRouter. Audio and video never leave this Mac."
        case .hermes:
            "Transcript text is sent to your local Hermes API server. Hermes may use its configured tools (including web) on your behalf."
        case .openClaw:
            "Transcript text is sent to your OpenClaw gateway. The agent may use its tools (including web) on your behalf."
        }
    }

    private func installSauronMemoryIntoHermes() {
        appState.syncMemoryMCPServer()
        let token = KeychainStore.mcpServerToken
        do {
            let result = try HermesMCPInstaller.installSauronMemory(
                endpoint: appState.settings.mcpEndpointURL,
                token: token
            )
            status = result.message
        } catch {
            status = error.localizedDescription
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            let (client, _) = try appState.makeClient()
            let listed = try await client.testConnection()
            models = listed
            status = listed.isEmpty
                ? "Connected, but no models were listed."
                : "Connected. \(listed.count) model\(listed.count == 1 ? "" : "s") available."
            if appState.settings.modelID.isEmpty, let first = listed.first {
                appState.settings.modelID = first.id
            }
        } catch {
            status = error.localizedDescription
        }
    }
}

struct PermissionsSettingsView: View {
    @State private var permissions: [PermissionStatus] = []

    var body: some View {
        Form {
            Section("On this Mac") {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(permissions) { item in
                        permissionRow(item)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { permissions = await PermissionService.snapshot() }
    }

    private func permissionRow(_ item: PermissionStatus) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(item.title)
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(item.granted ? "On" : "Off")
                .foregroundStyle(item.granted ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
            if !item.granted {
                Button("Enable") {
                    Task {
                        await PermissionService.request(item.id)
                        permissions = await PermissionService.snapshot()
                    }
                }
                .observerGlassButton()
            }
        }
    }
}

struct ResearchSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var tavilyKey: String = KeychainStore.tavilyAPIKey ?? ""

    var body: some View {
        @Bindable var settings = appState.settings
        Form {
            Section("Live Assist") {
                Toggle("Live research & fact-check", isOn: $settings.liveResearchEnabled)
                if settings.providerKind.providesBuiltInWebResearch {
                    Text("During a meeting, Sauron extracts claims and questions and asks \(settings.providerKind.displayName) to research them with its built-in tools. Tavily is not used with this provider.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("During a meeting, Sauron extracts short claims and questions from the transcript. With a Tavily key, it can fact-check and research on the web.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Stepper(
                    "Max queries per meeting: \(settings.maxResearchQueriesPerMeeting)",
                    value: $settings.maxResearchQueriesPerMeeting,
                    in: 0...20
                )
                Stepper(
                    "Cooldown: \(Int(settings.researchCooldownSeconds))s",
                    value: $settings.researchCooldownSeconds,
                    in: 10...180,
                    step: 5
                )
            }

            if settings.usesTavilyForResearch {
                Section("Tavily account") {
                    SecureField("API key", text: $tavilyKey)
                        .onChange(of: tavilyKey) { _, value in
                            KeychainStore.tavilyAPIKey = value
                        }
                    Picker("API", selection: $settings.tavilyAPIMode) {
                        ForEach(TavilyAPIMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Text(settings.tavilyAPIMode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if settings.tavilyAPIMode != .research {
                    Section("Search") {
                        Picker("Depth", selection: $settings.tavilySearchDepth) {
                            ForEach(TavilySearchDepth.allCases) { depth in
                                Text(depth.title).tag(depth)
                            }
                        }
                        Stepper(
                            "Results per query: \(settings.tavilyMaxResults)",
                            value: $settings.tavilyMaxResults,
                            in: 1...20
                        )
                        Stepper(
                            "Chunks per source: \(settings.tavilyChunksPerSource)",
                            value: $settings.tavilyChunksPerSource,
                            in: 1...3
                        )
                        .disabled(settings.tavilySearchDepth == .ultraFast)
                        if settings.tavilySearchDepth == .ultraFast {
                            Text("Chunks per source is unavailable for Ultra-fast depth.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if settings.tavilyAPIMode != .search {
                    Section("Research") {
                        Picker("Model", selection: $settings.tavilyResearchModel) {
                            ForEach(TavilyResearchModel.allCases) { model in
                                Text(model.title).tag(model)
                            }
                        }
                        Text(settings.tavilyResearchModel.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Output length", selection: $settings.tavilyResearchOutputLength) {
                            ForEach(TavilyResearchOutputLength.allCases) { length in
                                Text(length.title).tag(length)
                            }
                        }
                        Text("Research runs as a background Tavily task and may take longer than Search. Prefer Mini + Short during live meetings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Domains") {
                    TextField("Allowed domains", text: $settings.tavilyIncludeDomains, prompt: Text("sec.gov, reuters.com"))
                    Text("Optional soft preference. Comma or newline separated hosts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Blocked domains", text: $settings.tavilyExcludeDomains, prompt: Text("reddit.com, quora.com"))
                    Text("Hard blocklist for Search and Research. Comma or newline separated hosts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Text("Only short claim or question text is sent to Tavily. Audio and video never leave this Mac. Past-meeting recall uses Settings → Memory.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Web research") {
                    Text("Tavily is disabled while Models → Backend is \(settings.providerKind.displayName). Switch to Ollama, LM Studio, or OpenRouter to configure Tavily again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct PeopleSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var selfName: String = ""
    @State private var newPersonName: String = ""

    private var store: SpeakerProfileStore { SpeakerProfileStore.shared }
    private var fluid: FluidAudioModelStore { appState.fluidModels }

    var body: some View {
        @Bindable var settings = appState.settings
        Form {
            Section("You") {
                TextField("Your name", text: $selfName)
                    .onSubmit { commitSelfName() }
                    .onChange(of: selfName) { _, _ in }
                Text("Your microphone is always labeled with this name. It is never diarized.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("People") {
                if store.otherProfiles.isEmpty {
                    Text("Add colleagues here, then assign auto-detected speakers to them in a meeting report.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(store.otherProfiles, id: \.id) { profile in
                    HStack {
                        TextField("Name", text: Binding(
                            get: { profile.name },
                            set: { store.rename(profile, to: $0) }
                        ))
                        Button(role: .destructive) {
                            store.delete(profile)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Add person", text: $newPersonName)
                        .onSubmit { addPerson() }
                    Button("Add") { addPerson() }
                        .disabled(newPersonName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Section("On-device speech") {
                Toggle("Neural speaker separation", isOn: $settings.neuralDiarizationEnabled)
                    .onChange(of: settings.neuralDiarizationEnabled) { _, enabled in
                        appState.diarizer.setPreferNeural(enabled)
                        if enabled || settings.enhanceTranscriptEnabled {
                            fluid.prepareIfNeeded(enabled: true)
                        }
                    }
                Toggle("Enhance transcript after meeting", isOn: $settings.enhanceTranscriptEnabled)
                    .onChange(of: settings.enhanceTranscriptEnabled) { _, enabled in
                        if enabled || settings.neuralDiarizationEnabled {
                            fluid.prepareIfNeeded(enabled: true)
                        }
                    }
                LabeledContent("Diarization models") {
                    Text(fluid.diarizationStatus.title)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Parakeet ASR") {
                    Text(fluid.asrStatus.title)
                        .foregroundStyle(.secondary)
                }
                if fluid.isPreparing {
                    ProgressView()
                        .controlSize(.small)
                } else if !fluid.modelsReady {
                    Button("Download models") {
                        fluid.prepareIfNeeded(enabled: true)
                    }
                }
                Text("Sortformer separates remote voices on the Apple Neural Engine. Parakeet retranscribes saved audio after the call for higher accuracy — live captions stay on Apple Speech so capture stays fast. Audio never leaves this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = fluid.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section {
                Text("Remote voices are clustered during capture. Assign Speaker 1, Speaker 2, … to these people in the report so future meetings can auto-match.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            store.attach(context: appState.modelContext)
            selfName = store.selfProfile.name
            if settings.neuralDiarizationEnabled || settings.enhanceTranscriptEnabled {
                fluid.prepareIfNeeded(enabled: true)
            }
        }
        .onDisappear {
            commitSelfName()
        }
    }

    private func commitSelfName() {
        store.renameSelf(to: selfName)
        selfName = store.selfProfile.name
    }

    private func addPerson() {
        let name = newPersonName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        store.addPerson(name: name)
        newPersonName = ""
    }
}
