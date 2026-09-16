import AVFoundation
import Foundation

/// Serializes all AVComposition construction/export across the app.
///
/// AVFoundation's internal media-selection and track-reader caches on macOS are not safe
/// against concurrent AVComposition/AVPlayerItem construction and teardown from independent
/// call sites (playback compositing here vs. export compositing in `MediaCompose`) — running
/// two at once has crashed with a SIGSEGV deep in MediaToolbox. `AVMutableComposition` is not
/// Sendable, so it can't be handed through an actor-isolated closure; instead this is a plain
/// async mutex — callers `acquire()`, do their composition work in their own context, then
/// `release()` — so only one composition is ever being built/torn down at a time app-wide.
actor MediaCompositionGate {
    static let shared = MediaCompositionGate()

    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

enum MediaCompose {
    /// Mix mic + system (or whichever exists) into a single AAC file.
    static func mixAudio(
        micURL: URL?,
        systemURL: URL?,
        outputURL: URL
    ) async throws -> URL? {
        try await Task.detached(priority: MediaEncodePolicy.exportTaskPriority) {
            try await mixAudioLocked(micURL: micURL, systemURL: systemURL, outputURL: outputURL)
        }.value
    }

    /// Mux window video with mixed audio into one playable MP4.
    /// Prefer passthrough remux, then hardware HEVC, then H.264 size ladders.
    static func muxVideo(
        videoURL: URL?,
        audioURL: URL?,
        outputURL: URL
    ) async throws -> URL? {
        if MediaEncodePolicy.shouldSkipVideoMux {
            return usableMediaURL(videoURL)
        }
        return try await Task.detached(priority: MediaEncodePolicy.exportTaskPriority) {
            try await muxVideoLocked(videoURL: videoURL, audioURL: audioURL, outputURL: outputURL)
        }.value
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

    // MARK: - Internals

    private static func mixAudioLocked(
        micURL: URL?,
        systemURL: URL?,
        outputURL: URL
    ) async throws -> URL? {
        let mic = usableMediaURL(micURL)
        let system = usableMediaURL(systemURL)
        guard mic != nil || system != nil else { return nil }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Reprocessing can pass the same path back in as both a source and `outputURL` (e.g.
        // re-mixing from an already-mixed file). Never delete/overwrite the destination before
        // the source has been fully read — copy/export to a sibling temp file, then replace.
        if let mic, system == nil {
            if mic == outputURL { return outputURL }
            try replaceItem(at: outputURL, withContentsCopiedFrom: mic)
            return outputURL
        }
        if let system, mic == nil {
            if system == outputURL { return outputURL }
            try replaceItem(at: outputURL, withContentsCopiedFrom: system)
            return outputURL
        }

        guard let mic, let system else { return nil }

        await MediaCompositionGate.shared.acquire()
        defer {
            let gate = MediaCompositionGate.shared
            Task { await gate.release() }
        }
        do {
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
                throw SauronError.captureFailed("Could not create audio mix export session.")
            }
            export.audioMix = mix

            let tempURL = temporaryURL(near: outputURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            try await export.export(to: tempURL, as: .m4a)
            guard FileManager.default.fileExists(atPath: tempURL.path) else {
                throw SauronError.captureFailed("Audio mix export did not finish.")
            }
            try replaceItem(at: outputURL, movingFrom: tempURL)
            return outputURL
        }
    }

    private static func muxVideoLocked(
        videoURL: URL?,
        audioURL: URL?,
        outputURL: URL
    ) async throws -> URL? {
        guard let video = usableMediaURL(videoURL) else { return nil }
        guard let audio = usableMediaURL(audioURL) else { return video }

        // Reprocessing can pass the already-composed output back in as `videoURL` (its raw
        // capture reference is gone once composed once). Never delete/overwrite `outputURL`
        // before `video`/`audio` have been fully read — every export below lands in a sibling
        // temp file first and is only moved into place once reading is done.
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        await MediaCompositionGate.shared.acquire()
        defer {
            let gate = MediaCompositionGate.shared
            Task { await gate.release() }
        }
        do {
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

            let available = Set(AVAssetExportSession.allExportPresets())
            let candidates = MediaEncodePolicy.muxPresetPreference.filter { available.contains($0) }
            let presets = candidates.isEmpty ? [AVAssetExportPresetPassthrough] : candidates

            let tempURL = temporaryURL(near: outputURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            for preset in presets {
                try? FileManager.default.removeItem(at: tempURL)
                guard let export = AVAssetExportSession(asset: composition, presetName: preset) else {
                    continue
                }
                do {
                    try await export.export(to: tempURL, as: .mp4)
                } catch {
                    continue
                }
                let outputSize = (try? tempURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                let outputBPS = Double(outputSize) / max(videoDuration.seconds, 1)
                if FileManager.default.fileExists(atPath: tempURL.path),
                   outputSize > 0,
                   outputBPS > 12_000 {
                    try replaceItem(at: outputURL, movingFrom: tempURL)
                    return outputURL
                }
            }

            // Fall back to the raw capture rather than shipping a black mux.
            return video
        }
    }

    private static func usableMediaURL(_ url: URL?) -> URL? {
        guard let url else { return nil }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) > 0
        else { return nil }
        return url
    }

    /// A sibling of `url` in the same directory (so the final move is a same-volume rename,
    /// not a cross-device copy) that won't collide with a real file.
    private static func temporaryURL(near url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)-\(url.lastPathComponent)")
    }

    /// Moves `tempURL` onto `outputURL`, replacing whatever (if anything) is there.
    private static func replaceItem(at outputURL: URL, movingFrom tempURL: URL) throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: outputURL)
        }
    }

    /// Copies `source` onto `outputURL` via a temp file, replacing whatever (if anything) is
    /// already at `outputURL` only once the copy has fully succeeded.
    private static func replaceItem(at outputURL: URL, withContentsCopiedFrom source: URL) throws {
        let tempURL = temporaryURL(near: outputURL)
        try? FileManager.default.removeItem(at: tempURL)
        try FileManager.default.copyItem(at: source, to: tempURL)
        do {
            try replaceItem(at: outputURL, movingFrom: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }
}

typealias AudioMixComposer = MediaCompose
