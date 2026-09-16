import Accelerate
import AudioToolbox
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

    static func makeSampleBuffer(
        from pcm: AVAudioPCMBuffer,
        presentationTimeStamp: CMTime,
        decodeTimeStamp: CMTime = .invalid
    ) -> CMSampleBuffer? {
        let frames = Int(pcm.frameLength)
        guard frames > 0, pcm.format.sampleRate > 0 else { return nil }
        var asbd = pcm.format.streamDescription.pointee
        var formatDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else { return nil }

        let duration = CMTime(
            value: CMTimeValue(frames),
            timescale: CMTimeScale(max(1, Int32(pcm.format.sampleRate.rounded())))
        )
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTimeStamp.isValid ? presentationTimeStamp : .zero,
            decodeTimeStamp: decodeTimeStamp
        )
        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(frames),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr, let sampleBuffer else { return nil }

        let listStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: pcm.audioBufferList
        )
        guard listStatus == noErr else { return nil }
        return sampleBuffer
    }
}
