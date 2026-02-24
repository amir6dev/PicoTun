package httpmux

import (
	"bufio"
	"fmt"
	"math/rand"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
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

// randomAcceptLang returns a realistic Accept-Language header
func randomAcceptLang() string {
	langs := []string{
		"en-US,en;q=0.9",
		"en-US,en;q=0.9,fa;q=0.8",
		"en-GB,en;q=0.9,en-US;q=0.8",
		"en-US,en;q=0.9,de;q=0.8",
		"en-US,en;q=0.9,fr;q=0.8",
		"en,en-US;q=0.9",
		"en-US,en;q=0.9,ar;q=0.8",
		"en-US,en;q=0.9,tr;q=0.8",
	}
	return langs[secureRandInt(len(langs))]
}

// randomPlatform returns a Sec-Ch-Ua-Platform value
func randomPlatform() string {
	platforms := []string{`"Windows"`, `"macOS"`, `"Linux"`}
	return platforms[secureRandInt(len(platforms))]
}

// randomQueryString generates a realistic random query string
func randomQueryString() string {
	queries := []string{
		"?q=" + randAlphaNum(5+secureRandInt(10)),
		"?s=" + randAlphaNum(4+secureRandInt(8)) + "&lang=en",
		"?p=" + fmt.Sprintf("%d", 1+secureRandInt(500)),
		"?id=" + randAlphaNum(8) + "&v=" + fmt.Sprintf("%d", secureRandInt(10)),
		"?ref=" + randAlphaNum(6),
		"?t=" + fmt.Sprintf("%d", 1700000000+secureRandInt(100000000)),
		"?utm_source=" + randAlphaNum(5) + "&utm_medium=web",
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

// ServerHandshake — server-side validation (for tcpmux direct mode)
func ServerHandshake(conn net.Conn, cfg *MimicConfig) error {
	conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	defer conn.SetReadDeadline(time.Time{})

	reader := bufio.NewReader(conn)
	req, err := http.ReadRequest(reader)
	if err != nil {
		return err
	}

	if cfg != nil && cfg.FakeDomain != "" {
		if req.Host != cfg.FakeDomain && !strings.HasSuffix(req.Host, "."+cfg.FakeDomain) {
			writeFakeResponse(conn, 404)
			return fmt.Errorf("invalid host: %s", req.Host)
		}
	}

	expectedPath := "/"
	if cfg != nil && cfg.FakePath != "" {
		expectedPath = strings.Split(cfg.FakePath, "{")[0]
	}
	if !strings.HasPrefix(req.URL.Path, expectedPath) {
		writeFakeResponse(conn, 404)
		return fmt.Errorf("invalid path: %s", req.URL.Path)
	}

	resp := "HTTP/1.1 101 Switching Protocols\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" +
		"\r\n"
	_, err = conn.Write([]byte(resp))
	return err
}

func writeFakeResponse(conn net.Conn, code int) {
	resp := fmt.Sprintf("HTTP/1.1 %d Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", code)
	conn.Write([]byte(resp))
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
