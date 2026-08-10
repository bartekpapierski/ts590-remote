package radio

import (
	"errors"
	"io"
	"sync"
	"testing"
	"time"

	"go.uber.org/zap"
)

// scriptedPort is an io.ReadWriteCloser that, on each Write, delivers the
// next scripted response to a pending Read — modelling the rig's query
// echo. An empty script means "no response".
type scriptedPort struct {
	mu      sync.Mutex
	written []byte
	script  [][]byte
	readCh  chan []byte
	closed  chan struct{}
}

func (s *scriptedPort) Write(p []byte) (int, error) {
	s.mu.Lock()
	s.written = append(s.written, p...)
	var resp []byte
	if len(s.script) > 0 {
		resp = s.script[0]
		s.script = s.script[1:]
	}
	s.mu.Unlock()
	if resp != nil {
		select {
		case s.readCh <- resp:
		case <-s.closed:
		}
	}
	return len(p), nil
}

func (s *scriptedPort) Read(p []byte) (int, error) {
	select {
	case line := <-s.readCh:
		return copy(p, line), nil
	case <-s.closed:
		return 0, io.EOF
	}
}

func (s *scriptedPort) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	select {
	case <-s.closed:
	default:
		close(s.closed)
	}
	return nil
}

func (s *scriptedPort) writtenString() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return string(s.written)
}

func TestIsQuery(t *testing.T) {
	tests := []struct {
		cmd  string
		want bool
	}{
		{"FA;", true},
		{"TX;", true},
		{"FA00014000000;", false},
		{"PS1;", false},
	}
	for _, tc := range tests {
		if got := isQueryCmd(tc.cmd); got != tc.want {
			t.Errorf("isQuery(%q) = %v, want %v", tc.cmd, got, tc.want)
		}
	}
}

func TestTimeoutFor(t *testing.T) {
	r := &Radio{
		queryTimeout: 1500 * time.Millisecond,
		powerTimeout: 10 * time.Second,
	}
	if got := r.timeoutFor("PS"); got != r.powerTimeout {
		t.Errorf("timeoutFor(PS) = %v, want powerTimeout %v", got, r.powerTimeout)
	}
	if got := r.timeoutFor("FA"); got != r.queryTimeout {
		t.Errorf("timeoutFor(FA) = %v, want queryTimeout %v", got, r.queryTimeout)
	}
}

func TestHandleLineReplyMatch(t *testing.T) {
	r := &Radio{EventCh: make(chan string, 4), log: zap.NewNop()}
	pr := &pendingReq{code: "FA", respCh: make(chan string, 1)}
	r.pendingMu.Lock()
	r.pending = pr
	r.pendingMu.Unlock()

	r.handleLine("FA1400000000;")

	select {
	case resp := <-pr.respCh:
		if resp != "FA1400000000;" {
			t.Fatalf("got resp %q, want FA1400000000;", resp)
		}
	default:
		t.Fatal("expected pending request to be answered")
	}
	r.pendingMu.Lock()
	defer r.pendingMu.Unlock()
	if r.pending != nil {
		t.Fatal("pending request should be cleared after match")
	}
}

func TestHandleLineRejectMatch(t *testing.T) {
	r := &Radio{EventCh: make(chan string, 4), log: zap.NewNop()}
	pr := &pendingReq{code: "FA", respCh: make(chan string, 1)}
	r.pendingMu.Lock()
	r.pending = pr
	r.pendingMu.Unlock()

	r.handleLine("?;")

	select {
	case resp := <-pr.respCh:
		if resp != "?;" {
			t.Fatalf("got resp %q, want ?;", resp)
		}
	default:
		t.Fatal("expected pending request to be answered with ?;")
	}
}

