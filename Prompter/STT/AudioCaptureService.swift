//
//  AudioCaptureService.swift
//  Prompter
//
//  Sole owner of the microphone. Captures audio on the real-time audio thread,
//  deep-copies each buffer, and broadcasts ordered chunks to any number of
//  subscribers (STT engines, VAD). Survives audio device / format changes by
//  reinstalling the tap and notifying subscribers.
//
//  Threading model:
//  - The tap callback (real-time audio thread) does the minimum: deep-copy,
//    RMS, yield. AsyncStream.yield is thread-safe and non-blocking.
//  - All control-plane work (start/stop/config changes) is serialized on a
//    dedicated dispatch queue so state transitions can never interleave.
//

import AVFoundation
import Foundation

/// A single captured audio chunk. The PCM buffer is a private deep copy made on
/// the audio thread and never mutated afterwards, so it is safe to send across
/// threads despite AVAudioPCMBuffer not being Sendable.
nonisolated struct AudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    /// RMS energy of the chunk (0 when muted).
    let rms: Float
}

nonisolated enum AudioCaptureEvent: @unchecked Sendable {
    case chunk(AudioChunk)
    /// The audio hardware configuration changed (device swap, sample-rate
    /// change). Capture restarts automatically; buffer formats may differ from
    /// this point on, so engines should rebuild converters / recognition
    /// requests.
    case formatChanged
}

nonisolated final class AudioCaptureService: @unchecked Sendable {

    private let engine = AVAudioEngine()
    private let controlQueue = DispatchQueue(label: "prompter.audio.capture.control")

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<AudioCaptureEvent>.Continuation] = [:]
    private var isCapturing = false
    private var configChangeObserver: NSObjectProtocol?

    // MARK: - Subscriptions

    /// Create an ordered stream of capture events. The stream finishes when the
    /// service stops. Buffering is bounded: if a consumer stalls, the oldest
    /// chunks are dropped rather than growing memory without bound.
    func subscribe() -> AsyncStream<AudioCaptureEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            self.lock.lock()
            self.continuations[id] = continuation
            self.lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
        }
    }

    private func broadcast(_ event: AudioCaptureEvent) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets {
            continuation.yield(event)
        }
    }

    // MARK: - Lifecycle

    /// Start (or restart) capturing. Idempotent: an already-running engine is
    /// torn down first so a stale tap can never linger.
    func start() throws {
        try controlQueue.sync {
            teardownEngineLocked()
            try installTapAndStartLocked()
            lock.lock()
            isCapturing = true
            lock.unlock()

            if configChangeObserver == nil {
                configChangeObserver = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange,
                    object: engine,
                    queue: nil
                ) { [weak self] _ in
                    self?.handleConfigurationChange()
                }
            }
        }
    }

    /// Stop capturing and finish all subscriber streams.
    func stop() {
        controlQueue.sync {
            lock.lock()
            isCapturing = false
            let targets = Array(continuations.values)
            continuations.removeAll()
            lock.unlock()

            teardownEngineLocked()
            if let observer = configChangeObserver {
                NotificationCenter.default.removeObserver(observer)
                configChangeObserver = nil
            }
            for continuation in targets {
                continuation.finish()
            }
        }
    }

    // MARK: - Engine plumbing (controlQueue only)

    private func teardownEngineLocked() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
    }

    private func installTapAndStartLocked() throws {
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw STTError.engineNotAvailable
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let muted = MicState.shared.isMuted
            guard let copy = Self.copyBuffer(buffer, silenced: muted) else { return }
            let rms: Float
            if muted {
                rms = 0
            } else if let data = buffer.floatChannelData?[0] {
                rms = audioRMS(data, count: Int(buffer.frameLength))
            } else {
                rms = 0
            }
            self.broadcast(.chunk(AudioChunk(buffer: copy, rms: rms)))
        }

        engine.prepare()
        try engine.start()
    }

    /// Audio hardware changed underneath us. Reinstall the tap with the new
    /// format and keep going; retry with a delay if the device isn't ready yet.
    private func handleConfigurationChange() {
        controlQueue.async { [weak self] in
            self?.restartAfterConfigChange(attempt: 0)
        }
    }

    private func restartAfterConfigChange(attempt: Int) {
        lock.lock()
        let capturing = isCapturing
        lock.unlock()
        guard capturing else { return }

        teardownEngineLocked()
        do {
            try installTapAndStartLocked()
            broadcast(.formatChanged)
            print("[AudioCaptureService] Recovered from audio configuration change")
        } catch {
            guard attempt < 10 else {
                print("[AudioCaptureService] Failed to recover from configuration change: \(error)")
                return
            }
            controlQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.restartAfterConfigChange(attempt: attempt + 1)
            }
        }
    }

    // MARK: - Buffer copy

    /// Deep-copy a PCM buffer (or produce a zeroed one of identical shape when
    /// muted, so downstream timing is unaffected).
    private static func copyBuffer(_ buffer: AVAudioPCMBuffer, silenced: Bool) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)

        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<channels {
                if silenced {
                    dst[ch].update(repeating: 0, count: frames)
                } else {
                    dst[ch].update(from: src[ch], count: frames)
                }
            }
        } else if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            for ch in 0..<channels {
                if silenced {
                    dst[ch].update(repeating: 0, count: frames)
                } else {
                    dst[ch].update(from: src[ch], count: frames)
                }
            }
        } else {
            return nil
        }
        return copy
    }
}
