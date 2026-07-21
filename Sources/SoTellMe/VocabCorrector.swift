import Foundation

/// Post-processing pass that fixes common mis-transcriptions of tech/gaming
/// jargon that the model prompt-biasing alone doesn't always catch.
final class VocabCorrector {
    private let corrections: [(NSRegularExpression, String)]

    init() {
        var loaded: [(NSRegularExpression, String)] = []
        if let url = Bundle.module.url(forResource: "vocab_corrections", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            for (pattern, replacement) in dict {
                let escaped = NSRegularExpression.escapedPattern(for: pattern)
                if let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: [.caseInsensitive]) {
                    loaded.append((regex, replacement))
                }
            }
        }
        corrections = loaded
    }

    func apply(to text: String) -> String {
        var result = text
        for (regex, replacement) in corrections {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: replacement)
        }
        return result
    }
}
