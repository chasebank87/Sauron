import AppKit
import CoreMedia
import Darwin
import XCTest
@testable import Sauron

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
                bundleIdentifier: "app.sauron.simulate",
                appName: "Sauron",
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

final class MenuBarMarkAssetTests: XCTestCase {
    func testMenuBarMarkIsTemplateSizedForStatusItem() {
        let image = NSImage(named: "MenuBarMark")
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.isTemplate, true)
        XCTAssertEqual(image?.size, NSSize(width: 18, height: 18))
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
        try "Sauron indexes attached briefs.".write(to: txt, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            try DocumentTextExtractor.extract(url: txt),
            "Sauron indexes attached briefs."
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

    func testPresenceScoresClampOnInitAndDecode() throws {
        let scores = MeetingPresenceScores(
            likeability: 0,
            professionalism: 12,
            receptiveness: 5.5,
            clarity: 1,
            collaboration: 10
        )
        XCTAssertEqual(scores.likeability, 1, accuracy: 0.001)
        XCTAssertEqual(scores.professionalism, 10, accuracy: 0.001)
        XCTAssertEqual(scores.receptiveness, 5.5, accuracy: 0.001)

        let raw = """
        {"likeability":-3,"professionalism":15,"receptiveness":7,"clarity":8,"collaboration":9,"note":"Stay concise."}
        """
        let data = try XCTUnwrap(raw.data(using: .utf8))
        let decoded = try JSONDecoder().decode(MeetingPresenceScores.self, from: data)
        XCTAssertEqual(decoded.likeability, 1, accuracy: 0.001)
        XCTAssertEqual(decoded.professionalism, 10, accuracy: 0.001)
        XCTAssertEqual(decoded.note, "Stay concise.")
    }

    func testPresenceHeuristicsScorerParsesJSON() throws {
        let raw = """
        ```json
        {
          "likeability": 7,
          "professionalism": 8,
          "receptiveness": 6,
          "clarity": 7.5,
          "collaboration": 8,
          "note": "Invite quieter voices in."
        }
        ```
        """
        let scores = try XCTUnwrap(PresenceHeuristicsScorer.parse(raw))
        XCTAssertEqual(scores.likeability, 7, accuracy: 0.001)
        XCTAssertEqual(scores.clarity, 7.5, accuracy: 0.001)
        XCTAssertEqual(scores.note, "Invite quieter voices in.")
        XCTAssertNil(PresenceHeuristicsScorer.parse("not json"))
    }

    func testTalkMetricsSumsSelfSegmentsAndClampsShare() {
        let segments: [(isSelf: Bool, start: TimeInterval, end: TimeInterval)] = [
            (true, 0, 10),
            (false, 10, 40),
            (true, 40, 55),
            (true, 60, 58) // negative duration ignored via max(0, ...)
        ]
        let talk = MeetingTalkMetrics.selfTalkDuration(segments: segments)
        XCTAssertEqual(talk, 25, accuracy: 0.001)
        XCTAssertEqual(MeetingTalkMetrics.talkShare(selfTalk: 25, meetingDuration: 100), 0.25, accuracy: 0.001)
        XCTAssertEqual(MeetingTalkMetrics.talkShare(selfTalk: 50, meetingDuration: 0), 0, accuracy: 0.001)
        XCTAssertEqual(MeetingTalkMetrics.talkShare(selfTalk: 200, meetingDuration: 100), 1, accuracy: 0.001)
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
            "Meeting memory is disabled in Sauron settings."
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

    @MainActor
    func testAgentProvidersUseSeparateEmbeddingBackend() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "observer.tests.embed.\(UUID().uuidString)")!)
        settings.providerKind = .ollama
        XCTAssertEqual(settings.resolvedEmbeddingProviderKind, .ollama)
        XCTAssertFalse(settings.usesSeparateEmbeddingProvider)

        settings.providerKind = .hermes
        settings.embeddingProviderKind = .openRouter
        XCTAssertTrue(settings.usesSeparateEmbeddingProvider)
        XCTAssertEqual(settings.resolvedEmbeddingProviderKind, .openRouter)
        XCTAssertEqual(SettingsStore.defaultEmbeddingModel(for: settings.resolvedEmbeddingProviderKind), "openai/text-embedding-3-small")

