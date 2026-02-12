package httpmux

import (
	"log"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

type tcpLink struct {
	c net.Conn
}

// udpLink represents a single UDP "association" (one remote peer) bound to a stream id.
type udpLink struct {
	ln       *net.UDPConn
	peer     *net.UDPAddr
	lastSeen int64 // unix seconds
}

var (
	serverLinksMu sync.Mutex
	serverLinks   = map[uint32]*tcpLink{}

	serverUDPLinksMu sync.Mutex
	serverUDPLinks   = map[uint32]*udpLink{}
	serverUDPKeyToID = map[string]uint32{} // key = ln.LocalAddr() + "|" + peer.String()

	nextStreamID uint32 = 2
)

func (s *Server) StartReverseTCP(bindAddr, targetAddr string) {
	ln, err := net.Listen("tcp", bindAddr)
	if err != nil {
		log.Printf("❌ Reverse listen failed %s: %v", bindAddr, err)
		return
	}
	log.Printf("🔗 Reverse TCP Listening: %s -> Client -> %s", bindAddr, targetAddr)

	for {
		c, err := ln.Accept()
		if err != nil {
			continue
		}
		go s.handleInboundTCP(c, targetAddr)
	}
}

func (s *Server) handleInboundTCP(c net.Conn, target string) {
	// ✅ فیکس: دریافت سشن فعال فعلی (دیگر Global نیست)
	sess := s.getActiveSession()
	if sess == nil {
		c.Close()
		return
	}

	id := atomic.AddUint32(&nextStreamID, 2)

	serverLinksMu.Lock()
	serverLinks[id] = &tcpLink{c: c}
	serverLinksMu.Unlock()

	// Back-compat: client treats no scheme as tcp. We still send tcp:// for clarity.
	openPayload := []byte("tcp://" + target)

	select {
	case sess.Outgoing <- &Frame{
		StreamID: id,
		Type:     FrameOpen,
		Length:   uint32(len(openPayload)),
		Payload:  openPayload,
	}:
	default:
		c.Close()
	}
}

// StartReverseUDP listens on UDP and forwards packets to the client-side target via frames.
// A separate StreamID is allocated per (listener, remote peer) so replies are routed correctly.
func (s *Server) StartReverseUDP(bindAddr, targetAddr string) {
	laddr, err := net.ResolveUDPAddr("udp", bindAddr)
	if err != nil {
		log.Printf("❌ Reverse UDP resolve failed %s: %v", bindAddr, err)
		return
	}
	ln, err := net.ListenUDP("udp", laddr)
	if err != nil {
		log.Printf("❌ Reverse UDP listen failed %s: %v", bindAddr, err)
		return
	}
	log.Printf("🔗 Reverse UDP Listening: %s -> Client -> %s", bindAddr, targetAddr)

	// Cleanup old UDP peers (best-effort)
	go func() {
		t := time.NewTicker(30 * time.Second)
		defer t.Stop()
		for range t.C {
			now := time.Now().Unix()
			var toClose []uint32
			serverUDPLinksMu.Lock()
			for id, l := range serverUDPLinks {
				if now-atomic.LoadInt64(&l.lastSeen) > 120 {
					toClose = append(toClose, id)
					delete(serverUDPKeyToID, ln.LocalAddr().String()+"|"+l.peer.String())
					delete(serverUDPLinks, id)
				}
			}
			serverUDPLinksMu.Unlock()

			if len(toClose) == 0 {
				continue
			}
			sess := s.getActiveSession()
			if sess == nil {
				continue
			}
			for _, id := range toClose {
				select {
				case sess.Outgoing <- &Frame{StreamID: id, Type: FrameClose}:
				default:
				}
			}
		}
	}()

	buf := make([]byte, 65535)
	for {
		n, raddr, err := ln.ReadFromUDP(buf)
		if err != nil {
			continue
		}

		sess := s.getActiveSession()
		if sess == nil || n <= 0 {
			continue
		}

		key := ln.LocalAddr().String() + "|" + raddr.String()

		var id uint32
		var isNew bool
		serverUDPLinksMu.Lock()
		id = serverUDPKeyToID[key]
		if id == 0 {
			id = atomic.AddUint32(&nextStreamID, 2)
			serverUDPKeyToID[key] = id
			serverUDPLinks[id] = &udpLink{
				ln:       ln,
				peer:     raddr,
				lastSeen: time.Now().Unix(),
			}
			isNew = true
		} else {
			if l := serverUDPLinks[id]; l != nil {
				atomic.StoreInt64(&l.lastSeen, time.Now().Unix())
			}
		}
		serverUDPLinksMu.Unlock()

		if isNew {
			openPayload := []byte("udp://" + targetAddr)
			select {
			case sess.Outgoing <- &Frame{StreamID: id, Type: FrameOpen, Payload: openPayload}:
			default:
				// if we can't open, drop
				continue
			}
		}

		// send packet
		payload := append([]byte(nil), buf[:n]...)
		select {
		case sess.Outgoing <- &Frame{StreamID: id, Type: FrameData, Payload: payload}:
		default:
			// queue full, drop packet
		}
	}
}
