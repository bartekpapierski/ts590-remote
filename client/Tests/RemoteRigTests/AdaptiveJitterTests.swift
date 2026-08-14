import Foundation
import Testing
@testable import RemoteRig

struct AdaptiveJitterTests {

    @Test func regressOnDropout() {
        var aj = AdaptiveJitter(depth: 2, minDepth: 1, maxDepth: 8)
        aj.update(isDropout: true, occupancyFrames: 0)
        #expect(aj.depth == 3)
    }

    @Test func capsAtMaxDepth() {
        var aj = AdaptiveJitter(depth: 7, minDepth: 1, maxDepth: 8)
        aj.update(isDropout: true, occupancyFrames: 0)
        #expect(aj.depth == 8)
        aj.update(isDropout: true, occupancyFrames: 0)
        #expect(aj.depth == 8, "depth must not exceed maxDepth")
    }

    @Test func noGrowthOnCleanRun() {
        var aj = AdaptiveJitter(depth: 2, minDepth: 1, maxDepth: 8)
        aj.update(isDropout: false, occupancyFrames: 1)
        #expect(aj.depth == 2, "a clean, under-target run must not grow")
    }

    @Test func shrinksWhenPersistentlyOverfilled() {
        var aj = AdaptiveJitter(depth: 5, minDepth: 1, maxDepth: 8, shrinkEvery: 50)
        // Occupancy stays above depth + margin for long enough to trigger shrink.
        for _ in 0..<50 {
            aj.update(isDropout: false, occupancyFrames: 20)
        }
        #expect(aj.depth == 4, "over-filled buffer should recover one frame of latency")
    }

    @Test func dropoutResetsShrinkCount() {
        var aj = AdaptiveJitter(depth: 5, minDepth: 1, maxDepth: 8, shrinkEvery: 10)
        // Nearly enough over-filled passes to shrink...
        for _ in 0..<9 {
            aj.update(isDropout: false, occupancyFrames: 20)
        }
        // ...interrupted by a dropout: it grows depth and resets the shrink tally.
        aj.update(isDropout: true, occupancyFrames: 0)
        #expect(aj.depth == 6)
        for _ in 0..<9 {
            aj.update(isDropout: false, occupancyFrames: 20)
        }
        // If the tally had not been reset, the 18 cumulative over-filled passes
        // would have shrunk below 6.
        #expect(aj.depth == 6, "shrink must not fire across a dropout reset")
    }

    @Test func clampsInitDepth() {
        #expect(AdaptiveJitter(depth: 0, minDepth: 1, maxDepth: 8).depth == 1)
        #expect(AdaptiveJitter(depth: 99, minDepth: 1, maxDepth: 8).depth == 8)
        #expect(AdaptiveJitter(depth: 3, minDepth: 1, maxDepth: 8).depth == 3)
    }
}