        settings.embeddingProviderKind = .hermes // invalid for embeddings → coerced to ollama
        XCTAssertEqual(settings.embeddingProviderKind, .ollama)
        XCTAssertEqual(settings.resolvedEmbeddingProviderKind, .ollama)
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

final class SpeakerDiarizerTests: XCTestCase {
    func testPitchGatedMergeRejectsMaleFemaleFingerprints() {
        // Synthetic fingerprints: shared bands, divergent normalized log-F0.
        var male = [Float](repeating: 0.1, count: 18)
        male.append(0.15) // low F0 bin
        male.append(contentsOf: [Float](repeating: 0.2, count: 8))
        var female = [Float](repeating: 0.1, count: 18)
        female.append(0.85) // high F0 bin
        female.append(contentsOf: [Float](repeating: 0.05, count: 8))
        XCTAssertFalse(SpeakerDiarizer.pitchCompatible(male, female, maxLogF0Delta: 0.22))
        XCTAssertTrue(SpeakerDiarizer.pitchCompatible(male, male, maxLogF0Delta: 0.22))
    }

    func testLongTurnSegmentationReturnsAtLeastOneSlice() {
        let rate = 16_000.0
        let samples = (0..<Int(rate * 0.8)).map { i -> Float in
            sinf(2 * .pi * 120 * Float(i) / Float(rate)) * 0.2
        }
        let slices = SpeakerDiarizer.segmentTurn(
            samples: samples,
            sampleRate: rate,
            turnStart: 0,
            turnEnd: 0.8
        )
        XCTAssertFalse(slices.isEmpty)
        XCTAssertFalse(slices[0].fingerprint.isEmpty)
    }
}

final class MeetingUserNotesChunkTests: XCTestCase {
    func testUserNotesBecomeMemoryChunks() {
        let chunks = MeetingChunker.chunks(
            meetingID: UUID(),
            title: "Sync",
            date: .now,
            transcriptSegments: [],
            summary: nil,
            userNotes: "Follow up with design on the palette."
        )
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].kind, .userNote)
        XCTAssertTrue(chunks[0].text.contains("Your notes:"))
        XCTAssertTrue(chunks[0].text.contains("palette"))
    }
}

final class DiarizationTimelineMapperTests: XCTestCase {
    func testSortformerIndexMapsToCluster() {
        XCTAssertEqual(DiarizationTimelineMapper.clusterKey(sortformerIndex: 0), SpeakerKey.cluster(1))
        XCTAssertEqual(DiarizationTimelineMapper.clusterKey(sortformerIndex: 3), SpeakerKey.cluster(4))
    }

    func testMajorityOverlapWins() {
        let turns = [
            DiarizationTimelineMapper.Turn(start: 0, end: 5, speakerKey: SpeakerKey.cluster(1)),
            DiarizationTimelineMapper.Turn(start: 5, end: 12, speakerKey: SpeakerKey.cluster(2))
        ]
        XCTAssertEqual(
            DiarizationTimelineMapper.speakerKey(turns: turns, at: 6, end: 10),
            SpeakerKey.cluster(2)
        )
        XCTAssertEqual(
            DiarizationTimelineMapper.speakerKey(turns: turns, at: 0.5, end: 2),
            SpeakerKey.cluster(1)
        )
    }

    func testEmptyTurnsUseFallback() {
        XCTAssertEqual(
            DiarizationTimelineMapper.speakerKey(turns: [], at: 0, end: 1, fallback: SpeakerKey.cluster(3)),
            SpeakerKey.cluster(3)
        )
    }
}

final class DiarizationRouterTests: XCTestCase {
    func testFallsBackToClassicWhenNeuralMissing() {
        let router = DiarizationRouter()
        router.setPreferNeural(true)
        XCTAssertFalse(router.isUsingNeural)
        router.start(profilePrints: [])
        XCTAssertEqual(router.speakerKey(at: 0, end: 1), SpeakerKey.cluster(1))
        router.stop()
    }

    func testPreferNeuralOffKeepsClassicEvenIfAttached() {
        let router = DiarizationRouter()
        let neural = NeuralMeetingDiarizer()
        router.attachNeural(neural)
        router.setPreferNeural(false)
        XCTAssertFalse(router.isUsingNeural)
    }
}

