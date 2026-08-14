//go:build !noaudio

package audio

import "sync"

const (
	// jbMaxAhead is the hard safety cap: a frame more than this far ahead of
	// the play head is assumed to be from a stale/reordered stream and dropped.
	jbMaxAhead = 64
	// jbMinDepth / jbMaxDepth bound the configured pre-buffer depth (frames).
	jbMinDepth = 1
	jbMaxDepth = 64
	// jbIdleResetGets is how many consecutive empty gets with no incoming
	// frames are treated as the end of a transmission. The uplink only carries
	// audio while the operator transmits, so once the gap is long enough the
	// buffer re-arms its pre-buffer so the next transmission starts clean.
	// ~500 ms of 20 ms frames.
	jbIdleResetGets = 25
)

// JitterStats is a point-in-time snapshot of the uplink jitter buffer used
// for diagnostics.
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

// uplinkJB is a fixed-depth jitter buffer for decoded uplink (client mic)
// frames. Frames are keyed by their sequence number; the consumer pulls the
// next expected frame in order.
//
// The buffer pre-buffers its depth at the start of a transmission to absorb
// the one-way network latency, then plays through in real time: a missing
// frame (packet loss) is skipped by jumping to the oldest buffered frame, and
// a true underrun (frames delayed past the buffer) plays one frame of silence
// and keeps going rather than growing the buffer. Growing the depth on an
// underrun cannot fix clock drift — it only adds latency and makes each
// dropout pause longer — so the depth is fixed at the configured value.
// When the operator stops transmitting (an idle gap), the pre-buffer is
// re-armed so the next transmission starts clean.
type uplinkJB struct {
	mu       sync.Mutex
	frames   map[uint16][]int16
	next     uint16
	frameLen int
	maxAhead int

	depth    int
	minDepth int
	maxDepth int
	started  bool
	idle     int // consecutive empty gets with no incoming frames

	dropouts int64
	skips    int64
	late     int64
}

func newUplinkJB(frameLen int) *uplinkJB {
	return newUplinkJBDepth(frameLen, jbMinDepth, jbMinDepth, jbMaxDepth)
}

// newUplinkJBDepth creates a jitter buffer with an explicit pre-buffer depth
// (in frames) and display bounds.
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
	j.idle = 0
	j.frames[seq] = f
}

// get returns the next frame to play and advances the play head.
//
// Before the first frames of a transmission arrive the buffer holds output
// until it has accumulated its depth, absorbing the one-way latency so the
// first words are not clipped. Once playing, if the expected sequence number
// is missing (a packet was lost) the play head jumps to the oldest buffered
// frame rather than stalling. If there is nothing to play at all the buffer
// reports an underrun and plays one frame of silence — the depth is not grown
// (that would only add latency) and the idle counter detects when the
// transmission ends so the next one pre-buffers again. The second return
// indicates whether a frame was available.
func (j *uplinkJB) get() ([]int16, bool) {
	j.mu.Lock()
	defer j.mu.Unlock()

	if !j.started {
		if len(j.frames) < j.depth {
			j.countIdle()
			return nil, false
		}
		j.started = true
	}

	f, ok := j.frames[j.next]
	if ok {
		delete(j.frames, j.next)
		j.next++
		return f, true
	}

	oldest, ok := j.oldestAhead()
	if !ok {
		// True underrun: nothing to play. Play one frame of silence; the idle
		// counter decides whether this is a jitter dip (frames resume) or the
		// end of the transmission (re-arm the pre-buffer).
		j.dropouts++
		j.countIdle()
		return nil, false
	}
	j.skips++
	j.next = oldest
	f = j.frames[oldest]
	delete(j.frames, oldest)
	j.next++
	return f, true
}

// countIdle is called for each get with nothing to play. An extended run with
// no incoming frames means the operator stopped transmitting; re-arm the
// pre-buffer so the next transmission starts clean instead of playing the
// first (latency-delayed) frames immediately.
func (j *uplinkJB) countIdle() {
	j.idle++
	if j.idle >= jbIdleResetGets {
		j.idle = 0
		j.started = false
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
