package radio

import (
	"errors"
	"io"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	serial "go.bug.st/serial"
	"go.uber.org/zap"
)

var (
	ErrTimeout   = errors.New("radio: command timeout")
	ErrNotOpen   = errors.New("radio: radio not opened")
	ErrNoPending  = errors.New("radio: no pending request matched")
)

// Radio wraps the TS-590S serial (CAT) connection. I/O flows through the
// reader/writer/closer seam so the reply-matching state machine in Send and
// handleLine can be tested against a scripted fake instead of hardware.
type Radio struct {
	mu     sync.Mutex
	reader io.Reader
	writer io.Writer
	closer io.Closer

	// Reply timeouts. Send uses these; tests shorten them.
	setWait      time.Duration // set commands: wait for a possible "?" error reply
	queryTimeout time.Duration // query commands: wait for the echo
	powerTimeout time.Duration // "PS;" specifically, power-on can take seconds

	closed chan struct{}
	done   sync.Once

	// EventCh carries unsolicited CAT output from the rig (dial turns, etc.)
	EventCh chan string

	pendingMu sync.Mutex
	pending  *pendingReq

	ptt atomic.Bool

	log *zap.Logger
}

type pendingReq struct {
	code   string // 2-char command code, e.g. "FA"
	respCh chan string
}

// New builds a Radio over an arbitrary reader/writer/closer and starts its
// read loop. Open wires the real serial port through it; tests inject a
// scripted fake.
func New(reader io.Reader, writer io.Writer, closer io.Closer, log *zap.Logger) *Radio {
	r := &Radio{
		reader:       reader,
		writer:       writer,
		closer:       closer,
		setWait:      400 * time.Millisecond,
		queryTimeout: 1500 * time.Millisecond,
		powerTimeout: 10 * time.Second,
		closed:       make(chan struct{}),
		EventCh:      make(chan string, 64),
		log:          zap.NewNop(),
	}
	if log != nil {
		r.log = log
	}
	go r.readLoop()
	return r
}

// Open connects to the rig's CAT serial port and starts the reader goroutine.
func Open(port string, baud int) (*Radio, error) {
	mode := &serial.Mode{
		BaudRate: baud,
		Parity:   serial.NoParity,
		DataBits: 8,
		StopBits: serial.OneStopBit,
	}
	p, err := serial.Open(port, mode)
	if err != nil {
		return nil, err
	}
	// Non-blocking-ish reads so the loop can observe shutdown.
	_ = p.SetReadTimeout(time.Millisecond * 100)

	return New(p, p, p, nil), nil
}

func (r *Radio) SetLogger(l *zap.Logger) { r.log = l }

// Events exposes the unsolicited-CAT-output channel. Consumers (e.g. the
// control server) read from it to forward rig events to clients.
func (r *Radio) Events() <-chan string { return r.EventCh }

// Close tears down the reader and serial port.
func (r *Radio) Close() {
	r.done.Do(func() {
		close(r.closed)
		r.mu.Lock()
		if r.closer != nil {
			_ = r.closer.Close()
		}
		r.mu.Unlock()
	})
}

func (r *Radio) readLoop() {
	buf := make([]byte, 256)
	var acc []byte
	for {
		select {
		case <-r.closed:
			return
		default:
		}
		n, err := r.reader.Read(buf)
		if n > 0 {
			for i := 0; i < n; i++ {
				b := buf[i]
				if b == ';' {
					line := string(acc)
					acc = acc[:0]
					if line != "" {
						r.handleLine(line + ";")
					}
				} else {
					acc = append(acc, b)
				}
			}
		}
		if err != nil {
			if err == io.EOF {
				return
			}
			// transient read error / timeout: keep going
			time.Sleep(10 * time.Millisecond)
		}
	}
}

func (r *Radio) handleLine(line string) {
	r.log.Debug("cat recv raw", zap.String("line", line))
	r.pendingMu.Lock()
	p := r.pending
	if p != nil && (strings.HasPrefix(line, p.code) || line == "?;") {
		r.pending = nil
		r.pendingMu.Unlock()
		p.respCh <- line
		return
	}
	r.pendingMu.Unlock()

	// unsolicited output -> broadcast as event
	select {
	case r.EventCh <- line:
	default:
		r.log.Warn("radio event channel full, dropping", zap.String("line", line))
	}
}

// Send writes a CAT command (appending ';' if missing) and waits for the
// rig's response. The TS-590S echoes *query* commands (e.g. "FA;") but does
// NOT echo *set* commands (e.g. "FA00014000000;", "PS1;") — those execute
// silently, or reply "?" on error. We therefore wait for an echo on queries
// only, and treat set commands as fire-and-forget (with a short wait for a
// possible "?" error reply).
func (r *Radio) Send(cmd string) (string, error) {
	if r == nil || r.writer == nil {
		return "", ErrNotOpen
	}
	cmd = strings.TrimSpace(cmd)
	if !strings.HasSuffix(cmd, ";") {
		cmd += ";"
	}
	if len(cmd) < 3 {
		return "", errors.New("radio: command too short")
	}
	code := cmd[:2]
	isQuery := isQueryCmd(cmd)

	pr := &pendingReq{code: code, respCh: make(chan string, 1)}
	r.pendingMu.Lock()
	r.pending = pr
	r.pendingMu.Unlock()

	r.log.Debug("cat send", zap.String("cmd", cmd))

	r.mu.Lock()
	_, err := r.writer.Write([]byte(cmd))
	r.mu.Unlock()
	if err != nil {
		r.clearPending(pr)
		return "", err
	}

	if !isQuery {
		// Set command: rig does not echo. Wait briefly for a possible "?"
		// error reply; otherwise assume success.
		select {
		case resp := <-pr.respCh:
			r.clearPending(pr)
			if resp == "?;" {
				r.log.Debug("cat rejected", zap.String("cmd", code))
				return "", errors.New("radio: command rejected")
			}
			return resp, nil
		case <-time.After(r.setWait):
			r.clearPending(pr)
			return "", nil
		}
	}

	select {
	case resp := <-pr.respCh:
		if resp == "?;" {
			r.log.Debug("cat unsupported", zap.String("cmd", code))
			return "", errors.New("radio: command not supported")
		}
		r.log.Debug("cat recv", zap.String("cmd", code), zap.String("resp", resp))
		return resp, nil
	case <-time.After(r.timeoutFor(code)):
		r.clearPending(pr)
		r.log.Warn("cat timeout", zap.String("cmd", cmd))
		return "", ErrTimeout
	}
}

// clearPending drops pr from the pending slot unless a newer request has
// taken its place.
func (r *Radio) clearPending(pr *pendingReq) {
	r.pendingMu.Lock()
	if r.pending == pr {
		r.pending = nil
	}
	r.pendingMu.Unlock()
}

// isQueryCmd reports whether a normalized CAT command ("XX;" exactly) is a
// read; a longer command is a write. The caller must have appended ';' — the
// helper does not validate it. TX; and RX; are 3-char but are *set* commands:
// they answer only when the Auto Information function is ON, so waiting for
// an echo would time out. Treat them as fire-and-forget like other sets.
func isQueryCmd(cmd string) bool {
	if len(cmd) != 3 {
		return false
	}
	code := cmd[:2]
	return code != "TX" && code != "RX"
}

// timeoutFor returns the reply window for a command code. Powering on the rig
// takes several seconds (DSP boot), so the PS code gets a longer window.
func (r *Radio) timeoutFor(code string) time.Duration {
	if code == "PS" {
		return r.powerTimeout
	}
	return r.queryTimeout
}
