import CoreML
import FluidAudio
import Foundation
import Observation

enum FluidModelStatus: Equatable, Sendable {
    case notDownloaded
    case downloading(Double)
    case ready
    case failed(String)

    var title: String {
        switch self {
        case .notDownloaded: "Not downloaded"
        case .downloading(let p): "Downloading… \(Int(p * 100))%"
        case .ready: "Ready"
        case .failed(let message): "Failed: \(message)"
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Downloads and holds FluidAudio Sortformer + Parakeet models under Application Support.
@Observable
@MainActor
final class FluidAudioModelStore {
    static let shared = FluidAudioModelStore()

    var diarizationStatus: FluidModelStatus = .notDownloaded
    var asrStatus: FluidModelStatus = .notDownloaded
    var isPreparing = false
    var lastError: String?

    @ObservationIgnored private let neural = NeuralMeetingDiarizer(config: .default)
    @ObservationIgnored private var asrModels: AsrModels?
    @ObservationIgnored private weak var router: DiarizationRouter?
    @ObservationIgnored private var prepareTask: Task<Void, Never>?

    var neuralDiarizer: NeuralMeetingDiarizer { neural }

    var modelsReady: Bool {
        diarizationStatus.isReady && asrStatus.isReady
    }

    private var cacheDirectory: URL {
        let url = MediaStore.applicationSupport.appending(path: "Models", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func attach(router: DiarizationRouter) {
        self.router = router
        if diarizationStatus.isReady {
            router.attachNeural(neural)
        }
    }

    func prepareIfNeeded(enabled: Bool) {
        guard enabled else { return }
        guard prepareTask == nil else { return }
        prepareTask = Task { [weak self] in
            await self?.downloadAndLoad()
            self?.prepareTask = nil
        }
    }

    func downloadAndLoad() async {
        guard !isPreparing else { return }
        isPreparing = true
        lastError = nil
        defer { isPreparing = false }

        do {
            diarizationStatus = .downloading(0)
            let sortformerModels = try await SortformerModels.loadFromHuggingFace(
                config: .default,
                cacheDirectory: cacheDirectory,
                computeUnits: .cpuAndNeuralEngine
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.diarizationStatus = .downloading(progress.fractionCompleted)
                }
            }
            neural.attach(models: sortformerModels)
            router?.attachNeural(neural)
            diarizationStatus = .ready
        } catch {
            diarizationStatus = .failed(error.localizedDescription)
            lastError = error.localizedDescription
            router?.attachNeural(nil)
        }

        do {
            asrStatus = .downloading(0)
            var configuration = AsrModels.defaultConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            let models = try await AsrModels.downloadAndLoad(
                to: cacheDirectory.appending(path: "parakeet-v2", directoryHint: .isDirectory),
                configuration: configuration,
                version: .v2
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.asrStatus = .downloading(progress.fractionCompleted)
                }
            }
            asrModels = models
            asrStatus = .ready
        } catch {
            asrStatus = .failed(error.localizedDescription)
            lastError = error.localizedDescription
            asrModels = nil
        }
    }

    /// Snapshot of loaded ASR models for offline retranscription (nil if not ready).
    func currentAsrModels() -> AsrModels? {
        asrModels
    }
}
