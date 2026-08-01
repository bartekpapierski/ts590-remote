//go:build !noaudio

package main

import (
	"github.com/gordonklaus/portaudio"
	"go.uber.org/zap"
)

// initAudioStack initializes PortAudio and logs the available devices.
// It returns a cleanup function (portaudio.Terminate).
func initAudioStack(log *zap.Logger) (func() error, error) {
	if err := portaudio.Initialize(); err != nil {
		return nil, err
	}
	if devs, err := portaudio.Devices(); err == nil {
		for _, d := range devs {
			log.Info("audio device",
				zap.String("name", d.Name),
				zap.Int("in", d.MaxInputChannels),
				zap.Int("out", d.MaxOutputChannels))
		}
	}
	return portaudio.Terminate, nil
}
