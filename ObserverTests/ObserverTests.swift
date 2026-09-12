import AppKit
import XCTest
@testable import Observer

final class MeetingAppCatalogTests: XCTestCase {
    func testZoomNativeMeeting() {
        XCTAssertEqual(
            MeetingAppCatalog.match(
                bundleIdentifier: "us.zoom.xos",
                appName: "zoom.us",
                windowTitle: "Weekly sync"
            ),
            .zoom
        )
    }

    func testZoomHomeWindowIgnored() {
        XCTAssertNil(
            MeetingAppCatalog.match(
                bundleIdentifier: "us.zoom.xos",
                appName: "zoom.us",
                windowTitle: "Zoom Workplace"
            )
        )
    }

    func testGoogleMeetInChrome() {
        XCTAssertEqual(
            MeetingAppCatalog.match(
                bundleIdentifier: "com.google.Chrome",
                appName: "Google Chrome",
                windowTitle: "Standup - Meet - Google Chrome"
            ),
            .meet
        )
    }

    func testMeetDoesNotMatchRandomTab() {
        XCTAssertNil(
            MeetingAppCatalog.match(
                bundleIdentifier: "com.google.Chrome",
                appName: "Google Chrome",
                windowTitle: "How to meet people - Google Chrome"
            )
        )
    }

    func testTeamsMeeting() {
        XCTAssertEqual(
            MeetingAppCatalog.match(
                bundleIdentifier: "com.microsoft.teams2",
                appName: "Microsoft Teams",
                windowTitle: "Meeting with Chase Elder | Microsoft Teams"
            ),
            .teams
        )
        XCTAssertEqual(
            MeetingAppCatalog.match(
                bundleIdentifier: "com.microsoft.teams2",
                appName: "Microsoft Teams",
                windowTitle: "Design review | Microsoft Teams"
            ),
            .teams
        )
    }

    func testTeamsShellWindowsIgnored() {
        XCTAssertNil(
            MeetingAppCatalog.match(
                bundleIdentifier: "com.microsoft.teams2",
                appName: "Microsoft Teams",
                windowTitle: "Calendar | (External) | Microsoft Teams"
            )
        )
        XCTAssertNil(
            MeetingAppCatalog.match(
                bundleIdentifier: "com.microsoft.teams2",
                appName: "Microsoft Teams",
                windowTitle: "Chat | Braian Ramirez | Microsoft Teams"
            )
        )
        XCTAssertNil(
            MeetingAppCatalog.match(
                bundleIdentifier: "com.microsoft.teams2",
                appName: "Microsoft Teams",
                windowTitle: "Calendar | Microsoft Teams"
            )
        )
    }

    func testMeetingWindowPickerPrefersCallStage() {
        let calendar = MeetingCandidate(
            id: "a",
            kind: .teams,
            appName: "Microsoft Teams",
            bundleIdentifier: "com.microsoft.teams2",
            windowTitle: "Calendar | Microsoft Teams",
            windowID: 1,
            isSimulated: false,
            calendarEventTitle: nil,
            pixelArea: 2_000_000
        )
        let meeting = MeetingCandidate(
            id: "b",
            kind: .teams,
            appName: "Microsoft Teams",
            bundleIdentifier: "com.microsoft.teams2",
            windowTitle: "Meeting with Chase Elder | Microsoft Teams",
            windowID: 2,
            isSimulated: false,
            calendarEventTitle: nil,
            pixelArea: 900_000
        )
        XCTAssertEqual(MeetingWindowPicker.best(from: [calendar, meeting])?.windowID, 2)
    }

    func testSlackHuddleOnly() {
        XCTAssertEqual(
            MeetingAppCatalog.match(
                bundleIdentifier: "com.tinyspeck.slackmacgap",
                appName: "Slack",
                windowTitle: "Huddle with design"
            ),
            .slack
        )
        XCTAssertNil(
            MeetingAppCatalog.match(
                bundleIdentifier: "com.tinyspeck.slackmacgap",
                appName: "Slack",
                windowTitle: "#general"
            )
        )
    }

    func testFaceTime() {
        XCTAssertEqual(
            MeetingAppCatalog.match(
                bundleIdentifier: "com.apple.FaceTime",
                appName: "FaceTime",
                windowTitle: "FaceTime"
            ),
            .faceTime
        )
    }

    func testSimulated() {
        XCTAssertEqual(
            MeetingAppCatalog.match(
                bundleIdentifier: "app.observer.simulate",
                appName: "Observer",
                windowTitle: "Simulated meeting"
            ),
            .simulated
        )
    }
}

