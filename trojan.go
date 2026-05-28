package httpmux

// ═══════════════════════════════════════════════════════════════
// PicoTun — Trojan Transport (v2.5.7)
//
// A standalone TLS transport that authenticates clients with a
// SHA-224 hash token instead of an HTTP/WebSocket handshake.
//
// How it works:
//   Server: listens on TLS with a REAL certificate (Let's Encrypt).
//           First 58 bytes from client = hex(SHA224(PSK)) + "\r\n".
//           Match → smux tunnel.  No match → realistic HTML decoy.
//   Client: TLS connect (utls fingerprint rotation + ClientHello
//           fragmentation), then sends 58-byte token, then smux.
//
// DPI resistance:
//   • TLS cert from a real domain — indistinguishable from HTTPS
//   • utls fingerprint rotation — no fixed TLS fingerprint
//   • Active probe returns realistic HTML — not detectable as proxy
//   • No WebSocket upgrade — just plain TLS (harder to flag)
//   • ClientHello fragmentation — bypasses SNI-based blocking
// ═══════════════════════════════════════════════════════════════

import (
	"crypto/sha256"
	"crypto/tls"
	"fmt"
	"io"
	"log"
	"net"
	"strings"
	"time"

	utls "github.com/refraction-networking/utls"
	"github.com/xtaci/smux"
)

const trojanAuthLen = 58 // 56 hex chars (SHA-224) + "\r\n"

// trojanHash returns hex(SHA-224(psk)) — always 56 characters.
func trojanHash(psk string) string {
	h := sha256.New224()
	h.Write([]byte(psk))
	return fmt.Sprintf("%x", h.Sum(nil))
}

// ═══════════════════════════════════════════════════
// Server
// ═══════════════════════════════════════════════════

// serveTrojan is the entry point for the trojan transport on the server.
// It bypasses the HTTP mux entirely and handles raw TLS connections.
// cert_file and key_file in config MUST point to a real certificate.
func (s *Server) serveTrojan(addr string) error {
	if s.Config.CertFile == "" || s.Config.KeyFile == "" {
		return fmt.Errorf("trojan transport requires cert_file and key_file — get a free cert with: certbot certonly --standalone -d yourdomain.com")
	}

	cert, err := tls.LoadX509KeyPair(s.Config.CertFile, s.Config.KeyFile)
	if err != nil {
		return fmt.Errorf("trojan: load cert: %w", err)
	}

	tlsCfg := &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS12,
		NextProtos:   []string{"http/1.1"}, // no h2 — we don't speak HTTP at all
	}

	ln, err := tls.Listen("tcp", addr, tlsCfg)
	if err != nil {
		return fmt.Errorf("trojan: listen %s: %w", addr, err)
	}
	defer ln.Close()

	log.Printf("[TROJAN] listening on %s  cert=%s", addr, s.Config.CertFile)

	for {
		conn, err := ln.Accept()
		if err != nil {
			time.Sleep(50 * time.Millisecond)
			continue
		}
		go s.handleTrojanConn(conn)
	}
}

// handleTrojanConn peeks the first 58 bytes to decide:
//   - Auth token present → tunnel session
//   - Anything else     → decoy HTTPS response (active probe resistance)
func (s *Server) handleTrojanConn(conn net.Conn) {
	defer func() {
		if r := recover(); r != nil {
			conn.Close()
		}
	}()

	conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	buf := make([]byte, trojanAuthLen)
	n, _ := io.ReadFull(conn, buf)
	conn.SetReadDeadline(time.Time{})

	expected := trojanHash(s.PSK) + "\r\n"
	if n == trojanAuthLen && string(buf) == expected {
		log.Printf("[TROJAN] authenticated from %s", conn.RemoteAddr())
		s.handleTrojanSession(conn)
	} else {
		// Return a realistic decoy page — do NOT reveal tunnel nature
		s.trojanSendDecoy(conn)
	}
}

