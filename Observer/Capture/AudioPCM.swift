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
}
