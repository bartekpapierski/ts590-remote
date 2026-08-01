package protocol

import (
	"encoding/json"
	"testing"
)

func TestMsgAuthOK(t *testing.T) {
	m := MsgAuthOK()
	if m.T != "auth_ok" {
		t.Errorf("T = %q, want %q", m.T, "auth_ok")
	}
}

func TestMsgAuthFail(t *testing.T) {
	m := MsgAuthFail()
	if m.T != "auth_fail" {
		t.Errorf("T = %q, want %q", m.T, "auth_fail")
	}
}

func TestMsgError(t *testing.T) {
	m := MsgError("something broke")
	if m.T != "error" {
		t.Errorf("T = %q, want %q", m.T, "error")
	}
	if m.Msg != "something broke" {
		t.Errorf("Msg = %q, want %q", m.Msg, "something broke")
	}
}

func TestMsgCatResp(t *testing.T) {
	m := MsgCatResp("FA00014000000;")
	if m.T != "cat_resp" {
		t.Errorf("T = %q, want %q", m.T, "cat_resp")
	}
	if m.Raw != "FA00014000000;" {
		t.Errorf("Raw = %q, want %q", m.Raw, "FA00014000000;")
	}
}

func TestMsgCatEvent(t *testing.T) {
	m := MsgCatEvent("MD1;")
	if m.T != "cat_event" {
		t.Errorf("T = %q, want %q", m.T, "cat_event")
	}
	if m.Raw != "MD1;" {
		t.Errorf("Raw = %q, want %q", m.Raw, "MD1;")
	}
}

func TestMsgState(t *testing.T) {
	s := &RadioState{FreqA: 14000000, Mode: "USB", PTT: true}
	m := MsgState(s)
	if m.T != "state" {
		t.Errorf("T = %q, want %q", m.T, "state")
	}
	if m.State == nil {
		t.Fatal("State should not be nil")
	}
	if m.State.FreqA != 14000000 {
		t.Errorf("State.FreqA = %d, want 14000000", m.State.FreqA)
	}
	if m.State.Mode != "USB" {
		t.Errorf("State.Mode = %q, want %q", m.State.Mode, "USB")
	}
	if !m.State.PTT {
		t.Error("State.PTT should be true")
	}
}

func TestMsgAudioStatus(t *testing.T) {
	m := MsgAudioStatus("started")
	if m.T != "audio" {
		t.Errorf("T = %q, want %q", m.T, "audio")
	}
	if m.Status != "started" {
		t.Errorf("Status = %q, want %q", m.Status, "started")
	}
}

func TestMsgAudioRxStatus(t *testing.T) {
	m := MsgAudioRxStatus("paused")
	if m.T != "audio_rx" {
		t.Errorf("T = %q, want %q", m.T, "audio_rx")
	}
	if m.Status != "paused" {
		t.Errorf("Status = %q, want %q", m.Status, "paused")
	}
}

func TestMsgAudioParams(t *testing.T) {
	p := &OpusParams{SampleRate: 16000, Channels: 2, FrameMs: 20, Bitrate: 32000}
	m := MsgAudioParams(p, true)
	if m.T != "audio_params" {
		t.Errorf("T = %q, want %q", m.T, "audio_params")
	}
	if m.SampleRate != 16000 {
		t.Errorf("SampleRate = %d, want 16000", m.SampleRate)
	}
	if m.Channels != 2 {
		t.Errorf("Channels = %d, want 2", m.Channels)
	}
	if m.FrameMs != 20 {
		t.Errorf("FrameMs = %d, want 20", m.FrameMs)
	}
	if m.Bitrate != 32000 {
		t.Errorf("Bitrate = %d, want 32000", m.Bitrate)
	}
	if !m.Adjusted {
		t.Error("Adjusted should be true")
	}
}

func TestMsgPTTAck(t *testing.T) {
	m := MsgPTTAck(true)
	if m.T != "ptt_ack" {
		t.Errorf("T = %q, want %q", m.T, "ptt_ack")
	}
	if m.On == nil {
		t.Fatal("On should not be nil")
	}
	if !*m.On {
		t.Error("On should be true")
	}

	m2 := MsgPTTAck(false)
	if m2.On == nil || *m2.On {
		t.Error("On should be false")
	}
}

func TestMessageJSONRoundTrip(t *testing.T) {
	original := Message{
		T:      "cat",
		Cmd:    "FA00014000000;",
		Raw:    "FA00014000000;",
		Status: "started",
	}
	data, err := json.Marshal(original)
	if err != nil {
		t.Fatalf("json.Marshal failed: %v", err)
	}
	var decoded Message
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("json.Unmarshal failed: %v", err)
	}
	if decoded.T != original.T {
		t.Errorf("T = %q, want %q", decoded.T, original.T)
	}
	if decoded.Cmd != original.Cmd {
		t.Errorf("Cmd = %q, want %q", decoded.Cmd, original.Cmd)
	}
	if decoded.Raw != original.Raw {
		t.Errorf("Raw = %q, want %q", decoded.Raw, original.Raw)
	}
	if decoded.Status != original.Status {
		t.Errorf("Status = %q, want %q", decoded.Status, original.Status)
	}
}

func TestMessageJSONOmitEmpty(t *testing.T) {
	// Fields with omitempty should not appear when zero-valued.
	m := Message{T: "auth_ok"}
	data, err := json.Marshal(m)
	if err != nil {
		t.Fatalf("json.Marshal failed: %v", err)
	}
	s := string(data)
	if contains(s, "cmd") {
		t.Errorf("omitempty failed: %q contains 'cmd'", s)
	}
	if contains(s, "raw") {
		t.Errorf("omitempty failed: %q contains 'raw'", s)
	}
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || (len(s) > 0 && stringContains(s, substr)))
}

func stringContains(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}
