import WhisperKit
import Foundation

/// Wraps WhisperKit (local CoreML Whisper inference) and biases decoding
/// toward common software-development and gaming vocabulary.
final class Transcriber {
    private var whisperKit: WhisperKit?

    private static let vocabHint = """
    Vocabulaire technique : Docker, Kubernetes, npm, GitHub, GitLab, API, framework, backend, \
    frontend, Python, JavaScript, TypeScript, Swift, Xcode, VS Code, commit, merge, pull request, \
    webhook, WebSocket, JSON, YAML, SQL, NoSQL, OAuth, JWT, CPU, GPU, RAM, SSD, SSH, URL, UI, UX. \
    Vocabulaire gaming : framerate, FPS, spawn, respawn, nerf, buff, matchmaking, ping, lag, loot, \
    cooldown, aggro, battle royale, speedrun, clutch, teamfight, gank, smurf, tryhard, noob, DPS, \
    PvP, PvE, AFK, GG.
    """

    func loadModel(named modelName: String = "small") async throws {
        whisperKit = try await WhisperKit(model: modelName)
    }

    func transcribe(samples: [Float]) async throws -> String {
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
            // on every 1.2s live tick, not just the final pass) and the
            // higher-temperature retries sample more randomly, which can
            // introduce word errors rather than fix them. Disabling it keeps
            // a single deterministic greedy pass.
            temperatureFallbackCount: 0,
            usePrefillPrompt: true,
            // The app only ever reads `.text`; timestamp tokens are pure
            // unneeded decode overhead here.
            withoutTimestamps: true,
            promptTokens: promptTokens(using: whisperKit)
        )

        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        return results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func promptTokens(using whisperKit: WhisperKit) -> [Int]? {
        guard let tokenizer = whisperKit.tokenizer else { return nil }
        return tokenizer.encode(text: Self.vocabHint)
    }
}

enum TranscriberError: Error {
    case modelNotLoaded
}
