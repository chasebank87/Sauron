import AVFoundation
import CoreVideo
import Foundation
import VideoToolbox

/// Shared encode knobs: prefer VideoToolbox/GPU (HEVC), and shed CPU work under heat or Low Power Mode.
enum MediaEncodePolicy {
    static var thermalState: ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }

    static var isLowPowerMode: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// Prefer hardware HEVC when the writer accepts it; H.264 remains the fallback.
    static var prefersHEVC: Bool { true }

    /// Screen-capture pixel format the media block can encode without a CPU BGRA→YUV convert.
    static var capturePixelFormat: OSType {
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    }

    /// Software BGRA fallback if ScreenCaptureKit rejects biplanar 420.
    static var capturePixelFormatFallback: OSType {
        kCVPixelFormatType_32BGRA
    }

    /// VideoToolbox compression properties: hardware encoder, realtime, no B-frame reorder.
    static func videoCompressionProperties(
        codec: AVVideoCodecType,
        width: Int,
        height: Int
    ) -> [String: Any] {
        let fps = liveTargetFPS
        var properties: [String: Any] = [
            AVVideoAverageBitRateKey: liveBitRate(width: width, height: height, codec: codec),
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: max(2, fps * 2),
            kVTCompressionPropertyKey_RealTime as String: true,
            kVTCompressionPropertyKey_AllowFrameReordering as String: false,
            kVTCompressionPropertyKey_MaximizePowerEfficiency as String: true,
            kVTCompressionPropertyKey_EncoderSpecification as String: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true
            ]
        ]
        if codec == .hevc {
            properties[kVTCompressionPropertyKey_ProfileLevel as String] = kVTProfileLevel_HEVC_Main_AutoLevel
        } else {
            properties[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        return properties
    }

    /// Target capture frame rate — drops frames above this to keep encode cheap.
    static var liveTargetFPS: Int {
        if isLowPowerMode { return 10 }
        switch thermalState {
        case .nominal: return 20
        case .fair: return 15
        case .serious: return 10
        case .critical: return 6
        @unknown default: return 12
        }
    }

    /// Bits/sec for live video. HEVC uses a lower multiplier than H.264 for similar quality.
    static func liveBitRate(width: Int, height: Int, codec: AVVideoCodecType) -> Int {
        let pixels = max(1, width * height)
        let base: Int
        switch codec {
        case .hevc:
            base = max(3_000_000, pixels * 3)
        default:
            base = max(6_000_000, pixels * 6)
        }
        let scale: Double
        if isLowPowerMode { return Int(Double(base) * 0.45) }
        switch thermalState {
        case .nominal: scale = 1.0
        case .fair: scale = 0.75
        case .serious: scale = 0.5
        case .critical: scale = 0.35
        @unknown default: scale = 0.6
        }
        return Int(Double(base) * scale)
    }

    /// Skip expensive CI rescale when the machine is hot — drop the frame instead.
    static var shouldAvoidCPUFrameConvert: Bool {
        if isLowPowerMode { return true }
        switch thermalState {
        case .serious, .critical: return true
        default: return false
        }
    }

    /// Under critical thermal pressure, stop accepting live video frames (audio continues).
    static var shouldDropAllLiveVideo: Bool {
        thermalState == .critical
    }

    /// Skip the post-meeting video re-encode/mux; keep separate tracks and let the player compose.
    static var shouldSkipVideoMux: Bool {
        if isLowPowerMode { return true }
        switch thermalState {
        case .serious, .critical: return true
        default: return false
        }
    }

    /// Export session priority: cheaper work when the system is stressed.
    static var exportTaskPriority: TaskPriority {
        if isLowPowerMode { return .background }
        switch thermalState {
        case .nominal, .fair: return .utility
        case .serious, .critical: return .background
        @unknown default: return .utility
        }
    }

    /// Ordered mux presets — remux first, then hardware HEVC, then H.264 size ladders.
    static var muxPresetPreference: [String] {
        var presets: [String] = [AVAssetExportPresetPassthrough]
        if prefersHEVC {
            presets += [
                AVAssetExportPresetHEVC1920x1080,
                AVAssetExportPresetHEVCHighestQuality
            ]
        }
        if shouldUseLowerQualityExport {
            presets += [
                AVAssetExportPreset1280x720,
                AVAssetExportPreset960x540,
                AVAssetExportPreset640x480,
                AVAssetExportPreset1920x1080
            ]
        } else {
            presets += [
                AVAssetExportPreset1920x1080,
                AVAssetExportPreset1280x720,
                AVAssetExportPresetHighestQuality
            ]
        }
        return presets
    }

    private static var shouldUseLowerQualityExport: Bool {
        if isLowPowerMode { return true }
        switch thermalState {
        case .fair, .serious, .critical: return true
        default: return false
        }
    }
}
