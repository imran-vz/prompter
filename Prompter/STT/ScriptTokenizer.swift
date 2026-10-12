//
//  ScriptTokenizer.swift
//  Prompter
//
//  Turns a Script (or a transcript) into the normalised words the aligner
//  compares, keeping each word's UTF-16 range in the original text so an
//  Alignment can point back at exactly what is on screen.
//

import Foundation

nonisolated struct ScriptToken: Equatable, Sendable {
    /// Lowercased letters only (apostrophes inside words are dropped, so
    /// "Don't" and "dont" compare equal).
    let word: String
    /// UTF-16 range of the source text this word came from. Every word spelled
    /// out from one number ("42" → "forty", "two") shares the number's range.
    let range: NSRange
}

nonisolated struct TokenizedText: Sendable {
    let tokens: [ScriptToken]
    /// Indices into `tokens` where a sentence or line starts.
    let sentenceStarts: [Int]

    var words: [String] { tokens.map(\.word) }
}

nonisolated enum ScriptTokenizer {

    /// Tokenise text for alignment.
    ///
    /// - Stage directions (`[bracketed]` text) are skipped: the speaker never
    ///   says them, so matching against them only adds noise.
    /// - Digit runs are spelled out, because recognisers return "three" as
    ///   often as "3".
    static func tokenize(_ text: String, locale: Locale = .current) -> TokenizedText {
        var tokens: [ScriptToken] = []
        var sentenceStarts: [Int] = []
        var atSentenceStart = true

        let chars = Array(text)
        var offsets: [Int] = []   // UTF-16 offset of each Character
        offsets.reserveCapacity(chars.count + 1)
        var running = 0
        for ch in chars {
            offsets.append(running)
            running += ch.utf16.count
        }
        offsets.append(running)

        var i = 0
        var bracketDepth = 0
        while i < chars.count {
            let ch = chars[i]

            if ch == "[" { bracketDepth += 1; i += 1; continue }
            if ch == "]" { bracketDepth = max(0, bracketDepth - 1); i += 1; continue }
            if bracketDepth > 0 {
                if ch == "\n" { bracketDepth = 0; atSentenceStart = true }   // unclosed bracket ends at the line
                i += 1
                continue
            }

            if ch.isLetter {
                let start = i
                var word = ""
                while i < chars.count {
                    let c = chars[i]
                    if c.isLetter {
                        word += c.lowercased()
                        i += 1
                    } else if isApostrophe(c), i + 1 < chars.count, chars[i + 1].isLetter, !word.isEmpty {
                        i += 1
                    } else {
                        break
                    }
                }
                if atSentenceStart { sentenceStarts.append(tokens.count); atSentenceStart = false }
                tokens.append(ScriptToken(word: word,
                                          range: NSRange(location: offsets[start], length: offsets[i] - offsets[start])))
                continue
            }

            if ch.isASCIIDigit {
                let start = i
                var digits = ""
                while i < chars.count, chars[i].isASCIIDigit {
                    digits.append(chars[i])
                    i += 1
                }
                let range = NSRange(location: offsets[start], length: offsets[i] - offsets[start])
                let spelled = spellOut(digits, locale: locale)
                if !spelled.isEmpty, atSentenceStart { sentenceStarts.append(tokens.count); atSentenceStart = false }
                for word in spelled {
                    tokens.append(ScriptToken(word: word, range: range))
                }
                continue
            }

            if ch == "." || ch == "!" || ch == "?" || ch.isNewline {
                atSentenceStart = true
            }
            i += 1
        }

        return TokenizedText(tokens: tokens, sentenceStarts: sentenceStarts)
    }

    /// Normalised words only (for transcripts, where ranges don't matter).
    static func words(_ text: String, locale: Locale = .current) -> [String] {
        tokenize(text, locale: locale).words
    }

    // MARK: - Helpers

    private static func isApostrophe(_ c: Character) -> Bool {
        c == "'" || c == "\u{2019}"
    }

    private static func spellOut(_ digits: String, locale: Locale) -> [String] {
        // Very long digit runs (phone numbers, IDs) are read digit by digit.
        guard digits.count <= 9, let value = Int(digits) else {
            return digits.flatMap { spellOut(String($0), locale: locale) }
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = locale
        guard let spelled = formatter.string(from: NSNumber(value: value)) else { return [] }
        return spelled.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
    }
}

private extension Character {
    nonisolated var isASCIIDigit: Bool { isASCII && isWholeNumber }
}
