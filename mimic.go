package httpmux

import (
	"bufio"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"io"
	"math/rand"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
	"sync"
	"time"
)

func init() {
	rand.Seed(time.Now().UnixNano())
}

type MimicConfig struct {
	FakeDomain    string   `yaml:"fake_domain"`
	FakePath      string   `yaml:"fake_path"`
	UserAgent     string   `yaml:"user_agent"`
	CustomHeaders []string `yaml:"custom_headers"`
	SessionCookie bool     `yaml:"session_cookie"`
	Chunked       bool     `yaml:"chunked"`
}

// ═══════════════════════════════════════════════════════════════
// bufferedConn — CRITICAL FIX for data loss bug.
//
// Problem: bufio.NewReader(conn) in http.ReadResponse may read
// ahead beyond the HTTP response boundary. Those extra bytes are
// the first smux frames (keepalive, version negotiation).
// If we discard the bufio.Reader and use raw conn for EncryptedConn,
// those buffered bytes are LOST → smux session dies in ~30 seconds.
//
// Solution: wrap conn + bufio.Reader so Read() goes through the
// buffer first, preserving any pre-read smux data.
// ═══════════════════════════════════════════════════════════════

type bufferedConn struct {
	net.Conn
	r *bufio.Reader
}

func (c *bufferedConn) Read(p []byte) (int, error) {
	return c.r.Read(p)
}

// ClientHandshake performs the HTTP upgrade handshake (client side).
// Returns a wrapped net.Conn that preserves any buffered data.
func ClientHandshake(conn net.Conn, cfg *MimicConfig) (net.Conn, error) {
	return ClientHandshakeWithStealth(conn, cfg, nil)
}

