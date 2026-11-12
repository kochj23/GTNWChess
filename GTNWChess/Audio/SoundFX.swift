//
//  SoundFX.swift
//  GTNW Chess
//
//  Original procedural sound effects, synthesised at launch (no samples): sine/saw oscillators with pitch sweeps,
//  filtered noise and ADSR-style envelopes, rendered into PCM buffers and played through an AVAudioEngine
//  player pool.
//

import AVFoundation
import Foundation

enum SFX: String, CaseIterable, Sendable {
    case select, move, capture, laser, cannon, boing, beam, orbital, gravity, shatter, crumble, pop, dissolve, powerDown
    case check, victory, defeat, draw, whoosh, click
}

enum Synth {
    static let sampleRate = 44_100.0

    /// Deterministic pseudo-noise (xorshift) so renders are reproducible and testable.
    struct Noise {
        var state: UInt32 = 0x9E37_79B9
        mutating func next() -> Float {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            return Float(state) / Float(UInt32.max) * 2 - 1
        }
    }

    /// Renders an effect to mono samples in -1...1.
    static func render(_ fx: SFX) -> [Float] {
        switch fx {
        case .select: return tone(0.06, f0: 880, f1: 1320, wave: .sine, attack: 0.002, release: 0.04, gain: 0.35)
        case .click: return tone(0.03, f0: 1600, f1: 1200, wave: .square, attack: 0.001, release: 0.02, gain: 0.15)
        case .move: return mix(tone(0.12, f0: 220, f1: 180, wave: .sine, attack: 0.003, release: 0.1, gain: 0.5),
                               noise(0.05, cutoff: 0.08, gain: 0.15))
        case .capture: return mix(tone(0.25, f0: 300, f1: 90, wave: .saw, attack: 0.002, release: 0.2, gain: 0.35),
                                  noise(0.2, cutoff: 0.3, gain: 0.3))
        case .laser: return tone(0.35, f0: 2400, f1: 300, wave: .square, attack: 0.001, release: 0.25, gain: 0.25)
        case .cannon: return mix(noise(0.6, cutoff: 0.05, gain: 0.9), tone(0.4, f0: 90, f1: 40, wave: .sine, attack: 0.001, release: 0.35, gain: 0.7))
        case .boing: return vibrato(0.5, f0: 180, f1: 520, depth: 0.25, rate: 18, gain: 0.4)
        case .beam: return mix(tone(0.7, f0: 660, f1: 700, wave: .saw, attack: 0.05, release: 0.3, gain: 0.18),
                               tone(0.7, f0: 990, f1: 1050, wave: .sine, attack: 0.05, release: 0.3, gain: 0.2))
        case .orbital: return chord(0.6, [523, 659, 784], wave: .sine, gain: 0.25, sweepUp: true)
        case .gravity: return tone(0.9, f0: 160, f1: 30, wave: .saw, attack: 0.2, release: 0.4, gain: 0.35)
        case .shatter: return mix(noise(0.5, cutoff: 0.9, gain: 0.35), chord(0.5, [2093, 2637, 3136], wave: .sine, gain: 0.1, sweepUp: false))
        case .crumble: return noise(0.9, cutoff: 0.04, gain: 0.8, wobble: 9)
        case .pop: return mix(tone(0.08, f0: 600, f1: 1400, wave: .sine, attack: 0.001, release: 0.06, gain: 0.5), noise(0.1, cutoff: 0.5, gain: 0.25))
        case .dissolve: return chord(1.0, [1046, 1318, 1567, 2093], wave: .sine, gain: 0.14, sweepUp: true)
        case .powerDown: return tone(0.9, f0: 440, f1: 55, wave: .saw, attack: 0.01, release: 0.6, gain: 0.3)
        case .check: return seq([tone(0.12, f0: 988, f1: 988, wave: .square, attack: 0.002, release: 0.05, gain: 0.2),
                                 tone(0.16, f0: 740, f1: 740, wave: .square, attack: 0.002, release: 0.1, gain: 0.2)])
        case .victory: return seq([chord(0.18, [523, 659], wave: .saw, gain: 0.18, sweepUp: false),
                                   chord(0.18, [659, 784], wave: .saw, gain: 0.18, sweepUp: false),
                                   chord(0.6, [784, 988, 1175], wave: .saw, gain: 0.18, sweepUp: false)])
        case .defeat: return seq([tone(0.3, f0: 392, f1: 370, wave: .saw, attack: 0.01, release: 0.2, gain: 0.25),
                                  tone(0.7, f0: 330, f1: 220, wave: .saw, attack: 0.01, release: 0.5, gain: 0.25)])
        case .draw: return chord(0.7, [440, 554], wave: .sine, gain: 0.2, sweepUp: false)
        case .whoosh: return noise(0.45, cutoff: 0.2, gain: 0.35, wobble: 2)
        }
    }

