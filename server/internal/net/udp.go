package net

import (
	"encoding/binary"
	"net"
	"sync"

	"go.uber.org/zap"
)

// UDPServer transports Opus audio datagrams. The client's source address
// is learned from the first packet it sends (or a hello), after which
// downlink packets are sent to that address.
type UDPServer struct {
	conn     *net.UDPConn
	mu       sync.RWMutex
	client   *net.UDPAddr
	audioMgr AudioIf
	log      *zap.Logger
}

func NewUDPServer(addr string, mgr AudioIf, log *zap.Logger) (*UDPServer, error) {
	a, err := net.ResolveUDPAddr("udp", addr)
	if err != nil {
		return nil, err
	}
	conn, err := net.ListenUDP("udp", a)
	if err != nil {
		return nil, err
	}
	s := &UDPServer{conn: conn, audioMgr: mgr, log: log}
	go s.readLoop()
	return s, nil
}

func (s *UDPServer) readLoop() {
	buf := make([]byte, 4096)
	for {
		n, raddr, err := s.conn.ReadFromUDP(buf)
		if err != nil {
			return
		}
		s.mu.Lock()
		s.client = raddr
		s.mu.Unlock()

		if n < 3 {
			continue // hello / empty
		}
		seq := binary.BigEndian.Uint16(buf[0:2])
		data := make([]byte, n-2)
		copy(data, buf[2:n])
		s.audioMgr.PushUplink(seq, data)
	}
}

// SendDownlink transmits a downlink (radio RX) Opus frame to the client.
func (s *UDPServer) SendDownlink(seq uint16, data []byte) {
	s.mu.RLock()
	addr := s.client
	s.mu.RUnlock()
	if addr == nil {
		return
	}
	pkt := make([]byte, 2+len(data))
	binary.BigEndian.PutUint16(pkt[0:2], seq)
	copy(pkt[2:], data)
	_, _ = s.conn.WriteToUDP(pkt, addr)
}
