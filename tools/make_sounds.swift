// Renders the six Cadence sounds to 44.1 kHz mono CAF files (docs/SPEC.md section 5.6).
//
//   swift tools/make_sounds.swift [output folder]      default: App/Resources/Sounds, or run `make sounds`
//
// No packages and no audio framework: the samples are computed here and the CAF file is written byte by byte, so
// two runs give byte for byte the same files and the sounds are clearly ours.
//
// The notes are the table in docs/SPEC.md section 5.6, in D major pentatonic. Every note is a sine with the
// envelope of the design prototype (design/coach/language.js, playSound): gain 0, a linear rise to 0.1 over 12 ms,
// then an exponential decay to 0.0001 at the note's length. The prototype stops each oscillator 20 ms after the
// decay ends, at 0.0001 (-80 dBFS); here the sound ends where the last decay ends.
//
// Each file is scaled to -18 LUFS (see `loudness`) unless that would put its peak above -1 dBFS. A file never
// reaches 700 ms: the ring.closed chord decays until exactly 700 ms, so every sound is cut at 699 ms, where its
// gain is still 0.000101, a step far below the 16-bit noise floor.
//
// Samples are 16-bit little-endian integers, rounded, with no dither.

import Foundation

// MARK: The sounds

struct Note {
    let hz: Double
    let startMs: Int
    let lengthMs: Int
}

struct Sound {
    let name: String
    let notes: [Note]
}

let sounds: [Sound] = [
    Sound(name: "day.start", notes: [Note(hz: 587.33, startMs: 0, lengthMs: 320)]),
    Sound(name: "capture.saved", notes: [
        Note(hz: 880, startMs: 0, lengthMs: 160),
        Note(hz: 1174.66, startMs: 60, lengthMs: 220),
    ]),
    Sound(name: "plan.committed", notes: [
        Note(hz: 587.33, startMs: 0, lengthMs: 300),
        Note(hz: 739.99, startMs: 70, lengthMs: 300),
        Note(hz: 880, startMs: 140, lengthMs: 360),
    ]),
    Sound(name: "ring.closed", notes: [
        Note(hz: 587.33, startMs: 0, lengthMs: 700),
        Note(hz: 739.99, startMs: 0, lengthMs: 700),
        Note(hz: 880, startMs: 0, lengthMs: 700),
        Note(hz: 1174.66, startMs: 90, lengthMs: 600),
    ]),
    Sound(name: "streak.milestone", notes: [
        Note(hz: 587.33, startMs: 0, lengthMs: 300),
        Note(hz: 659.25, startMs: 55, lengthMs: 300),
        Note(hz: 739.99, startMs: 110, lengthMs: 300),
        Note(hz: 880, startMs: 165, lengthMs: 300),
        Note(hz: 1174.66, startMs: 220, lengthMs: 400),
    ]),
    Sound(name: "agent.logged", notes: [Note(hz: 1318.51, startMs: 0, lengthMs: 120)]),
]

// MARK: Rendering

let sampleRate = 44_100
let maxFrames = 699 * sampleRate / 1000  // 30,825 frames, 698.98 ms: under 700 ms
let notePeak = 0.1
let noteFloor = 0.0001
let attack = 0.012
let targetLUFS = -18.0
let ceiling = pow(10.0, -1.0 / 20)  // -1 dBFS

/// The prototype's gain at `t` seconds into a note of `length` seconds.
func gain(at t: Double, length: Double) -> Double {
    if t < attack { return notePeak * t / attack }
    return notePeak * pow(noteFloor / notePeak, (t - attack) / (length - attack))
}

/// The unscaled mix, one value per frame.
func render(_ sound: Sound) -> [Double] {
    let end = sound.notes.map { $0.startMs + $0.lengthMs }.max() ?? 0
    let frames = min(end * sampleRate / 1000, maxFrames)
    var out = [Double](repeating: 0, count: frames)
    for note in sound.notes {
        let start = Double(note.startMs) / 1000
        let length = Double(note.lengthMs) / 1000
        for n in 0..<frames {
            let t = Double(n) / Double(sampleRate) - start
            if t < 0 || t >= length { continue }
            out[n] += sin(2 * Double.pi * note.hz * t) * gain(at: t, length: length)
        }
    }
    return out
}

// MARK: Loudness

