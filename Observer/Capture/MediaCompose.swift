import AVFoundation
import Foundation

enum MediaCompose {
    /// Mix mic + system (or whichever exists) into a single AAC file.
    static func mixAudio(
        micURL: URL?,
        systemURL: URL?,
        outputURL: URL
    ) async throws -> URL? {
        let mic = usableMediaURL(micURL)
        let system = usableMediaURL(systemURL)
        guard mic != nil || system != nil else { return nil }

        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if let mic, system == nil {
            try FileManager.default.copyItem(at: mic, to: outputURL)
            return outputURL
        }
        if let system, mic == nil {
            try FileManager.default.copyItem(at: system, to: outputURL)
            return outputURL
        }

        guard let mic, let system else { return nil }

        let composition = AVMutableComposition()
        let micAsset = AVURLAsset(url: mic)
        let systemAsset = AVURLAsset(url: system)

        let micTracks = try await micAsset.loadTracks(withMediaType: .audio)
        let systemTracks = try await systemAsset.loadTracks(withMediaType: .audio)
        guard let micTrack = micTracks.first, let systemTrack = systemTracks.first else {
            return nil
        }

        let micDuration = try await micAsset.load(.duration)
        let systemDuration = try await systemAsset.load(.duration)

        guard let compositionMic = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ), let compositionSystem = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { return nil }

        try compositionMic.insertTimeRange(
            CMTimeRange(start: .zero, duration: micDuration),
            of: micTrack,
            at: .zero
        )
        try compositionSystem.insertTimeRange(
            CMTimeRange(start: .zero, duration: systemDuration),
            of: systemTrack,
            at: .zero
        )

        let mix = AVMutableAudioMix()
        let micParams = AVMutableAudioMixInputParameters(track: compositionMic)
        micParams.setVolume(0.95, at: .zero)
        let systemParams = AVMutableAudioMixInputParameters(track: compositionSystem)
        systemParams.setVolume(0.95, at: .zero)
        mix.inputParameters = [micParams, systemParams]

        guard let export = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw ObserverError.captureFailed("Could not create audio mix export session.")
        }
        export.audioMix = mix

        try await export.export(to: outputURL, as: .m4a)
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw ObserverError.captureFailed("Audio mix export did not finish.")
        }
        return outputURL
    }

    /// Mux window video with mixed audio into one playable MP4.
    /// Prefer remux-style presets so we don't re-encode (and potentially blacken) the video.
    static func muxVideo(
        videoURL: URL?,
        audioURL: URL?,
        outputURL: URL
    ) async throws -> URL? {
        guard let video = usableMediaURL(videoURL) else { return nil }
        guard let audio = usableMediaURL(audioURL) else { return video }

        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)

        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        guard let sourceVideo = videoTracks.first else { return video }

        let videoDuration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)

        // If the raw video is suspiciously tiny for its duration, skip mux and keep
        // separate tracks — a black re-encode helps nobody.
        let videoSize = (try? video.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let bytesPerSecond = Double(videoSize) / max(videoDuration.seconds, 1)
        if bytesPerSecond < 12_000 {
            return video
        }

        guard let compositionVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { return video }

        try compositionVideo.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: sourceVideo,
            at: .zero
        )
        compositionVideo.preferredTransform = try await sourceVideo.load(.preferredTransform)

        if let sourceAudio = audioTracks.first,
           let compositionAudio = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let insertDuration = CMTimeMinimum(audioDuration, videoDuration)
            try compositionAudio.insertTimeRange(
                CMTimeRange(start: .zero, duration: insertDuration),
                of: sourceAudio,
                at: .zero
            )
        }

        // Avoid HighestQuality re-encode when possible — it can produce black frames
        // from some ScreenCaptureKit H.264 bitstreams. Prefer 1920x1080 / 1280x720.
        let preferredPresets = [
            AVAssetExportPreset1920x1080,
            AVAssetExportPreset1280x720,
            AVAssetExportPresetHighestQuality
        ]
        let available = Set(AVAssetExportSession.allExportPresets())
        let preset = preferredPresets.first(where: { available.contains($0) })
            ?? AVAssetExportPresetPassthrough
        guard let export = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw ObserverError.captureFailed("Could not create video mux export session.")
        }

        try await export.export(to: outputURL, as: .mp4)
        let outputSize = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let outputBPS = Double(outputSize) / max(videoDuration.seconds, 1)
        guard FileManager.default.fileExists(atPath: outputURL.path),
              outputSize > 0,
              outputBPS > 12_000
        else {
            // Fall back to the raw capture rather than shipping a black mux.
            return video
        }
        return outputURL
    }

    static func mixedAudioURL(in folder: URL) -> URL {
        folder.appending(path: "mixed.m4a")
    }

    static func composedVideoURL(in folder: URL) -> URL {
        folder.appending(path: "recording.mp4")
    }

    /// Back-compat names.
    static func mix(micURL: URL?, systemURL: URL?, outputURL: URL) async throws -> URL? {
        try await mixAudio(micURL: micURL, systemURL: systemURL, outputURL: outputURL)
    }

    static func mixedURL(in folder: URL) -> URL {
        mixedAudioURL(in: folder)
    }

    private static func usableMediaURL(_ url: URL?) -> URL? {
        guard let url else { return nil }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) > 0
        else { return nil }
        return url
    }
}

typealias AudioMixComposer = MediaCompose
