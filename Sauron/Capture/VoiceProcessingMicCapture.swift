import AudioToolbox
import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

/// Microphone capture through Apple VoiceProcessing IO.
///
/// Kept for experiments / possible future duplex use. Meeting recording does **not**
/// use this path: Sauron does not render remote audio through VPIO, so the unit has
/// no far-end reference and tends to duck Zoom/Teams instead of cancelling echo.
/// Production AEC is Speex with captured system audio as the reference
/// (`AcousticEchoCanceller` via `CaptureEngine`).
final class VoiceProcessingMicCapture: @unchecked Sendable {
    var onBuffer: ((CMSampleBuffer) -> Void)?

    private let queue = DispatchQueue(label: "app.sauron.voice-mic", qos: .userInitiated)
    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private var isRunning = false
    private var routeObserver: NSObjectProtocol?
    private var deviceUID: String?
    private var inputMuted = false

    func start(deviceUID: String?) throws {
        try queue.sync {
            guard !isRunning else { return }
            self.deviceUID = deviceUID
            try activateLocked()
            isRunning = true
        }
    }

    func stop() {
        queue.sync {
            deactivateLocked()
            isRunning = false
        }
    }

    func setDeviceUID(_ deviceUID: String?) throws {
        try queue.sync {
            let previous = self.deviceUID
            self.deviceUID = deviceUID
            guard isRunning else { return }
            deactivateLocked()
            do {
                try activateLocked()
            } catch {
                self.deviceUID = previous
                do {
                    try activateLocked()
                } catch {
                    isRunning = false
                    throw error
                }
                throw SauronError.captureFailed("Could not switch microphone; kept the previous input.")
            }
        }
    }

    /// Keeps Apple’s canceller adapted while the user is muted.
    func setInputMuted(_ muted: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.inputMuted = muted
            guard self.isRunning else { return }
            self.engine.inputNode.isVoiceProcessingInputMuted = muted
        }
    }

    deinit {
        onBuffer = nil
        deactivateLocked()
    }

    // MARK: - Engine

    private func activateLocked() throws {
        let input = engine.inputNode
        _ = engine.outputNode

        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            throw SauronError.captureFailed("Apple echo cancellation is unavailable (\(error.localizedDescription)).")
        }

        let ducking = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
            enableAdvancedDucking: false,
            duckingLevel: .min
        )
        input.voiceProcessingOtherAudioDuckingConfiguration = ducking
        input.isVoiceProcessingAGCEnabled = false
        input.isVoiceProcessingBypassed = false
        muteVoiceProcessingOutput(input)
        try bindInputDeviceLocked()

        engine.prepare()
        installTapLocked()
        observeRouteChangesLocked()

        do {
            try engine.start()
        } catch {
            deactivateLocked()
            throw SauronError.captureFailed("Could not start Apple echo-cancelled microphone (\(error.localizedDescription)).")
        }

        muteVoiceProcessingOutput(input)
        input.voiceProcessingOtherAudioDuckingConfiguration = ducking
        input.isVoiceProcessingInputMuted = inputMuted
    }

    private func deactivateLocked() {
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
            self.routeObserver = nil
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        if engine.inputNode.isVoiceProcessingEnabled {
            try? engine.inputNode.setVoiceProcessingEnabled(false)
        }
        engine.reset()
    }

    private func installTapLocked() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        // Apple’s tap range is 100…400 ms. 100 ms at 48 kHz is 4800 frames.
        engine.inputNode.installTap(onBus: 0, bufferSize: 4800, format: nil) { [weak self] buffer, time in
            self?.emit(buffer, time: time)
        }
        tapInstalled = true
    }

    private func emit(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let sampleBuffer = AudioPCM.makeSampleBuffer(from: buffer, capturedAt: time) else { return }
        onBuffer?(sampleBuffer)
    }

    private func observeRouteChangesLocked() {
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
        }
        routeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard self.isRunning else { return }
                self.deactivateLocked()
                do {
                    try self.activateLocked()
                } catch {
                    self.isRunning = false
                }
            }
        }
    }

    private func muteVoiceProcessingOutput(_ input: AVAudioInputNode) {
        guard let audioUnit = input.audioUnit else { return }
        var mute: UInt32 = 1
        AudioUnitSetProperty(
            audioUnit,
            kAUVoiceIOProperty_MuteOutput,
            kAudioUnitScope_Global,
            0,
            &mute,
            UInt32(MemoryLayout<UInt32>.size)
        )
    }

    private func bindInputDeviceLocked() throws {
        let deviceID: AudioDeviceID
        if let deviceUID, !deviceUID.isEmpty {
            guard let resolved = AudioDeviceCatalog.coreAudioDeviceID(matchingUID: deviceUID) else {
                throw SauronError.captureFailed("Microphone is not available to Apple echo cancellation.")
            }
            deviceID = resolved
        } else if let resolved = AudioDeviceCatalog.defaultInputDeviceID() {
            deviceID = resolved
        } else {
            return
        }

        guard let audioUnit = engine.inputNode.audioUnit else {
            throw SauronError.captureFailed("Apple echo cancellation has no audio unit.")
        }
        var id = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            1,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status == noErr { return }

        do {
            try engine.inputNode.auAudioUnit.setDeviceID(deviceID)
        } catch {
            throw SauronError.captureFailed("Could not bind microphone to Apple echo cancellation (\(error.localizedDescription)).")
        }
    }
}