func TestHandleLineNoPendingIsEvent(t *testing.T) {
	r := &Radio{EventCh: make(chan string, 4), log: zap.NewNop()}
	r.handleLine("SM0000000000000;")
	select {
	case ev := <-r.EventCh:
		if ev != "SM0000000000000;" {
			t.Fatalf("got event %q, want SM0000000000000;", ev)
		}
	default:
		t.Fatal("expected unsolicited line to be broadcast as event")
	}
}

func TestHandleLineMismatchIsEvent(t *testing.T) {
	r := &Radio{EventCh: make(chan string, 4), log: zap.NewNop()}
	pr := &pendingReq{code: "FA", respCh: make(chan string, 1)}
	r.pendingMu.Lock()
	r.pending = pr
	r.pendingMu.Unlock()

	r.handleLine("SM0000000000000;")

	// mismatch must go to the event channel, not the pending request
	select {
	case ev := <-r.EventCh:
		if ev != "SM0000000000000;" {
			t.Fatalf("got event %q, want SM0000000000000;", ev)
		}
	default:
		t.Fatal("expected mismatch to be broadcast as event")
	}
	r.pendingMu.Lock()
	defer r.pendingMu.Unlock()
	if r.pending != pr {
		t.Fatal("pending request should survive a non-matching line")
	}
}

// newTestRadio builds a Radio over a scriptedPort with short timeouts.
func newTestRadio(script ...string) (*Radio, *scriptedPort) {
	p := &scriptedPort{
		readCh: make(chan []byte, 8),
		closed: make(chan struct{}),
	}
	for _, s := range script {
		p.script = append(p.script, []byte(s))
	}
	r := New(p, p, p, zap.NewNop())
	r.setWait = 20 * time.Millisecond
	r.queryTimeout = 20 * time.Millisecond
	r.powerTimeout = 20 * time.Millisecond
	return r, p
}

func TestSendQueryEcho(t *testing.T) {
	r, p := newTestRadio("FA1400000000;")
	defer r.Close()

	resp, err := r.Send("FA;")
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	if resp != "FA1400000000;" {
		t.Fatalf("got %q, want FA1400000000;", resp)
	}
	if got := p.writtenString(); got != "FA;" {
		t.Fatalf("wrote %q, want FA;", got)
	}
}

func TestSendQueryRejected(t *testing.T) {
	r, _ := newTestRadio("?;")
	defer r.Close()

	_, err := r.Send("FA;")
	if err == nil || err.Error() != "radio: command not supported" {
		t.Fatalf("got err %v, want command not supported", err)
	}
}

func TestSendSetFireAndForget(t *testing.T) {
	r, p := newTestRadio()
	defer r.Close()

	resp, err := r.Send("FA00014000000;")
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	if resp != "" {
		t.Fatalf("got %q, want empty fire-and-forget response", resp)
	}
	if got := p.writtenString(); got != "FA00014000000;" {
		t.Fatalf("wrote %q, want FA00014000000;", got)
	}
}

func TestSendSetRejected(t *testing.T) {
	r, _ := newTestRadio("?;")
	defer r.Close()

	_, err := r.Send("FA00014000000;")
	if err == nil || err.Error() != "radio: command rejected" {
		t.Fatalf("got err %v, want command rejected", err)
	}
}

func TestSendQueryTimeout(t *testing.T) {
	r, _ := newTestRadio()
	defer r.Close()

	_, err := r.Send("FA;")
	if !errors.Is(err, ErrTimeout) {
		t.Fatalf("got err %v, want ErrTimeout", err)
	}
}

func TestSendNotOpen(t *testing.T) {
	r := &Radio{}
	_, err := r.Send("FA;")
	if !errors.Is(err, ErrNotOpen) {
		t.Fatalf("got err %v, want ErrNotOpen", err)
	}
}

func TestSendCommandTooShort(t *testing.T) {
	r, _ := newTestRadio()
	defer r.Close()

	_, err := r.Send("X")
	if err == nil || err.Error() != "radio: command too short" {
		t.Fatalf("got err %v, want command too short", err)
	}
}
