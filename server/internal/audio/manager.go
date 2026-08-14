//go:build !noaudio

package audio

import (
	"sync"
	"sync/atomic"

	"go.uber.org/zap"

	"github.com/bartek/ts590-remote/server/internal/protocol"
)

// Manager owns the audio stream lifecycle. It is safe for concurrent use.
type Manager struct {
	mu        sync.Mutex
	def       *protocol.OpusParams
	device    string
	gain      float32
	jitter    int
	jitterMin int
	jitterMax int
	sendDown  func(uint16, []byte)
	rxPaused  atomic.Bool

	stream  *Stream
	running bool
	params  *protocol.OpusParams

	log *zap.Logger
}

func NewManager(def *protocol.OpusParams, device string, gain float32, jitter, jitterMin, jitterMax int, sendDown func(uint16, []byte), log *zap.Logger) *Manager {
	if def == nil {
		def = &protocol.OpusParams{SampleRate: 48000, Channels: 1, FrameMs: 20, Bitrate: 48000}
	}
	if gain <= 0 {
		gain = 1.0
	}
	return &Manager{def: def, device: device, gain: gain, jitter: jitter, jitterMin: jitterMin, jitterMax: jitterMax, sendDown: sendDown, log: log}
}

// SetSendDown wires the downlink sender (the UDP server) after both exist.
func (m *Manager) SetSendDown(fn func(uint16, []byte)) { m.sendDown = fn }

// Start opens the audio stream, clamping the requested Opus parameters to
// the rig device. It returns the effective parameters and whether they were
// adjusted from the request.
func (m *Manager) Start(req *protocol.OpusParams) (*protocol.OpusParams, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.running {
		return m.params, false, nil
	}
	if req == nil {
		req = m.def
	}
	eff, st, err := Open(m.device, req, m.gain, m.jitter, m.jitterMin, m.jitterMax, m.sendDown, &m.rxPaused, m.log)
	if err != nil {
		return nil, false, err
	}
	m.stream = st
	m.params = eff
	m.running = true
	if err := st.Start(); err != nil {
		st.Close()
		m.stream = nil
		m.running = false
		return nil, false, err
	}
	adjusted := req != nil && *req != *eff
	return eff, adjusted, nil
}

// Stop tears down the audio stream.
func (m *Manager) Stop() {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.stream != nil {
		m.stream.Close()
		m.stream = nil
	}
	m.running = false
}

func (m *Manager) Running() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.running
}

// PauseRx stops the server sending the downlink (incoming) audio stream,
// saving bandwidth while you are away. Control + TX still work.
func (m *Manager) PauseRx(pause bool) { m.rxPaused.Store(pause) }

func (m *Manager) RxPaused() bool { return m.rxPaused.Load() }

// PushUplink feeds a decoded mic frame from the network into the stream.
func (m *Manager) PushUplink(seq uint16, data []byte) {
	m.mu.Lock()
	st := m.stream
	m.mu.Unlock()
	if st != nil {
		st.PushUplink(seq, data)
	}
}