final class MeetingSummaryTests: XCTestCase {
    func testParsesJSON() throws {
        let raw = """
        {
          "title": "Launch review",
          "summary": "We locked Friday.",
          "notes": ["Design is ready"],
          "keyPeople": ["Ada", "Chase"],
          "topics": ["Launch"],
          "decisions": ["Ship Friday"],
          "actionItems": [{"owner": "Ada", "text": "Cut the branch", "due": "Thursday"}],
          "nextSteps": ["Notify support"],
          "blockers": ["Waiting on legal"],
          "openQuestions": ["Who pages?"],
          "quotes": ["Let's ship it"]
        }
        """
        let summary = Summarizer.parse(raw)
        XCTAssertEqual(summary.title, "Launch review")
        XCTAssertEqual(summary.notes, ["Design is ready"])
        XCTAssertEqual(summary.keyPeople, ["Ada", "Chase"])
        XCTAssertEqual(summary.topics, ["Launch"])
        XCTAssertEqual(summary.decisions, ["Ship Friday"])
        XCTAssertEqual(summary.actionItems.first?.owner, "Ada")
        XCTAssertEqual(summary.actionItems.first?.text, "Cut the branch")
        XCTAssertEqual(summary.actionItems.first?.due, "Thursday")
        XCTAssertEqual(summary.nextSteps, ["Notify support"])
        XCTAssertEqual(summary.blockers, ["Waiting on legal"])
    }

    func testLegacyJSONStillParses() {
        let raw = """
        {
          "title": "A",
          "summary": "B",
          "decisions": [],
          "actionItems": [{"owner": null, "text": "Do thing"}],
          "openQuestions": [],
          "quotes": []
        }
        """
        let summary = Summarizer.parse(raw)
        XCTAssertEqual(summary.title, "A")
        XCTAssertTrue(summary.notes.isEmpty)
        XCTAssertEqual(summary.actionItems.first?.text, "Do thing")
    }

    func testExtractsFencedJSON() {
        let raw = """
        Sure.
        ```json
        {"title":"A","summary":"B","decisions":[],"actionItems":[],"openQuestions":[],"quotes":[]}
        ```
        """
        let summary = Summarizer.parse(raw)
        XCTAssertEqual(summary.title, "A")
        XCTAssertEqual(summary.summary, "B")
    }

    func testFallsBackToRawText() {
        let summary = Summarizer.parse("not json at all")
        XCTAssertEqual(summary.summary, "not json at all")
        XCTAssertEqual(summary.title, "Meeting notes")
    }
}

final class PermissionProbeTests: XCTestCase {
    func testNewlyGrantedScreenRequiresRelaunch() {
        let live = PermissionProbe.Snapshot(screen: false, windows: false, mic: true, speech: true, calendar: true)
        let fresh = PermissionProbe.Snapshot(screen: true, windows: true, mic: true, speech: true, calendar: true)
        XCTAssertTrue(fresh.hasNewlyGranted(comparedTo: live))
    }

    func testMatchingSnapshotsDoNotRelaunch() {
        let live = PermissionProbe.Snapshot(screen: false, windows: false, mic: true, speech: false, calendar: false)
        XCTAssertFalse(live.hasNewlyGranted(comparedTo: live))
    }

    func testDeniedFreshProcessDoesNotRelaunch() {
        let live = PermissionProbe.Snapshot(screen: false, windows: false, mic: false, speech: false, calendar: false)
        let fresh = PermissionProbe.Snapshot(screen: false, windows: false, mic: false, speech: false, calendar: false)
        XCTAssertFalse(fresh.hasNewlyGranted(comparedTo: live))
    }

    func testEmptyPermissionsAreNotAllGranted() {
        let empty: [PermissionStatus] = []
        XCTAssertFalse(empty.allGranted)
    }

    func testAllPermissionsGranted() {
        let items = [
            PermissionStatus(id: "screen", title: "S", detail: "", granted: true, required: true, systemImage: "eye"),
            PermissionStatus(id: "mic", title: "M", detail: "", granted: true, required: true, systemImage: "mic")
        ]
        XCTAssertTrue(items.allGranted)
    }
}

final class CaptureMediaTests: XCTestCase {
    func testVideoAndAudioIncludesVisualAndAudio() {
        XCTAssertEqual(CaptureMedia.videoAndAudio.modes(transcript: false), [.visual, .audio])
        XCTAssertEqual(
            CaptureMedia.videoAndAudio.modes(transcript: true),
            [.visual, .audio, .transcript]
        )
    }