// handleTrojanSession takes an authenticated connection and creates a smux session.
// Reuses the server's existing session pool and stream handler.
func (s *Server) handleTrojanSession(conn net.Conn) {
	ec, err := NewEncryptedConn(conn, s.PSK, s.Obfs, &s.Config.Stealth)
	if err != nil {
		log.Printf("[TROJAN] encrypt: %v", err)
		conn.Close()
		return
	}

	sc := buildSmuxConfig(s.Config)
	sess, err := smux.Server(ec, sc)
	if err != nil {
		log.Printf("[TROJAN] smux: %v", err)
		ec.Close()
		return
	}

	ss := &serverSession{
		sess:    sess,
		remote:  conn.RemoteAddr().String(),
		created: time.Now(),
	}
	s.addSession(ss)
	log.Printf("[TROJAN] session from %s (pool: %d)", ss.remote, s.poolSize())

	if s.Config.Stealth.FakeTraffic {
		go s.fakeTrafficLoop(ss)
	}

	for {
		stream, err := sess.AcceptStream()
		if err != nil {
			break
		}
		go s.handleStream(ss, stream)
	}

	s.removeSession(ss)
	sess.Close()
	log.Printf("[TROJAN] session closed %s after %v (pool: %d)",
		ss.remote, time.Since(ss.created).Round(time.Second), s.poolSize())
}

// trojanSendDecoy sends a realistic HTML response to active probes.
// The DPI sees: TLS handshake with real cert → normal HTTPS response. Nothing unusual.
func (s *Server) trojanSendDecoy(conn net.Conn) {
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	writeFakeResponse(conn, 200)
}

// ═══════════════════════════════════════════════════
// Client
// ═══════════════════════════════════════════════════

// connectAndServeTrojan is the client entry point for the trojan transport.
// Called from connectAndServe when transport == "trojan".
// Bypasses the HTTP/WebSocket handshake — goes straight to TLS + auth + smux.
func (c *Client) connectAndServeTrojan(id int, path PathConfig) error {
	addr := strings.TrimSpace(path.Addr)
	if addr == "" {
		return fmt.Errorf("empty address")
	}

	dialTimeout := time.Duration(path.DialTimeout) * time.Second
	if dialTimeout <= 0 {
		dialTimeout = 10 * time.Second
	}

	host, port := parseAddr(addr, "trojan")
	dialAddr := net.JoinHostPort(host, port)

	// Pre-connect jitter for DPI timing evasion
	if c.cfg.Stealth.ConnJitterMS > 0 {
		time.Sleep(time.Duration(secureRandInt(c.cfg.Stealth.ConnJitterMS)) * time.Millisecond)
	}

	conn, err := c.dialTrojan(dialAddr, host, dialTimeout)
	if err != nil {
		return fmt.Errorf("dial: %w", err)
	}

	ec, err := NewEncryptedConn(conn, c.psk, c.obfs, &c.cfg.Stealth)
	if err != nil {
		conn.Close()
		return fmt.Errorf("encrypt: %w", err)
	}

	sc := buildSmuxConfig(c.cfg)
	sess, err := smux.Client(ec, sc)
	if err != nil {
		ec.Close()
		return fmt.Errorf("smux: %w", err)
	}

	c.addSession(sess)
	log.Printf("[TROJAN#%d] connected to %s (pool: %d)", id, dialAddr, c.sessionCount())

	for {
		stream, err := sess.AcceptStream()
		if err != nil {
			c.removeSession(sess)
			sess.Close()
			return fmt.Errorf("session closed: %w", err)
		}
		go c.handleReverseStream(stream)
	}
}

// dialTrojan: TLS connect with utls fingerprint rotation and ClientHello
// fragmentation, then sends the 58-byte auth token.
func (c *Client) dialTrojan(addr, sni string, timeout time.Duration) (net.Conn, error) {
	// Fragment the TLS ClientHello to bypass SNI-based blocking
	fragCfg := &FragmentConfig{
		Enabled:  true,
		MinSize:  64,
		MaxSize:  191,
		MinDelay: 1,
		MaxDelay: 3,
	}

	rawConn, err := DialFragmented(addr, fragCfg, timeout)
	if err != nil {
		return nil, err
	}

	// SNI override: useful when server IP differs from the cert domain
	if c.cfg.Trojan.SNI != "" {
		sni = c.cfg.Trojan.SNI
	}

	helloID := randomTLSHello() // Chrome/Firefox/Edge/Safari — rotates per connection
	uConn := utls.UClient(rawConn, &utls.Config{
		ServerName:         sni,
		InsecureSkipVerify: c.cfg.Trojan.SkipVerify, // false by default — verify real cert
	}, helloID)

	if err := uConn.Handshake(); err != nil {
		uConn.Close()
		return nil, fmt.Errorf("tls: %w", err)
	}

	// Send auth token: hex(SHA-224(psk)) + "\r\n"  (58 bytes total)
	token := trojanHash(c.psk) + "\r\n"
	if _, err := uConn.Write([]byte(token)); err != nil {
		uConn.Close()
		return nil, fmt.Errorf("auth write: %w", err)
	}

	return uConn, nil
}
