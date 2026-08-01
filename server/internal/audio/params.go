//go:build !noaudio

package audio

import "github.com/bartek/ts590-remote/server/internal/protocol"

var validRates = map[int]bool{8000: true, 12000: true, 16000: true, 24000: true, 48000: true}
var validFrames = map[int]bool{5: true, 10: true, 20: true, 40: true, 60: true}

// ClampParams reconciles a requested Opus configuration with the rig's
// USB audio device capabilities. The resulting values are what both sides
// must use so the encoder and decoder agree.
func ClampParams(req *protocol.OpusParams, devRate, devChannels int) (*protocol.OpusParams, bool) {
	eff := &protocol.OpusParams{}

	sr := 48000
	if req != nil && req.SampleRate != 0 {
		sr = req.SampleRate
	}
	if !validRates[sr] {
		if validRates[devRate] {
			sr = devRate
		} else {
			sr = 48000
		}
	}
	eff.SampleRate = sr

	ch := 1
	if req != nil && req.Channels != 0 {
		ch = req.Channels
	}
	if ch < 1 {
		ch = 1
	}
	if ch > 2 {
		// Opus only supports mono or stereo.
		ch = 2
	}
	if ch > devChannels {
		ch = devChannels
	}
	if ch < 1 {
		ch = 1
	}
	eff.Channels = ch

	fm := 20
	if req != nil && req.FrameMs != 0 {
		fm = req.FrameMs
	}
	if !validFrames[fm] {
		fm = 20
	}
	eff.FrameMs = fm

	br := 48000
	if req != nil && req.Bitrate != 0 {
		br = req.Bitrate
	}
	if br < 500 {
		br = 500
	}
	if br > 128000 {
		br = 128000
	}
	eff.Bitrate = br

	adjusted := false
	if req != nil {
		if req.SampleRate != eff.SampleRate ||
			req.Channels != eff.Channels ||
			req.FrameMs != eff.FrameMs ||
			req.Bitrate != eff.Bitrate {
			adjusted = true
		}
	}
	return eff, adjusted
}

// FrameSize returns the number of samples per channel per Opus frame.
func FrameSize(sampleRate, frameMs int) int {
	return sampleRate * frameMs / 1000
}