//go:build !noaudio

package audio

import "sync"

// uplinkJB is a tiny jitter buffer for decoded uplink (client mic) frames.
// Frames are keyed by their sequence number; the consumer pulls the next
// expected frame in order. Missing frames (packet loss) are skipped by
// jumping to the oldest buffered frame, and frames outside the jitter
// window are dropped so the buffer stays bounded.
type uplinkJB struct {
	mu       sync.Mutex
	frames   map[uint16][]int16
	next     uint16
	frameLen int
	maxAhead int
}

func newUplinkJB(frameLen int) *uplinkJB {
	return &uplinkJB{
		frames:   make(map[uint16][]int16),
		frameLen: frameLen,
		maxAhead: 64,
	}
}

// put inserts a decoded frame if it falls within the jitter window around
// the play head. Frames behind the play head (too late) or more than
// maxAhead frames ahead (would only add latency) are dropped.
func (j *uplinkJB) put(seq uint16, f []int16) {
	j.mu.Lock()
	defer j.mu.Unlock()
	d := seqDelta(seq, j.next)
	if d < 0 || d > j.maxAhead {
		return
	}
	j.frames[seq] = f
}

// get returns the next frame to play and advances the play head. If the
// expected sequence number is missing (a packet was lost), the play head
// jumps to the oldest buffered frame instead of stalling playback forever.
// The second return indicates whether a frame was available.
func (j *uplinkJB) get() ([]int16, bool) {
	j.mu.Lock()
	defer j.mu.Unlock()
	f, ok := j.frames[j.next]
	if !ok {
		oldest, ok := j.oldestAhead()
		if !ok {
			return nil, false
		}
		j.next = oldest
		f = j.frames[oldest]
	}
	delete(j.frames, j.next)
	j.next++
	return f, true
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
