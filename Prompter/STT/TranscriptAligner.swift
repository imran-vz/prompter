//
//  TranscriptAligner.swift
//  Prompter
//

import Foundation

nonisolated struct AlignmentResult: Equatable, Sendable {
    /// Fraction of the Script's words read so far (0…1). Only used as a
    /// fallback when the on-screen text layout is unavailable.
    let progress: Double
    let confidence: Double
    let matchedText: String
    let wordStartIndex: Int
    /// One past the last matched word.
    let wordEndIndex: Int
    /// UTF-16 offset in the Script just after the last word heard.
    let readUpToOffset: Int
    /// UTF-16 range in the Script of the last word heard (the Current word).
    let currentWordRange: NSRange
}

/// Fuzzy-matches a spoken transcript against a script to find the current
/// reading position. Runs as an `actor` so all work happens off the main thread.
actor TranscriptAligner {
    private var originalScript: NSString = ""
    private var words: [String] = []
    private var ranges: [NSRange] = []
    private var sentenceStarts: [Int] = []
    private var locale: Locale = .current

    private let partialWindowSize = 6
    private let finalWindowSize = 10

    private var lastMatchedIndex = 0

    func reset() {
        lastMatchedIndex = 0
    }

    func setLocale(_ newLocale: Locale) {
        guard newLocale != locale else { return }
        locale = newLocale
        updateScript(originalScript as String)
    }

    func updateScript(_ newScript: String) {
        originalScript = newScript as NSString
        let tokenized = ScriptTokenizer.tokenize(newScript, locale: locale)
        words = tokenized.words
        ranges = tokenized.tokens.map(\.range)
        sentenceStarts = tokenized.sentenceStarts
        lastMatchedIndex = 0
    }

    /// Find the current reading position for a transcript. Callers serialize
    /// alignment through a single worker, so results are inherently in order.
    func align(transcript: String, isFinal: Bool) -> AlignmentResult? {
        let transcriptWords = ScriptTokenizer.words(transcript, locale: locale)
        guard !transcriptWords.isEmpty, !words.isEmpty else { return nil }

        let windowSize = isFinal ? finalWindowSize : partialWindowSize
        let searchWindow = min(windowSize, transcriptWords.count)
        let query = Array(transcriptWords.suffix(searchWindow))

        var bestScore: Double = 0
        var bestIndex = 0
        var searched = Set<Int>()

        // 1. Search near last matched position
        let nearStart = max(0, lastMatchedIndex - searchWindow)
        let nearEnd = min(words.count, lastMatchedIndex + searchWindow * 3)
        searchRange(nearStart..<nearEnd, query: query, window: searchWindow,
                    searched: &searched, bestScore: &bestScore, bestIndex: &bestIndex)

        // 2. Search sentence starts
        if bestScore < 0.7 {
            for (si, start) in sentenceStarts.enumerated() {
                let end = si + 1 < sentenceStarts.count ? sentenceStarts[si + 1] : words.count
                searchRange(start..<end, query: query, window: searchWindow,
                            searched: &searched, bestScore: &bestScore, bestIndex: &bestIndex)
            }
        }

        // 3. Full scan fallback
        if bestScore < 0.5 {
            searchRange(0..<words.count, query: query, window: searchWindow,
                        searched: &searched, bestScore: &bestScore, bestIndex: &bestIndex)
        }

        guard bestScore > 0.35 else { return nil }

        // Forward bias
        if bestIndex < lastMatchedIndex {
            let jump = lastMatchedIndex - bestIndex
            if jump > 15 && bestScore < 0.85 { return nil }
            if jump > 5 && bestScore < 0.7 { return nil }
        }

        lastMatchedIndex = bestIndex

        // Anchor to the last word of the matched window: the word just heard.
        let lastIndex = min(bestIndex + searchWindow, words.count) - 1
        let startRange = ranges[bestIndex]
        let endRange = ranges[lastIndex]
        let matchedRange = NSRange(location: startRange.location,
                                   length: NSMaxRange(endRange) - startRange.location)

        return AlignmentResult(
            progress: Double(lastIndex + 1) / Double(words.count),
            confidence: bestScore,
            matchedText: originalScript.substring(with: matchedRange),
            wordStartIndex: bestIndex,
            wordEndIndex: lastIndex + 1,
            readUpToOffset: NSMaxRange(endRange),
            currentWordRange: endRange
        )
    }

    // MARK: - Matching

    private func searchRange(_ range: Range<Int>, query: [String], window: Int,
                             searched: inout Set<Int>,
                             bestScore: inout Double, bestIndex: inout Int) {
        let clampedEnd = min(range.upperBound, words.count)
        guard range.lowerBound < clampedEnd else { return }
        for i in range.lowerBound..<clampedEnd {
            guard searched.insert(i).inserted else { continue }
            let slice = Array(words[i..<min(i + window, words.count)])
            let score = fuzzyMatch(query: query, target: slice)
            if score > bestScore {
                bestScore = score
                bestIndex = i
            }
        }
    }

    private func fuzzyMatch(query: [String], target: [String]) -> Double {
        let maxLen = max(query.count, target.count)
        guard maxLen > 0 else { return 0 }
        return 1.0 - Double(levenshtein(query, target)) / Double(maxLen)
    }

    private func levenshtein(_ a: [String], _ b: [String]) -> Int {
        let n = a.count, m = b.count
        guard n > 0 else { return m }
        guard m > 0 else { return n }

        var prev = Array(0...m)
        var curr = Array(repeating: 0, count: m + 1)

        for i in 1...n {
            curr[0] = i
            for j in 1...m {
                curr[j] = min(
                    prev[j] + 1,
                    curr[j - 1] + 1,
                    prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                )
            }
            swap(&prev, &curr)
        }
        return prev[m]
    }
}
