//
//  STTController.swift
//  Prompter
//
//  Orchestrates speech-to-text and alignment.
//  Alignment runs on a background actor; only UI updates touch main thread.
//

import Foundation
import Combine

@MainActor
final class STTController: ObservableObject {
    @Published var isRunning = false
    @Published var lastTranscript = ""
    @Published var lastAlignment: AlignmentResult?
    /// Current VAD state — updated as the engine emits transition events.
    @Published var vadState: VADState = .silence

    /// Called on main thread when alignment completes. Set by ViewModel.
    var onAlignment: ((AlignmentResult) -> Void)?

    /// Called on main thread when a turn ends (speech → silence after hangover).
    /// Receives the committed transcript text — mirrors Pindrop's `endOfUtteranceCallback`.
    var onEndOfUtterance: ((String) -> Void)?

    private var engine: STTEngine
    private let aligner = TranscriptAligner()
    private var transcriptionTask: Task<Void, Never>?

    private var accumulatedTranscript = ""
    private var currentScript = ""

    // MARK: - Init

    init(script: String = "", engine: STTEngine? = nil) {
        self.engine = engine ?? AppleSpeechEngine()
        Task { await aligner.updateScript(script) }
        self.engine.setContextualStrings(from: script)
    }

    // MARK: - Public

    func updateScript(_ script: String) {
        currentScript = script
        Task { await aligner.updateScript(script) }
        engine.setContextualStrings(from: script)
    }

    func setEngine(_ newEngine: STTEngine) {
        let script = currentScript
        if isRunning {
            Task {
                await stop()
                engine = newEngine
                engine.setContextualStrings(from: script)
                await start()
            }
        } else {
            engine = newEngine
            engine.setContextualStrings(from: script)
        }
    }

    func start() async {
        guard !isRunning else { return }
        accumulatedTranscript = ""
        vadState = .silence
        do {
            try await engine.prepare()
            let stream = engine.makeTranscriptionStream()
            try await engine.start()
            isRunning = true
            listen(to: stream)
        } catch {
            // Errors are non-fatal; STT simply won't run
        }
    }

    func stop() async {
        guard isRunning else { return }
        await engine.stop()
        transcriptionTask?.cancel()
        transcriptionTask = nil
        isRunning = false
    }

    func resetAlignment() {
        accumulatedTranscript = ""
        lastTranscript = ""
        lastAlignment = nil
        Task { await aligner.reset() }
    }

    // MARK: - Private

    private func listen(to stream: AsyncStream<TranscriptionChunk>) {
        transcriptionTask?.cancel()
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            for await chunk in stream {
                guard !Task.isCancelled else { return }
                self.process(chunk)
            }
        }
    }

    private func process(_ chunk: TranscriptionChunk) {
        // VAD-only event (guard isFinal: Apple Speech emits text:"" on error, not a VAD event)
        if chunk.text.isEmpty && !chunk.isFinal {
            handleVADTransition(to: chunk.vadState)
            return
        }

        guard vadState != .silence else { return }

        lastTranscript = chunk.text

        let textToAlign: String
        let isFinal = chunk.isFinal

        if isFinal {
            accumulatedTranscript = merge(accumulated: accumulatedTranscript, final: chunk.text)
            textToAlign = accumulatedTranscript
        } else {
            guard !chunk.text.split(whereSeparator: \.isWhitespace).isEmpty else { return }
            textToAlign = chunk.text
        }

        Task.detached(priority: .high) { [weak self] in
            guard let self else { return }
            let (result, seq) = await self.aligner.align(transcript: textToAlign, isFinal: isFinal)

            guard let result,
                  result.confidence >= (isFinal ? 0.25 : 0.30),
                  await self.aligner.isCurrent(seq) else { return }

            await MainActor.run {
                self.lastAlignment = result
                self.onAlignment?(result)
            }
        }
    }

    // MARK: - VAD / Turn Detection

    private func handleVADTransition(to newState: VADState) {
        let previous = vadState
        vadState = newState
        #if DEBUG
        print("[STTController] VAD: \(previous) → \(newState)")
        #endif

        // Turn ended: speech (or trailing edge) transitioned to confirmed silence
        if previous != .silence && newState == .silence {
            commitTurnEnd()
        }
    }

    /// Fire a final alignment with the accumulated transcript and notify the ViewModel
    /// that the teleprompter position should be locked until speech resumes.
    private func commitTurnEnd() {
        let transcript = accumulatedTranscript
        guard !transcript.isEmpty else { return }

        // Notify immediately — position freeze must not depend on alignment succeeding,
        // since in-flight alignment tasks may have already incremented the sequence counter.
        onEndOfUtterance?(transcript)

        Task.detached(priority: .high) { [weak self] in
            guard let self else { return }
            let (result, seq) = await self.aligner.align(transcript: transcript, isFinal: true)

            guard let result,
                  result.confidence >= 0.25,
                  await self.aligner.isCurrent(seq) else { return }

            await MainActor.run {
                self.lastAlignment = result
                self.onAlignment?(result)
            }
        }
    }

    // MARK: - Transcript Merging

    private func merge(accumulated: String, final: String) -> String {
        let a = accumulated.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let f = final.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if a.hasSuffix(f) { return accumulated }

        let wa = a.split(whereSeparator: \.isWhitespace).map(String.init)
        let wf = f.split(whereSeparator: \.isWhitespace).map(String.init)

        var overlap = 0
        for n in 1...min(wa.count, wf.count) {
            if Array(wa.suffix(n)) == Array(wf.prefix(n)) { overlap = n }
        }
        if overlap > 0 {
            let kept = wa.dropLast(overlap).joined(separator: " ")
            return kept.isEmpty ? final : kept + " " + final
        }
        return accumulated.isEmpty ? final : accumulated + " " + final
    }
}
