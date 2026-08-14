import Foundation

/// Adaptive target depth for the downlink (rig -> client) jitter buffer.
///
/// The render thread consumes buffered PCM in real time, so a silent underrun
/// (dropdown) is caused by the network not delivering a frame in time. This
/// type tunes the number of frames the client holds before playing in response
/// to the observed stream:
///
///   - a dropout grows the target depth so more jitter is absorbed;
///   - a persistent over-filled buffer (no dropouts, many frames held) shrinks
///     the target depth to recover added latency.
///
/// It is a pure value type so the policy is unit-testable without the audio
/// engine.
struct AdaptiveJitter {
    private(set) var depth: Int
    let minDepth: Int
    let maxDepth: Int
    let overMargin: Int
    let shrinkEvery: Int

    private var overCount = 0

    init(depth: Int, minDepth: Int = 1, maxDepth: Int = 20, overMargin: Int = 2, shrinkEvery: Int = 250) {
        self.minDepth = max(minDepth, 1)
        self.maxDepth = max(self.minDepth, maxDepth)
        self.depth = min(max(depth, self.minDepth), self.maxDepth)
        self.overMargin = overMargin
        self.shrinkEvery = max(shrinkEvery, 1)
    }

    /// Feed one render pull. `isDropout` is true when the consumer could not be
    /// fully fed (a silent gap); `occupancyFrames` is how many frames were held.
    mutating func update(isDropout: Bool, occupancyFrames: Int) {
        if isDropout {
            if depth < maxDepth { depth += 1 }
            overCount = 0
        } else if depth > minDepth {
            if occupancyFrames >= depth + overMargin {
                overCount += 1
                if overCount >= shrinkEvery {
                    depth -= 1
                    overCount = 0
                }
            } else {
                overCount = 0
            }
        } else {
            overCount = 0
        }
    }
}
