import AudioToolbox
import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

/// Captures system / process output audio via a Core Audio process tap.
///
/// FaceTime (and Continuity phone) call audio is produced by system daemons like
/// `avconferenced`, which ScreenCaptureKit cannot see. A stereo global process tap
/// hears that mix; the microphone is captured separately via ScreenCaptureKit.
/// When echo cancellation is on, this far-end stream is also fed to Speex so
/// speaker bleed can be removed from the mic (“You”) lane. Buffers are stamped
/// with host time so software AEC can align them with the mic timestamps.
final class SystemAudioTap: @unchecked Sendable {
    var onBuffer: ((CMSampleBuffer) -> Void)?

    private let queue = DispatchQueue(label: "app.sauron.system-tap", qos: .utility)
    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var asbd = AudioStreamBasicDescription()
    private var formatDescription: CMAudioFormatDescription?
    private var isRunning = false

    func start() throws {
        try queue.sync {
            guard !isRunning else { return }
            try activate()
            isRunning = true
        }
    }

    func stop() {
        queue.sync {
            deactivate()
            isRunning = false
        }
    }

    deinit {
        deactivate()
    }

    // MARK: - Setup

    private func activate() throws {
        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        var excludeIDs: [AudioObjectID] = []
        if let processObject = Self.processObjectID(for: ownPID) {
            excludeIDs.append(processObject)
        }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excludeIDs)
        description.name = "Sauron System Audio"
        description.uuid = UUID()
        description.isPrivate = true
        // Default mute behavior is unmuted — keep FaceTime playing to the speakers.
        description.isExclusive = true
        if #available(macOS 26.0, *) {
            description.bundleIDs = ["app.sauron.Sauron"]
            description.isProcessRestoreEnabled = true
        }

        var tap: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        let createTapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard createTapStatus == noErr, tap != kAudioObjectUnknown else {
            throw SauronError.captureFailed("Could not create system audio tap (\(createTapStatus)).")
        }
        tapID = tap

        asbd = try Self.tapFormat(for: tap)
        var asbdCopy = asbd
        var formatDesc: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbdCopy,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        guard formatStatus == noErr, let formatDesc else {
            deactivate()
            throw SauronError.captureFailed("Could not describe system audio tap format.")
        }
        formatDescription = formatDesc

        let tapUUID = description.uuid.uuidString
        let aggregateUID = "app.sauron.SystemAudioTap.\(tapUUID)"
        let aggregateName = "Sauron System Audio Aggregate"

        let tapList: [[String: Any]] = [[
            kAudioSubTapUIDKey: tapUUID,
            kAudioSubTapDriftCompensationKey: true
        ]]
        let aggregateProperties: [String: Any] = [
            kAudioAggregateDeviceNameKey: aggregateName,
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceTapListKey: tapList,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceIsPrivateKey: true
        ]

        var aggregate: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateProperties as CFDictionary,
            &aggregate
        )
        guard aggregateStatus == noErr, aggregate != kAudioObjectUnknown else {
            deactivate()
            throw SauronError.captureFailed("Could not create system audio aggregate (\(aggregateStatus)).")
        }
        aggregateID = aggregate

        var procID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, queue) { [weak self]
            _, inInputData, _, _, _ in
            self?.handleInput(inInputData)
        }
        guard ioStatus == noErr, let procID else {
            deactivate()
            throw SauronError.captureFailed("Could not attach system audio IOProc (\(ioStatus)).")
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggregate, procID)
        guard startStatus == noErr else {
            deactivate()
            throw SauronError.captureFailed("Could not start system audio tap (\(startStatus)).")
        }
    }

    private func deactivate() {
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil

        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        aggregateID = AudioDeviceID(kAudioObjectUnknown)

        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
        formatDescription = nil
    }

    // MARK: - Buffers

    private func handleInput(_ inInputData: UnsafePointer<AudioBufferList>?) {
        guard let inInputData, let formatDescription, let onBuffer else { return }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        guard let first = abl.first,
              let data = first.mData,
              first.mDataByteSize > 0
        else { return }

        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return }
        let frameCount = Int(first.mDataByteSize) / bytesPerFrame
        guard frameCount > 0 else { return }

        // Host time so AEC can align this far-end with ScreenCaptureKit mic timestamps.
        let endHost = AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())
        let durationNanos = UInt64((Double(frameCount) / max(asbd.mSampleRate, 1) * 1_000_000_000).rounded())
        let startHost = endHost > durationNanos ? endHost - durationNanos : 0
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(asbd.mSampleRate)),
            presentationTimeStamp: CMTime(value: Int64(startHost), timescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )

        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr, let sampleBuffer else { return }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: Int(first.mDataByteSize),
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: Int(first.mDataByteSize),
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == noErr, let blockBuffer else { return }

        let copyStatus = CMBlockBufferReplaceDataBytes(
            with: data,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: Int(first.mDataByteSize)
        )
        guard copyStatus == noErr else { return }
        guard CMSampleBufferSetDataBuffer(sampleBuffer, newValue: blockBuffer) == noErr else { return }

        onBuffer(sampleBuffer)
    }

    // MARK: - HAL helpers

    private static func processObjectID(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidCopy = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &pidCopy) { pidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pidPointer,
                &size,
                &objectID
            )
        }
        guard status == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }

    private static func tapFormat(for tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr else {
            throw SauronError.captureFailed("Could not read system audio tap format (\(status)).")
        }
        return asbd
    }
}
