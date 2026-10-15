import Foundation

/// Intentionally narrow: equivalent morphology/auxiliaries may keep their wording, but reordered roles,
/// quantities, names, dates, negation, modality, and new clauses must remain observable.
public enum FactualRewrite {
    private static func clauses(_ text: String) -> [String] {
        text.components(separatedBy: ". ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }.filter { !$0.isEmpty }
    }
    private static func signature(_ text: String) -> [String] {
        let forms = ["tells":"tell", "says":"say", "owns":"own", "moves":"move", "follows":"follow", "needs":"need"]
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "%" }).map(String.init)
        return words.enumerated().filter { index, word in
            // Remove only the auxiliary before a known equivalent verb, never a person named Will.
            !(word == "will" && index > 0 && index + 1 < words.count && Set(forms.values).contains(words[index + 1].lowercased()))
        }.map { _, word in forms[word.lowercased()] ?? word.lowercased() }
    }
    public static func preserve(previous: String, proposed: String) -> (text: String, kept: Bool) {
        let old = clauses(previous)
        var kept = false
        let result = clauses(proposed).map { clause -> String in
            guard let match = old.first(where: { signature($0) == signature(clause) }), match != clause else { return clause }
            kept = true; return match
        }.joined(separator: ". ") + (proposed.hasSuffix(".") ? "." : "")
        return (result, kept)
    }
}
