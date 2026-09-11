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
                windowTitle: "Design review | Microsoft Teams"
            ),
            .teams
        )
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
          "decisions": ["Ship Friday"],
          "actionItems": [{"owner": "Ada", "text": "Cut the branch"}],
          "openQuestions": ["Who pages?"],
          "quotes": ["Let's ship it"]
        }
        """
        let summary = Summarizer.parse(raw)
        XCTAssertEqual(summary.title, "Launch review")
        XCTAssertEqual(summary.decisions, ["Ship Friday"])
        XCTAssertEqual(summary.actionItems.first?.owner, "Ada")
        XCTAssertEqual(summary.actionItems.first?.text, "Cut the branch")
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
        XCTAssertTrue(
            RecordedMeetingWatch.isPresent(
                sessionKey: zoom.sessionKey,
                windowID: zoom.windowID,
                in: [zoom]
            )
        )
    }

    func testSameAppDifferentWindowDoesNotKeepRecordingAlive() {
        let original = candidate(kind: .zoom, bundle: "us.zoom.xos", windowID: 12)
        let leftoverHome = candidate(kind: .zoom, bundle: "us.zoom.xos", windowID: 99)
        XCTAssertFalse(
            RecordedMeetingWatch.isPresent(
                sessionKey: original.sessionKey,
                windowID: original.windowID,
                in: [leftoverHome]
            )
        )
    }

    func testDifferentAppDoesNotCount() {
        let zoom = candidate(kind: .zoom, bundle: "us.zoom.xos", windowID: 12)
        let teams = candidate(kind: .teams, bundle: "com.microsoft.teams2", windowID: 4)
        XCTAssertFalse(
            RecordedMeetingWatch.isPresent(
                sessionKey: zoom.sessionKey,
                windowID: zoom.windowID,
                in: [teams]
            )
        )
    }

    func testEmptyMatchesMeansMeetingEnded() {
        let zoom = candidate(kind: .zoom, bundle: "us.zoom.xos", windowID: 12)
        XCTAssertFalse(
            RecordedMeetingWatch.isPresent(
                sessionKey: zoom.sessionKey,
                windowID: zoom.windowID,
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
