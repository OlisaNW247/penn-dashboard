import Foundation

/// A small deterministic generator (SplitMix64) for tests that need
/// "random" input a failure can be reproduced from. `SystemRandomNumberGenerator`
/// cannot be seeded, so a failure it found would be gone on the next run; this
/// one gives the same sequence for the same seed on every machine, so a test
/// names its seed and a red run is a repro, not an anecdote.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
