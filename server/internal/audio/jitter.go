//go:build !noaudio

package audio

import "sync"

const (
	// jbMaxAhead is the hard safety cap: a frame more than this far ahead of
	// the play head is assumed to be from a stale/reordered stream and dropped.
	jbMaxAhead = 64
	// jbMinDepth / jbMaxDepth bound the adaptive target depth (in frames).
	jbMinDepth = 1
	jbMaxDepth = 64
	// jbOverMargin is how many frames the buffer may hold above its target
	// before it starts counting toward shrinking the target.
	jbOverMargin = 2
	// jbShrinkEvery is how many consecutive over-filled gets trigger a
	// one-frame shrink of the target depth (~5 s of 20 ms frames).
	jbShrinkEvery = 250
)

// JitterStats is a point-in-time snapshot of the uplink jitter buffer used
// for diagnostics and adaptive tuning.
type JitterStats struct {
	Depth     int
	MinDepth  int
	MaxDepth  int
	Started   bool
	Dropouts  int64 // silent underruns (nothing to play)
	Skips     int64 // lost frames jumped over
	Late      int64 // frames dropped because they arrived past their deadline
	Fill      int   // frames currently buffered ahead of the play head
	Occupancy int   // total frames buffered
}

// uplinkJB is an adaptive jitter buffer for decoded uplink (client mic)
// frames. Frames are keyed by their sequence number; the consumer pulls the
// next expected frame in order. The buffer holds up to its target depth of
// frames ahead of the play head to absorb jitter, then adapts that depth to
// the observed stream:
//
//   - a silent underrun (dropout) grows the target depth so more jitter is
//     absorbed;
//   - a persistent over-filled buffer (no dropouts, many frames held) shrinks
//     the target depth to recover added latency.
//
// Missing frames (packet loss) are skipped by jumping to the oldest buffered
// frame, and frames outside the jitter window are dropped so the buffer stays
// bounded.
type uplinkJB struct {
	mu       sync.Mutex
	frames   map[uint16][]int16
	next     uint16
	frameLen int
	maxAhead int

	depth     int
	minDepth  int
	maxDepth  int
	started   bool
	overCount int

	dropouts int64
	skips    int64
	late     int64
}

func newUplinkJB(frameLen int) *uplinkJB {
	return newUplinkJBDepth(frameLen, jbMinDepth, jbMinDepth, jbMaxDepth)
}

// newUplinkJBDepth creates an adaptive jitter buffer with an explicit initial
// target depth and bounds on how far it may adapt.
func newUplinkJBDepth(frameLen, depth, minDepth, maxDepth int) *uplinkJB {
	if minDepth < 1 {
		minDepth = 1
	}
	if maxDepth < minDepth {
		maxDepth = minDepth
	}
	if depth < minDepth {
		depth = minDepth
	}
	if depth > maxDepth {
		depth = maxDepth
	}
	return &uplinkJB{
		frames:   make(map[uint16][]int16),
		frameLen: frameLen,
		maxAhead: jbMaxAhead,
		depth:    depth,
		minDepth: minDepth,
		maxDepth: maxDepth,
	}
}

// put inserts a decoded frame if it falls within the jitter window around
// the play head. Frames behind the play head (too late) or more than
// maxAhead frames ahead (would only add latency) are dropped.
func (j *uplinkJB) put(seq uint16, f []int16) {
	j.mu.Lock()
	defer j.mu.Unlock()
	d := seqDelta(seq, j.next)
	if d < 0 {
		j.late++
		return
	}
	if d > j.maxAhead {
		return
	}
	j.frames[seq] = f
}

// get returns the next frame to play and advances the play head.
//
// Before the first frames arrive (and again after any true underrun) the
// buffer holds output until it has accumulated its target depth, so an
// initial burst of jitter is absorbed and a post-underrun reservoir is rebuilt
// before playback resumes. Once playing, if the expected sequence number is
// missing (a packet was lost) the play head jumps to the oldest buffered frame
// rather than stalling forever. If there is nothing to play at all the buffer
// reports an underrun, grows its target depth and re-enters refill mode. The
// second return indicates whether a frame was available.
func (j *uplinkJB) get() ([]int16, bool) {
	j.mu.Lock()
	defer j.mu.Unlock()

	if !j.started {
		if len(j.frames) < j.depth {
			return nil, false
		}
		j.started = true
	}

	f, ok := j.frames[j.next]
	if ok {
		delete(j.frames, j.next)
		j.next++
		j.checkShrink()
		return f, true
	}

	oldest, ok := j.oldestAhead()
	if !ok {
		// True underrun: nothing to play. Report silence, grow the target
		// depth so more jitter is absorbed, and drop back into refill mode so
		// the buffer accumulates to the (possibly grown) depth before resuming
		// playback instead of draining straight away.
		j.dropouts++
		j.grow()
		j.started = false
		return nil, false
	}
	j.skips++
	j.next = oldest
	f = j.frames[oldest]
	delete(j.frames, oldest)
	j.next++
	j.checkShrink()
	return f, true
}

// grow increases the target depth after an underrun so the buffer absorbs
// more jitter next time.
func (j *uplinkJB) grow() {
	if j.depth < j.maxDepth {
		j.depth++
	}
	j.overCount = 0
}

// checkShrink slowly lowers the target depth while the buffer is
// persistently over-filled, recovering latency that is no longer needed.
func (j *uplinkJB) checkShrink() {
	if j.depth <= j.minDepth {
		j.overCount = 0
		return
	}
	if len(j.frames) >= j.depth+jbOverMargin {
		j.overCount++
		if j.overCount >= jbShrinkEvery {
			j.depth--
			j.overCount = 0
		}
	} else {
		j.overCount = 0
	}
}

// oldestAhead returns the smallest sequence number buffered ahead of the
// play head.
func (j *uplinkJB) oldestAhead() (uint16, bool) {
	var oldest uint16
	found := false
	for k := range j.frames {
		if seqDelta(k, j.next) <= 0 {
			continue
		}
		if !found || seqDelta(k, oldest) < 0 {
			oldest = k
			found = true
		}
	}
	return oldest, found
}

// stats returns a point-in-time snapshot for diagnostics.
func (j *uplinkJB) stats() JitterStats {
	j.mu.Lock()
	defer j.mu.Unlock()
	fill := 0
	for k := range j.frames {
		if seqDelta(k, j.next) > 0 {
			fill++
		}
	}
	return JitterStats{
		Depth:     j.depth,
		MinDepth:  j.minDepth,
		MaxDepth:  j.maxDepth,
		Started:   j.started,
		Dropouts:  j.dropouts,
		Skips:     j.skips,
		Late:      j.late,
		Fill:      fill,
		Occupancy: len(j.frames),
	}
}

// seqDelta returns a-b accounting for uint16 wrap-around.
func seqDelta(a, b uint16) int {
	d := int(a) - int(b)
	if d > 32767 {
		d -= 65536
	}
	if d < -32768 {
		d += 65536
	}
	return d
}
