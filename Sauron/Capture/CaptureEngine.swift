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
    private var echoCanceller: AcousticEchoCanceller?
    private var voiceMic: VoiceProcessingMicCapture?
    private var usesVoiceProcessingMic = false
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
        echoCancellation: Bool,
        folder: URL
    ) async throws {
        includeVideo = modes.contains(.visual)
        includeAudio = modes.contains(.audio) || modes.contains(.transcript)
        // FaceTime remote audio isn't visible to ScreenCaptureKit — always use a process tap.
        usesCoreAudioSystemTap = includeAudio && candidate.kind.needsCoreAudioSystemTap
        self.audioSource = usesCoreAudioSystemTap ? .system : audioSource
        self.microphoneDeviceID = microphoneDeviceID
        usesVoiceProcessingMic = false
        echoCanceller = nil
        isStopping = false
        writer = MediaWriter(folder: folder, includeVideo: includeVideo, includeAudio: includeAudio)

        if includeAudio, echoCancellation {
            tryStartVoiceProcessingMic()
            if !usesVoiceProcessingMic {
                echoCanceller = AcousticEchoCanceller()
            }
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw SauronError.screenRecordingDenied
        }

        let videoFilter = try makeVideoFilter(candidate: candidate, content: content, target: videoTarget)
        let captureSCKMic = includeAudio && !usesVoiceProcessingMic
        let captureSystemViaSCK = includeAudio && !usesCoreAudioSystemTap

        if captureSCKMic || captureSystemViaSCK {
            try await startAudioStream(
                candidate: candidate,
                content: content,
                captureMicrophone: captureSCKMic,
                captureSystemViaSCK: captureSystemViaSCK
            )
        }

        if includeAudio, usesCoreAudioSystemTap {
            let tap = SystemAudioTap()
            tap.onBuffer = { [weak self] sampleBuffer in
                guard let self, self.includeAudio else { return }
                self.echoCanceller?.ingestFarEnd(sampleBuffer)
                self.writer?.appendSystem(sampleBuffer)
                self.onSystemAudio?(sampleBuffer)
            }
            do {
                try tap.start()
                systemTap = tap
            } catch {
                // Fall back to SCK system audio rather than failing the whole recording.
                usesCoreAudioSystemTap = false
                if let audioStream {
                    try audioStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
                    try await audioStream.updateConfiguration(
                        makeAudioConfiguration(
                            microphoneDeviceID: microphoneDeviceID,
                            captureSystemViaSCK: true,
                            captureMicrophone: captureSCKMic
                        )
                    )
                } else {
                    try await startAudioStream(
                        candidate: candidate,
                        content: content,
                        captureMicrophone: captureSCKMic,
                        captureSystemViaSCK: true
                    )
                }
                onFailure?(error)
            }
        }

        if includeVideo {
            let videoConfiguration = makeVideoConfiguration(filter: videoFilter, content: content)
            do {
                videoStream = try await startVideoStream(filter: videoFilter, configuration: videoConfiguration)
            } catch {
                var fallback = videoConfiguration
                fallback.pixelFormat = MediaEncodePolicy.capturePixelFormatFallback
                videoStream = try await startVideoStream(filter: videoFilter, configuration: fallback)
            }
        }
    }

    private func startVideoStream(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> SCStream {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try await stream.startCapture()
        return stream
    }

    /// Switch mic mid-recording using the priority fallback list.
    func switchMicrophone(to deviceID: String?) async throws {
        guard includeAudio else { return }
        echoCanceller?.reset()
        microphoneDeviceID = deviceID
        if usesVoiceProcessingMic, let voiceMic {
            try voiceMic.setDeviceUID(deviceID)
            return
        }
        guard let audioStream else { return }
        let configuration = makeAudioConfiguration(
            microphoneDeviceID: deviceID,
            captureSystemViaSCK: !usesCoreAudioSystemTap,
            captureMicrophone: true
        )
        try await audioStream.updateConfiguration(configuration)
    }

    /// Toggle mic mute during an active capture. When muted, mic samples are
    /// dropped from the writer and from downstream callbacks (monitor, diarizer,
    /// transcription). System audio keeps flowing.
    func toggleMicMute() {
        micMuted.toggle()
        voiceMic?.setInputMuted(micMuted)
        onMicMuteChanged?(micMuted)
    }

    var isMicMuted: Bool { micMuted }

    func stop() async {
        isStopping = true
        let video = videoStream
        let audio = audioStream
        let tap = systemTap
        let mic = voiceMic
        videoStream = nil
        audioStream = nil
        systemTap = nil
        voiceMic = nil
        usesVoiceProcessingMic = false
        echoCanceller = nil
        tap?.stop()
        mic?.stop()
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
            echoCanceller?.ingestFarEnd(sampleBuffer)
            writer?.appendSystem(sampleBuffer)
            onSystemAudio?(sampleBuffer)
        case .microphone:
            guard includeAudio, !usesVoiceProcessingMic else { return }
            // Keep AEC adapted while muted so unmuting doesn't dump a burst of echo.
            let micBuffer = echoCanceller?.processNearEnd(sampleBuffer) ?? sampleBuffer
            if !isMicMuted {
                writer?.appendMic(micBuffer)
                onMicAudio?(micBuffer)
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

    private func tryStartVoiceProcessingMic() {
        let capture = VoiceProcessingMicCapture()
        capture.onBuffer = { [weak self] sampleBuffer in
            self?.handleVoiceMic(sampleBuffer)
        }
        do {
            try capture.start(deviceUID: microphoneDeviceID)
            voiceMic = capture
            usesVoiceProcessingMic = true
        } catch {
            capture.stop()
            usesVoiceProcessingMic = false
        }
    }

    private func handleVoiceMic(_ sampleBuffer: CMSampleBuffer) {
        micQueue.async { [weak self] in
            guard let self, self.includeAudio, !self.isStopping else { return }
            if !self.isMicMuted {
                self.writer?.appendMic(sampleBuffer)
                self.onMicAudio?(sampleBuffer)
            }
        }
    }

    private func startAudioStream(
        candidate: MeetingCandidate,
        content: SCShareableContent,
        captureMicrophone: Bool,
        captureSystemViaSCK: Bool
    ) async throws {
        let audioFilter = try makeAudioFilter(
            candidate: candidate,
            content: content,
            source: audioSource
        )
        let audioConfiguration = makeAudioConfiguration(
            microphoneDeviceID: microphoneDeviceID,
            captureSystemViaSCK: captureSystemViaSCK,
            captureMicrophone: captureMicrophone
        )
        let stream = SCStream(filter: audioFilter, configuration: audioConfiguration, delegate: self)
        if captureSystemViaSCK {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
        }
        if captureMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: micQueue)
        }
        try await stream.startCapture()
        audioStream = stream
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
        captureSystemViaSCK: Bool,
        captureMicrophone: Bool
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = captureSystemViaSCK
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = captureMicrophone
        // Speaker bleed is removed by VoiceProcessing IO, or Speex when that unit is busy.
        if captureMicrophone, let microphoneDeviceID, !microphoneDeviceID.isEmpty {
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
        configuration.queueDepth = 3
        configuration.pixelFormat = MediaEncodePolicy.capturePixelFormat
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
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(max(1, MediaEncodePolicy.liveTargetFPS))
        )
        // GPU-scale in ScreenCaptureKit so VideoToolbox gets encoder-sized frames (no CI/CPU rescale).
        configuration.scalesToFit = true
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