    func testAudioOnlyNeverIncludesVisual() {
        XCTAssertEqual(CaptureMedia.audioOnly.modes(transcript: false), [.audio])
        XCTAssertEqual(CaptureMedia.audioOnly.modes(transcript: true), [.audio, .transcript])
    }
}

final class CaptureAudioSourceTests: XCTestCase {
    func testDefaultIsSystem() {
        XCTAssertEqual(CaptureAudioSource.system.liveLabel, "System")
        XCTAssertEqual(CaptureAudioSource.meetingApp.liveLabel, "App")
    }

    func testSilenceCopyNamesEachSource() {
        XCTAssertTrue(AudioSignalSource.microphone.silentMessage.contains("microphone"))
        XCTAssertTrue(AudioSignalSource.system.silentMessage.contains("system audio"))
        XCTAssertTrue(AudioSignalSource.meetingApp.silentMessage.contains("meeting app"))
    }
}

final class AudioDeviceCatalogTests: XCTestCase {
    func testResolvedPriorityPinsSystemDefaultFirst() {
        let resolved = AudioDeviceCatalog.resolvedPriority(savedIDs: ["fake-id"])
        XCTAssertEqual(resolved.first?.id, AudioInputDevice.systemDefaultID)
        XCTAssertTrue(resolved.first?.isSystemDefault == true)
        XCTAssertNil(resolved.first?.captureDeviceID)
    }
}

final class RecordedMeetingWatchTests: XCTestCase {
    func testSameWindowCountsAsPresent() {
        let zoom = candidate(kind: .zoom, bundle: "us.zoom.xos", windowID: 12)
        XCTAssertNotNil(
            RecordedMeetingWatch.continuingMatch(
                sessionKey: zoom.sessionKey,
                windowID: zoom.windowID,
                bundleIdentifier: zoom.bundleIdentifier,
                kind: zoom.kind,
                in: [zoom]
            )
        )
    }

    func testSameAppNewWindowCountsAsContinuingMeeting() {
        // Zoom/Teams often mint a new window ID mid-call; catalog already excludes
        // home chrome, so another same-app match means the call moved.
        let original = candidate(kind: .zoom, bundle: "us.zoom.xos", windowID: 12)
        let replaced = candidate(kind: .zoom, bundle: "us.zoom.xos", windowID: 99)
        let match = RecordedMeetingWatch.continuingMatch(
            sessionKey: original.sessionKey,
            windowID: original.windowID,
            bundleIdentifier: original.bundleIdentifier,
            kind: original.kind,
            in: [replaced]
        )
        XCTAssertEqual(match?.windowID, 99)
    }

    func testDifferentAppDoesNotCount() {
        let zoom = candidate(kind: .zoom, bundle: "us.zoom.xos", windowID: 12)
        let teams = candidate(kind: .teams, bundle: "com.microsoft.teams2", windowID: 4)
        XCTAssertNil(
            RecordedMeetingWatch.continuingMatch(
                sessionKey: zoom.sessionKey,
                windowID: zoom.windowID,
                bundleIdentifier: zoom.bundleIdentifier,
                kind: zoom.kind,
                in: [teams]
            )
        )
    }

    func testEmptyMatchesMeansMeetingEnded() {
        let zoom = candidate(kind: .zoom, bundle: "us.zoom.xos", windowID: 12)
        XCTAssertNil(
            RecordedMeetingWatch.continuingMatch(
                sessionKey: zoom.sessionKey,
                windowID: zoom.windowID,
                bundleIdentifier: zoom.bundleIdentifier,
                kind: zoom.kind,
                in: []
            )
        )
    }

    private func candidate(kind: MeetingKind, bundle: String, windowID: UInt32) -> MeetingCandidate {
        MeetingCandidate(
            id: "\(bundle):\(windowID)",
            kind: kind,
            appName: kind.displayName,
            bundleIdentifier: bundle,
            windowTitle: "Weekly sync",
            windowID: windowID,
            isSimulated: false,
            calendarEventTitle: nil
        )
    }
}

final class LLMURLTests: XCTestCase {
    func testOpenAIRootDoesNotDuplicateV1() {
        XCTAssertEqual(
            LLMClient.openAIRoot(URL(string: "https://openrouter.ai/api/v1")!).absoluteString,
            "https://openrouter.ai/api/v1"
        )
        XCTAssertEqual(
            LLMClient.openAIRoot(URL(string: "http://127.0.0.1:11434")!).absoluteString,
            "http://127.0.0.1:11434/v1"
        )
    }
}

