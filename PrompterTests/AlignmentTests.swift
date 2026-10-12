//
//  AlignmentTests.swift
//  PrompterTests
//

import Foundation
import Testing
@testable import Prompter

private let english = Locale(identifier: "en_US")

private func substring(_ text: String, _ range: NSRange) -> String {
    (text as NSString).substring(with: range)
}

// MARK: - ScriptTokenizer

struct ScriptTokenizerTests {

    @Test func normalisesWordsAndKeepsApostrophesInside() {
        #expect(ScriptTokenizer.words("Don't STOP, now!", locale: english) == ["dont", "stop", "now"])
    }

    @Test func rangesPointBackAtTheOriginalText() {
        let text = "Hello, wonderful world."
        let tokens = ScriptTokenizer.tokenize(text, locale: english).tokens
        #expect(tokens.map { substring(text, $0.range) } == ["Hello", "wonderful", "world"])
    }

    @Test func rangesAreUTF16Offsets() {
        let text = "👋 hi there"
        let tokens = ScriptTokenizer.tokenize(text, locale: english).tokens
        #expect(tokens.first?.range == NSRange(location: 3, length: 2))
    }

    @Test func skipsStageDirections() {
        #expect(ScriptTokenizer.words("Hi [pause, smile] there", locale: english) == ["hi", "there"])
    }

    @Test func unclosedStageDirectionEndsAtTheLine() {
        #expect(ScriptTokenizer.words("Hi [pause\nthere", locale: english) == ["hi", "there"])
    }

    @Test func spellsOutNumbersSharingTheNumbersRange() {
        let text = "I have 42 cats"
        let tokens = ScriptTokenizer.tokenize(text, locale: english).tokens
        #expect(tokens.map(\.word) == ["i", "have", "forty", "two", "cats"])
        #expect(substring(text, tokens[2].range) == "42")
        #expect(tokens[2].range == tokens[3].range)
    }

    @Test func marksSentenceStarts() {
        let tokenized = ScriptTokenizer.tokenize("One two. Three\nFour five? Six", locale: english)
        #expect(tokenized.sentenceStarts == [0, 2, 3, 5])
    }
}

// MARK: - TranscriptAligner

struct TranscriptAlignerTests {

    private func aligner(_ script: String) async -> TranscriptAligner {
        let aligner = TranscriptAligner()
        await aligner.setLocale(english)
        await aligner.updateScript(script)
        return aligner
    }

    @Test func currentWordIsTheLastWordHeard() async throws {
        let script = "The quick brown fox jumps over the lazy dog."
        let result = try #require(await aligner(script).align(transcript: "the quick brown", isFinal: false))
        #expect(substring(script, result.currentWordRange) == "brown")
        #expect(result.readUpToOffset == NSMaxRange(result.currentWordRange))
        #expect(result.matchedText == "The quick brown")
    }

    @Test func followsTheSpeakerForward() async throws {
        let script = "The quick brown fox jumps over the lazy dog and runs into the forest."
        let a = await aligner(script)
        _ = await a.align(transcript: "the quick brown fox", isFinal: false)
        let result = try #require(await a.align(transcript: "the quick brown fox jumps over the lazy", isFinal: false))
        #expect(substring(script, result.currentWordRange) == "lazy")
    }

    @Test func toleratesMisheardWords() async throws {
        let script = "Thank you all for coming to the launch of our new product today."
        let result = try #require(await aligner(script).align(transcript: "for coming to the lunch of", isFinal: false))
        #expect(substring(script, result.currentWordRange) == "of")
    }

    @Test func matchesSpokenNumbersAgainstDigits() async throws {
        let script = "Last year we shipped 3 products to customers."
        let result = try #require(await aligner(script).align(transcript: "we shipped three products", isFinal: false))
        #expect(substring(script, result.currentWordRange) == "products")
    }

    @Test func stageDirectionsDontBreakTheMatch() async throws {
        let script = "Hello [pause] everyone, and welcome."
        let result = try #require(await aligner(script).align(transcript: "hello everyone and", isFinal: false))
        #expect(substring(script, result.currentWordRange) == "and")
    }

    @Test func ignoresUnrelatedSpeech() async {
        let script = "The quick brown fox jumps over the lazy dog."
        let result = await aligner(script).align(transcript: "completely different words here", isFinal: false)
        #expect(result == nil)
    }

    @Test func rejectsWeakBackwardJumps() async throws {
        let words = (1...40).map { "word\(Character(UnicodeScalar(96 + ($0 % 26))!))" }
        let script = "alpha beta gamma delta " + words.joined(separator: " ") + " omega sigma tau"
        let a = await aligner(script)
        _ = try #require(await a.align(transcript: "omega sigma tau", isFinal: false))
        // Weak match far behind the last position: ignored.
        let back = await a.align(transcript: "alpha zzz yyy", isFinal: false)
        #expect(back == nil)
    }

    @Test func emptyScriptNeverMatches() async {
        let result = await aligner("").align(transcript: "anything", isFinal: false)
        #expect(result == nil)
    }
}

// MARK: - TranscriptMerger

struct TranscriptMergerTests {

    @Test func firstFinalStartsTheTranscript() {
        #expect(TranscriptMerger.merge(accumulated: "", final: "hello there") == "hello there")
    }

    @Test func mergesOverlappingWords() {
        #expect(TranscriptMerger.merge(accumulated: "a b c", final: "b c d") == "a b c d")
    }

    @Test func overlapIgnoresCase() {
        #expect(TranscriptMerger.merge(accumulated: "Hello there", final: "there friend") == "Hello there friend")
    }

    @Test func repeatedFinalIsIgnored() {
        #expect(TranscriptMerger.merge(accumulated: "one two three", final: "two three") == "one two three")
    }

    @Test func suffixCheckIsWordLevel() {
        // "at" is a character suffix of "cat" but a new word.
        #expect(TranscriptMerger.merge(accumulated: "the cat", final: "at") == "the cat at")
    }

    @Test func transcriptIsCapped() {
        let long = (0..<(TranscriptMerger.maxWords + 50)).map { "w\($0)" }.joined(separator: " ")
        let merged = TranscriptMerger.merge(accumulated: long, final: "end")
        let words = merged.split(separator: " ")
        #expect(words.count == TranscriptMerger.maxWords)
        #expect(words.last == "end")
    }
}
