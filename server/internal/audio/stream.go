//go:build !noaudio

package audio

import (
	"fmt"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/gordonklaus/portaudio"
	"go.uber.org/zap"
	"gopkg.in/hraban/opus.v2"

	"github.com/bartek/ts590-remote/server/internal/protocol"
)

// Stream bridges the rig's USB audio device with the network:
//   - radio RX audio is captured, Opus-encoded, and sent downlink
//   - client uplink (mic) Opus is decoded and played to the rig's TX audio
type Stream struct {
	params   *protocol.OpusParams
	frameSize int // samples per channel
	frameLen  int // frameSize * channels
	enc       *opus.Encoder
	dec       *opus.Decoder

	pa       *portaudio.Stream
	encodeCh chan []int16
	uplink   *uplinkJB
	sendDown func(uint16, []byte)
	rxPaused *atomic.Bool

	seqMu sync.Mutex
	seq   uint16

	log    *zap.Logger
	closed chan struct{}
	once   sync.Once
}

// Open discovers the USB audio device, clamps the Opus parameters to its
// capabilities, and opens the full-duplex PortAudio stream. It returns the
// effective parameters the client must also use.
func Open(device string, req *protocol.OpusParams, sendDown func(uint16, []byte), rxPaused *atomic.Bool, log *zap.Logger) (*protocol.OpusParams, *Stream, error) {
	devs, err := portaudio.Devices()
	if err != nil {
		return nil, nil, err
	}
	// The rig may expose RX (playback) and TX (capture) as two separate USB
	// audio devices, so pick the input and output devices by name substring
	// independently instead of requiring a single full-duplex device.
	var inDev, outDev *portaudio.DeviceInfo
	target := strings.ToLower(strings.TrimSpace(device))
	for _, d := range devs {
		if strings.Contains(strings.ToLower(d.Name), target) {
			if d.MaxInputChannels > 0 && inDev == nil {
				inDev = d
			}
			if d.MaxOutputChannels > 0 && outDev == nil {
				outDev = d
			}
		}
	}
	if inDev == nil || outDev == nil {
		for _, d := range devs {
			log.Warn("audio device candidate",
				zap.String("name", d.Name),
				zap.Int("in", d.MaxInputChannels),
				zap.Int("out", d.MaxOutputChannels))
		}
		return nil, nil, fmt.Errorf("audio: need an input and output device matching %q (got in=%v out=%v)", device, inDev != nil, outDev != nil)
	}

	// Opus only supports mono/stereo; clamp the channel count to what both
	// devices actually support, and use the lower of the two sample rates.
	chCap := inDev.MaxInputChannels
	if outDev.MaxOutputChannels < chCap {
		chCap = outDev.MaxOutputChannels
	}
	if chCap < 1 {
		chCap = 1
	}
	devRate := int(inDev.DefaultSampleRate)
	if int(outDev.DefaultSampleRate) < devRate {
		devRate = int(outDev.DefaultSampleRate)
	}

	eff, _ := ClampParams(req, devRate, chCap)

	enc, err := opus.NewEncoder(eff.SampleRate, eff.Channels, opus.AppRestrictedLowdelay)
	if err != nil {
		return nil, nil, err
	}
	if err := enc.SetBitrate(eff.Bitrate); err != nil {
		return nil, nil, err
	}
	dec, err := opus.NewDecoder(eff.SampleRate, eff.Channels)
	if err != nil {
		return nil, nil, err
	}

	fs := FrameSize(eff.SampleRate, eff.FrameMs)
	s := &Stream{
		params:   eff,
		frameSize: fs,
		frameLen:  fs * eff.Channels,
		enc:       enc,
		dec:       dec,
		encodeCh:  make(chan []int16, 8),
		uplink:    newUplinkJB(fs * eff.Channels),
		sendDown:  sendDown,
		rxPaused:  rxPaused,
		log:       log,
		closed:    make(chan struct{}),
	}

	params := portaudio.StreamParameters{
		Input:  portaudio.StreamDeviceParameters{Device: inDev, Channels: eff.Channels, Latency: 0},
		Output: portaudio.StreamDeviceParameters{Device: outDev, Channels: eff.Channels, Latency: 0},
		SampleRate:     float64(eff.SampleRate),
		FramesPerBuffer: fs,
	}
	pa, err := portaudio.OpenStream(params, s.callback)
	if err != nil {
		return nil, nil, err
	}
	s.pa = pa
	go s.encodeLoop()
	return eff, s, nil
}

// Start begins audio flow.
func (s *Stream) Start() error { return s.pa.Start() }

// Close stops and releases the PortAudio stream.
func (s *Stream) Close() {
	s.once.Do(func() {
		close(s.closed)
		if s.pa != nil {
			_ = s.pa.Stop()
			_ = s.pa.Close()
		}
	})
}

// PushUplink decodes a received client Opus frame and queues it for playback.
func (s *Stream) PushUplink(seq uint16, data []byte) {
	pcm := make([]int16, s.frameLen)
	n, err := s.dec.Decode(data, pcm)
	if err != nil {
		return
	}
	pcm = pcm[:n*s.params.Channels]
	s.uplink.put(seq, pcm)
}

func (s *Stream) callback(in, out []float32, _ portaudio.StreamCallbackTimeInfo, _ portaudio.StreamCallbackFlags) {
	if len(in) > 0 {
		pcm := f32ToI16(in)
		select {
		case s.encodeCh <- pcm:
		default:
		}
	}
	if len(out) > 0 {
		f, ok := s.uplink.get()
		if ok && len(f) == len(out) {
			i16ToF32(f, out)
		} else {
			for i := range out {
				out[i] = 0
			}
		}
	}
}

func (s *Stream) encodeLoop() {
	for {
		select {
		case <-s.closed:
			return
		case pcm := <-s.encodeCh:
			if s.rxPaused != nil && s.rxPaused.Load() {
				continue // RX paused: do not consume downlink bandwidth
			}
			data := make([]byte, 4000)
			n, err := s.enc.Encode(pcm, data)
			if err != nil {
				continue
			}
			s.seqMu.Lock()
			s.seq++
			seq := s.seq
			s.seqMu.Unlock()
			s.sendDown(seq, data[:n])
		}
	}
}

// --- PCM helpers -------------------------------------------------------

func f32ToI16(in []float32) []int16 {
	out := make([]int16, len(in))
	for i, v := range in {
		if v > 1 {
			v = 1
		} else if v < -1 {
			v = -1
		}
		out[i] = int16(v * 32767)
	}
	return out
}

func i16ToF32(in []int16, out []float32) {
	for i, v := range in {
		out[i] = float32(v) / 32768.0
	}
}