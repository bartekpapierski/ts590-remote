package net

import (
	"bufio"
	"encoding/json"
	"net"
	"sync"

	"go.uber.org/zap"

	"github.com/bartek/ts590-remote/server/internal/config"
	"github.com/bartek/ts590-remote/server/internal/protocol"
)

// RadioIf is the CAT-control surface ControlServer dispatches against. It is
// satisfied by *radio.Radio in production and by fakes in tests.
type RadioIf interface {
	Send(cmd string) (string, error)
	SetPTT(on bool) error
	GetState() *protocol.RadioState
	Events() <-chan string
}

// AudioIf is the audio lifecycle surface ControlServer and UDPServer use. It
// is satisfied by *audio.Manager in production and by fakes in tests.
type AudioIf interface {
	Start(req *protocol.OpusParams) (*protocol.OpusParams, bool, error)
	Stop()
	Running() bool
	PauseRx(pause bool)
	RxPaused() bool
	PushUplink(seq uint16, data []byte)
}

// ControlServer accepts TCP control connections, authenticates with the
// pre-shared key, and dispatches CAT / audio / PTT / state messages.
type ControlServer struct {
	cfg      config.NetworkConfig
	psk      string
	radio    RadioIf
	audioMgr AudioIf
	log      *zap.Logger
}

func NewControlServer(cfg config.NetworkConfig, rad RadioIf, mgr AudioIf, log *zap.Logger) *ControlServer {
	return &ControlServer{
		cfg:      cfg,
		psk:      cfg.PSK,
		radio:    rad,
		audioMgr: mgr,
		log:      log,
	}
}

func (c *ControlServer) Listen() error {
	ln, err := net.Listen("tcp", c.cfg.ControlAddr)
	if err != nil {
		return err
	}
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go c.handle(conn)
		}
	}()
	return nil
}

// msgWriter serializes protocol messages as JSON lines onto a bufio.Writer.
// It is safe for concurrent use: unsolicited rig events and command replies
// are written from different goroutines.
type msgWriter struct {
	mu sync.Mutex
	w  *bufio.Writer
}

func (mw *msgWriter) send(m protocol.Message) {
	b, err := json.Marshal(m)
	if err != nil {
		return
	}
	mw.mu.Lock()
	defer mw.mu.Unlock()
	_, _ = mw.w.Write(append(b, '\n'))
	_ = mw.w.Flush()
}

func (c *ControlServer) handle(conn net.Conn) {
	defer conn.Close()
	remote := conn.RemoteAddr().String()
	clog := c.log.With(zap.String("client", remote))
	clog.Info("client connected")
	defer clog.Info("client disconnected")

	r := bufio.NewReader(conn)
	mw := &msgWriter{w: bufio.NewWriter(conn)}
	send := mw.send

	// authenticate
	line, err := r.ReadString('\n')
	if err != nil {
		clog.Warn("client closed before auth", zap.Error(err))
		return
	}
	var auth protocol.Message
	if err := json.Unmarshal([]byte(line), &auth); err != nil || auth.T != "auth" || auth.Token != c.psk {
		clog.Warn("authentication failed")
		send(protocol.MsgAuthFail())
		return
	}
	send(protocol.MsgAuthOK())
	clog.Info("client authenticated")

	// forward unsolicited rig events to this client
	evDone := make(chan struct{})
	if c.radio != nil {
		go func() {
			for {
				select {
				case <-evDone:
					return
				case ev := <-c.radio.Events():
					send(protocol.MsgCatEvent(ev))
				}
			}
		}()
	}
	defer close(evDone)

	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return
		}
		var msg protocol.Message
		if err := json.Unmarshal([]byte(line), &msg); err != nil {
			clog.Warn("bad json from client", zap.String("line", line))
			send(protocol.MsgError("bad json"))
			continue
		}
		c.dispatch(msg, send, clog)
	}
}

func (c *ControlServer) dispatch(msg protocol.Message, send func(protocol.Message), log *zap.Logger) {
	switch msg.T {
	case "cat":
		log.Info("cat command", zap.String("cmd", msg.Cmd))
		if c.radio == nil {
			send(protocol.MsgError("radio not connected"))
			return
		}
		resp, err := c.radio.Send(msg.Cmd)
		if err != nil {
			log.Warn("cat error", zap.String("cmd", msg.Cmd), zap.Error(err))
			send(protocol.MsgError(err.Error()))
			return
		}
		send(protocol.MsgCatResp(resp))

	case "audio":
		switch msg.Action {
		case "start":
			log.Info("audio start", zap.Any("requested", msg.Opus))
			eff, adjusted, err := c.audioMgr.Start(msg.Opus)
			if err != nil {
				log.Error("audio start failed", zap.Error(err))
				send(protocol.MsgError(err.Error()))
				return
			}
			log.Info("audio started", zap.Any("params", eff), zap.Bool("adjusted", adjusted))
			send(protocol.MsgAudioParams(eff, adjusted))
			send(protocol.MsgAudioStatus("started"))
		case "stop":
			log.Info("audio stop")
			c.audioMgr.Stop()
			send(protocol.MsgAudioStatus("stopped"))
		}

	case "audio_rx":
		log.Info("audio rx", zap.String("action", msg.Action))
		if msg.Action == "pause" {
			c.audioMgr.PauseRx(true)
		} else {
			c.audioMgr.PauseRx(false)
		}
		st := "running"
		if c.audioMgr.RxPaused() {
			st = "paused"
		}
		send(protocol.MsgAudioRxStatus(st))

	case "ptt":
		on := msg.On != nil && *msg.On
		log.Info("ptt", zap.Bool("on", on))
		if c.radio == nil {
			send(protocol.MsgError("radio not connected"))
			return
		}
		if err := c.radio.SetPTT(on); err != nil {
			log.Warn("ptt error", zap.Bool("on", on), zap.Error(err))
			send(protocol.MsgError(err.Error()))
			return
		}
		send(protocol.MsgPTTAck(on))

	case "state_req":
		log.Info("state request")
		if c.radio == nil {
			send(protocol.MsgError("radio not connected"))
			return
		}
		st := c.radio.GetState()
		st.AudioOn = c.audioMgr.Running()
		st.RxPaused = c.audioMgr.RxPaused()
		send(protocol.MsgState(st))

	default:
		log.Warn("unknown message type", zap.String("t", msg.T))
	}
}
