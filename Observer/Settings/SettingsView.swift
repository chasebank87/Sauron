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
            ProviderSettingsView()
                .environment(appState)
                .tabItem { Label("Models", systemImage: "cpu") }
            PermissionsSettingsView()
                .environment(appState)
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
            ResearchSettingsView()
                .tabItem { Label("Research", systemImage: "globe") }
        }
        .frame(width: 560, height: 460)
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
                Text("Observer looks for Zoom, Meet, Teams, FaceTime, Webex, and Slack huddles. It never joins the call.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct DevicesSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var devices: [AudioInputDevice] = []

    var body: some View {
        Form {
            Section("Microphone priority") {
                Text("Observer tries #1 first. If that mic stays silent during a recording, it automatically falls through to the next device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(index == 0 ? ObserverTheme.accent : .secondary)
                            .frame(width: 22, height: 22)
                            .background {
                                Circle()
                                    .fill(index == 0 ? ObserverTheme.accent.opacity(0.15) : Color.primary.opacity(0.06))
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
                }
                TextField("Model", text: $settings.modelID, prompt: Text("First available"))
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
                Text("Only transcript text is sent to the selected model. Audio and video never leave this Mac. Ollama and LM Studio stay on localhost.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
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
    var body: some View {
        Form {
            Section("Coming in Phase 2") {
                Text("Live fact-checking and research will use Tavily for web results. Audio still stays on-device; only short text queries go out.")
                    .foregroundStyle(.secondary)
                Text("Phase 3 adds RAG over your past meetings so Observer can recall decisions from earlier calls.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
