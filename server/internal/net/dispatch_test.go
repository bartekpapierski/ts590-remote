package net

import (
	"errors"
	"reflect"
	"testing"

	"go.uber.org/zap"

	"github.com/bartek/ts590-remote/server/internal/protocol"
)

var (
	errFakeRig   = errors.New("radio: command timeout")
	errFakeAudio = errors.New("audio start failed")
)

// fakeRig implements RigIf. The zero value returns empty responses.
type fakeRig struct {
	sendCmd  string
	sendResp string
	sendErr  error
	pttOn    bool
	pttErr   error
	state    protocol.RigState
	events   chan string
}

func (f *fakeRig) Send(cmd string) (string, error) {
	f.sendCmd = cmd
	return f.sendResp, f.sendErr
}

func (f *fakeRig) SetPTT(on bool) error {
	f.pttOn = on
	return f.pttErr
}

func (f *fakeRig) GetState() *protocol.RigState { return &f.state }

func (f *fakeRig) Events() <-chan string { return f.events }

// fakeAudio implements AudioIf.
type fakeAudio struct {
	startReq *protocol.OpusParams
	startEff *protocol.OpusParams
	adjusted bool
	startErr error
	rxPaused bool
	uplink   []byte
}

func (f *fakeAudio) Start(req *protocol.OpusParams) (*protocol.OpusParams, bool, error) {
	f.startReq = req
	if f.startEff == nil {
		f.startEff = req
	}
	return f.startEff, f.adjusted, f.startErr
}

func (f *fakeAudio) Stop() {}

func (f *fakeAudio) Running() bool { return f.startEff != nil }

func (f *fakeAudio) PauseRx(pause bool) { f.rxPaused = pause }

func (f *fakeAudio) RxPaused() bool { return f.rxPaused }

func (f *fakeAudio) PushUplink(seq uint16, data []byte) { f.uplink = data }

// collectSend returns a send func that appends every message it receives.
func collectSend() (func(protocol.Message), *[]protocol.Message) {
	var out []protocol.Message
	return func(m protocol.Message) { out = append(out, m) }, &out
}

func boolPtr(b bool) *bool { return &b }

func TestDispatch(t *testing.T) {
	tests := []struct {
		name string
		rig  *fakeRig // nil means radio not connected
		audio *fakeAudio
		msg   protocol.Message
		want  []protocol.Message
	}{
		{
			name:  "cat command",
			rig:   &fakeRig{sendResp: "FA1400000000;"},
			audio: &fakeAudio{},
			msg:   protocol.Message{T: "cat", Cmd: "FA;"},
			want:  []protocol.Message{protocol.MsgCatResp("FA1400000000;")},
		},
		{
			name:  "cat without radio",
			rig:   nil,
			audio: &fakeAudio{},
			msg:   protocol.Message{T: "cat", Cmd: "FA;"},
			want:  []protocol.Message{protocol.MsgError("radio not connected")},
		},
		{
			name:  "cat with send error",
			rig:   &fakeRig{sendErr: errFakeRig},
			audio: &fakeAudio{},
			msg:   protocol.Message{T: "cat", Cmd: "FA;"},
			want:  []protocol.Message{protocol.MsgError("radio: command timeout")},
		},
		{
			name:  "audio start",
			rig:   &fakeRig{},
			audio: &fakeAudio{},
			msg: protocol.Message{
				T:      "audio",
				Action: "start",
				Opus:   &protocol.OpusParams{SampleRate: 48000, Channels: 1, FrameMs: 20, Bitrate: 48000},
			},
			want: []protocol.Message{
				protocol.MsgAudioParams(&protocol.OpusParams{SampleRate: 48000, Channels: 1, FrameMs: 20, Bitrate: 48000}, false),
				protocol.MsgAudioStatus("started"),
			},
		},
		{
			name:  "audio start failure",
			rig:   &fakeRig{},
			audio: &fakeAudio{startErr: errFakeAudio},
			msg:   protocol.Message{T: "audio", Action: "start"},
			want:  []protocol.Message{protocol.MsgError("audio start failed")},
		},
		{
			name:  "audio stop",
			rig:   &fakeRig{},
			audio: &fakeAudio{startEff: &protocol.OpusParams{}},
			msg:   protocol.Message{T: "audio", Action: "stop"},
			want:  []protocol.Message{protocol.MsgAudioStatus("stopped")},
		},
		{
			name:  "audio_rx pause",
			rig:   &fakeRig{},
			audio: &fakeAudio{},
			msg:   protocol.Message{T: "audio_rx", Action: "pause"},
			want:  []protocol.Message{protocol.MsgAudioRxStatus("paused")},
		},
		{
			name:  "audio_rx resume",
			rig:   &fakeRig{},
			audio: &fakeAudio{rxPaused: true},
			msg:   protocol.Message{T: "audio_rx", Action: "resume"},
			want:  []protocol.Message{protocol.MsgAudioRxStatus("running")},
		},
		{
			name:  "ptt on",
			rig:   &fakeRig{},
			audio: &fakeAudio{},
			msg:   protocol.Message{T: "ptt", On: boolPtr(true)},
			want:  []protocol.Message{protocol.MsgPTTAck(true)},
		},
		{
			name:  "ptt without radio",
			rig:   nil,
			audio: &fakeAudio{},
			msg:   protocol.Message{T: "ptt", On: boolPtr(true)},
			want:  []protocol.Message{protocol.MsgError("radio not connected")},
		},
		{
			name:  "state_req",
			rig:   &fakeRig{state: protocol.RigState{FreqA: 14000000}},
			audio: &fakeAudio{rxPaused: true, startEff: &protocol.OpusParams{}},
			msg:   protocol.Message{T: "state_req"},
			want: []protocol.Message{protocol.MsgState(&protocol.RigState{
				FreqA:    14000000,
				AudioOn:  true,
				RxPaused: true,
			})},
		},
		{
			name:  "unknown type sends nothing",
			rig:   &fakeRig{},
			audio: &fakeAudio{},
			msg:   protocol.Message{T: "bogus"},
			want:  nil,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var rig RigIf
			if tc.rig != nil {
				rig = tc.rig
			}
			var audio AudioIf
			if tc.audio != nil {
				audio = tc.audio
			}
			c := &ControlServer{rig: rig, audioMgr: audio, log: zap.NewNop()}
			send, got := collectSend()
			c.dispatch(tc.msg, send, zap.NewNop())
			if !reflect.DeepEqual(*got, tc.want) {
				t.Fatalf("got %+v, want %+v", *got, tc.want)
			}
		})
	}
}