// StealthConfig is defined in config.go — forward reference for this file
// ClientHandshakeWithStealth is the v2.5.1 anti-DPI version that rotates
// domain, User-Agent, headers, and path per connection.
func ClientHandshakeWithStealth(conn net.Conn, cfg *MimicConfig, stealth *StealthConfig) (net.Conn, error) {
	domain := "www.google.com"
	path := "/"
	ua := "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"

	if cfg != nil {
		if cfg.FakeDomain != "" {
			domain = cfg.FakeDomain
		}
		if cfg.FakePath != "" {
			path = cfg.FakePath
		}
		if cfg.UserAgent != "" {
			ua = cfg.UserAgent
		}
	}

	// v2.5.1: Rotate domain & UA per connection to break DPI fingerprints
	if stealth != nil {
		if stealth.RotateDomain && len(stealth.DomainPool) > 0 {
			domain = stealth.DomainPool[secureRandInt(len(stealth.DomainPool))]
		}
		if stealth.RotateUA && len(stealth.UAPool) > 0 {
			ua = stealth.UAPool[secureRandInt(len(stealth.UAPool))]
		}
	}

	// v2.5.1: Randomize path with realistic query strings
	fullURL := "http://" + domain + path
	if strings.Contains(path, "{rand}") {
		fullURL, _ = BuildURLWithFakePath("http://"+domain, path)
	} else {
		// Add random query params to vary the URL fingerprint
		fullURL += randomQueryString()
	}

	req, err := http.NewRequest("GET", fullURL, nil)
	if err != nil {
		return nil, err
	}

	// v2.5.1: Build headers based on which "browser" UA we picked
	// Each browser has slightly different header patterns
	type hdr struct{ k, v string }
	baseHeaders := []hdr{
		{"Host", domain},
		{"User-Agent", ua},
		{"Connection", "Upgrade"},
		{"Upgrade", "websocket"},
		{"Sec-WebSocket-Key", generateWebSocketKeyBase64()},
		{"Sec-WebSocket-Version", "13"},
	}

	// Browser-specific headers — makes each connection look like a real browser
	var extraHeaders []hdr
	if strings.Contains(ua, "Firefox") {
		extraHeaders = []hdr{
			{"Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
			{"Accept-Language", randomAcceptLang()},
			{"Accept-Encoding", "gzip, deflate, br"},
			{"Sec-Fetch-Dest", "empty"},
			{"Sec-Fetch-Mode", "websocket"},
			{"Sec-Fetch-Site", "cross-site"},
			{"Origin", "https://" + domain},
			{"Pragma", "no-cache"},
			{"Cache-Control", "no-cache"},
		}
	} else if strings.Contains(ua, "Safari") && !strings.Contains(ua, "Chrome") {
		extraHeaders = []hdr{
			{"Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
			{"Accept-Language", randomAcceptLang()},
			{"Accept-Encoding", "gzip, deflate, br"},
			{"Origin", "https://" + domain},
		}
	} else {
		// Chrome / Edge
		extraHeaders = []hdr{
			{"Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8"},
			{"Accept-Language", randomAcceptLang()},
			{"Accept-Encoding", "gzip, deflate, br"},
			{"Sec-Fetch-Dest", "empty"},
			{"Sec-Fetch-Mode", "websocket"},
			{"Sec-Fetch-Site", "same-origin"},
			{"Origin", "https://" + domain},
			{"Sec-Ch-Ua-Platform", randomPlatform()},
			{"Cache-Control", "no-cache"},
			{"Pragma", "no-cache"},
		}
	}

	// Shuffle extra headers to randomize order
	for i := len(extraHeaders) - 1; i > 0; i-- {
		j := secureRandInt(i + 1)
		extraHeaders[i], extraHeaders[j] = extraHeaders[j], extraHeaders[i]
	}

	// Set base headers first (Host, UA, Connection, Upgrade, WS-Key, WS-Version)
	for _, h := range baseHeaders {
		req.Header.Set(h.k, h.v)
	}
	// Then set shuffled extra headers
	for _, h := range extraHeaders {
		req.Header.Set(h.k, h.v)
	}

	// Custom headers from config
	if cfg != nil {
		for _, h := range cfg.CustomHeaders {
			parts := strings.SplitN(h, ":", 2)
			if len(parts) == 2 {
				req.Header.Set(strings.TrimSpace(parts[0]), strings.TrimSpace(parts[1]))
			}
		}
		if cfg.SessionCookie {
			req.AddCookie(&http.Cookie{Name: "session", Value: generateSessionID()})
			// Realistic extra cookies sometimes
			if secureRandInt(3) == 0 {
				req.AddCookie(&http.Cookie{Name: "_ga", Value: fmt.Sprintf("GA1.2.%d.%d", 100000000+secureRandInt(900000000), 1700000000+secureRandInt(100000000))})
			}
			if secureRandInt(4) == 0 {
				req.AddCookie(&http.Cookie{Name: "consent", Value: "yes"})
			}
		}
	}

	reqDump, err := httputil.DumpRequest(req, false)
	if err != nil {
		return nil, err
	}
	if _, err = conn.Write(reqDump); err != nil {
		return nil, err
	}

	// CRITICAL: Keep the bufio.Reader — it may contain pre-read smux data!
	br := bufio.NewReader(conn)
	resp, err := http.ReadResponse(br, req)
	if err != nil {
		return nil, err
	}

	if resp.StatusCode != 101 && resp.StatusCode != 200 {
		return nil, fmt.Errorf("handshake: expected 101, got %d", resp.StatusCode)
	}

	return &bufferedConn{Conn: conn, r: br}, nil
}

// ──────────── v2.5.1 Anti-DPI Helpers ────────────

// randomAcceptLang returns a realistic Accept-Language header.
// No Persian (fa) — that would hint at an Iranian origin to the DPI engine.
func randomAcceptLang() string {
	langs := []string{
		"en-US,en;q=0.9",
		"en-GB,en;q=0.9,en-US;q=0.8",
		"en-US,en;q=0.9,de;q=0.8",
		"en-US,en;q=0.9,fr;q=0.8",
		"en-US,en;q=0.9,es;q=0.8",
		"en,en-US;q=0.9",
		"en-US,en;q=0.9,nl;q=0.8",
		"en-US,en;q=0.9,it;q=0.8",
		"en-US,en;q=0.9,pt;q=0.8",
		"en-AU,en;q=0.9,en-GB;q=0.8",
	}
	return langs[secureRandInt(len(langs))]
}

// randomPlatform returns a Sec-Ch-Ua-Platform value
func randomPlatform() string {
	platforms := []string{`"Windows"`, `"macOS"`, `"Linux"`}
	return platforms[secureRandInt(len(platforms))]
}

// randomQueryString generates a realistic random query string matched to common WS paths.
func randomQueryString() string {
	ts := fmt.Sprintf("%d", 1700000000+secureRandInt(200000000))
	rid := randAlphaNum(16)
	queries := []string{
		"?v=" + fmt.Sprintf("%d", 2+secureRandInt(8)) + "&t=" + ts,
		"?token=" + rid,
		"?session=" + rid + "&dc=" + randAlphaNum(3),
		"?clientId=" + rid,
		"?id=" + randAlphaNum(8) + "&ts=" + ts,
		"?auth=" + rid + "&ver=2",
		"?channel=" + randAlphaNum(6) + "&uid=" + fmt.Sprintf("%d", secureRandInt(999999)),
		"?t=" + ts + "&lang=en",
	}
	return queries[secureRandInt(len(queries))]
}

// generateWebSocketKeyBase64 generates a proper RFC 6455 base64 WS key
func generateWebSocketKeyBase64() string {
	b := make([]byte, 16)
	rand.Read(b)
	return base64Encode(b)
}

// base64Encode encodes bytes to standard base64
func base64Encode(data []byte) string {
	const enc = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	result := make([]byte, ((len(data)+2)/3)*4)
	for i, j := 0, 0; i < len(data); i += 3 {
		var val uint32
		remaining := len(data) - i
		switch {
		case remaining >= 3:
			val = uint32(data[i])<<16 | uint32(data[i+1])<<8 | uint32(data[i+2])
			result[j] = enc[val>>18&0x3F]
			result[j+1] = enc[val>>12&0x3F]
			result[j+2] = enc[val>>6&0x3F]
			result[j+3] = enc[val&0x3F]
		case remaining == 2:
			val = uint32(data[i])<<16 | uint32(data[i+1])<<8
			result[j] = enc[val>>18&0x3F]
			result[j+1] = enc[val>>12&0x3F]
			result[j+2] = enc[val>>6&0x3F]
			result[j+3] = '='
		case remaining == 1:
			val = uint32(data[i]) << 16
			result[j] = enc[val>>18&0x3F]
			result[j+1] = enc[val>>12&0x3F]
			result[j+2] = '='
			result[j+3] = '='
		}
		j += 4
	}
	return string(result)
}

// ServerHandshake — server-side validation (for direct TCP mode).
func ServerHandshake(conn net.Conn, cfg *MimicConfig) error {
	conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	defer conn.SetReadDeadline(time.Time{})

	reader := bufio.NewReader(conn)
	req, err := http.ReadRequest(reader)
	if err != nil {
		return err
	}

	if cfg != nil && cfg.FakeDomain != "" {
		if req.Host != cfg.FakeDomain && !strings.HasSuffix(req.Host, "."+cfg.FakeDomain) {
			writeFakeResponse(conn, 200)
			return fmt.Errorf("invalid host: %s", req.Host)
		}
	}

	expectedPath := "/"
	if cfg != nil && cfg.FakePath != "" {
		expectedPath = strings.Split(cfg.FakePath, "{")[0]
	}
	if !strings.HasPrefix(req.URL.Path, expectedPath) {
		writeFakeResponse(conn, 200)
		return fmt.Errorf("invalid path: %s", req.URL.Path)
	}

	wsKey := req.Header.Get("Sec-Websocket-Key")
	if wsKey == "" {
		wsKey = req.Header.Get("Sec-WebSocket-Key")
	}
	accept := computeWSAccept(wsKey)
	now := time.Now().UTC().Format("Mon, 02 Jan 2006 15:04:05 GMT")

	resp := "HTTP/1.1 101 Switching Protocols\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: " + accept + "\r\n" +
		"Date: " + now + "\r\n" +
		"Server: " + randomServerSoftware() + "\r\n" +
		"\r\n"
	_, err = conn.Write([]byte(resp))
	return err
}

func writeFakeResponse(conn net.Conn, _ int) {
	// Return a realistic 200 page to fool active probes — never reveal tunnel nature.
	bodies := []string{
		`<!DOCTYPE html><html><head><title>Google</title><meta charset="utf-8"></head><body><p>Search the world's information.</p></body></html>`,
		`<!DOCTYPE html><html><head><title>Microsoft</title></head><body><p>Cloud computing services.</p></body></html>`,
		`<!DOCTYPE html><html><head><title>Cloudflare</title></head><body><h1>Welcome to Cloudflare</h1></body></html>`,
	}
	body := bodies[secureRandInt(len(bodies))]
	now := time.Now().UTC().Format("Mon, 02 Jan 2006 15:04:05 GMT")
	srv := randomServerSoftware()
	resp := fmt.Sprintf(
		"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %d\r\n"+
			"Date: %s\r\nServer: %s\r\nCache-Control: private\r\nConnection: close\r\n\r\n%s",
		len(body), now, srv, body,
	)
	conn.Write([]byte(resp))
}

// randomServerSoftware returns a varied, realistic server header value.
func randomServerSoftware() string {
	servers := []string{
		"nginx/1.24.0", "nginx/1.25.4", "nginx/1.26.1",
		"Apache/2.4.58 (Ubuntu)", "Apache/2.4.62",
		"cloudflare", "gws", "Microsoft-IIS/10.0",
		"openresty/1.25.3.1",
	}
	return servers[secureRandInt(len(servers))]
}

// computeWSAccept computes the RFC 6455 Sec-WebSocket-Accept value from client's key.
func computeWSAccept(clientKey string) string {
	const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
	h := sha1.New()
	h.Write([]byte(clientKey + magic))
	return base64.StdEncoding.EncodeToString(h.Sum(nil))
}

// ─────────────────────────────────────────────────────────────────────────────
// wsFrameConn — wraps net.Conn with RFC 6455 WebSocket binary framing.
//
// After the HTTP 101 upgrade, all tunnel data is wrapped in proper WS frames.
// This makes post-handshake traffic indistinguishable from real WebSocket
// binary streams. Iran's DPI looks for the absence of WS framing as a signal
// that the "WebSocket upgrade" was fake — this defeats that heuristic.
//
// Client frames are masked per RFC 6455 §5.3 (client MUST mask).
// Server frames are unmasked per RFC 6455 §5.1 (server MUST NOT mask).
// ─────────────────────────────────────────────────────────────────────────────

type wsFrameConn struct {
	net.Conn
	isClient bool
	readBuf  []byte
	readMu   sync.Mutex
}

func newWSFrameConn(conn net.Conn, isClient bool) net.Conn {
	return &wsFrameConn{Conn: conn, isClient: isClient}
}

func (c *wsFrameConn) Write(data []byte) (int, error) {
	frame := buildWSFrame(data, c.isClient)
	if _, err := c.Conn.Write(frame); err != nil {
		return 0, err
	}
	return len(data), nil
}

func (c *wsFrameConn) Read(p []byte) (int, error) {
	c.readMu.Lock()
	defer c.readMu.Unlock()

	if len(c.readBuf) > 0 {
		n := copy(p, c.readBuf)
		c.readBuf = c.readBuf[n:]
		return n, nil
	}

	payload, err := readWSFrame(c.Conn)
	if err != nil {
		return 0, err
	}

	n := copy(p, payload)
	if n < len(payload) {
		c.readBuf = append([]byte(nil), payload[n:]...)
	}
	return n, nil
}

// buildWSFrame constructs a single RFC 6455 WebSocket binary frame.
func buildWSFrame(payload []byte, masked bool) []byte {
	length := len(payload)

	headerSize := 2
	if length > 65535 {
		headerSize += 8
	} else if length > 125 {
		headerSize += 2
	}
	if masked {
		headerSize += 4
	}

	frame := make([]byte, 0, headerSize+length)
	// FIN=1, RSV=000, opcode=0x2 (binary)
	frame = append(frame, 0x82)

	var maskBit byte
	if masked {
		maskBit = 0x80
	}

	switch {
	case length <= 125:
		frame = append(frame, maskBit|byte(length))
	case length <= 65535:
		frame = append(frame, maskBit|126, byte(length>>8), byte(length))
	default:
		frame = append(frame, maskBit|127)
		for i := 7; i >= 0; i-- {
			frame = append(frame, byte(length>>(uint(i)*8)))
		}
	}

	if masked {
		maskKey := [4]byte{randByte(), randByte(), randByte(), randByte()}
		frame = append(frame, maskKey[:]...)
		for i, b := range payload {
			frame = append(frame, b^maskKey[i%4])
		}
	} else {
		frame = append(frame, payload...)
	}

	return frame
}

// readWSFrame reads exactly one WebSocket frame and returns the unmasked payload.
func readWSFrame(conn net.Conn) ([]byte, error) {
	header := make([]byte, 2)
	if _, err := io.ReadFull(conn, header); err != nil {
		return nil, err
	}

	opcode := header[0] & 0x0F
	masked := header[1]&0x80 != 0
	payloadLen := int(header[1] & 0x7F)

	if payloadLen == 126 {
		ext := make([]byte, 2)
		if _, err := io.ReadFull(conn, ext); err != nil {
			return nil, err
		}
		payloadLen = int(binary.BigEndian.Uint16(ext))
	} else if payloadLen == 127 {
		ext := make([]byte, 8)
		if _, err := io.ReadFull(conn, ext); err != nil {
			return nil, err
		}
		payloadLen = int(binary.BigEndian.Uint64(ext))
	}

	var maskKey [4]byte
	if masked {
		if _, err := io.ReadFull(conn, maskKey[:]); err != nil {
			return nil, err
		}
	}

	if payloadLen > 16<<20 {
		return nil, fmt.Errorf("ws frame too large: %d", payloadLen)
	}

	// Close frame — graceful shutdown
	if opcode == 0x08 {
		return nil, io.EOF
	}

	if payloadLen == 0 {
		return []byte{}, nil
	}

	payload := make([]byte, payloadLen)
	if _, err := io.ReadFull(conn, payload); err != nil {
		return nil, err
	}

	if masked {
		for i := range payload {
			payload[i] ^= maskKey[i%4]
		}
	}

	return payload, nil
}

func ApplyMimicHeaders(req *http.Request, cfg *MimicConfig, cookieName, cookieValue string) {
	if cfg == nil {
		return
	}
	req.Header.Set("User-Agent", cfg.UserAgent)
	if cfg.FakeDomain != "" {
		req.Header.Set("Host", cfg.FakeDomain)
	}
}

func BuildURLWithFakePath(baseURL, fakePath string) (string, error) {
	if fakePath == "" {
		return baseURL, nil
	}
	u, err := url.Parse(baseURL)
	if err != nil {
		return "", err
	}
	fp := fakePath
	if strings.Contains(fp, "{rand}") {
		fp = strings.ReplaceAll(fp, "{rand}", randAlphaNum(8))
	}
	if !strings.HasPrefix(fp, "/") {
		fp = "/" + fp
	}
	u.Path = fp
	return u.String(), nil
}

func randAlphaNum(n int) string {
	const letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	b := make([]byte, n)
	for i := range b {
		b[i] = letters[rand.Intn(len(letters))]
	}
	return string(b)
}

func generateWebSocketKey() string {
	b := make([]byte, 16)
	rand.Read(b)
	return fmt.Sprintf("%x", b)
}

func generateSessionID() string {
	b := make([]byte, 16)
	rand.Read(b)
	return fmt.Sprintf("%x", b)
}