final class SpeakerKeyTests: XCTestCase {
    func testLegacyYouAndOthersNormalize() {
        XCTAssertEqual(SpeakerKey.normalize("you"), SpeakerKey.selfKey)
        XCTAssertEqual(SpeakerKey.normalize("others"), SpeakerKey.cluster(1))
        XCTAssertTrue(SpeakerKey.isSelf("you"))
        XCTAssertEqual(SpeakerKey.clusterIndex("cluster:3"), 3)
    }

    func testProfileKeyRoundTrip() {
        let id = UUID()
        let key = SpeakerKey.profile(id)
        XCTAssertEqual(SpeakerKey.profileID(key), id)
        XCTAssertEqual(SpeakerKey.fallbackDisplayName(SpeakerKey.cluster(2)), "Speaker 2")
    }
}

final class TavilyClientTests: XCTestCase {
    func testDecodesSearchPayloadShape() throws {
        let json = """
        {
          "answer": "Yes.",
          "results": [
            {"title": "Example", "url": "https://example.com", "content": "Hello"}
          ]
        }
        """.data(using: .utf8)!
        let object = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        XCTAssertEqual(object?["answer"] as? String, "Yes.")
        let results = object?["results"] as? [[String: Any]]
        XCTAssertEqual(results?.first?["title"] as? String, "Example")
    }

    func testParsesDomainList() {
        let domains = TavilyDomainList.parse("sec.gov, https://www.reuters.com\nreddit.com")
        XCTAssertEqual(domains, ["sec.gov", "reuters.com", "reddit.com"])
    }

    func testSearchDepthRawValuesMatchAPI() {
        XCTAssertEqual(TavilySearchDepth.ultraFast.rawValue, "ultra-fast")
        XCTAssertEqual(TavilySearchDepth.advanced.rawValue, "advanced")
    }
}

final class MeetingMemoryTests: XCTestCase {
    func testChunkerBuildsSummaryAndTranscriptWindows() {
        let summary = MeetingSummary(
            title: "Sync",
            summary: "We talked about launch.",
            notes: ["Note A"],
            keyPeople: [],
            topics: ["Launch"],
            decisions: ["Ship Friday"],
            actionItems: [ActionItem(owner: "Chase", text: "Write docs", due: nil)],
            nextSteps: [],
            blockers: [],
            openQuestions: ["Who owns QA?"],
            quotes: []
        )
        let segments = (0..<15).map { i in
            (start: TimeInterval(i), end: TimeInterval(i) + 1, text: "Line \(i) about the launch plan.")
        }
        let chunks = MeetingChunker.chunks(
            meetingID: UUID(),
            title: "Sync",
            date: .now,
            transcriptSegments: segments,
            summary: summary
        )
        XCTAssertTrue(chunks.contains { $0.kind == .summary })
        XCTAssertTrue(chunks.contains { $0.kind == .action })
        XCTAssertTrue(chunks.contains { $0.kind == .transcript })
        XCTAssertGreaterThanOrEqual(chunks.filter { $0.kind == .transcript }.count, 2)
    }

    func testDocumentChunksIncludeFilenamePrefixAndWindows() {
        let body = String(repeating: "Launch checklist item. ", count: 80)
        XCTAssertGreaterThan(body.count, 1000)
        let chunks = MeetingChunker.documentChunks(
            meetingID: UUID(),
            title: "Sync",
            date: .now,
            documents: [("roadmap.md", body)]
        )
        XCTAssertGreaterThanOrEqual(chunks.count, 2)
        XCTAssertTrue(chunks.allSatisfy { $0.kind == .document })
        XCTAssertTrue(chunks.allSatisfy { $0.text.hasPrefix("Document: roadmap.md\n") })
    }

