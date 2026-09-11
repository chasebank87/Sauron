import AVFoundation
import Foundation

enum AudioMixComposer {
    /// Mix mic + system (or whichever exists) into a single AAC file.
    static func mix(
        micURL: URL?,
        systemURL: URL?,
        outputURL: URL
    ) async throws -> URL? {
        let mic = usableAudioURL(micURL)
        let system = usableAudioURL(systemURL)
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
        micParams.setVolume(0.9, at: .zero)
        let systemParams = AVMutableAudioMixInputParameters(track: compositionSystem)
        systemParams.setVolume(0.9, at: .zero)
        mix.inputParameters = [micParams, systemParams]

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw ObserverError.captureFailed("Could not create audio mix export session.")
        }
        export.audioMix = mix

        try await export.export(to: outputURL, as: .m4a)
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw ObserverError.captureFailed("Audio mix export did not finish.")
        }
        return outputURL
    }

    static func mixedURL(in folder: URL) -> URL {
        folder.appending(path: "mixed.m4a")
    }

    private static func usableAudioURL(_ url: URL?) -> URL? {
        guard let url else { return nil }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) > 0
        else { return nil }
        return url
    }
}
