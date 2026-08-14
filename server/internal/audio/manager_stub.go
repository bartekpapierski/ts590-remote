//go:build noaudio

package audio

import (
	"github.com/bartek/ts590-remote/server/internal/protocol"
	"go.uber.org/zap"
)

// Manager is a no-op stand-in used when the server is built with the
// `noaudio` build tag (no cgo / PortAudio / Opus). Control, CAT and auth
// still work; audio start/stop are accepted but produce no real stream.
type Manager struct{}

func NewManager(def *protocol.OpusParams, device string, gain float32, jitter, jitterMin, jitterMax int, sendDown func(uint16, []byte), log *zap.Logger) *Manager {
	return &Manager{}
}

func (m *Manager) SetSendDown(fn func(uint16, []byte)) {}

func (m *Manager) Start(req *protocol.OpusParams) (*protocol.OpusParams, bool, error) {
	eff := &protocol.OpusParams{SampleRate: 48000, Channels: 1, FrameMs: 20, Bitrate: 48000}
	if req != nil {
		eff = req
	}
	return eff, false, nil
}

func (m *Manager) Stop()                          {}
func (m *Manager) Running() bool                  { return false }
func (m *Manager) PauseRx(pause bool)             {}
func (m *Manager) RxPaused() bool                 { return false }
func (m *Manager) PushUplink(seq uint16, data []byte) {}
func (m *Manager) Stats() protocol.Stats          { return protocol.Stats{} }
