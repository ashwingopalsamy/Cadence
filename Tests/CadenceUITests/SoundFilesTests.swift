import AVFoundation
import Foundation
import Testing

/// The six shipped CAF files, read back through Apple's own decoder and measured with a BS.1770 style meter written
/// here on purpose, apart from the one in tools/make_sounds.swift, so the two have to agree
/// (docs/SPEC.md section 5.6).
@Suite struct SoundFilesTests {
    static let names = ["day.start", "capture.saved", "plan.committed", "ring.closed", "streak.milestone", "agent.logged"]
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources/Sounds", isDirectory: true)

    struct Clip {
        var samples: [Double]
        var sampleRate: Double
        var channels: Int
        var seconds: Double { Double(samples.count) / sampleRate }
        var peak: Double { samples.reduce(0) { max($0, abs($1)) } }
    }

    static func read(_ name: String) throws -> Clip {
        let file = try AVAudioFile(forReading: directory.appendingPathComponent("\(name).caf"))
        let frames = AVAudioFrameCount(file.length)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        try file.read(into: buffer)
        let data = try #require(buffer.floatChannelData)
        let samples = (0..<Int(buffer.frameLength)).map { Double(data[0][$0]) }
        return Clip(samples: samples, sampleRate: file.fileFormat.sampleRate, channels: Int(file.fileFormat.channelCount))
    }

    // MARK: A BS.1770 meter, for one channel

    struct Biquad {
        var b: (Double, Double, Double)
        var a: (Double, Double)

        func run(_ x: [Double]) -> [Double] {
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            var out = [Double]()
            out.reserveCapacity(x.count)
            for v in x {
                let y = b.0 * v + b.1 * x1 + b.2 * x2 - a.0 * y1 - a.1 * y2
                out.append(y)
                x2 = x1; x1 = v; y2 = y1; y1 = y
            }
            return out
        }
    }

    /// The two stages of K weighting at any sample rate: a high shelf near 1.7 kHz, then a 38 Hz high pass.
    static func kStages(rate: Double) -> [Biquad] {
        var K = tan(Double.pi * 1681.974450955533 / rate)
        let Q1 = 0.7071752369554196
        let Vh = pow(10.0, 3.999843853973347 / 20)
        let Vb = pow(Vh, 0.4996667741545416)
        var a0 = 1 + K / Q1 + K * K
        let shelf = Biquad(
            b: ((Vh + Vb * K / Q1 + K * K) / a0, 2 * (K * K - Vh) / a0, (Vh - Vb * K / Q1 + K * K) / a0),
            a: (2 * (K * K - 1) / a0, (1 - K / Q1 + K * K) / a0))
        K = tan(Double.pi * 38.13547087602444 / rate)
        let Q2 = 0.5003270373238773
        a0 = 1 + K / Q2 + K * K
        let highPass = Biquad(b: (1, -2, 1), a: (2 * (K * K - 1) / a0, (1 - K / Q2 + K * K) / a0))
        return [shelf, highPass]
    }

    /// Loudness of the 400 ms block that starts with the file: BS.1770 blocks are 400 ms, a shorter file is padded
    /// with silence, and anything after 400 ms is more than 30 dB down for these decays.
    static func lufs(_ clip: Clip) -> Double {
        let block = Int(0.4 * clip.sampleRate)
        var x = Array(clip.samples.prefix(block))
        x += [Double](repeating: 0, count: block - x.count)
        for stage in kStages(rate: clip.sampleRate) { x = stage.run(x) }
        let meanSquare = x.reduce(0) { $0 + $1 * $1 } / Double(block)
        return -0.691 + 10 * log10(meanSquare)
    }

    // MARK: Tests

    @Test func theKWeightingMatchesTheStandardsCoefficientsAt48kHz() {
        let stages = Self.kStages(rate: 48_000)
        #expect(abs(stages[0].b.0 - 1.53512485958697) < 1e-9)
        #expect(abs(stages[0].b.1 - -2.69169618940638) < 1e-9)
        #expect(abs(stages[0].b.2 - 1.19839281085285) < 1e-9)
        #expect(abs(stages[0].a.0 - -1.69065929318241) < 1e-9)
        #expect(abs(stages[0].a.1 - 0.73248077421585) < 1e-9)
        #expect(abs(stages[1].a.0 - -1.99004745483398) < 1e-9)
        #expect(abs(stages[1].a.1 - 0.99007225036621) < 1e-9)
    }

    @Test func aFullScale997HzToneReadsMinus3Point01LUFS() {
        // BS.1770 defines its offset so that this tone reads -3.01 LUFS.
        let rate = 44_100.0
        let tone = (0..<Int(rate)).map { sin(2 * Double.pi * 997 * Double($0) / rate) }
        #expect(abs(Self.lufs(Clip(samples: tone, sampleRate: rate, channels: 1)) - -3.01) < 0.1)
    }

    @Test func sixFilesShipAsMono44100UnderSevenHundredMilliseconds() throws {
        for name in Self.names {
            let clip = try Self.read(name)
            #expect(clip.channels == 1, "\(name)")
            #expect(clip.sampleRate == 44_100, "\(name)")
            #expect(clip.seconds > 0.1 && clip.seconds < 0.7, "\(name) lasts \(clip.seconds) s")
        }
    }

    @Test func theLengthsFollowTheNoteTable() throws {
        // The last note ends at start plus length; ring.closed would reach 700 ms and is cut to stay under it.
        let milliseconds = ["day.start": 320, "capture.saved": 280, "plan.committed": 500, "ring.closed": 699,
                            "streak.milestone": 620, "agent.logged": 120]
        for (name, ms) in milliseconds {
            let clip = try Self.read(name)
            #expect(abs(clip.seconds * 1000 - Double(ms)) < 1.0, "\(name) lasts \(clip.seconds * 1000) ms")
        }
    }

    @Test func eachFileIsNormalisedNearMinus18LUFS() throws {
        for name in Self.names {
            let level = Self.lufs(try Self.read(name))
            #expect(abs(level - -18) < 0.5, "\(name) reads \(level) LUFS")
        }
    }

    @Test func noFileClips() throws {
        for name in Self.names {
            let clip = try Self.read(name)
            #expect(clip.peak < 0.9, "\(name) peaks at \(clip.peak)")
            #expect(clip.peak > 0.1, "\(name) is nearly silent")
        }
    }

    @Test func theEnvelopeRisesOverTwelveMillisecondsThenDecaysToSilence() throws {
        let clip = try Self.read("day.start")
        #expect(abs(clip.samples[0]) < 0.001)
        let rate = clip.sampleRate
        let loudest = clip.samples.indices.max { abs(clip.samples[$0]) < abs(clip.samples[$1]) } ?? 0
        let atMs = Double(loudest) / rate * 1000
        #expect(atMs > 8 && atMs < 16, "the loudest sample is at \(atMs) ms")
        // The last millisecond sits at the prototype's 0.0001 floor, far below 1% of the peak.
        let tail = clip.samples.suffix(Int(rate / 1000))
        #expect(tail.allSatisfy { abs($0) < clip.peak * 0.01 })
    }
}