    enum Wave { case sine, saw, square }

    static func envelope(_ i: Int, _ n: Int, attack: Double, release: Double) -> Float {
        let t = Double(i) / sampleRate, total = Double(n) / sampleRate
        if t < attack { return Float(t / max(attack, 1e-6)) }
        let tail = total - t
        if tail < release { return Float(max(0, tail / max(release, 1e-6))) }
        return 1
    }

    static func tone(_ dur: Double, f0: Double, f1: Double, wave: Wave, attack: Double, release: Double, gain: Float) -> [Float] {
        let n = Int(dur * sampleRate)
        var out = [Float](repeating: 0, count: n)
        var phase = 0.0
        for i in 0..<n {
            let k = Double(i) / Double(max(n - 1, 1))
            let f = f0 * pow(f1 / f0, k)
            phase += f / sampleRate
            phase -= floor(phase)
            let v: Double
            switch wave {
            case .sine: v = sin(2 * .pi * phase)
            case .saw: v = 2 * phase - 1
            case .square: v = phase < 0.5 ? 1 : -1
            }
            out[i] = Float(v) * gain * envelope(i, n, attack: attack, release: release)
        }
        return out
    }

    static func vibrato(_ dur: Double, f0: Double, f1: Double, depth: Double, rate: Double, gain: Float) -> [Float] {
        let n = Int(dur * sampleRate)
        var out = [Float](repeating: 0, count: n)
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / sampleRate, k = Double(i) / Double(n)
            let f = (f0 + (f1 - f0) * k) * (1 + depth * sin(2 * .pi * rate * t) * (1 - k))
            phase += f / sampleRate
            out[i] = Float(sin(2 * .pi * phase)) * gain * envelope(i, n, attack: 0.005, release: 0.2)
        }
        return out
    }

    static func noise(_ dur: Double, cutoff: Double, gain: Float, wobble: Double = 0) -> [Float] {
        let n = Int(dur * sampleRate)
        var out = [Float](repeating: 0, count: n)
        var rng = Noise()
        var lp: Float = 0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let c = Float(min(1, max(0.005, cutoff * (wobble > 0 ? 0.6 + 0.4 * sin(2 * .pi * wobble * t) : 1))))
            lp += c * (rng.next() - lp)
            let decay = Float(exp(-3 * Double(i) / Double(n)))
            out[i] = lp * gain * decay * envelope(i, n, attack: 0.002, release: 0.05) * 2
        }
        return out
    }

    static func chord(_ dur: Double, _ freqs: [Double], wave: Wave, gain: Float, sweepUp: Bool) -> [Float] {
        freqs.map { tone(dur, f0: $0, f1: sweepUp ? $0 * 1.5 : $0, wave: wave, attack: 0.01, release: dur * 0.6, gain: gain) }
            .reduce([Float](repeating: 0, count: Int(dur * sampleRate))) { mix($0, $1) }
    }

    static func mix(_ a: [Float], _ b: [Float]) -> [Float] {
        let n = max(a.count, b.count)
        return (0..<n).map { i in
            let v = (i < a.count ? a[i] : 0) + (i < b.count ? b[i] : 0)
            return max(-1, min(1, v))
        }
    }

    static func seq(_ parts: [[Float]]) -> [Float] { parts.flatMap { $0 } }
}

/// Plays the effects. Muted under XCTest and when sound is off; never throws into the game.
@MainActor
final class SoundPlayer {
    static let shared = SoundPlayer()

    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var buffers: [SFX: AVAudioPCMBuffer] = [:]
    private var next = 0
    private var started = false
    var enabled = true
    var volume: Float = 0.8 { didSet { engine.mainMixerNode.outputVolume = volume } }

    private init() {}

    private func setUp() {
        guard !started, !RuntimeEnv.underXCTest else { return }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Synth.sampleRate, channels: 1) else { return }
        for _ in 0..<8 {
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: format)
            players.append(p)
        }
        for fx in SFX.allCases {
            let samples = Synth.render(fx)
            guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { continue }
            b.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { src in b.floatChannelData![0].update(from: src.baseAddress!, count: samples.count) }
            buffers[fx] = b
        }
        engine.mainMixerNode.outputVolume = volume
        do { try engine.start(); started = true } catch { started = false }
    }

    func play(_ fx: SFX) {
        guard enabled else { return }
        setUp()
        guard started, let b = buffers[fx], !players.isEmpty else { return }
        let p = players[next % players.count]
        next += 1
        p.stop()
        p.scheduleBuffer(b, at: nil, options: [], completionHandler: nil)
        p.play()
    }
}
