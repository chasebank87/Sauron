import AVFoundation
import CoreMedia
import Foundation

enum AudioPCM {
    static func buffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        guard var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
            return nil
        }
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }
        pcm.frameLength = frameCount

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcm.mutableAudioBufferList
        )
        if copyStatus == noErr {
            return pcm
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let accessStatus = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard accessStatus == kCMBlockBufferNoErr, let dataPointer, totalLength > 0 else { return nil }

        let audioBufferList = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        var offset = 0
        for buffer in audioBufferList {
            guard let destination = buffer.mData else { continue }
            let byteCount = Int(buffer.mDataByteSize)
            guard offset + byteCount <= totalLength else { return nil }
            memcpy(destination, dataPointer.advanced(by: offset), byteCount)
            offset += byteCount
        }
        return pcm
    }

    /// Average channels to mono in −1…1.
    static func mixdown(_ pcm: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(pcm.frameLength)
        let channels = Int(pcm.format.channelCount)
        guard frames > 0, channels > 0 else { return [] }
        var mono = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(channels)
        if let data = pcm.floatChannelData {
            for channel in 0..<channels {
                for frame in 0..<frames {
                    mono[frame] += data[channel][frame]
                }
            }
            if channels > 1 {
                for frame in 0..<frames { mono[frame] *= scale }
            }
            return mono
        }
        if let data = pcm.int16ChannelData {
            let toFloat: Float = 1 / 32767
            for channel in 0..<channels {
                for frame in 0..<frames {
                    mono[frame] += Float(data[channel][frame]) * toFloat
                }
            }
            if channels > 1 {
                for frame in 0..<frames { mono[frame] *= scale }
            }
            return mono
        }
        return []
    }

    static func resample(_ input: [Float], from sourceRate: Double, to destRate: Double, count: Int? = nil) -> [Float] {
        guard !input.isEmpty, sourceRate > 0, destRate > 0 else { return input }
        let outCount = count ?? max(1, Int((Double(input.count) * destRate / sourceRate).rounded()))
        if outCount == input.count, abs(sourceRate - destRate) < 0.5 {
            return input
        }
        if outCount <= 0 { return [] }
        if input.count == 1 { return [Float](repeating: input[0], count: outCount) }
        var output = [Float](repeating: 0, count: outCount)
        let scale = Double(input.count - 1) / Double(max(outCount - 1, 1))
        for index in 0..<outCount {
            let src = Double(index) * scale
            let i0 = min(Int(src), input.count - 1)
            let i1 = min(i0 + 1, input.count - 1)
            let frac = Float(src - Double(i0))
            output[index] = input[i0] + (input[i1] - input[i0]) * frac
        }
        return output
    }

    static func int16(from floats: [Float]) -> [Int16] {
        floats.map { sample in
            let clipped = max(-1, min(1, sample))
            return Int16((clipped * 32767).rounded())
        }
    }

    static func floats(from ints: [Int16]) -> [Float] {
        ints.map { Float($0) / 32767 }
    }

    static func replacing(sampleBuffer: CMSampleBuffer, withMono mono: [Float]) -> CMSampleBuffer? {
        guard let pcm = buffer(from: sampleBuffer) else { return nil }
        let frames = Int(pcm.frameLength)
        guard frames > 0, mono.count == frames else { return nil }
        write(mono: mono, into: pcm)
        return makeSampleBuffer(from: pcm, matching: sampleBuffer)
    }

    private static func write(mono: [Float], into pcm: AVAudioPCMBuffer) {
        let frames = Int(pcm.frameLength)
        let channels = Int(pcm.format.channelCount)
        if let data = pcm.floatChannelData {
            for channel in 0..<channels {
                for frame in 0..<frames {
                    data[channel][frame] = mono[frame]
                }
            }
            return
        }
        if let data = pcm.int16ChannelData {
            for channel in 0..<channels {
                for frame in 0..<frames {
                    let clipped = max(-1 as Float, min(1, mono[frame]))
                    data[channel][frame] = Int16((clipped * 32767).rounded())
                }
            }
        }
    }

    private static func makeSampleBuffer(from pcm: AVAudioPCMBuffer, matching original: CMSampleBuffer) -> CMSampleBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(original) else { return nil }
        let abl = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        var byteCount = 0
        for buffer in abl {
            byteCount += Int(buffer.mDataByteSize)
        }
        guard byteCount > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        var offset = 0
        for buffer in abl {
            guard let data = buffer.mData else { continue }
            let length = Int(buffer.mDataByteSize)
            let copyStatus = CMBlockBufferReplaceDataBytes(
                with: data,
                blockBuffer: blockBuffer,
                offsetIntoDestination: offset,
                dataLength: length
            )
            guard copyStatus == kCMBlockBufferNoErr else { return nil }
            offset += length
        }

        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(original),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(original),
            decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(original)
        )
        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(pcm.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr else { return nil }
        return sampleBuffer
    }
}
