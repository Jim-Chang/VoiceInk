import Foundation

struct TranscribeCppModelArtifact: Sendable {
    let modelName: String
    let fileName: String
    let repository: String
    let repositoryRevision: String
    let expectedFileSize: Int64
    let expectedSHA256: String
    let architectureHint: String?
    let enablesInverseTextNormalization: Bool
    let maximumChunkSeconds: Int
    let boundarySearchSeconds: Int
    let boundaryEnergyWindowSamples: Int

    var downloadURL: URL {
        URL(
            string: "https://huggingface.co/\(repository)/resolve/\(repositoryRevision)/\(fileName)"
        )!
    }

    var modelDirectory: URL {
        Self.applicationSupportDirectory
            .appendingPathComponent("TranscribeCpp", isDirectory: true)
            .appendingPathComponent(modelName, isDirectory: true)
    }

    var modelFileURL: URL {
        modelDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    var checksumFileURL: URL {
        modelDirectory.appendingPathComponent(".\(fileName).sha256", isDirectory: false)
    }

    var installedModelFileURL: URL? {
        modelFileIsValid(in: modelDirectory) ? modelFileURL : nil
    }

    func modelFileIsValid(in directory: URL) -> Bool {
        let fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
        let checksumURL = directory.appendingPathComponent(".\(fileName).sha256", isDirectory: false)

        guard
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true,
            let size = values.fileSize,
            Int64(size) == expectedFileSize
        else {
            return false
        }

        let installedChecksum = try? String(contentsOf: checksumURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return installedChecksum == expectedSHA256
    }

    func removeInstalledFiles() {
        try? FileManager.default.removeItem(at: modelDirectory)
    }

    private static var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk", isDirectory: true)
    }
}

enum TranscribeCppModelCatalog {
    static let cohereTranscribe = TranscribeCppModelArtifact(
        modelName: "cohere-transcribe",
        fileName: "cohere-transcribe-03-2026-Q4_K_M.gguf",
        repository: "handy-computer/cohere-transcribe-03-2026-gguf",
        repositoryRevision: "dfa4adebb64f3076b7b6b90b721275cc069cb421",
        expectedFileSize: 1_558_162_944,
        expectedSHA256: "0ea56826d8bd5d74b7143a4a04e022dc1bb75452cfae49d98b6acb0c1d16a1fb",
        architectureHint: "cohere",
        enablesInverseTextNormalization: false,
        maximumChunkSeconds: 35,
        boundarySearchSeconds: 5,
        boundaryEnergyWindowSamples: 1_600
    )

    static let senseVoiceSmall = TranscribeCppModelArtifact(
        modelName: "sensevoice-small",
        fileName: "SenseVoiceSmall-Q8_0.gguf",
        repository: "handy-computer/SenseVoiceSmall-gguf",
        repositoryRevision: "4a08b8e900b38a977e32eb08d5d0697d6e72ba04",
        expectedFileSize: 252_684_608,
        expectedSHA256: "6c759ee4c9748c9b3f7a5a60ca74f0f7e685fb9d45d1378fce7cfd62f59adf29",
        architectureHint: "sensevoice",
        enablesInverseTextNormalization: true,
        maximumChunkSeconds: 30,
        boundarySearchSeconds: 3,
        boundaryEnergyWindowSamples: 1_600
    )

    // voiceink-zhtw：TEA-ASR-1.1（Qwen3-ASR-1.7B 的台灣華語微調）。原作者只有 safetensors，
    // 這個 GGUF 是自己用 transcribe.cpp 的轉檔程式轉的（scripts/bench/tea_prepare.py）。
    // 這版 transcribe.cpp 每次最多產生 256 個 token，所以每 30 秒切一段。
    // 見 docs/plan/2026-10-22-tea-asr.md。
    static let teaASR11 = TranscribeCppModelArtifact(
        modelName: "tea-asr-1.1",
        fileName: "TEA-ASR-1.1-Q8_0.gguf",
        repository: "dorajim15/TEA-ASR-1.1-transcribe-cpp",
        repositoryRevision: "cc49fae1183e7458411663c2a39de1fdfef8ff7a",
        expectedFileSize: 2_184_763_808,
        expectedSHA256: "2e4aeb45c9e7f421d99909e29e49a54e204d70ed0e77bebc3f18a135d78298d0",
        architectureHint: "qwen3_asr",
        enablesInverseTextNormalization: false,
        maximumChunkSeconds: 30,
        boundarySearchSeconds: 3,
        boundaryEnergyWindowSamples: 1_600
    )

    private static let artifactsByModelName = [
        cohereTranscribe.modelName: cohereTranscribe,
        senseVoiceSmall.modelName: senseVoiceSmall,
        teaASR11.modelName: teaASR11,
    ]

    static func artifact(for modelName: String) -> TranscribeCppModelArtifact? {
        artifactsByModelName[modelName]
    }
}
