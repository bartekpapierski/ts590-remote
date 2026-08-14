//go:build !noaudio

package audio

import (
	"fmt"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gordonklaus/portaudio"
	"go.uber.org/zap"
	"gopkg.in/hraban/opus.v2"

	"github.com/bartek/ts590-remote/server/internal/protocol"
)

// Stream bridges the rig's USB audio device with the network:
//   - radio RX audio is captured, Opus-encoded, and sent downlink
//   - client uplink (mic) Opus is decoded and played to the rig's TX audio
type Stream struct {
	params    *protocol.OpusParams
	frameSize int // samples per channel
	frameLen  int // frameSize * channels
	enc       *opus.Encoder
	dec       *opus.Decoder

	pa       *portaudio.Stream
	uplink   *uplinkJB
	sendDown func(uint16, []byte)
	rxPaused *atomic.Bool

	inMu   sync.Mutex
	inBuf  []int16
	inWake chan struct{}

	seqMu sync.Mutex
	seq   uint16

	log        *zap.Logger
	closed     chan struct{}
	once       sync.Once
	dumpRaw    *os.File
	dumpBytes  int
	dumpCapped bool
	gain       float32 // PCM multiplier applied before encoding
}

// Open discovers the USB audio device, clamps the Opus parameters to its
// capabilities, and opens the full-duplex PortAudio stream. It returns the
// effective parameters the client must also use.
func Open(device string, req *protocol.OpusParams, gain float32, jitter, jitterMin, jitterMax int, sendDown func(uint16, []byte), rxPaused *atomic.Bool, log *zap.Logger) (*protocol.OpusParams, *Stream, error) {
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

	enc, err := opus.NewEncoder(eff.SampleRate, eff.Channels, opus.AppAudio)
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
		params:    eff,
		frameSize: fs,
		frameLen:  fs * eff.Channels,
		enc:       enc,
		dec:       dec,
		inWake:    make(chan struct{}, 1),
		uplink:    newUplinkJBDepth(fs*eff.Channels, jitter, jitterMin, jitterMax),
		sendDown:  sendDown,
		rxPaused:  rxPaused,
		log:       log,
		gain:      gain,
		closed:    make(chan struct{}),
	}

	// Env var overrides the config value (useful for one-off testing).
	if g := os.Getenv("TS590_AUDIO_GAIN"); g != "" {
		if v, err := fmt.Sscanf(g, "%f", &s.gain); err == nil && v == 1 {
			if s.gain < 0 {
				s.gain = 0
			}
			if s.gain > 2 {
				s.gain = 2
			}
		}
	}
	if s.gain != 1.0 {
		log.Info("audio gain", zap.Float32("gain", s.gain))
	}

	if p := os.Getenv("TS590_DUMP_PCM"); p != "" {
		f, err := os.Create(p)
		if err == nil {
			s.dumpRaw = f
			log.Info("dumping raw PCM (capped)", zap.String("path", p))
		}
	}

	params := portaudio.StreamParameters{
		Input:           portaudio.StreamDeviceParameters{Device: inDev, Channels: eff.Channels, Latency: 0},
		Output:          portaudio.StreamDeviceParameters{Device: outDev, Channels: eff.Channels, Latency: 0},
		SampleRate:      float64(eff.SampleRate),
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
func (s *Stream) Start() error {
	if err := s.pa.Start(); err != nil {
		return err
	}
	go s.statsLoop()
	return nil
}

// jitterStatsInterval controls how often the uplink jitter buffer is logged.
const jitterStatsInterval = 5 * time.Second

// statsLoop periodically logs the uplink jitter buffer so an operator can see
// it adapting to the live connection.
func (s *Stream) statsLoop() {
	t := time.NewTicker(jitterStatsInterval)
	defer t.Stop()
	for {
		select {
		case <-s.closed:
			return
		case <-t.C:
			st := s.uplink.stats()
			s.log.Info("uplink jitter",
				zap.Int("depth", st.Depth),
				zap.Int("min", st.MinDepth),
				zap.Int("max", st.MaxDepth),
				zap.Bool("started", st.Started),
				zap.Int64("dropouts", st.Dropouts),
				zap.Int64("skips", st.Skips),
				zap.Int64("late", st.Late),
				zap.Int("fill", st.Fill),
				zap.Int("occupancy", st.Occupancy))
		}
	}
}

// Close stops and releases the PortAudio stream.
func (s *Stream) Close() {
	s.once.Do(func() {
		close(s.closed)
		if s.dumpRaw != nil {
			s.dumpRaw.Close()
		}
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
		pcm := f32ToI16(in, s.gain)
		if s.dumpRaw != nil {
			if s.dumpBytes < 30*48000*s.params.Channels*2 { // ~30 s
				n, _ := s.dumpRaw.Write(u16ToBytes(pcm))
				s.dumpBytes += n
			} else if !s.dumpCapped {
				s.dumpCapped = true
				s.dumpRaw.Close()
				s.dumpRaw = nil
			}
		}
		s.inMu.Lock()
		s.inBuf = append(s.inBuf, pcm...)
		s.inMu.Unlock()
		// Non-blocking wake: if a wake signal is already pending, skip.
		select {
		case s.inWake <- struct{}{}:
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
	const maxPending = 1 << 19
	for {
		select {
		case <-s.closed:
			return
		case <-s.inWake:
			if s.rxPaused != nil && s.rxPaused.Load() {
				continue
			}
			s.inMu.Lock()
			buf := s.inBuf
			s.inBuf = nil
			s.inMu.Unlock()

			if len(buf) > maxPending {
				excess := len(buf) - maxPending
				excess -= excess % s.params.Channels
				buf = buf[excess:]
			}

			for len(buf) >= s.frameLen {
				frame := buf[:s.frameLen]
				buf = buf[s.frameLen:]

				data := make([]byte, 4000)
				n, err := s.enc.Encode(frame, data)
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
}

// --- PCM helpers -------------------------------------------------------

func f32ToI16(in []float32, gain float32) []int16 {
	out := make([]int16, len(in))
	for i, v := range in {
		v *= gain
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

func u16ToBytes(samples []int16) []byte {
	b := make([]byte, len(samples)*2)
	for i, v := range samples {
		b[i*2] = byte(v)
		b[i*2+1] = byte(v >> 8)
	}
	return b
}
