//go:build !noaudio

package audio

import (
	"testing"

	"github.com/bartek/ts590-remote/server/internal/protocol"
)

func TestClampParams_NilRequest(t *testing.T) {
	eff, adjusted := ClampParams(nil, 48000, 2)
	if eff.SampleRate != 48000 {
		t.Errorf("SampleRate = %d, want 48000", eff.SampleRate)
	}
	if eff.Channels != 1 {
		t.Errorf("Channels = %d, want 1", eff.Channels)
	}
	if eff.FrameMs != 20 {
		t.Errorf("FrameMs = %d, want 20", eff.FrameMs)
	}
	if eff.Bitrate != 48000 {
		t.Errorf("Bitrate = %d, want 48000", eff.Bitrate)
	}
	if adjusted {
		t.Error("adjusted should be false for nil request")
	}
}

func TestClampParams_ValidRequest(t *testing.T) {
	req := &protocol.OpusParams{SampleRate: 16000, Channels: 2, FrameMs: 20, Bitrate: 32000}
	eff, adjusted := ClampParams(req, 48000, 2)
	if eff.SampleRate != 16000 {
		t.Errorf("SampleRate = %d, want 16000", eff.SampleRate)
	}
	if eff.Channels != 2 {
		t.Errorf("Channels = %d, want 2", eff.Channels)
	}
	if eff.FrameMs != 20 {
		t.Errorf("FrameMs = %d, want 20", eff.FrameMs)
	}
	if eff.Bitrate != 32000 {
		t.Errorf("Bitrate = %d, want 32000", eff.Bitrate)
	}
	if adjusted {
		t.Error("adjusted should be false for valid request")
	}
}

func TestClampParams_InvalidSampleRate(t *testing.T) {
	tests := []struct {
		reqRate  int
		devRate  int
		wantRate int
	}{
		{32000, 48000, 48000},  // invalid -> dev rate
		{32000, 16000, 16000},  // invalid -> dev rate
		{32000, 96000, 48000},  // invalid -> dev rate invalid -> default
		{0, 48000, 48000},      // zero -> default
	}
	for _, tt := range tests {
		req := &protocol.OpusParams{SampleRate: tt.reqRate, Channels: 1, FrameMs: 20, Bitrate: 48000}
		eff, _ := ClampParams(req, tt.devRate, 1)
		if eff.SampleRate != tt.wantRate {
			t.Errorf("ClampParams rate %d/dev %d: SampleRate = %d, want %d", tt.reqRate, tt.devRate, eff.SampleRate, tt.wantRate)
		}
	}
}

func TestClampParams_InvalidChannels(t *testing.T) {
	tests := []struct {
		reqCh    int
		devCh    int
		wantCh   int
	}{
		{0, 2, 1},   // zero -> default 1
		{3, 2, 2},   // >2 -> clamped to 2
		{2, 1, 1},   // >dev -> clamped to dev
		{1, 2, 1},   // valid
		{2, 2, 2},   // valid
		{-1, 2, 1},  // negative -> 1
	}
	for _, tt := range tests {
		req := &protocol.OpusParams{SampleRate: 48000, Channels: tt.reqCh, FrameMs: 20, Bitrate: 48000}
		eff, _ := ClampParams(req, 48000, tt.devCh)
		if eff.Channels != tt.wantCh {
			t.Errorf("ClampParams channels %d/dev %d: Channels = %d, want %d", tt.reqCh, tt.devCh, eff.Channels, tt.wantCh)
		}
	}
}

func TestClampParams_InvalidFrameMs(t *testing.T) {
	tests := []struct {
		reqFrame int
		want     int
	}{
		{0, 20},    // zero -> default
		{15, 20},   // invalid -> default
		{30, 20},   // invalid -> default
		{5, 5},     // valid
		{10, 10},   // valid
		{20, 20},   // valid
		{40, 40},   // valid
		{60, 60},   // valid
	}
	for _, tt := range tests {
		req := &protocol.OpusParams{SampleRate: 48000, Channels: 1, FrameMs: tt.reqFrame, Bitrate: 48000}
		eff, _ := ClampParams(req, 48000, 1)
		if eff.FrameMs != tt.want {
			t.Errorf("ClampParams frameMs %d: FrameMs = %d, want %d", tt.reqFrame, eff.FrameMs, tt.want)
		}
	}
}

func TestClampParams_InvalidBitrate(t *testing.T) {
	tests := []struct {
		reqBR  int
		wantBR int
	}{
		{0, 48000},     // zero -> default
		{100, 500},     // too low -> 500
		{400, 500},     // too low -> 500
		{500, 500},     // valid minimum
		{128000, 128000}, // valid maximum
		{200000, 128000}, // too high -> 128000
		{-1, 500},      // negative -> clamped to 500 (after < 500 check)
	}
	for _, tt := range tests {
		req := &protocol.OpusParams{SampleRate: 48000, Channels: 1, FrameMs: 20, Bitrate: tt.reqBR}
		eff, _ := ClampParams(req, 48000, 1)
		if eff.Bitrate != tt.wantBR {
			t.Errorf("ClampParams bitrate %d: Bitrate = %d, want %d", tt.reqBR, eff.Bitrate, tt.wantBR)
		}
	}
}

func TestClampParams_AdjustedFlag(t *testing.T) {
	// When any field differs from request, adjusted should be true.
	req := &protocol.OpusParams{SampleRate: 32000, Channels: 1, FrameMs: 20, Bitrate: 48000}
	eff, adjusted := ClampParams(req, 48000, 1)
	if !adjusted {
		t.Error("adjusted should be true when sample rate is clamped")
	}
	if eff.SampleRate != 48000 {
		t.Errorf("SampleRate = %d, want 48000", eff.SampleRate)
	}

	// When all fields match, adjusted should be false.
	req2 := &protocol.OpusParams{SampleRate: 16000, Channels: 1, FrameMs: 10, Bitrate: 32000}
	_, adjusted2 := ClampParams(req2, 48000, 2)
	if adjusted2 {
		t.Error("adjusted should be false when all fields are valid")
	}
}

func TestFrameSize(t *testing.T) {
	tests := []struct {
		rate  int
		frame int
		want  int
	}{
		{48000, 20, 960},
		{48000, 10, 480},
		{48000, 5, 240},
		{48000, 40, 1920},
		{48000, 60, 2880},
		{8000, 20, 160},
		{16000, 20, 320},
		{12000, 20, 240},
	}
	for _, tt := range tests {
		got := FrameSize(tt.rate, tt.frame)
		if got != tt.want {
			t.Errorf("FrameSize(%d, %d) = %d, want %d", tt.rate, tt.frame, got, tt.want)
		}
	}
}
