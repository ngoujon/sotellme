import WhisperKit
import Foundation

/// Wraps WhisperKit (local CoreML Whisper inference).
///
/// No vocabulary prompt is given to the model: measured on the `small`
/// model, a prompt of tech/gaming terms added ~1.6s to *every* decode
/// (prompt tokens go through the decoder one by one) and made Whisper
/// return the whole window as a single segment, which breaks live
/// transcription (see AppDelegate). Jargon is fixed afterwards by
/// `VocabCorrector` instead.
///
/// An actor so the live (in-progress) pass and the final pass never run
/// inference on the same WhisperKit instance concurrently: a final pass
/// requested while a live tick is still decoding simply waits for it.
actor Transcriber {
    private var whisperKit: WhisperKit?

    /// Above this gzip compression ratio a segment is a repetition loop
    /// ("j-m-m-m-m-m…"), Whisper's usual failure mode on audio cut
    /// mid-word. Same threshold as WhisperKit's own fallback heuristic.
    private static let repetitionCompressionRatio: Float = 2.4

    func loadModel(named modelName: String = "small") async throws {
        // Load straight from the local copy when it exists: otherwise
        // WhisperKit queries Hugging Face on every launch to resolve the
        // model folder, even though the files are already on disk.
        if let folder = Self.localModelFolder(named: modelName) {
            whisperKit = try await WhisperKit(modelFolder: folder.path)
        } else {
            whisperKit = try await WhisperKit(model: modelName)
        }
    }

    /// Where WhisperKit's first-launch download puts the model (HubApi's
    /// default base, ~/Documents/huggingface). Nil if not downloaded yet.
    private static func localModelFolder(named modelName: String) -> URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let folder = documents
            .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent("openai_whisper-\(modelName)")
        let required = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"]
        let complete = required.allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        return complete ? folder : nil
    }

    /// A decoded stretch of speech; `end` is in seconds from the start of
    /// the audio passed to `transcribe`.
    struct Segment {
        let text: String
        let end: Float
        let isRepetitionLoop: Bool
    }

    func transcribe(samples: [Float]) async throws -> [Segment] {
        guard let whisperKit = whisperKit else {
            throw TranscriberError.modelNotLoaded
        }

        let options = DecodingOptions(
            task: .transcribe,
            language: "fr",
            temperature: 0,
            // WhisperKit defaults to up to 5 extra decode passes at rising
            // temperature whenever its quality heuristics flag the greedy
            // output as suspect. For short, near-field dictation this mostly
            // triggers false positives — it multiplies decode cost (this runs
            // on every live tick, not just the final pass) and the
            // higher-temperature retries sample more randomly, which can
            // introduce word errors rather than fix them. Disabling it keeps
            // a single deterministic greedy pass.
            temperatureFallbackCount: 0,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            // Timestamps give segment boundaries, which live transcription
            // uses to lock in finished sentences (see AppDelegate).
            withoutTimestamps: false
        )

        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        return results.flatMap(\.segments).map {
            Segment(
                text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                end: $0.end,
                isRepetitionLoop: $0.compressionRatio > Self.repetitionCompressionRatio
            )
        }
    }
}

enum TranscriberError: Error {
    case modelNotLoaded
}
