//
//  STTController.swift
//  Prompter
//
//  Supervises the speech-to-text pipeline:
//
//      AudioCaptureService ──► STT engine ──► transcription chunks ─┐
//              │                                                    ├─► alignment ─► UI
//              └────────────► VAD (in-order, adaptive) ─────────────┘
//
//  Stability principles:
//  - One supervisor task owns the whole chain. If any link dies (recognition
//    stream ends, capture fails), the chain is torn down and restarted with
//    backoff. The pipeline can only be "off" if the user turned it off or
//    permissions are denied.
//  - VAD is advisory: it gates scrolling and detects end-of-turn, but can never
//    drop a transcript. Words coming out of the recognizer count as speech.
//  - Alignment runs through a single coalescing worker: always aligns the
//    newest transcript, delivers results to the main thread strictly in order.
//

import Foundation
import Combine

@MainActor
final class STTController: ObservableObject {

    enum PipelineStatus: Equatable {
        case idle
        case starting
        case listening
        case restarting
        case failed(String)
    }

    // MARK: - Published State

    @Published private(set) var status: PipelineStatus = .idle
    @Published private(set) var lastTranscript = ""
    @Published private(set) var lastAlignment: AlignmentResult?
    @Published private(set) var vadState: VADState = .silence

    var isRunning: Bool { runTask != nil }

    /// Called on main thread when alignment completes. Set by ViewModel.
    var onAlignment: ((AlignmentResult) -> Void)?

    /// Called on main thread when a turn ends (speech → silence after hangover).
    /// Receives the committed transcript text.
    var onEndOfUtterance: ((String) -> Void)?

    // MARK: - Pipeline Components

    private var engine: STTEngine
    private let capture = AudioCaptureService()
    private let aligner = TranscriptAligner()
    private var vad = VADDetector()

    private var runTask: Task<Void, Never>?
    /// Bumped on every stop/engine-swap; stale supervisor loops see a mismatch
    /// and exit instead of fighting the new one for the capture service.
    private var generation = 0

    private var accumulatedTranscript = ""
    private var currentScript = ""

    // Alignment coalescing (all MainActor; the align itself runs on the actor)
    private var pendingAlignment: (text: String, isFinal: Bool)?
    private var alignmentWorker: Task<Void, Never>?

    // MARK: - Init

    init(script: String = "", engine: STTEngine? = nil) {
        self.engine = engine ?? AppleSpeechEngine()
        self.currentScript = script
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
        let wasRunning = isRunning
        stop()
        engine = newEngine
        engine.setContextualStrings(from: currentScript)
        if wasRunning { start() }
    }

    func start() {
        guard runTask == nil else { return }
        generation += 1
        let gen = generation
        status = .starting
        accumulatedTranscript = ""
        vad.reset()
        vadState = .silence
        runTask = Task { await self.supervise(generation: gen) }
    }

    func stop() {
        generation += 1
        runTask?.cancel()
        runTask = nil
        capture.stop()
        status = .idle
        vadState = .silence
    }

    func resetAlignment() {
        accumulatedTranscript = ""
        lastTranscript = ""
        lastAlignment = nil
        pendingAlignment = nil
        Task { await aligner.reset() }
    }

    // MARK: - Supervisor