final class ParakeetRetranscriberTests: XCTestCase {
    func testTagRemoteKeepsSelfAndMapsOthers() {
        let turns = [
            DiarizationTimelineMapper.Turn(start: 0, end: 4, speakerKey: SpeakerKey.cluster(2))
        ]
        let segments = [
            LiveSegment(id: UUID(), speakerKey: SpeakerKey.selfKey, text: "Hi", start: 0, end: 1, isFinal: true),
            LiveSegment(id: UUID(), speakerKey: SpeakerKey.cluster(1), text: "Hello", start: 1, end: 3, isFinal: true)
        ]
        let tagged = ParakeetRetranscriber.tagRemote(segments: segments, turns: turns)
        XCTAssertEqual(tagged[0].speakerKey, SpeakerKey.selfKey)
        XCTAssertEqual(tagged[1].speakerKey, SpeakerKey.cluster(2))
    }

    func testMergeRejectsTooShortUpgrade() {
        let existing = [
            LiveSegment(
                id: UUID(),
                speakerKey: SpeakerKey.selfKey,
                text: String(repeating: "a", count: 200),
                start: 0,
                end: 5,
                isFinal: true
            )
        ]
        let mic = [
            LiveSegment(id: UUID(), speakerKey: SpeakerKey.selfKey, text: "short", start: 0, end: 1, isFinal: true)
        ]
        XCTAssertNil(
            ParakeetRetranscriber.mergeLanes(
                mic: mic,
                remote: [],
                existing: existing,
                micConfidence: 0.9,
                remoteConfidence: 0.9
            )
        )
    }

    func testMergeAcceptsSubstantialUpgrade() {
        let existing = [
            LiveSegment(id: UUID(), speakerKey: SpeakerKey.selfKey, text: "old", start: 0, end: 1, isFinal: true)
        ]
        let mic = [
            LiveSegment(
                id: UUID(),
                speakerKey: SpeakerKey.selfKey,
                text: String(repeating: "better transcript ", count: 4),
                start: 0,
                end: 2,
                isFinal: true
            )
        ]
        let remote = [
            LiveSegment(
                id: UUID(),
                speakerKey: SpeakerKey.cluster(1),
                text: String(repeating: "remote words ", count: 4),
                start: 2,
                end: 4,
                isFinal: true
            )
        ]
        let merged = ParakeetRetranscriber.mergeLanes(
            mic: mic,
            remote: remote,
            existing: existing,
            micConfidence: 0.8,
            remoteConfidence: 0.8
        )
        XCTAssertEqual(merged?.count, 2)
        XCTAssertEqual(merged?.first?.speakerKey, SpeakerKey.selfKey)
    }
}

final class MenuBarPresentationTests: XCTestCase {
    func testWatchingChipReplacesRedundantSubtitle() {
        XCTAssertEqual(MenuBarPresentation.chipTitle(for: .detecting), "Watching")
        XCTAssertNotEqual(MenuBarPresentation.chipTitle(for: .detecting), "Watching for meetings")
        XCTAssertEqual(MenuBarPresentation.chipTitle(for: .idle), "Idle")
        XCTAssertEqual(MenuBarPresentation.chipTitle(for: .prompt), "Meeting detected")
        XCTAssertEqual(MenuBarPresentation.chipTitle(for: .recording), "Recording")
        XCTAssertEqual(MenuBarPresentation.chipTitle(for: .processing), "Writing report")
    }

    func testLiveDotTracksActiveStates() {
        XCTAssertFalse(MenuBarPresentation.chipIsLive(.idle))
        XCTAssertFalse(MenuBarPresentation.chipIsLive(.detecting))
        XCTAssertTrue(MenuBarPresentation.chipIsLive(.prompt))
        XCTAssertTrue(MenuBarPresentation.chipIsLive(.recording))
        XCTAssertFalse(MenuBarPresentation.chipIsLive(.processing))
    }

    func testRecentIconsUsePeopleForRealMeetingsAndSparklesForGenerated() {
        let real: [MeetingKind] = [.zoom, .teams, .meet, .faceTime, .webex, .slack, .unknown]
        for kind in real {
            XCTAssertEqual(MenuBarPresentation.recentSystemImage(for: kind), "person.2.fill")
            XCTAssertFalse(MenuBarPresentation.recentIsGenerated(kind))
        }
        XCTAssertEqual(MenuBarPresentation.recentSystemImage(for: .simulated), "sparkles")
        XCTAssertTrue(MenuBarPresentation.recentIsGenerated(.simulated))
    }
}

