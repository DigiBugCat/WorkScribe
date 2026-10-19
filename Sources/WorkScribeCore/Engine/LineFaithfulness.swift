import Foundation

/// A numeric support check only. Semantic faithfulness belongs to the one-jot prompt.
public enum LineFaithfulness {
    public static func grounded(_ text: String, evidence: [String], jot: String) -> Bool {
        let quantities = text.replacingOccurrences(of: #"(?i)\bspeaker\s+\d+\b"#, with: "speaker", options: .regularExpression)
        return Grounding.numbers(in: quantities).isSubset(of: Grounding.numbers(in: evidence.joined(separator: ". ")))
    }
}
