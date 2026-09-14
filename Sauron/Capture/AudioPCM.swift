import Accelerate
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

    /// Average channels to mono in −1…1 using Accelerate (SIMD), not a per-sample Swift loop.
    static func mixdown(_ pcm: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(pcm.frameLength)
        let channels = Int(pcm.format.channelCount)
        guard frames > 0, channels > 0 else { return [] }
        let count = vDSP_Length(frames)
        if let data = pcm.floatChannelData {
            if channels == 1 {
                return Array(UnsafeBufferPointer(start: data[0], count: frames))
            }
            var mono = [Float](repeating: 0, count: frames)
            mono.withUnsafeMutableBufferPointer { dest in
                guard let out = dest.baseAddress else { return }
                vDSP_vadd(data[0], 1, data[1], 1, out, 1, count)
                if channels > 2 {
                    for channel in 2..<channels {
                        vDSP_vadd(out, 1, data[channel], 1, out, 1, count)
                    }
                }
                var scale = 1 / Float(channels)
                vDSP_vsmul(out, 1, &scale, out, 1, count)
            }
            return mono
        }
        if let data = pcm.int16ChannelData {
            var mono = [Float](repeating: 0, count: frames)
            var scratch = [Float](repeating: 0, count: frames)
            let toFloat: Float = 1 / 32767
            mono.withUnsafeMutableBufferPointer { dest in
                scratch.withUnsafeMutableBufferPointer { temp in
                    guard let out = dest.baseAddress, let converted = temp.baseAddress else { return }
                    vDSP_vflt16(data[0], 1, converted, 1, count)
                    if channels == 1 {
                        var scale = toFloat
                        vDSP_vsmul(converted, 1, &scale, out, 1, count)
                        return
                    }
                    vDSP_vflt16(data[1], 1, out, 1, count)
                    vDSP_vadd(converted, 1, out, 1, out, 1, count)
                    if channels > 2 {
                        for channel in 2..<channels {
                            vDSP_vflt16(data[channel], 1, converted, 1, count)
                            vDSP_vadd(out, 1, converted, 1, out, 1, count)
                        }
                    }
                    var scale = toFloat / Float(channels)
                    vDSP_vsmul(out, 1, &scale, out, 1, count)
                }
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

        // 48 kHz → 16 kHz is the AEC path; average groups of 3 with Accelerate.
        if count == nil, abs(sourceRate - destRate * 3) < 1, input.count >= 3 {
            let grouped = input.count / 3
            var output = [Float](repeating: 0, count: grouped)
            input.withUnsafeBufferPointer { src in
                output.withUnsafeMutableBufferPointer { dst in
                    guard let source = src.baseAddress, let dest = dst.baseAddress else { return }
                    for index in 0..<grouped {
                        let base = index * 3
                        dest[index] = (source[base] + source[base + 1] + source[base + 2]) * (1 / 3)
                    }
                }
            }
            return output
        }

        var output = [Float](repeating: 0, count: outCount)
        let scale = Double(input.count - 1) / Double(max(outCount - 1, 1))
        input.withUnsafeBufferPointer { src in
            guard let source = src.baseAddress else { return }
            for index in 0..<outCount {
                let srcIndex = Double(index) * scale
                let i0 = min(Int(srcIndex), input.count - 1)
                let i1 = min(i0 + 1, input.count - 1)
                let frac = Float(srcIndex - Double(i0))
                output[index] = source[i0] + (source[i1] - source[i0]) * frac
            }
        }
        return output
    }

    static func int16(from floats: [Float]) -> [Int16] {
        let count = vDSP_Length(floats.count)
        guard floats.count > 0 else { return [] }
        var clipped = [Float](repeating: 0, count: floats.count)
        var low: Float = -1
        var high: Float = 1
        floats.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            vDSP_vclip(base, 1, &low, &high, &clipped, 1, count)
        }
        var scale: Float = 32767
        vDSP_vsmul(clipped, 1, &scale, &clipped, 1, count)
        var output = [Int16](repeating: 0, count: floats.count)
        vDSP_vfixr16(clipped, 1, &output, 1, count)
        return output
    }

    static func floats(from ints: [Int16]) -> [Float] {
        let count = vDSP_Length(ints.count)
        guard ints.count > 0 else { return [] }
        var output = [Float](repeating: 0, count: ints.count)
        ints.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            vDSP_vflt16(base, 1, &output, 1, count)
        }
        var scale: Float = 1 / 32767
        vDSP_vsmul(output, 1, &scale, &output, 1, count)
        return output
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