final class LivePaneSharePolicyTests: XCTestCase {
    @MainActor
    func testHideLivePanesWhileSharingDefaultsOn() {
        let suite = "observer.tests.hide-panes.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(defaults: defaults)
        XCTAssertTrue(settings.hideLivePanesWhileSharing)
        settings.hideLivePanesWhileSharing = false
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.hideLivePanesWhileSharing)
    }

    func testHidesOnlyWhenSettingOnSharingAndRecording() {
        XCTAssertTrue(
            LivePaneSharePolicy.shouldHidePanes(
                settingEnabled: true,
                isUserScreenSharing: true,
                isRecording: true
            )
        )
        XCTAssertFalse(
            LivePaneSharePolicy.shouldHidePanes(
                settingEnabled: false,
                isUserScreenSharing: true,
                isRecording: true
            )
        )
        XCTAssertFalse(
            LivePaneSharePolicy.shouldHidePanes(
                settingEnabled: true,
                isUserScreenSharing: false,
                isRecording: true
            )
        )
        XCTAssertFalse(
            LivePaneSharePolicy.shouldHidePanes(
                settingEnabled: true,
                isUserScreenSharing: true,
                isRecording: false
            )
        )
    }
}

final class ScreenShareHoldTests: XCTestCase {
    func testHidesImmediatelyAndRestoresAfterGrace() {
        var hold = ScreenShareHold()
        let start = Date()
        hold.update(detected: true, now: start)
        XCTAssertTrue(hold.isSharing)
        hold.update(detected: false, now: start.addingTimeInterval(0.3))
        XCTAssertTrue(hold.isSharing, "brief gaps should not restore the pane")
        hold.update(detected: false, now: start.addingTimeInterval(1.0))
        XCTAssertFalse(hold.isSharing)
        hold.update(detected: true, now: start.addingTimeInterval(1.1))
        XCTAssertTrue(hold.isSharing)
    }
}

final class LocalScreenShareSignalTests: XCTestCase {
    func testZoomLocalShareToolbar() {
        XCTAssertTrue(
            LocalScreenShareSignal.indicatesLocalShare(
                windowTitle: "You are sharing your screen",
                bundleIdentifier: "us.zoom.xos",
                appName: "zoom.us"
            )
        )
        XCTAssertTrue(
            LocalScreenShareSignal.indicatesLocalShare(
                windowTitle: "You are sharing",
                bundleIdentifier: "us.zoom.xos",
                appName: "zoom.us"
            )
        )
        XCTAssertTrue(
            LocalScreenShareSignal.indicatesLocalShare(
                windowTitle: "Stop sharing",
                bundleIdentifier: "us.zoom.xos",
                appName: "zoom.us"
            )
        )
    }

    func testZoomMeetingWithoutShareStaysVisible() {
        XCTAssertFalse(
            LocalScreenShareSignal.indicatesLocalShare(
                windowTitle: "Weekly sync",
                bundleIdentifier: "us.zoom.xos",
                appName: "zoom.us"
            )
        )
    }

    func testRemoteParticipantShareDoesNotHide() {
        XCTAssertFalse(
            LocalScreenShareSignal.indicatesLocalShare(
                windowTitle: "Jamie is sharing their screen",
                bundleIdentifier: "us.zoom.xos",
                appName: "zoom.us"
            )
        )
    }

    func testTeamsAndMeetPresenterTitles() {
        XCTAssertTrue(
            LocalScreenShareSignal.indicatesLocalShare(
                windowTitle: "You're presenting",
                bundleIdentifier: "com.microsoft.teams2",
                appName: "Microsoft Teams"
            )
        )
        XCTAssertTrue(
            LocalScreenShareSignal.indicatesLocalShare(
                windowTitle: "Presenting now - Meet - Google Chrome",
                bundleIdentifier: "com.google.Chrome",
                appName: "Google Chrome"
            )
        )
        XCTAssertTrue(
            LocalScreenShareSignal.indicatesLocalShare(
                windowTitle: "Standup - Meet - Presenting - Google Chrome",
                bundleIdentifier: "com.google.Chrome",
                appName: "Google Chrome"
            )
        )
    }

    func testMeetTabWithoutPresentingDoesNotHide() {
        XCTAssertFalse(
            LocalScreenShareSignal.indicatesLocalShare(
                windowTitle: "Standup - Meet - Google Chrome",
                bundleIdentifier: "com.google.Chrome",
                appName: "Google Chrome"
            )
        )
    }

