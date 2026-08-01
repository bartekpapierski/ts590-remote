//go:build !noaudio

package audio

import (
	"testing"
)

func TestSeqDelta(t *testing.T) {
	tests := []struct {
		a, b uint16
		want int
	}{
		{100, 90, 10},
		{90, 100, -10},
		{0, 0, 0},
		{1, 0, 1},
		{0, 1, -1},
		// Wrap-around: a is 11 ahead of b in the short direction
		{5, 65530, 11},
		{65530, 5, -11}, // short way around (negative)
		// Boundary: exactly 32767
		{32767, 0, 32767},
		// Boundary: exactly -32768
		{0, 32768, -32768},
	}
	for _, tt := range tests {
		got := seqDelta(tt.a, tt.b)
		if got != tt.want {
			t.Errorf("seqDelta(%d, %d) = %d, want %d", tt.a, tt.b, got, tt.want)
		}
	}
}

func TestJitterBuffer(t *testing.T) {
	jb := newUplinkJB(960)

	// Initially empty.
	f, ok := jb.get()
	if ok {
		t.Error("get() on empty buffer should return false")
	}
	if f != nil {
		t.Error("get() on empty buffer should return nil frame")
	}

	// Put a frame at seq 0.
	frame0 := []int16{1, 2, 3}
	jb.put(0, frame0)

	// get() should return it.
	f, ok = jb.get()
	if !ok {
		t.Fatal("get() should return true after put(0)")
	}
	if len(f) != 3 || f[0] != 1 || f[1] != 2 || f[2] != 3 {
		t.Errorf("get() returned %v, want [1 2 3]", f)
	}

	// Buffer should be empty again.
	f, ok = jb.get()
	if ok {
		t.Error("get() should return false after consuming the only frame")
	}

	// Out-of-order: put seq 2, then seq 1, then get should return seq 1.
	jb.put(2, []int16{7, 8})
	jb.put(1, []int16{4, 5, 6})
	f, ok = jb.get()
	if !ok {
		t.Fatal("get() should return true")
	}
	if len(f) != 3 || f[0] != 4 {
		t.Errorf("get() returned %v, want [4 5 6] (seq 1)", f)
	}
	// Now get seq 2.
	f, ok = jb.get()
	if !ok {
		t.Fatal("get() should return true for seq 2")
	}
	if len(f) != 2 || f[0] != 7 {
		t.Errorf("get() returned %v, want [7 8] (seq 2)", f)
	}
}

func TestJitterBufferSkipsLostFrames(t *testing.T) {
	jb := newUplinkJB(960)

	// Frames 0..2 arrive in order; frame 3 is lost; frames 4..5 arrive.
	jb.put(0, []int16{1})
	jb.put(1, []int16{2})
	jb.put(2, []int16{3})
	jb.put(4, []int16{5})
	jb.put(5, []int16{6})

	// 0, 1, 2 play in order.
	for i, want := range [][]int16{{1}, {2}, {3}} {
		f, ok := jb.get()
		if !ok {
			t.Fatalf("get() #%d should return a frame", i)
		}
		if f[0] != want[0] {
			t.Errorf("get() #%d returned %v, want [%d]", i, f, want[0])
		}
	}

	// Frame 3 is missing: the play head must jump to frame 4 instead
	// of stalling playback forever.
	f, ok := jb.get()
	if !ok {
		t.Fatal("get() should skip the lost frame and return seq 4")
	}
	if f[0] != 5 {
		t.Errorf("get() returned %v, want [5] (seq 4)", f)
	}

	f, ok = jb.get()
	if !ok {
		t.Fatal("get() should return seq 5")
	}
	if f[0] != 6 {
		t.Errorf("get() returned %v, want [6] (seq 5)", f)
	}

	_, ok = jb.get()
	if ok {
		t.Error("get() should report empty buffer after consuming all frames")
	}
}

