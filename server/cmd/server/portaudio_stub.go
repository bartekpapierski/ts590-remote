//go:build noaudio

package main

import "go.uber.org/zap"

// initAudioStack is a no-op when built with the noaudio tag (no cgo,
// PortAudio or Opus): the headless control/CAT/auth build must run on
// machines without audio hardware.
func initAudioStack(_ *zap.Logger) (func() error, error) {
	return func() error { return nil }, nil
}