    func testSharePointAndShareholderDoNotHide() {
        XCTAssertFalse(
            LocalScreenShareSignal.indicatesLocalShare(
                windowTitle: "SharePoint - Google Chrome",
                bundleIdentifier: "com.google.Chrome",
                appName: "Google Chrome"
            )
        )
        XCTAssertFalse(
            LocalScreenShareSignal.indicatesLocalShare(
                windowTitle: "Shareholder meeting notes",
                bundleIdentifier: "com.google.Chrome",
                appName: "Google Chrome"
            )
        )
    }

    func testFaceTimeScreenSharing() {
        XCTAssertTrue(
            LocalScreenShareSignal.indicatesLocalShare(
                windowTitle: "Screen Sharing",
                bundleIdentifier: "com.apple.FaceTime",
                appName: "FaceTime"
            )
        )
    }

    func testCptHostHelperCountsAsLocalZoomShare() {
        XCTAssertTrue(
            LocalScreenShareSignal.isShareDetected(
                windows: [],
                runningApps: [(bundleIdentifier: "us.zoom.CptHost", appName: "CptHost")]
            )
        )
        XCTAssertFalse(
            LocalScreenShareSignal.isShareDetected(
                windows: [
                    .init(title: "Weekly sync", bundleIdentifier: "us.zoom.xos", appName: "zoom.us")
                ],
                runningApps: [(bundleIdentifier: "us.zoom.xos", appName: "zoom.us")]
            )
        )
    }

    func testSauronOwnRecordingIsNotAShareSignal() {
        XCTAssertFalse(
            LocalScreenShareSignal.indicatesLocalShare(
                windowTitle: "Live Assist",
                bundleIdentifier: "app.sauron.Sauron",
                appName: "Sauron"
            )
        )
    }
}
final class AcousticEchoCancellerTests: XCTestCase {
    func testResampleRoundTripKeepsRequestedCount() {
        let input = (0..<480).map { sin(Float($0) / 8) }
        let down = AudioPCM.resample(input, from: 48_000, to: 16_000)
        XCTAssertEqual(down.count, 160)
        let up = AudioPCM.resample(down, from: 16_000, to: 48_000, count: 480)
        XCTAssertEqual(up.count, 480)
    }

    func testInt16RoundTrip() {
        let values: [Float] = [0, 0.5, -0.5, 1, -1]
        let ints = AudioPCM.int16(from: values)
        let back = AudioPCM.floats(from: ints)
        XCTAssertEqual(back[0], 0, accuracy: 0.002)
        XCTAssertEqual(back[1], 0.5, accuracy: 0.002)
        XCTAssertEqual(back[4], -1, accuracy: 0.002)
    }

    func testReplacingMicBufferKeepsSineAndAudioBufferList() {
        let frames = 480
        var sine = [Float](repeating: 0, count: frames)
        for index in 0..<frames {
            sine[index] = 0.5 * sin(2 * Float.pi * Float(index) / 40)
        }
        guard let original = AudioPCM.sampleBuffer(
            mono: sine,
            sampleRate: 48_000,
            presentationTimeStamp: CMTime(value: 1_000, timescale: 48_000)
        ) else {
            XCTFail("could not wrap original mic buffer")
            return
        }

        var listSize = 0
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            original,
            bufferListSizeNeededOut: &listSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: nil
        )
        XCTAssertTrue(
            sizeStatus == noErr || sizeStatus == kCMSampleBufferError_ArrayTooSmall,
            "AEC output must expose an AudioBufferList for AAC, got \(sizeStatus)"
        )
        XCTAssertGreaterThan(listSize, 0)

