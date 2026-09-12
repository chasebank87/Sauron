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

    private let videoQueue = DispatchQueue(label: "app.observer.capture.video")
    private let audioQueue = DispatchQueue(label: "app.observer.capture.audio")
    private var videoStream: SCStream?
    private var audioStream: SCStream?
    private var writer: MediaWriter?
    private var includeVideo = false
    private var includeAudio = false
    private var audioSource: CaptureAudioSource = .system
    private var microphoneDeviceID: String?
    private var isStopping = false

    var videoPath: String? { writer?.videoURL?.path }
    var micPath: String? { writer?.micURL?.path }
    var systemPath: String? { writer?.systemURL?.path }
    var activeMicrophoneDeviceID: String? { microphoneDeviceID }

    func start(
        candidate: MeetingCandidate,
        modes: Set<RecordMode>,
        audioSource: CaptureAudioSource,
        microphoneDeviceID: String?,
        folder: URL
    ) async throws {
        includeVideo = modes.contains(.visual)
        includeAudio = modes.contains(.audio) || modes.contains(.transcript)
        self.audioSource = audioSource
        self.microphoneDeviceID = microphoneDeviceID
        isStopping = false
        writer = MediaWriter(folder: folder, includeVideo: includeVideo, includeAudio: includeAudio)

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw ObserverError.screenRecordingDenied
        }

        let videoFilter = try makeVideoFilter(candidate: candidate, content: content)
        let audioFilter = try makeAudioFilter(candidate: candidate, content: content, source: audioSource)

        if includeAudio {
            let audioConfiguration = makeAudioConfiguration(microphoneDeviceID: microphoneDeviceID)
            let stream = SCStream(filter: audioFilter, configuration: audioConfiguration, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)
            try await stream.startCapture()
            audioStream = stream
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
        let configuration = makeAudioConfiguration(microphoneDeviceID: deviceID)
        try await audioStream.updateConfiguration(configuration)
    }

    func stop() async {
        isStopping = true
        let video = videoStream
        let audio = audioStream
        videoStream = nil
        audioStream = nil
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
            guard includeAudio else { return }
            writer?.appendSystem(sampleBuffer)
            onSystemAudio?(sampleBuffer)
        case .microphone:
            guard includeAudio else { return }
            writer?.appendMic(sampleBuffer)
            onMicAudio?(sampleBuffer)
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

    private func makeVideoFilter(candidate: MeetingCandidate, content: SCShareableContent) throws -> SCContentFilter {
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
            throw ObserverError.noDisplay
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
            throw ObserverError.noDisplay
        }
        switch source {
        case .system:
            return SCContentFilter(display: display, excludingWindows: [])
        case .meetingApp:
            if candidate.isSimulated {
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

    private func makeAudioConfiguration(microphoneDeviceID: String?) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
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
