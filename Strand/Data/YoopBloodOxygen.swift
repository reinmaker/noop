import Foundation
import StrandAnalytics
import WhoopProtocol

/// Yoop: the night's blood oxygen from the strap's own reading.
///
/// A 5.0/MG strap works out blood oxygen itself and reports it as one byte (v18 `@82`, a whole percent) in a
/// 30-second burst every 20 minutes while asleep; every other second reads 0 or a flag value (2, 8, 16, 32, 128,
/// 160 and sums of them), which is not a percentage. WHOOP shows one figure per night, "averaged across sleep
/// time". So the night is the mean of its bursts, each burst standing for its median reading: the 30 readings of
/// a burst are one measurement (their spread is a point or two while bursts differ by 3), so the count of bursts,
/// about 22 a night, not the count of readings, is what the average rests on.
///
/// Checked against WHOOP's own history on the wearer's nights of 8 to 18 Oct 2026 (no night has both): the
/// nightly means were 93.4 to 96.7, WHOOP's own 93.1 to 96.5 for 8 to 16 Oct, the two periods averaging 94.4
/// and 94.8 with night to night spreads of 1.2 and 1.0. It is an estimate until a night has both readings.
enum YoopBloodOxygen {
    /// Readings further apart than this belong to different bursts.
    static let burstGapSec = 120
    /// A burst with fewer percentage readings than this is mostly flag values and is left out.
    static let minReadingsPerBurst = 5
    /// Bursts a night needs (about 2.7 hours of sleep at one every 20 minutes).
    static let minBursts = 8

    struct Night: Equatable {
        /// Mean percent, one decimal.
        let percent: Double
        /// Bursts it averages.
        let bursts: Int
    }

    /// The night over the readings inside `sessions`, or nil when the strap sent too few to average.
    static func night(sessions: [SleepSession], aux: [V18AuxSample]) -> Night? {
        let inSleep = aux.compactMap { sample -> (ts: Int, value: Int)? in
            guard let v = sample.auxByte82, (70...100).contains(v),
                  sessions.contains(where: { $0.start <= sample.ts && sample.ts <= $0.end }) else { return nil }
            return (sample.ts, v)
        }
        return night(readings: inSleep)
    }

    /// The night over percentage readings (`ts` in seconds, whole percent in 70...100), in any order.
    static func night(readings: [(ts: Int, value: Int)]) -> Night? {
        let sorted = readings.sorted { $0.ts < $1.ts }
        var bursts: [[Int]] = []
        var current: [Int] = []
        var last = 0
        for reading in sorted {
            if !current.isEmpty && reading.ts - last > burstGapSec {
                bursts.append(current)
                current = []
            }
            current.append(reading.value)
            last = reading.ts
        }
        if !current.isEmpty { bursts.append(current) }
        let medians = bursts.filter { $0.count >= minReadingsPerBurst }.map(median)
        guard medians.count >= minBursts else { return nil }
        let mean = medians.reduce(0, +) / Double(medians.count)
        return Night(percent: (mean * 10).rounded() / 10, bursts: medians.count)
    }

    private static func median(_ values: [Int]) -> Double {
        let s = values.sorted()
        let n = s.count
        return n % 2 == 1 ? Double(s[n / 2]) : Double(s[n / 2 - 1] + s[n / 2]) / 2
    }
}
