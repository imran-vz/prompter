import Combine
import Foundation
import WhisperKit

@MainActor
final class WhisperKitModelManager: ObservableObject {
    static let shared = WhisperKitModelManager()

    @Published var availableModels: [String] = []
    @Published var downloadedModels: [String] = []
    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0
    @Published var downloadError: String?

    private let defaultsKey = "WhisperKitDownloadedModels"
    private let pathsKey = "WhisperKitModelPaths"
    private let lastUsedKey = "WhisperKitLastUsedDates"

    private var modelPaths: [String: String] = [:]

    private init() {
        let defaults = UserDefaults.standard
        downloadedModels = defaults.stringArray(forKey: defaultsKey) ?? []
        modelPaths = defaults.dictionary(forKey: pathsKey) as? [String: String] ?? [:]
        Task {
            await fetchAvailableModels()
        }
    }

    func fetchAvailableModels() async {
        do {
            let models = try await WhisperKit.fetchAvailableModels()
            await MainActor.run {
                availableModels = models
            }
        } catch {
            await MainActor.run {
                availableModels = [
                    "tiny", "tiny.en",
                    "base", "base.en",
                    "small", "small.en",
                    "medium", "medium.en",
                    "large-v1", "large-v2", "large-v3"
                ]
            }
        }
    }

    func isDownloaded(_ model: String) -> Bool {
        downloadedModels.contains(model)
    }

    func lastUsedDate(for model: String) -> Date? {
        let dates = UserDefaults.standard.object(forKey: lastUsedKey) as? [String: Date] ?? [:]
        return dates[model]
    }

    func markUsed(model: String) {
        var dates = UserDefaults.standard.object(forKey: lastUsedKey) as? [String: Date] ?? [:]
        dates[model] = Date()
        UserDefaults.standard.set(dates, forKey: lastUsedKey)
        objectWillChange.send()
    }

    func delete(model: String) {
        guard let path = modelPaths[model] ?? locateModelPath(for: model) else {
            removeFromTracking(model: model)
            return
        }

        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            print("Failed to delete model \(model): \(error)")
        }

        removeFromTracking(model: model)
    }

    private func removeFromTracking(model: String) {
        downloadedModels.removeAll { $0 == model }
        modelPaths.removeValue(forKey: model)
        var dates = UserDefaults.standard.object(forKey: lastUsedKey) as? [String: Date] ?? [:]
        dates.removeValue(forKey: model)
        UserDefaults.standard.set(dates, forKey: lastUsedKey)
        UserDefaults.standard.set(downloadedModels, forKey: defaultsKey)
        UserDefaults.standard.set(modelPaths, forKey: pathsKey)
        objectWillChange.send()
    }

    private func locateModelPath(for model: String) -> String? {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let base = documents?.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
        guard let base = base else { return nil }

        do {
            let contents = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
            for url in contents {
                if url.lastPathComponent.contains(model) {
                    return url.path
                }
            }
        } catch {
            print("Failed to locate model path: \(error)")
        }
        return nil
    }

    func download(model: String) async {
        isDownloading = true
        downloadProgress = 0
        downloadError = nil
        defer {
            isDownloading = false
            downloadProgress = 0
        }

        do {
            let url = try await WhisperKit.download(variant: model) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.downloadProgress = progress.fractionCompleted
                }
            }
            if !downloadedModels.contains(model) {
                downloadedModels.append(model)
                UserDefaults.standard.set(downloadedModels, forKey: defaultsKey)
            }
            modelPaths[model] = url.path
            UserDefaults.standard.set(modelPaths, forKey: pathsKey)
        } catch {
            downloadError = error.localizedDescription
        }
    }
}