    func testChunksIncludeDocumentsWithoutTranscript() {
        let chunks = MeetingChunker.chunks(
            meetingID: UUID(),
            title: "Docs only",
            date: .now,
            transcriptSegments: [],
            summary: nil,
            documents: [("notes.txt", "Stakeholder approved the pricing change for Q4.")]
        )
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].kind, .document)
        XCTAssertTrue(chunks[0].text.contains("pricing change"))
    }

    func testDocumentTextExtractorReadsPlainTextAndRTF() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "observer-doc-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let txt = dir.appending(path: "brief.txt")
        try "Observer indexes attached briefs.".write(to: txt, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            try DocumentTextExtractor.extract(url: txt),
            "Observer indexes attached briefs."
        )

        let rtf = dir.appending(path: "brief.rtf")
        let attributed = NSAttributedString(string: "RTF action item for launch.")
        let rtfData = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        try rtfData.write(to: rtf)
        XCTAssertEqual(
            try DocumentTextExtractor.extract(url: rtf),
            "RTF action item for launch."
        )
    }

    func testMeetingDocumentStoreAttachAndRemove() throws {
        let meetingID = UUID()
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "observer-meeting-root-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            MediaStore.customMeetingsRoot = nil
            try? FileManager.default.removeItem(at: dir)
        }
        MediaStore.customMeetingsRoot = dir

        let source = dir.appending(path: "source-notes.md")
        try "# Agenda\nShip memory documents.".write(to: source, atomically: true, encoding: .utf8)
        let attached = try MeetingDocumentStore.attach(urls: [source], to: meetingID)
        XCTAssertEqual(attached.count, 1)
        XCTAssertEqual(MeetingDocumentStore.list(for: meetingID).count, 1)
        let texts = MeetingDocumentStore.extractableTexts(for: meetingID)
        XCTAssertEqual(texts.count, 1)
        XCTAssertTrue(texts[0].text.contains("Ship memory documents"))

        try MeetingDocumentStore.remove(id: attached[0].id, from: meetingID)
        XCTAssertTrue(MeetingDocumentStore.list(for: meetingID).isEmpty)
    }

    func testCosineIdenticalVectors() {
        let v: [Float] = [1, 0, 0]
        XCTAssertEqual(MeetingMemoryStore.cosine(v, v), 1, accuracy: 0.0001)
        XCTAssertEqual(MeetingMemoryStore.cosine(v, [0, 1, 0]), 0, accuracy: 0.0001)
    }

    func testMemoryMCPToolCatalog() {
        let names = MemoryMCPHandlers.toolNames
        XCTAssertEqual(names, [
            "search_meetings",
            "get_meeting",
            "list_recent_meetings",
            "memory_status"
        ])
    }

    func testMemoryMCPArgParsing() {
        XCTAssertEqual(MemoryMCPHandlers.stringArg("hello"), "hello")
        XCTAssertEqual(MemoryMCPHandlers.intArg(6), 6)
        XCTAssertEqual(MemoryMCPHandlers.intArg(6.0), 6)
        XCTAssertEqual(MemoryMCPHandlers.floatArg(0.42) ?? -1, Float(0.42), accuracy: 0.0001)
        XCTAssertEqual(MemoryMCPHandlers.stringArg(AnyCodable("x")), "x")
    }

    func testMemoryQueryErrorDisabledMessage() {
        XCTAssertEqual(
            MemoryQueryError.memoryDisabled.localizedDescription,
            "Meeting memory is disabled in Observer settings."
        )
    }

    func testFormatContextEmpty() {
        XCTAssertEqual(MeetingMemoryStore.formatContext([]), "")
    }

    @MainActor
    func testShouldInjectMemoryRespectsAgentProviders() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "observer.tests.mcp.\(UUID().uuidString)")!)
        settings.memoryEnabled = true
        settings.providerKind = .ollama
        XCTAssertTrue(settings.shouldInjectMemoryIntoPrompts)
        settings.providerKind = .hermes
        XCTAssertFalse(settings.shouldInjectMemoryIntoPrompts)
        settings.providerKind = .openClaw
        XCTAssertFalse(settings.shouldInjectMemoryIntoPrompts)
        settings.memoryEnabled = false
        settings.providerKind = .ollama
        XCTAssertFalse(settings.shouldInjectMemoryIntoPrompts)
    }

    func testTrackedItemFingerprintStable() {
        let a = TrackedItemStore.fingerprint(kind: .action, text: "Write Docs", owner: "Chase")
        let b = TrackedItemStore.fingerprint(kind: .action, text: "  write   docs ", owner: "chase")
        XCTAssertEqual(a, b)
    }

    func testReconcilerParsesResolvedJSON() {
        let id = UUID()
        let raw = """
        {"resolved":[{"id":"\(id.uuidString)","note":"Done in standup"}]}
        """
        let parsed = TrackedItemReconciler.parse(raw)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.id, id)
        XCTAssertEqual(parsed.first?.note, "Done in standup")
    }
}
