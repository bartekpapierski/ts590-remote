package config

import (
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

type Config struct {
	Radio   RadioConfig   `yaml:"radio"`
	Audio   AudioConfig   `yaml:"audio"`
	Network NetworkConfig `yaml:"network"`
}

type RadioConfig struct {
	Port           string `yaml:"port"`
	Baud           int    `yaml:"baud"`
	PowerOnConnect bool   `yaml:"powerOnConnect"`
}

type AudioConfig struct {
	Device       string `yaml:"device"`
	SampleRate   int    `yaml:"sampleRate"`
	Channels     int    `yaml:"channels"`
	OpusFrameMs  int    `yaml:"opusFrameMs"`
	OpusBitrate  int    `yaml:"opusBitrate"`
	JitterFrames int    `yaml:"jitterFrames"`
}

type NetworkConfig struct {
	ControlAddr string `yaml:"controlAddr"`
	AudioAddr   string `yaml:"audioAddr"`
	PSK         string `yaml:"psk"`
}

func Load(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config %q: %w", path, err)
	}
	var c Config
	if err := yaml.Unmarshal(data, &c); err != nil {
		return nil, fmt.Errorf("parse config %q: %w", path, err)
	}
	if c.Radio.Baud == 0 {
		c.Radio.Baud = 115200
	}
	if c.Audio.SampleRate == 0 {
		c.Audio.SampleRate = 48000
	}
	if c.Audio.Channels == 0 {
		c.Audio.Channels = 1
	}
	if c.Audio.OpusFrameMs == 0 {
		c.Audio.OpusFrameMs = 20
	}
	if c.Audio.OpusBitrate == 0 {
		c.Audio.OpusBitrate = 48000
	}
	if c.Audio.JitterFrames == 0 {
		c.Audio.JitterFrames = 2
	}
	if c.Network.ControlAddr == "" {
		c.Network.ControlAddr = "0.0.0.0:5900"
	}
	if c.Network.AudioAddr == "" {
		c.Network.AudioAddr = "0.0.0.0:5901"
	}
	return &c, nil
}
