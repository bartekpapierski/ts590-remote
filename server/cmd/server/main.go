package main

import (
	"flag"
	"os"
	"os/signal"

	"go.uber.org/zap"

	"github.com/bartek/ts590-remote/server/internal/audio"
	"github.com/bartek/ts590-remote/server/internal/config"
	netpkg "github.com/bartek/ts590-remote/server/internal/net"
	"github.com/bartek/ts590-remote/server/internal/protocol"
	"github.com/bartek/ts590-remote/server/internal/radio"
)

func main() {
	cfgPath := flag.String("config", "server.yaml", "path to config file")
	flag.Parse()

	cfg, err := config.Load(*cfgPath)
	if err != nil {
		cfg = &config.Config{} // defaults applied by Load are skipped on error; set them here
		cfg.Radio.Baud = 115200
		cfg.Audio.SampleRate = 48000
		cfg.Audio.Channels = 1
		cfg.Audio.OpusFrameMs = 20
		cfg.Audio.OpusBitrate = 48000
		cfg.Audio.JitterFrames = 2
		cfg.Network.ControlAddr = "0.0.0.0:5900"
		cfg.Network.AudioAddr = "0.0.0.0:5901"
	}

	logger, err := zap.NewProduction()
	if os.Getenv("TS590_DEBUG") != "" {
		logger, err = zap.NewDevelopment()
	}
	if err != nil {
		_, _ = os.Stderr.WriteString("logger init: " + err.Error() + "\n")
		os.Exit(1)
	}
	defer func() { _ = logger.Sync() }()

	cleanupAudio, err := initAudioStack(logger)
	if err != nil {
		logger.Fatal("portaudio init failed", zap.Error(err))
	}
	defer func() { _ = cleanupAudio() }()

	var radIf netpkg.RadioIf
	var rad *radio.Radio
	if r, err := radio.Open(cfg.Radio.Port, cfg.Radio.Baud); err != nil {
		logger.Warn("radio not opened; CAT disabled", zap.Error(err), zap.String("port", cfg.Radio.Port))
	} else {
		r.SetLogger(logger)
		if cfg.Radio.PowerOnConnect {
			if err := r.Power(true); err != nil {
				logger.Warn("power on failed", zap.Error(err))
			}
		}
		rad = r
		radIf = r
	}

	def := &protocol.OpusParams{
		SampleRate: cfg.Audio.SampleRate,
		Channels:   cfg.Audio.Channels,
		FrameMs:    cfg.Audio.OpusFrameMs,
		Bitrate:    cfg.Audio.OpusBitrate,
	}

	mgr := audio.NewManager(def, cfg.Audio.Device, nil, logger)
	udp, err := netpkg.NewUDPServer(cfg.Network.AudioAddr, mgr, logger)
	if err != nil {
		logger.Fatal("udp server failed", zap.Error(err))
	}
	mgr.SetSendDown(udp.SendDownlink)

	ctrl := netpkg.NewControlServer(cfg.Network, radIf, mgr, logger)
	if err := ctrl.Listen(); err != nil {
		logger.Fatal("control server failed", zap.Error(err))
	}
	logger.Info("server started",
		zap.String("control", cfg.Network.ControlAddr),
		zap.String("audio", cfg.Network.AudioAddr),
		zap.String("device", cfg.Audio.Device),
	)

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, append([]os.Signal{os.Interrupt}, extraSignals()...)...)
	<-sig

	logger.Info("shutting down")
	mgr.Stop()
	if rad != nil {
		rad.Close()
	}
}