    private func supervise(generation gen: Int) async {
        var backoff: TimeInterval = 0.5
        let engine = self.engine

        while gen == generation, !Task.isCancelled {
            do {
                try await engine.prepare()
                guard gen == generation, !Task.isCancelled else { break }

                // Subscribe before starting capture so no chunk is missed.
                let engineAudio = capture.subscribe()
                let vadAudio = capture.subscribe()
                let transcripts = try await engine.start(audio: engineAudio)
                guard gen == generation, !Task.isCancelled else {
                    await engine.stop()
                    break
                }
                try capture.start()
                status = .listening
                backoff = 0.5

                // Run both consumers; if either finishes, the chain is broken —
                // tear down and let the outer loop restart it.
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { [weak self] in
                        for await event in vadAudio {
                            guard let self, !Task.isCancelled else { return }
                            if case .chunk(let chunk) = event {
                                await self.processVAD(rms: chunk.rms)
                            }
                        }
                    }
                    group.addTask { [weak self] in
                        for await chunk in transcripts {
                            guard let self, !Task.isCancelled else { return }
                            await self.processTranscript(chunk)
                        }
                    }
                    await group.next()
                    group.cancelAll()
                }
                await engine.stop()
            } catch let error as STTError where error.isFatal {
                await engine.stop()
                if gen == generation { status = .failed(Self.describe(error)) }
                return
            } catch {
                await engine.stop()
            }

            if gen == generation { capture.stop() }
            guard gen == generation, !Task.isCancelled else { break }

            status = .restarting
            print("[STTController] Pipeline ended — restarting in \(backoff)s")
            try? await Task.sleep(for: .seconds(backoff))
            backoff = min(backoff * 2, 5)
        }
    }

    private static func describe(_ error: STTError) -> String {
        switch error {
        case .noMicrophoneAccess: return "Microphone access denied"
        case .notAuthorized: return "Speech recognition not authorized"
        case .engineNotAvailable: return "Speech engine unavailable"
        default: return "Speech recognition failed"
        }
    }

    // MARK: - VAD

    private func processVAD(rms: Float) {
        let now = Date().timeIntervalSinceReferenceDate
        let (newState, changed) = vad.process(rms: rms, now: now)
        if changed { applyVADTransition(to: newState) }
    }

    private func applyVADTransition(to newState: VADState) {
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

    /// Ask the engine to commit the current utterance, lock the teleprompter
    /// position, and fire a final alignment with the accumulated transcript.
    private func commitTurnEnd() {
        engine.finishUtterance()

        let transcript = accumulatedTranscript
        guard !transcript.isEmpty else { return }
        onEndOfUtterance?(transcript)
        scheduleAlignment(text: transcript, isFinal: true)
    }

    // MARK: - Transcripts

    private func processTranscript(_ chunk: TranscriptionChunk) {
        let text = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        lastTranscript = text

        // Words arriving from the recognizer outrank energy thresholds:
        // never let a miscalibrated VAD freeze the prompter mid-read.
        let now = Date().timeIntervalSinceReferenceDate
        let (newState, changed) = vad.noteSpeechEvidence(now: now)
        if changed { applyVADTransition(to: newState) }

        if chunk.isFinal {
            accumulatedTranscript = merge(accumulated: accumulatedTranscript, final: text)
            scheduleAlignment(text: accumulatedTranscript, isFinal: true)
        } else {
            scheduleAlignment(text: text, isFinal: false)
        }
    }

    // MARK: - Alignment (coalescing worker)

    /// Latest-wins scheduling: if alignments queue up faster than they run,
    /// intermediate transcripts are skipped — the newest one is always aligned,
    /// and results reach the UI strictly in order.
    private func scheduleAlignment(text: String, isFinal: Bool) {
        pendingAlignment = (text, isFinal)
        guard alignmentWorker == nil else { return }

        alignmentWorker = Task { [weak self] in
            while let self, let job = self.takePendingAlignment() {
                let result = await self.aligner.align(transcript: job.text, isFinal: job.isFinal)
                guard let result,
                      result.confidence >= (job.isFinal ? 0.25 : 0.30) else { continue }
                self.lastAlignment = result
                self.onAlignment?(result)
            }
            self?.alignmentWorker = nil
        }
    }

    private func takePendingAlignment() -> (text: String, isFinal: Bool)? {
        defer { pendingAlignment = nil }
        return pendingAlignment
    }

    // MARK: - Transcript Merging

    private func merge(accumulated: String, final: String) -> String {
        let a = accumulated.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let f = final.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if a.hasSuffix(f) { return accumulated }

        let wa = a.split(whereSeparator: \.isWhitespace).map(String.init)
        let wf = f.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !wa.isEmpty, !wf.isEmpty else {
            return accumulated.isEmpty ? final : accumulated
        }

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
