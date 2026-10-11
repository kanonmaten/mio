import Foundation

/// Chooses where an owned transcription core ends: at a natural pause 8–22 s into the core,
/// so words and speaker turns are not split. Energy only (20 ms mean-square frames over the
/// 16 kHz mono PCM the assembler already holds); it keeps no audio of its own.
///
/// A request is at most 1 s left context + 22 s core + 1 s right context = 24 s, which is
/// exactly API v1's limit (384,000 samples, 768,044 WAV bytes).
struct SpeechPauseDetector: Sendable {
    static let sampleRate = 16_000
    /// 20 ms. The assembler's one-second context (50 frames) keeps its buffer frame-aligned.
    static let frameSamples = 320

    var minimumCoreFrames = 400      // 8 s
    var maximumCoreFrames = 1_100    // 22 s
    var contextFrames = 50           // 1 s right context must exist after the cut
    var pauseFrames = 15             // 300 ms of quiet frames counts as a pause
    /// Early cuts need audible content: the loud reference (90th percentile, mean-square
    /// Int16 units) must exceed this (about −47 dBFS) and be 6 dB over the noise floor.
    var speechFloor = 20_000.0
    var speechOverNoise = 4.0
    /// A pause frame is at most twice the noise floor or 3 % of the loud reference, whichever
    /// is higher. The noise floor is the 2nd percentile: one 300 ms pause in a 23 s window
    /// is still about 1.3 % of its frames, so a higher percentile would land inside speech.
    var pauseOverNoise = 2.0
    var pauseFractionOfSpeech = 0.03

    /// Mean square of each complete frame from `firstFrame` on, as little-endian Int16 PCM.
    static func frameEnergies(_ pcm: Data, from firstFrame: Int = 0) -> [Double] {
        let frameBytes = frameSamples * 2
        let complete = pcm.count / frameBytes
        guard complete > firstFrame else { return [] }
        return pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Double] in
            (max(0, firstFrame)..<complete).map { (frame: Int) -> Double in
                var sum = 0.0
                let base = frame * frameBytes
                for sample in 0..<frameSamples {
                    let value = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: base + sample * 2, as: Int16.self)))
                    sum += value * value
                }
                return sum / Double(frameSamples)
            }
        }
    }

    /// The exclusive core end, in frames counted from `energies[0]`, or nil to wait for more
    /// audio. The first clear pause after the minimum wins (lowest latency); once the
    /// maximum core plus right context is buffered, the quietest window is forced, preferring
    /// the latest equal candidate so silence and steady noise produce few, long requests.
    func coreEnd(energies: [Double], coreStart: Int) -> Int? {
        let available = energies.count
        let half = pauseFrames / 2
        let earliest = coreStart + minimumCoreFrames
        let latest = coreStart + maximumCoreFrames
        guard coreStart >= 0, available - contextFrames >= earliest else { return nil }
        let window = energies[coreStart..<available].sorted()
        let noise = window[window.count / 50]
        let reference = window[min(window.count - 1, window.count * 9 / 10)]
        if reference >= speechFloor, reference >= noise * speechOverNoise {
            let threshold = max(noise * pauseOverNoise, reference * pauseFractionOfSpeech)
            let lastCut = min(latest, available - contextFrames)
            var run = 0
            var frame = earliest - half
            while frame < available {
                run = energies[frame] <= threshold ? run + 1 : 0
                let cut = frame - pauseFrames + 1 + half
                if cut > lastCut { break }
                if run >= pauseFrames, cut >= earliest { return cut }
                frame += 1
            }
        }
        guard available >= latest + contextFrames else { return nil }
        var best = earliest
        var bestEnergy = Double.infinity
        for cut in earliest...latest {
            var sum = 0.0
            for frame in (cut - half)..<(cut - half + pauseFrames) { sum += energies[frame] }
            if sum <= bestEnergy { best = cut; bestEnergy = sum }
        }
        return best
    }
}
