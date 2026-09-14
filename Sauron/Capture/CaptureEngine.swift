import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onSystemAudio: ((CMSampleBuffer) -> Void)?
    var onMicAudio: ((CMSampleBuffer) -> Void)?
    var onFailure: ((Error) -> Void)?
    /// Fired when SCK stops a live stream unexpectedly (e.g. meeting window closed).
    var onCaptureInterrupted: ((Error) -> Void)?
    /// Fired when mic mute state changes mid-capture.
    var onMicMuteChanged: ((Bool) -> Void)?

    private let videoQueue = DispatchQueue(label: "app.sauron.capture.video", qos: .userInitiated)
    /// Mic has its own queue so remote/system audio + diarization never block “You” capture.
    private let micQueue = DispatchQueue(label: "app.sauron.capture.mic", qos: .userInitiated)
    private let systemQueue = DispatchQueue(label: "app.sauron.capture.system", qos: .utility)
    private var videoStream: SCStream?
    private var audioStream: SCStream?
    private var systemTap: SystemAudioTap?
    private var writer: MediaWriter?
    private var includeVideo = false
    private var includeAudio = false
    private var usesCoreAudioSystemTap = false
    private var audioSource: CaptureAudioSource = .system
    private var microphoneDeviceID: String?
    private var isStopping = false
    private var micMuted = false

    var videoPath: String? { writer?.videoURL?.path }
    var micPath: String? { writer?.micURL?.path }
    var systemPath: String? { writer?.systemURL?.path }
    var activeMicrophoneDeviceID: String? { microphoneDeviceID }

    func start(
        candidate: MeetingCandidate,
        modes: Set<RecordMode>,
        audioSource: CaptureAudioSource,
        videoTarget: CaptureVideoTarget = .auto,
        microphoneDeviceID: String?,
        folder: URL
    ) async throws {
        includeVideo = modes.contains(.visual)
        includeAudio = modes.contains(.audio) || modes.contains(.transcript)
        // FaceTime remote audio isn't visible to ScreenCaptureKit — always use a process tap.
        usesCoreAudioSystemTap = includeAudio && candidate.kind.needsCoreAudioSystemTap
        self.audioSource = usesCoreAudioSystemTap ? .system : audioSource
        self.microphoneDeviceID = microphoneDeviceID
        isStopping = false
        writer = MediaWriter(folder: folder, includeVideo: includeVideo, includeAudio: includeAudio)

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw SauronError.screenRecordingDenied
        }

        let videoFilter = try makeVideoFilter(candidate: candidate, content: content, target: videoTarget)
        let audioFilter = try makeAudioFilter(
            candidate: candidate,
            content: content,
            source: self.audioSource
        )

        if includeAudio {
            let audioConfiguration = makeAudioConfiguration(
                microphoneDeviceID: microphoneDeviceID,
                captureSystemViaSCK: !usesCoreAudioSystemTap
            )
            let stream = SCStream(filter: audioFilter, configuration: audioConfiguration, delegate: self)
            if !usesCoreAudioSystemTap {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
            }
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: micQueue)
            try await stream.startCapture()
            audioStream = stream

            if usesCoreAudioSystemTap {
                let tap = SystemAudioTap()
                tap.onBuffer = { [weak self] sampleBuffer in
                    guard let self, self.includeAudio else { return }
                    self.writer?.appendSystem(sampleBuffer)
                    self.onSystemAudio?(sampleBuffer)
                }
                do {
                    try tap.start()
                    systemTap = tap
                } catch {
                    // Fall back to SCK system audio rather than failing the whole recording.
                    usesCoreAudioSystemTap = false
                    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
                    try await stream.updateConfiguration(
                        makeAudioConfiguration(
                            microphoneDeviceID: microphoneDeviceID,
                            captureSystemViaSCK: true
                        )
                    )
                    onFailure?(error)
                }
            }
        }

        if includeVideo {
            let videoConfiguration = makeVideoConfiguration(filter: videoFilter, content: content)
            let stream = SCStream(filter: videoFilter, configuration: videoConfiguration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
            try await stream.startCapture()
            videoStream = stream
        }
    }

    /// Switch mic mid-recording using the priority fallback list.
    func switchMicrophone(to deviceID: String?) async throws {
        guard includeAudio, let audioStream else { return }
        microphoneDeviceID = deviceID
        let configuration = makeAudioConfiguration(
            microphoneDeviceID: deviceID,
            captureSystemViaSCK: !usesCoreAudioSystemTap
        )
        try await audioStream.updateConfiguration(configuration)
    }

    /// Toggle mic mute during an active capture. When muted, mic samples are
    /// dropped from the writer and from downstream callbacks (monitor, diarizer,
    /// transcription). System audio keeps flowing.
    func toggleMicMute() {
        micMuted.toggle()
        onMicMuteChanged?(micMuted)
    }

    var isMicMuted: Bool { micMuted }

    func stop() async {
        isStopping = true
        let video = videoStream
        let audio = audioStream
        let tap = systemTap
        videoStream = nil
        audioStream = nil
        systemTap = nil
        tap?.stop()
        if let video {
            try? await video.stopCapture()
        }
        if let audio {
            try? await audio.stopCapture()
        }
        await writer?.finish()
        isStopping = false
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        switch type {
        case .screen:
            guard includeVideo, isCompleteFrame(sampleBuffer) else { return }
            writer?.appendVideo(sampleBuffer)
        case .audio:
            guard includeAudio, !usesCoreAudioSystemTap else { return }
            writer?.appendSystem(sampleBuffer)
            onSystemAudio?(sampleBuffer)
        case .microphone:
            guard includeAudio else { return }
            if !isMicMuted {
                writer?.appendMic(sampleBuffer)
                onMicAudio?(sampleBuffer)
            }
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !isStopping else { return }
        if stream === videoStream {
            videoStream = nil
        }
        if stream === audioStream {
            audioStream = nil
        }
        onCaptureInterrupted?(error)
    }

    private func makeVideoFilter(
        candidate: MeetingCandidate,
        content: SCShareableContent,
        target: CaptureVideoTarget
    ) throws -> SCContentFilter {
        switch target {
        case .window(let windowID):
            if let window = content.windows.first(where: { $0.windowID == windowID }) {
                return SCContentFilter(desktopIndependentWindow: window)
            }
            // Window closed — fall through to auto.
            break
        case .display(let displayID):
            if let display = content.displays.first(where: { $0.displayID == displayID }) {
                return SCContentFilter(display: display, excludingWindows: [])
            }
            if let display = preferredDisplay(in: content) {
                return SCContentFilter(display: display, excludingWindows: [])
            }
            throw SauronError.noDisplay
        case .auto:
            break
        }

        // Re-pick the best live meeting window (Teams Calendar shells must not win).
        let liveMatches = content.windows.compactMap { window -> MeetingCandidate? in
            guard window.isOnScreen else { return nil }
            let frame = window.frame
            guard frame.width >= 220, frame.height >= 160 else { return nil }
            let title = window.title ?? ""
            let bundle = window.owningApplication?.bundleIdentifier
            let appName = window.owningApplication?.applicationName
            guard let kind = MeetingAppCatalog.match(
                bundleIdentifier: bundle,
                appName: appName,
                windowTitle: title
            ) else { return nil }
            let bundleID = bundle ?? "unknown"
            return MeetingCandidate(
                id: "\(bundleID):\(window.windowID)",
                kind: kind,
                appName: appName ?? kind.displayName,
                bundleIdentifier: bundleID,
                windowTitle: title,
                windowID: window.windowID,
                isSimulated: false,
                calendarEventTitle: nil,
                pixelArea: max(frame.width, 1) * max(frame.height, 1)
            )
        }
        let resolved = MeetingWindowPicker.bestContinuing(from: candidate, in: liveMatches) ?? candidate

        if let windowID = resolved.windowID,
           let window = content.windows.first(where: { $0.windowID == windowID }) {
            return SCContentFilter(desktopIndependentWindow: window)
        }
        guard let display = preferredDisplay(in: content) else {
            throw SauronError.noDisplay
        }
        if let app = meetingApplication(candidate: resolved, content: content) {
            return SCContentFilter(display: display, including: [app], exceptingWindows: [])
        }
        return SCContentFilter(display: display, excludingWindows: [])
    }

    private func makeAudioFilter(
        candidate: MeetingCandidate,
        content: SCShareableContent,
        source: CaptureAudioSource
    ) throws -> SCContentFilter {
        guard let display = preferredDisplay(in: content) else {
            throw SauronError.noDisplay
        }
        switch source {
        case .system:
            return SCContentFilter(display: display, excludingWindows: [])
        case .meetingApp:
            // FaceTime audio lives in system daemons — never filter to FaceTime.app only.
            if candidate.kind.needsCoreAudioSystemTap || candidate.isSimulated {
                return SCContentFilter(display: display, excludingWindows: [])
            }
            if let app = meetingApplication(candidate: candidate, content: content) {
                return SCContentFilter(display: display, including: [app], exceptingWindows: [])
            }
            return SCContentFilter(display: display, excludingWindows: [])
        }
    }

    private func meetingApplication(candidate: MeetingCandidate, content: SCShareableContent) -> SCRunningApplication? {
        content.applications.first(where: { $0.bundleIdentifier == candidate.bundleIdentifier })
    }

    private func preferredDisplay(in content: SCShareableContent) -> SCDisplay? {
        content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first
    }

    private func makeAudioConfiguration(
        microphoneDeviceID: String?,
        captureSystemViaSCK: Bool
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = captureSystemViaSCK
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = true
        if let microphoneDeviceID, !microphoneDeviceID.isEmpty {
            configuration.microphoneCaptureDeviceID = microphoneDeviceID
        }
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 5
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        return configuration
    }

    private func makeVideoConfiguration(filter: SCContentFilter, content: SCShareableContent) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = false
        configuration.captureMicrophone = false
        configuration.showsCursor = true
        configuration.queueDepth = 5
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.includeChildWindows = true

        let width: CGFloat
        let height: CGFloat
        if filter.style == .window {
            width = filter.contentRect.width * CGFloat(max(filter.pointPixelScale, 1))
            height = filter.contentRect.height * CGFloat(max(filter.pointPixelScale, 1))
        } else if let display = preferredDisplay(in: content) {
            width = CGFloat(display.width)
            height = CGFloat(display.height)
        } else {
            width = 1280
            height = 720
        }
        let maxEdge: CGFloat = 3200
        let longest = max(width, height)
        let scale = longest > maxEdge ? maxEdge / longest : 1
        // H.264 requires even dimensions — odd heights produce a stripe / corrupt frames.
        configuration.width = Self.evenPixelDimension(Int((width * scale).rounded()))
        configuration.height = Self.evenPixelDimension(Int((height * scale).rounded()))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 20)
        // Prefer sharper text on Retina meeting UIs.
        configuration.scalesToFit = false
        return configuration
    }

    /// Macroblock-safe size for H.264 / HEVC (minimum 2, always even).
    private static func evenPixelDimension(_ value: Int) -> Int {
        let floored = max(2, value)
        return floored - (floored % 2)
    }

    private func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let raw = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw)
        else {
            return true
        }
        return status == .complete
    }
}
