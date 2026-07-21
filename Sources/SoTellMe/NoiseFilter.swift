import Foundation

/// Strips non-speech annotations that Whisper sometimes hallucinates instead
/// of transcribing actual words: bracketed/parenthesized sound descriptions
/// (e.g. "[Musique]", "(rires)", "(bruit de fond)"), stray music-note glyphs,
/// and a handful of well-known boilerplate phrases it picks up from its
/// subtitle training data on noisy or near-silent audio. Spoken numbers and
/// math are untouched — they never take this bracketed/credited form.
enum NoiseFilter {
    private static let bracketedAnnotation = try! NSRegularExpression(
        pattern: #"\[[^\[\]]{0,120}\]"#
    )
    private static let parenthesizedAnnotation = try! NSRegularExpression(
        pattern: #"\([^()]{0,120}\)"#
    )
    private static let musicNotes = try! NSRegularExpression(pattern: "[♪🎵🎶]+")
    private static let extraWhitespace = try! NSRegularExpression(pattern: #"\s{2,}"#)

    /// Boilerplate Whisper hallucinates on noisy/near-silent audio instead of
    /// admitting there's no speech — mostly auto-subtitle credit lines it
    /// saw in training data.
    private static let hallucinatedPhrases = [
        "sous-titres réalisés par la communauté d'amara.org",
        "sous-titrage st' 501",
        "sous-titrage société radio-canada",
        "merci d'avoir regardé cette vidéo",
        "merci d'avoir regardé",
        "n'hésitez pas à vous abonner",
        "abonnez-vous à la chaîne",
        "à bientôt pour une nouvelle vidéo",
    ]

    static func apply(to text: String) -> String {
        var result = text
        result = replaceAll(bracketedAnnotation, in: result, with: "")
        result = replaceAll(parenthesizedAnnotation, in: result, with: "")
        result = replaceAll(musicNotes, in: result, with: "")

        for phrase in hallucinatedPhrases {
            result = removeCaseInsensitive(phrase, from: result)
        }

        result = replaceAll(extraWhitespace, in: result, with: " ")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replaceAll(_ regex: NSRegularExpression, in text: String, with replacement: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }

    private static func removeCaseInsensitive(_ phrase: String, from text: String) -> String {
        var result = text
        while let range = result.range(of: phrase, options: .caseInsensitive) {
            result.removeSubrange(range)
        }
        return result
    }
}
