//
//  TranscriptMerger.swift
//  Prompter
//
//  Joins Finals into the Accumulated transcript.
//

import Foundation

nonisolated enum TranscriptMerger {

    /// Only the tail is ever aligned (10 words for Finals), so older words are
    /// dropped to keep the transcript from growing for the whole session.
    static let maxWords = 200

    /// Append `final` to `accumulated`, merging words that overlap the end of
    /// `accumulated` with the start of `final` (engines often repeat the tail
    /// of the previous Utterance).
    static func merge(accumulated: String, final: String) -> String {
        let wa = words(accumulated)
        let wf = words(final)
        guard !wf.isEmpty else { return accumulated }
        guard !wa.isEmpty else { return capped(final) }

        let la = wa.map { $0.lowercased() }
        let lf = wf.map { $0.lowercased() }

        // Final already present at the end: nothing new.
        if la.count >= lf.count, Array(la.suffix(lf.count)) == lf { return accumulated }

        var overlap = 0
        for n in 1...min(la.count, lf.count) where Array(la.suffix(n)) == Array(lf.prefix(n)) {
            overlap = n
        }
        let merged = Array(wa.dropLast(overlap)) + wf
        return capped(merged.joined(separator: " "))
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func capped(_ text: String) -> String {
        let w = words(text)
        guard w.count > maxWords else { return text }
        return w.suffix(maxWords).joined(separator: " ")
    }
}
