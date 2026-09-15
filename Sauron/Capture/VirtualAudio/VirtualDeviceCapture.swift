import AudioToolbox
import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

/// Captures PCM from the Sauron Audio virtual device (meeting-app far-end).
final class VirtualDeviceCapture: @unchecked Sendable {
    var onBuffer: ((CMSampleBuffer) -> Void)?

    private let queue = DispatchQueue(label: "app.sauron.virtual-capture", qos: .userInitiated)
    private var deviceID: AudioDeviceID = kAudioObjectUnknown
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

    deinit { deactivate() }

    private func activate() throws {
        guard let deviceID = VirtualAudioDevice.coreAudioDeviceID() else {
            throw SauronError.captureFailed("Sauron Audio device is not loaded. Install it from Settings.")
        }
        self.deviceID = deviceID

        asbd = try Self.inputFormat(for: deviceID)
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
            throw SauronError.captureFailed("Could not create virtual audio format (\(formatStatus)).")
        }
        formatDescription = formatDesc

        let callback: AudioDeviceIOProc = { _, now, inputData, _, _, _, clientData in
            guard let clientData else { return noErr }
            let capture = Unmanaged<VirtualDeviceCapture>.fromOpaque(clientData).takeUnretainedValue()
            capture.handleIO(now: now.pointee, inputData: inputData)
            return noErr
        }

        let client = Unmanaged.passUnretained(self).toOpaque()
        var procID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcID(deviceID, callback, client, &procID)
        guard procStatus == noErr, let procID else {
            throw SauronError.captureFailed("Could not create virtual audio IOProc (\(procStatus)).")
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(deviceID, procID)
        guard startStatus == noErr else {
            deactivate()
            throw SauronError.captureFailed("Could not start Sauron Audio capture (\(startStatus)).")
        }
    }

    private func deactivate() {
        if let procID = ioProcID, deviceID != kAudioObjectUnknown {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        ioProcID = nil
        deviceID = kAudioObjectUnknown
        formatDescription = nil
    }

    private func handleIO(now: AudioTimeStamp, inputData: UnsafePointer<AudioBufferList>?) {
        guard let inputData, let formatDescription else { return }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard let first = abl.first, let data = first.mData, first.mDataByteSize > 0 else { return }

        let frameCount = Int(first.mDataByteSize) / Int(max(asbd.mBytesPerFrame, 1))
        guard frameCount > 0 else { return }

        let startHost = now.mHostTime
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(asbd.mSampleRate)),
            presentationTimeStamp: CMTime(value: Int64(bitPattern: startHost), timescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
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
        guard CMBlockBufferReplaceDataBytes(
            with: data,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: Int(first.mDataByteSize)
        ) == noErr else { return }
        guard CMSampleBufferSetDataBuffer(sampleBuffer, newValue: blockBuffer) == noErr else { return }

        onBuffer?(sampleBuffer)
    }

    private static func inputFormat(for deviceID: AudioDeviceID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &asbd)
        guard status == noErr else {
            throw SauronError.captureFailed("Could not read Sauron Audio format (\(status)).")
        }
        return asbd
    }
}