/// An approximation of integrated loudness (ITU-R BS.1770, mono) that fits files shorter than one gating block.
///
/// What it does: K weighting (the standard's high shelf and 38 Hz high pass, derived for 44.1 kHz), then the mean
/// square over one 400 ms block that starts with the file, padded with silence when the file is shorter, then
/// -0.691 + 10 log10. What it leaves out: block overlap and gating, which need a signal of several blocks. Every
/// sound has all its energy in the first 400 ms (what follows is more than 30 dB down), so the single block holds
/// the whole sound. A full-scale 997 Hz sine reads -3.01 with this meter, as the standard defines.
func loudness(_ samples: [Double]) -> Double {
    let block = sampleRate * 4 / 10
    var x = Array(samples.prefix(block))
    x += [Double](repeating: 0, count: block - x.count)
    for stage in kWeighting(rate: Double(sampleRate)) { x = stage.run(x) }
    let meanSquare = x.reduce(0) { $0 + $1 * $1 } / Double(block)
    return -0.691 + 10 * log10(meanSquare)
}

struct Biquad {
    let b0: Double, b1: Double, b2: Double
    let a1: Double, a2: Double

    func run(_ input: [Double]) -> [Double] {
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        var out = [Double]()
        out.reserveCapacity(input.count)
        for x in input {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            out.append(y)
            x2 = x1; x1 = x
            y2 = y1; y1 = y
        }
        return out
    }
}

func kWeighting(rate: Double) -> [Biquad] {
    // Stage 1, the head-related high shelf. At 48 kHz these formulas give the standard's published coefficients.
    var k = tan(Double.pi * 1681.974450955533 / rate)
    let q1 = 0.7071752369554196
    let vh = pow(10.0, 3.999843853973347 / 20)
    let vb = pow(vh, 0.4996667741545416)
    var a0 = 1 + k / q1 + k * k
    let shelf = Biquad(
        b0: (vh + vb * k / q1 + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q1 + k * k) / a0,
        a1: 2 * (k * k - 1) / a0, a2: (1 - k / q1 + k * k) / a0)
    // Stage 2, the revised low-frequency B-curve: a 38 Hz high pass.
    k = tan(Double.pi * 38.13547087602444 / rate)
    let q2 = 0.5003270373238773
    a0 = 1 + k / q2 + k * k
    let highPass = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q2 + k * k) / a0)
    return [shelf, highPass]
}

// MARK: Normalising and quantising

struct Rendered {
    let name: String
    let pcm: [Int16]
    let scale: Double
    let capped: Bool
}

func normalise(_ sound: Sound) -> Rendered {
    let raw = render(sound)
    let peak = raw.reduce(0) { max($0, abs($1)) }
    let wanted = pow(10.0, (targetLUFS - loudness(raw)) / 20)
    let allowed = ceiling / peak
    let scale = min(wanted, allowed)
    let pcm = raw.map { Int16(max(-32767, min(32767, (($0 * scale) * 32767).rounded()))) }
    return Rendered(name: sound.name, pcm: pcm, scale: scale, capped: allowed < wanted)
}

func decoded(_ pcm: [Int16]) -> [Double] { pcm.map { Double($0) / 32768 } }

// MARK: CAF

/// A CAF file: file header, an audio description chunk and a data chunk, every field big endian except the
/// samples, which the description marks little endian (Apple's CoreAudioFormat.h).
func caf(_ pcm: [Int16]) -> Data {
    var data = Data()
    func put(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
    func put16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    func put32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    func put64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }

    put("caff")
    put16(1)  // version
    put16(0)  // flags

    put("desc")
    put64(32)
    put64(Double(sampleRate).bitPattern)  // mSampleRate, a big endian Float64
    put("lpcm")
    put32(2)  // kCAFLinearPCMFormatFlagIsLittleEndian: signed integers, no float flag
    put32(2)  // bytes per packet
    put32(1)  // frames per packet
    put32(1)  // channels per frame
    put32(16)  // bits per channel

    put("data")
    put64(UInt64(4 + pcm.count * 2))  // the edit count plus the samples
    put32(0)  // edit count
    for sample in pcm {
        withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
    }
    return data
}

// MARK: Main

let scriptURL = URL(fileURLWithPath: #filePath)
let defaultFolder = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("App/Resources/Sounds", isDirectory: true)
let folder = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true) : defaultFolder

do {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for sound in sounds {
        let rendered = normalise(sound)
        let file = folder.appendingPathComponent("\(sound.name).caf")
        try caf(rendered.pcm).write(to: file, options: .atomic)
        let samples = decoded(rendered.pcm)
        let peak = samples.reduce(0) { max($0, abs($1)) }
        let line = String(
            format: "%@  %4d ms  %6.2f LUFS  peak %6.2f dBFS%@",
            sound.name.padding(toLength: 17, withPad: " ", startingAt: 0),
            rendered.pcm.count * 1000 / sampleRate, loudness(samples), 20 * log10(peak),
            rendered.capped ? "  (limited by the -1 dBFS ceiling)" : "")
        print(line)
    }
} catch {
    FileHandle.standardError.write(Data("make_sounds: \(error.localizedDescription)\n".utf8))
    exit(1)
}