        let quieter = sine.map { $0 * 0.5 }
        guard let replaced = AudioPCM.replacing(sampleBuffer: original, withMono: quieter),
              let pcm = AudioPCM.buffer(from: replaced)
        else {
            XCTFail("could not round-trip replaced mic buffer")
            return
        }
        let mix = AudioPCM.mixdown(pcm)
        XCTAssertEqual(mix.count, frames)
        XCTAssertEqual(mix[10], quieter[10], accuracy: 0.02)
        XCTAssertEqual(
            CMSampleBufferGetNumSamples(replaced),
            CMItemCount(frames)
        )
        XCTAssertEqual(
            CMSampleBufferGetPresentationTimeStamp(replaced).seconds,
            CMSampleBufferGetPresentationTimeStamp(original).seconds,
            accuracy: 0.0001
        )
    }

    func testEchoOnlyCancelsDelayedFarEnd() {
        let aec = AcousticEchoCanceller()
        let rate = AcousticEchoCanceller.processSampleRate
        let hop = AcousticEchoCanceller.frameSize
        let delay = Int(0.048 * Double(rate))
        let total = rate * 3
        var far = [Int16](repeating: 0, count: total)
        var near = [Int16](repeating: 0, count: total)
        for index in 0..<total {
            let t = Double(index) / Double(rate)
            let sample = 0.45 * sin(2 * Double.pi * 220 * t)
                + 0.30 * sin(2 * Double.pi * 347 * t)
                + 0.18 * sin(2 * Double.pi * 513 * t)
            far[index] = Int16((sample * 18_000).rounded())
        }
        for index in delay..<total {
            near[index] = Int16((0.4 * Double(far[index - delay])).rounded())
        }

        var output = [Int16]()
        output.reserveCapacity(total)
        for offset in stride(from: 0, to: total - hop, by: hop) {
            let time = Double(offset) / Double(rate)
            aec.ingestFarEnd16k(Array(far[offset..<(offset + hop)]), time: time)
            output.append(contentsOf: aec.processNearEnd16k(Array(near[offset..<(offset + hop)]), time: time))
        }

        let settle = rate
        let measured = min(output.count, total)
        XCTAssertGreaterThan(measured, settle + hop)
        let nearRMS = rms(near[settle..<measured])
        let outRMS = rms(output[settle..<measured])
        XCTAssertGreaterThan(nearRMS, 500)
        let erle = 10 * log10((nearRMS * nearRMS) / (outRMS * outRMS + 1e-9))
        XCTAssertGreaterThan(erle, 12, "expected >12 dB echo return loss, got \(erle)")
    }

    func testLocalToneSurvivesEchoCancellation() {
        let aec = AcousticEchoCanceller()
        let rate = AcousticEchoCanceller.processSampleRate
        let hop = AcousticEchoCanceller.frameSize
        let delay = Int(0.048 * Double(rate))
        let total = rate * 3
        var far = [Int16](repeating: 0, count: total)
        var near = [Int16](repeating: 0, count: total)
        for index in 0..<total {
            let t = Double(index) / Double(rate)
            let sample = 0.45 * sin(2 * Double.pi * 220 * t)
                + 0.30 * sin(2 * Double.pi * 347 * t)
            far[index] = Int16((sample * 18_000).rounded())
            var mix = 0.25 * sin(2 * Double.pi * 137 * t) * 20_000
            if index >= delay {
                mix += 0.4 * Double(far[index - delay])
            }
            mix = max(-32767, min(32767, mix))
            near[index] = Int16(mix.rounded())
        }

        var output = [Int16]()
        for offset in stride(from: 0, to: total - hop, by: hop) {
            let time = Double(offset) / Double(rate)
            aec.ingestFarEnd16k(Array(far[offset..<(offset + hop)]), time: time)
            output.append(contentsOf: aec.processNearEnd16k(Array(near[offset..<(offset + hop)]), time: time))
        }

        let settle = rate
        let measured = min(output.count, total)
        let outRMS = rms(output[settle..<measured])
        // Local tone alone is ~3536 RMS; echo-only near is ~2900. Cancelled output
        // should stay in the local-speech ballpark, not collapse to residual echo.
        XCTAssertGreaterThan(outRMS, 1_500)
        XCTAssertLessThan(outRMS, 6_000)
    }

    private func rms(_ samples: ArraySlice<Int16>) -> Double {
        guard !samples.isEmpty else { return 0 }
        var acc = 0.0
        for sample in samples {
            let value = Double(sample)
            acc += value * value
        }
        return sqrt(acc / Double(samples.count))
    }
}

final class EchoCancellationSettingsTests: XCTestCase {
    @MainActor
    func testEchoCancellationDefaultsOn() {
        let name = "observer.tests.aec.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        let settings = SettingsStore(defaults: suite)
        XCTAssertTrue(settings.echoCancellationEnabled)
        settings.echoCancellationEnabled = false
        XCTAssertFalse(settings.echoCancellationEnabled)
    }
}
