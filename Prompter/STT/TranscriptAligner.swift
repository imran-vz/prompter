//
//  TranscriptAligner.swift
//  Prompter
//

import Foundation

struct AlignmentResult: Equatable, Sendable {
    let progress: Double
    let confidence: Double
    let matchedText: String
    let wordStartIndex: Int
    let wordEndIndex: Int
    let readUpToOffset: Int
}

/// Fuzzy-matches a spoken transcript against a script to find the current
/// reading position. Runs as an `actor` so all work happens off the main thread.
actor TranscriptAligner {
    private var script: String = ""
    private var originalScript: String = ""
    private var words: [String] = []
    private var wordRanges: [Range<String.Index>] = []
    private var totalWords: Int = 1
    private var sentences: [[String]] = []
    private var sentenceStartIndices: [Int] = []

    private let partialWindowSize = 6
    private let finalWindowSize = 10

    private var lastMatchedIndex = 0
    private var sequence: UInt64 = 0

    func reset() {
        lastMatchedIndex = 0
        sequence = 0
    }

    func updateScript(_ newScript: String) {
        script = newScript
        originalScript = newScript
        let normalized = Self.normalize(newScript)
        words = normalized.components(separatedBy: " ")
        totalWords = max(1, words.count)
        lastMatchedIndex = 0
        sequence = 0

        // Build word → original-text range mapping
        var ranges: [Range<String.Index>] = []
        var cursor = newScript.startIndex
        for _ in words {
            while cursor < newScript.endIndex,
                  !CharacterSet.letters.contains(newScript[cursor].unicodeScalars.first!) {
                cursor = newScript.index(after: cursor)
            }
            let start = cursor
            while cursor < newScript.endIndex,
                  CharacterSet.letters.contains(newScript[cursor].unicodeScalars.first!) {
                cursor = newScript.index(after: cursor)
            }
            ranges.append(start..<cursor)
        }
        wordRanges = ranges

        // Sentence segmentation
        var sents: [[String]] = []
        var indices: [Int] = []
        var wordCursor = 0
        for sentence in newScript.components(separatedBy: CharacterSet(charactersIn: ".\n")) {
            let sentWords = Self.normalize(sentence).components(separatedBy: " ").filter { !$0.isEmpty }
            guard !sentWords.isEmpty else { continue }
            sents.append(sentWords)
            indices.append(wordCursor)
            wordCursor += sentWords.count
        }
        sentences = sents.isEmpty ? [words] : sents
        sentenceStartIndices = indices.isEmpty ? [0] : indices
    }

    /// Returns (result, sequenceNumber). Callers should discard stale results.
    func align(transcript: String, isFinal: Bool) -> (AlignmentResult?, UInt64) {
        sequence += 1
        let seq = sequence
        let result = doAlign(transcript: transcript, isFinal: isFinal)
        return (result, seq)
    }

    func isCurrent(_ seq: UInt64) -> Bool { seq == sequence }

    // MARK: - Core alignment

    private func doAlign(transcript: String, isFinal: Bool) -> AlignmentResult? {
        let transcriptWords = Self.normalize(transcript).components(separatedBy: " ")
        guard !transcriptWords.isEmpty, !words.isEmpty else { return nil }

        let windowSize = isFinal ? finalWindowSize : partialWindowSize
        let searchWindow = min(windowSize, transcriptWords.count)
        guard searchWindow > 0 else { return nil }

        let trailingTranscript = Array(transcriptWords.suffix(searchWindow))

        var bestScore: Double = 0
        var bestIndex: Int = 0
        var searched = Set<Int>()

        // 1. Search near last matched position
        let nearStart = max(0, lastMatchedIndex - searchWindow)
        let nearEnd = min(words.count, lastMatchedIndex + searchWindow * 3)
        searchRange(nearStart..<nearEnd, query: trailingTranscript, window: searchWindow,
                    searched: &searched, bestScore: &bestScore, bestIndex: &bestIndex)

        // 2. Search sentence boundaries
        if bestScore < 0.7 {
            for (si, startIdx) in sentenceStartIndices.enumerated() {
                let end = startIdx + sentences[si].count
                searchRange(startIdx..<end, query: trailingTranscript, window: searchWindow,
                            searched: &searched, bestScore: &bestScore, bestIndex: &bestIndex)
            }
        }

        // 3. Full scan fallback
        if bestScore < 0.5 {
            searchRange(0..<words.count, query: trailingTranscript, window: searchWindow,
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

        // Progress anchored to END of matched window
        let endIndex = min(bestIndex + searchWindow, totalWords - 1)
        let startRange = wordRanges[bestIndex]
        let endRange = wordRanges[endIndex]
        let matchedText = String(originalScript[startRange.lowerBound..<endRange.upperBound])

        let progress = Double(endIndex) / Double(totalWords)
        let readUpToOffset = endRange.upperBound.utf16Offset(in: originalScript)

        return AlignmentResult(
            progress: progress,
            confidence: bestScore,
            matchedText: matchedText,
            wordStartIndex: bestIndex,
            wordEndIndex: endIndex + 1,
            readUpToOffset: readUpToOffset
        )
    }

    private func searchRange(_ range: Range<Int>, query: [String], window: Int,
                             searched: inout Set<Int>,
                             bestScore: inout Double, bestIndex: inout Int) {
        let clampedEnd = min(range.upperBound, words.count)
        for i in range.lowerBound..<clampedEnd {
            guard !searched.contains(i) else { continue }
            searched.insert(i)
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

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