func TestJitterBufferDoesNotStallAfterLongGap(t *testing.T) {
	jb := newUplinkJB(960)

	jb.put(0, []int16{1})
	jb.get() // plays seq 0, next = 1

	// A whole burst is lost; the next received frame is far ahead.
	jb.put(10, []int16{11})
	f, ok := jb.get()
	if !ok {
		t.Fatal("get() should jump over the lost burst")
	}
	if f[0] != 11 {
		t.Errorf("get() returned %v, want [11]", f)
	}
}

func TestJitterBufferDropsBehindPlayhead(t *testing.T) {
	jb := newUplinkJB(960)

	jb.put(5, []int16{1})
	jb.put(6, []int16{2})
	jb.get() // plays seq 5, next = 6
	jb.get() // plays seq 6, next = 7

	// A late-arriving frame behind the play head must be dropped, not
	// buffered, and must not move the play head backwards.
	jb.put(4, []int16{99})
	f, ok := jb.get()
	if ok {
		t.Errorf("get() returned %v, want no frame (late seq 4 dropped)", f)
	}

	// A frame within the window is still accepted.
	jb.put(7, []int16{3})
	f, ok = jb.get()
	if !ok || f[0] != 3 {
		t.Errorf("get() = %v, %v; want [3], true", f, ok)
	}
}

func TestJitterBufferDropsTooFarAhead(t *testing.T) {
	jb := newUplinkJB(960)

	jb.put(0, []int16{1})
	// A frame 100 sequences ahead would add ~2s of latency and indicate a
	// stale/reordered stream; it must not be buffered.
	jb.put(100, []int16{99})

	f, ok := jb.get()
	if !ok || f[0] != 1 {
		t.Errorf("get() = %v, %v; want [1], true", f, ok)
	}
	_, ok = jb.get()
	if ok {
		t.Error("get() should not return the too-far-ahead frame")
	}
}

func TestJitterBufferWraparound(t *testing.T) {
	jb := newUplinkJB(960)

	// Play head starts at 0. Put frame at seq 0 and seq 1.
	jb.put(0, []int16{1})
	jb.put(1, []int16{2})

	// get() should return seq 0.
	f, ok := jb.get()
	if !ok {
		t.Fatal("get() should return true for seq 0")
	}
	if f[0] != 1 {
		t.Errorf("get() returned %v, want [1]", f)
	}

	// get() should return seq 1.
	f, ok = jb.get()
	if !ok {
		t.Fatal("get() should return true for seq 1")
	}
	if f[0] != 2 {
		t.Errorf("get() returned %v, want [2]", f)
	}

	// Now test wrap-around: advance play head to 65535 by consuming
	// frames up to 65534, then put 65535 and 0 (wrap).
	for i := uint16(2); i < 65535; i++ {
		jb.put(i, []int16{int16(i)})
		jb.get() // consume each in order
	}
	// next is now 65535.
	jb.put(65535, []int16{99})
	jb.put(0, []int16{100}) // wraps to 0, which is next after 65535

	// get() should return seq 65535.
	f, ok = jb.get()
	if !ok {
		t.Fatal("get() should return true for seq 65535")
	}
	if f[0] != 99 {
		t.Errorf("get() returned %v, want [99]", f)
	}

	// get() should return seq 0 (wrap-around).
	f, ok = jb.get()
	if !ok {
		t.Fatal("get() should return true for seq 0 after wrap")
	}
	if f[0] != 100 {
		t.Errorf("get() returned %v, want [100]", f)
	}
}

func TestJitterBufferWraparoundLoss(t *testing.T) {
	jb := newUplinkJB(960)

	// Advance the play head to just before the wrap point.
	for i := uint16(0); i < 65534; i++ {
		jb.put(i, []int16{1})
		jb.get()
	}
	// next = 65534. Frames 65534 and 65535 are lost; frame 0 (wrapped)
	// arrives.
	jb.put(0, []int16{99})

	f, ok := jb.get()
	if !ok {
		t.Fatal("get() should jump across the wrap boundary to seq 0")
	}
	if f[0] != 99 {
		t.Errorf("get() returned %v, want [99]", f)
	}
}
