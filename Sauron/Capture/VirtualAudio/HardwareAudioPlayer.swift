import AudioToolbox
import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

/// Plays far-end (virtual capture) PCM to a real hardware output so the user still hears the meeting.
final class HardwareAudioPlayer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.sauron.hardware-playback", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var isRunning = false

    /// `nil` / empty uses the system default output device.
    func start(outputUID: String?) throws {
        try queue.sync {
            guard !isRunning else { return }
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)

            if let outputUID, !outputUID.isEmpty,
               let deviceID = AudioDeviceCatalog.coreAudioDeviceID(matchingUID: outputUID)
            {
                try Self.setOutputDevice(engine: engine, deviceID: deviceID)
            }

            let format = engine.outputNode.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else {
                throw SauronError.captureFailed("Hardware output format is unavailable.")
            }
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.prepare()
            try engine.start()
            player.play()
            self.engine = engine
            self.player = player
            self.outputFormat = format
            isRunning = true
        }
    }

    func stop() {
        queue.sync {
            player?.stop()
            engine?.stop()
            player = nil
            engine = nil
            converter = nil
            outputFormat = nil
            isRunning = false
        }
    }

    func schedule(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [weak self] in
            self?.enqueue(sampleBuffer)
        }
    }

    deinit { stop() }

    private func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning, let player, let outputFormat else { return }
        guard let source = AudioPCM.buffer(from: sampleBuffer) else { return }
        guard let playable = convertIfNeeded(source, to: outputFormat) else { return }
        player.scheduleBuffer(playable, completionHandler: nil)
    }

    private func convertIfNeeded(_ source: AVAudioPCMBuffer, to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        // Must match exactly, interleaving included — AVAudioPlayerNode's connected bus
        // format is always non-interleaved, while the Sauron Audio driver (libASPL) hands
        // us interleaved Float32. A commonFormat-only check misses that and feeds
        // scheduleBuffer a buffer laid out wrong for the render graph, corrupting it.
        if source.format == target {
            return source
        }
        if converter == nil || converter?.inputFormat != source.format {
            converter = AVAudioConverter(from: source.format, to: target)
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / source.format.sampleRate
        let outFrames = AVAudioFrameCount(Double(source.frameLength) * ratio) + 32
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outFrames) else { return nil }
        var error: NSError?
        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return source
        }
        converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
        return error == nil ? outBuffer : nil
    }

    private static func setOutputDevice(engine: AVAudioEngine, deviceID: AudioDeviceID) throws {
        guard let audioUnit = engine.outputNode.audioUnit else {
            throw SauronError.captureFailed("Output audio unit missing.")
        }
        var deviceID = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            size
        )
        guard status == noErr else {
            throw SauronError.captureFailed("Could not select playback device (\(status)).")
        }
    }
}
