package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoad_Defaults(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "server.yaml")
	content := `
radio:
  port: /dev/ttyACM0
network:
  psk: secret123
`
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		t.Fatalf("WriteFile failed: %v", err)
	}

	c, err := Load(path)
	if err != nil {
		t.Fatalf("Load failed: %v", err)
	}

	// Explicitly set values.
	if c.Radio.Port != "/dev/ttyACM0" {
		t.Errorf("Radio.Port = %q, want %q", c.Radio.Port, "/dev/ttyACM0")
	}
	if c.Network.PSK != "secret123" {
		t.Errorf("Network.PSK = %q, want %q", c.Network.PSK, "secret123")
	}

	// Defaults applied.
	if c.Radio.Baud != 115200 {
		t.Errorf("Radio.Baud = %d, want 115200", c.Radio.Baud)
	}
	if c.Radio.PowerOnConnect {
		t.Error("Radio.PowerOnConnect should default to false")
	}
	if c.Audio.SampleRate != 48000 {
		t.Errorf("Audio.SampleRate = %d, want 48000", c.Audio.SampleRate)
	}
	if c.Audio.Channels != 1 {
		t.Errorf("Audio.Channels = %d, want 1", c.Audio.Channels)
	}
	if c.Audio.OpusFrameMs != 20 {
		t.Errorf("Audio.OpusFrameMs = %d, want 20", c.Audio.OpusFrameMs)
	}
	if c.Audio.OpusBitrate != 48000 {
		t.Errorf("Audio.OpusBitrate = %d, want 48000", c.Audio.OpusBitrate)
	}
	if c.Audio.JitterFrames != 2 {
		t.Errorf("Audio.JitterFrames = %d, want 2", c.Audio.JitterFrames)
	}
	if c.Audio.JitterMinFrames != 1 {
		t.Errorf("Audio.JitterMinFrames = %d, want 1", c.Audio.JitterMinFrames)
	}
	if c.Audio.JitterMaxFrames != 64 {
		t.Errorf("Audio.JitterMaxFrames = %d, want 64", c.Audio.JitterMaxFrames)
	}
	if c.Audio.Gain != 1.0 {
		t.Errorf("Audio.Gain = %v, want 1.0", c.Audio.Gain)
	}
	if c.Network.ControlAddr != "0.0.0.0:5900" {
		t.Errorf("Network.ControlAddr = %q, want %q", c.Network.ControlAddr, "0.0.0.0:5900")
	}
	if c.Network.AudioAddr != "0.0.0.0:5901" {
		t.Errorf("Network.AudioAddr = %q, want %q", c.Network.AudioAddr, "0.0.0.0:5901")
	}
}

func TestLoad_FullConfig(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "server.yaml")
	content := `
radio:
  port: /dev/ttyUSB0
  baud: 9600
  powerOnConnect: true
audio:
  device: "USB Audio Device"
  sampleRate: 16000
  channels: 2
  opusFrameMs: 40
  opusBitrate: 32000
  jitterFrames: 4
  jitterMinFrames: 2
  jitterMaxFrames: 16
network:
  controlAddr: "127.0.0.1:5900"
  audioAddr: "127.0.0.1:5901"
  psk: mysecret
`
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		t.Fatalf("WriteFile failed: %v", err)
	}

	c, err := Load(path)
	if err != nil {
		t.Fatalf("Load failed: %v", err)
	}

	if c.Radio.Port != "/dev/ttyUSB0" {
		t.Errorf("Radio.Port = %q, want %q", c.Radio.Port, "/dev/ttyUSB0")
	}
	if c.Radio.Baud != 9600 {
		t.Errorf("Radio.Baud = %d, want 9600", c.Radio.Baud)
	}
	if !c.Radio.PowerOnConnect {
		t.Error("Radio.PowerOnConnect should be true")
	}
	if c.Audio.Device != "USB Audio Device" {
		t.Errorf("Audio.Device = %q, want %q", c.Audio.Device, "USB Audio Device")
	}
	if c.Audio.SampleRate != 16000 {
		t.Errorf("Audio.SampleRate = %d, want 16000", c.Audio.SampleRate)
	}
	if c.Audio.Channels != 2 {
		t.Errorf("Audio.Channels = %d, want 2", c.Audio.Channels)
	}
	if c.Audio.OpusFrameMs != 40 {
		t.Errorf("Audio.OpusFrameMs = %d, want 40", c.Audio.OpusFrameMs)
	}
	if c.Audio.OpusBitrate != 32000 {
		t.Errorf("Audio.OpusBitrate = %d, want 32000", c.Audio.OpusBitrate)
	}
	if c.Audio.JitterFrames != 4 {
		t.Errorf("Audio.JitterFrames = %d, want 4", c.Audio.JitterFrames)
	}
	if c.Audio.JitterMinFrames != 2 {
		t.Errorf("Audio.JitterMinFrames = %d, want 2", c.Audio.JitterMinFrames)
	}
	if c.Audio.JitterMaxFrames != 16 {
		t.Errorf("Audio.JitterMaxFrames = %d, want 16", c.Audio.JitterMaxFrames)
	}
	if c.Network.ControlAddr != "127.0.0.1:5900" {
		t.Errorf("Network.ControlAddr = %q, want %q", c.Network.ControlAddr, "127.0.0.1:5900")
	}
	if c.Network.AudioAddr != "127.0.0.1:5901" {
		t.Errorf("Network.AudioAddr = %q, want %q", c.Network.AudioAddr, "127.0.0.1:5901")
	}
	if c.Network.PSK != "mysecret" {
		t.Errorf("Network.PSK = %q, want %q", c.Network.PSK, "mysecret")
	}
}

func TestLoad_FileNotFound(t *testing.T) {
	_, err := Load("/nonexistent/path/server.yaml")
	if err == nil {
		t.Fatal("Load should return error for nonexistent file")
	}
}

func TestLoad_InvalidYAML(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "server.yaml")
	content := `
radio:
  port: /dev/ttyACM0
  baud: [invalid
`
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		t.Fatalf("WriteFile failed: %v", err)
	}

	_, err := Load(path)
	if err == nil {
		t.Fatal("Load should return error for invalid YAML")
	}
}
