package net

import (
	"bufio"
	"encoding/json"
	"net"
	"testing"
	"time"

	"go.uber.org/zap"

	"github.com/bartek/ts590-remote/server/internal/config"
	"github.com/bartek/ts590-remote/server/internal/protocol"
)

// TestHandleAuthAndEvents exercises the full connection lifecycle through
// the dispatch seams: PSK auth handshake, CAT command round-trip, and
// unsolicited rig events forwarded to the client.
func TestHandleAuthAndEvents(t *testing.T) {
	rig := &fakeRig{sendResp: "FA1400000000;"}
	audio := &fakeAudio{}
	rig.events = make(chan string, 4)

	c := &ControlServer{
		cfg:      config.NetworkConfig{PSK: "test-psk"},
		psk:      "test-psk",
		rig:      rig,
		audioMgr: audio,
		log:      zap.NewNop(),
	}

	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()
	go c.handle(server)

	r := bufio.NewReader(client)
	send := func(m protocol.Message) error {
		b, err := json.Marshal(m)
		if err != nil {
			return err
		}
		_, err = client.Write(append(b, '\n'))
		return err
	}
	recv := func() (protocol.Message, error) {
		line, err := r.ReadString('\n')
		if err != nil {
			return protocol.Message{}, err
		}
		var m protocol.Message
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			return protocol.Message{}, err
		}
		return m, nil
	}

	// wrong psk -> auth_fail, connection closes
	if err := send(protocol.Message{T: "auth", Token: "wrong"}); err != nil {
		t.Fatal(err)
	}
	if m, err := recv(); err != nil || m.T != "auth_fail" {
		t.Fatalf("got %+v, err %v; want auth_fail", m, err)
	}
	if _, err := r.ReadString('\n'); err == nil {
		t.Fatal("expected connection close after auth_fail")
	}

	// fresh connection, right psk -> auth_ok
	server, client = net.Pipe()
	defer server.Close()
	defer client.Close()
	go c.handle(server)
	r = bufio.NewReader(client)

	if err := send(protocol.Message{T: "auth", Token: "test-psk"}); err != nil {
		t.Fatal(err)
	}
	if m, err := recv(); err != nil || m.T != "auth_ok" {
		t.Fatalf("got %+v, err %v; want auth_ok", m, err)
	}

	// cat round-trip
	if err := send(protocol.Message{T: "cat", Cmd: "FA;"}); err != nil {
		t.Fatal(err)
	}
	if m, err := recv(); err != nil || m.T != "cat_resp" || m.Raw != "FA1400000000;" {
		t.Fatalf("got %+v, err %v; want cat_resp FA1400000000;", m, err)
	}

	// unsolicited rig event -> cat_event
	rig.events <- "SM0000000000000;"
	select {
	case m := <-readAsync(recv):
		if m.T != "cat_event" || m.Raw != "SM0000000000000;" {
			t.Fatalf("got %+v; want cat_event SM0000000000000;", m)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for cat_event")
	}
}

// readAsync drains one message from recv on a goroutine.
func readAsync(recv func() (protocol.Message, error)) chan protocol.Message {
	ch := make(chan protocol.Message, 1)
	go func() {
		m, _ := recv()
		ch <- m
	}()
	return ch
}

// TestHandlePingPongAndStats exercises the ping/pong round-trip and the
// periodic uplink-jitter telemetry push through a live control connection.
func TestHandlePingPongAndStats(t *testing.T) {
	audio := &fakeAudio{stats: protocol.Stats{Depth: 3, MinDepth: 1, MaxDepth: 64, Dropouts: 7, Skips: 2, Late: 1, Fill: 1, Occupancy: 2}}
	c := &ControlServer{
		psk:        "test-psk",
		rig:        &fakeRig{},
		audioMgr:   audio,
		log:        zap.NewNop(),
		statsEvery: 20 * time.Millisecond,
	}

	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()
	go c.handle(server)

	r := bufio.NewReader(client)
	send := func(m protocol.Message) error {
		b, err := json.Marshal(m)
		if err != nil {
			return err
		}
		_, err = client.Write(append(b, '\n'))
		return err
	}
	recv := func() protocol.Message {
		for {
			line, err := r.ReadString('\n')
			if err != nil {
				t.Fatalf("read failed: %v", err)
			}
			var m protocol.Message
			if err := json.Unmarshal([]byte(line), &m); err != nil {
				continue
			}
			return m
		}
	}

	if err := send(protocol.Message{T: "auth", Token: "test-psk"}); err != nil {
		t.Fatal(err)
	}
	if m := recv(); m.T != "auth_ok" {
		t.Fatalf("got %+v; want auth_ok", m)
	}

	if err := send(protocol.Message{T: "ping"}); err != nil {
		t.Fatal(err)
	}

	// Collect messages until we have seen both a pong and a stats push.
	sawPong, sawStats := false, false
	for !sawPong || !sawStats {
		m := recv()
		switch m.T {
		case "pong":
			sawPong = true
		case "stats":
			if m.Stats == nil {
				t.Fatal("stats message missing payload")
			}
			if m.Stats.Depth != 3 || m.Stats.Dropouts != 7 {
				t.Fatalf("stats payload = %+v; want depth=3 dropouts=7", m.Stats)
			}
			sawStats = true
		}
	}
}
