package main

import (
	"bufio"
	"crypto/tls"
	"flag"
	"fmt"
	"io"
	"log"
	"math/rand"
	"net"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/xtaci/smux"
	"gopkg.in/yaml.v3"
)

// --- Config Structures (Matching Dagger YAML Structure) ---

type Config struct {
	Mode        string            `yaml:"mode"`
	Listen      string            `yaml:"listen,omitempty"`
	Transport   string            `yaml:"transport,omitempty"`
	PSK         string            `yaml:"psk"`
	Profile     string            `yaml:"profile"`
	Verbose     bool              `yaml:"verbose"`
	CertFile    string            `yaml:"cert_file,omitempty"`
	KeyFile     string            `yaml:"key_file,omitempty"`
	
	Maps        []PortMap         `yaml:"maps,omitempty"`
	Paths       []PathConfig      `yaml:"paths,omitempty"`
	
	Obfuscation ObfuscationConfig `yaml:"obfuscation"`
	HttpMimic   HttpMimicConfig   `yaml:"http_mimic"`
	Smux        SmuxConfig        `yaml:"smux"`
	Advanced    AdvancedConfig    `yaml:"advanced"`
}

type PortMap struct {
	Type   string `yaml:"type"`
	Bind   string `yaml:"bind"`
	Target string `yaml:"target"`
}

type PathConfig struct {
	Transport      string `yaml:"transport"`
	Addr           string `yaml:"addr"`
	ConnectionPool int    `yaml:"connection_pool"`
	AggressivePool bool   `yaml:"aggressive_pool"`
	RetryInterval  int    `yaml:"retry_interval"`
	DialTimeout    int    `yaml:"dial_timeout"`
}

type ObfuscationConfig struct {
	Enabled     bool    `yaml:"enabled"`
	MinPadding  int     `yaml:"min_padding"`
	MaxPadding  int     `yaml:"max_padding"`
	MinDelayMs  int     `yaml:"min_delay_ms"`
	MaxDelayMs  int     `yaml:"max_delay_ms"`
	BurstChance float64 `yaml:"burst_chance"`
}

type HttpMimicConfig struct {
	FakeDomain      string   `yaml:"fake_domain"`
	FakePath        string   `yaml:"fake_path"`
	UserAgent       string   `yaml:"user_agent"`
	ChunkedEncoding bool     `yaml:"chunked_encoding"`
	SessionCookie   bool     `yaml:"session_cookie"`
	CustomHeaders   []string `yaml:"custom_headers"`
}

type SmuxConfig struct {
	KeepAlive int `yaml:"keepalive"`
	MaxRecv   int `yaml:"max_recv"`
	MaxStream int `yaml:"max_stream"`
	FrameSize int `yaml:"frame_size"`
	Version   int `yaml:"version"`
}

type AdvancedConfig struct {
	TcpNoDelay      bool `yaml:"tcp_nodelay"`
	TcpKeepAlive    int  `yaml:"tcp_keepalive"`
	TcpReadBuffer   int  `yaml:"tcp_read_buffer"`
	TcpWriteBuffer  int  `yaml:"tcp_write_buffer"`
	MaxConnections  int  `yaml:"max_connections"`
}

var (
	configPath    = flag.String("c", "/etc/DaggerConnect/config.yaml", "Path to config file")
	globalSession *smux.Session
	sessionMutex  sync.Mutex
)

func main() {
	flag.Parse()
	
	data, err := os.ReadFile(*configPath)
	if err != nil { log.Fatalf("❌ Config Load Error: %v", err) }
	
	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil { log.Fatalf("❌ YAML Parse Error: %v", err) }

	if cfg.Verbose {
		log.Printf("🔥 DaggerConnect Started | Mode: %s | Profile: %s", cfg.Mode, cfg.Profile)
	}

	if cfg.Mode == "server" {
		runServer(&cfg)
	} else {
		runClient(&cfg)
	}
}

// ================= HELPERS =================

func applyAdvancedTCP(conn net.Conn, adv *AdvancedConfig) {
	if tcpConn, ok := conn.(*net.TCPConn); ok {
		tcpConn.SetNoDelay(adv.TcpNoDelay)
		tcpConn.SetKeepAlive(true)
		tcpConn.SetKeepAlivePeriod(time.Duration(adv.TcpKeepAlive) * time.Second)
		if adv.TcpReadBuffer > 0 { tcpConn.SetReadBuffer(adv.TcpReadBuffer) }
		if adv.TcpWriteBuffer > 0 { tcpConn.SetWriteBuffer(adv.TcpWriteBuffer) }
	}
}

func getSmuxConfig(s *SmuxConfig) *smux.Config {
	conf := smux.DefaultConfig()
	if s.KeepAlive > 0 { conf.KeepAliveInterval = time.Duration(s.KeepAlive) * time.Second }
	if s.MaxRecv > 0 { conf.MaxReceiveBuffer = s.MaxRecv }
	if s.MaxStream > 0 { conf.MaxStreamBuffer = s.MaxStream }
	if s.FrameSize > 0 { conf.MaxFrameSize = s.FrameSize }
	if s.Version > 0 { conf.Version = s.Version }
	return conf
}

// ================= SERVER =================

func runServer(cfg *Config) {
	// 1. Listen for Tunnel
	go func() {
		var ln net.Listener
		var err error
		
		if cfg.Transport == "httpsmux" || cfg.Transport == "wssmux" {
			cert, err := tls.LoadX509KeyPair(cfg.CertFile, cfg.KeyFile)
			if err != nil { log.Fatalf("TLS Error: %v", err) }
			ln, err = tls.Listen("tcp", cfg.Listen, &tls.Config{Certificates: []tls.Certificate{cert}})
		} else {
			ln, err = net.Listen("tcp", cfg.Listen)
		}
		if err != nil { log.Fatalf("Listen Error: %v", err) }
		if cfg.Verbose { log.Printf("✅ Tunnel Listening on %s (%s)", cfg.Listen, cfg.Transport) }

		for {
			conn, err := ln.Accept()
			if err != nil { continue }
			
			// Apply Advanced TCP settings
			applyAdvancedTCP(conn, &cfg.Advanced)
			
			go handleServerTunnel(conn, cfg)
		}
	}()

	// 2. Start Port Mappings
	for _, m := range cfg.Maps {
		go startServerMapping(m, cfg)
	}

	select {}
}

func handleServerTunnel(conn net.Conn, cfg *Config) {
	// Obfuscation: Initial Delay
	if cfg.Obfuscation.Enabled {
		delay := cfg.Obfuscation.MinDelayMs
		if cfg.Obfuscation.MaxDelayMs > cfg.Obfuscation.MinDelayMs {
			delay += rand.Intn(cfg.Obfuscation.MaxDelayMs - cfg.Obfuscation.MinDelayMs)
		}
		if delay > 0 { time.Sleep(time.Duration(delay) * time.Millisecond) }
	}

	// HTTP Mimicry
	if cfg.Transport == "httpmux" || cfg.Transport == "httpsmux" {
		conn.SetReadDeadline(time.Now().Add(5 * time.Second))
		br := bufio.NewReader(conn)
		req, err := http.ReadRequest(br)
		if err != nil { conn.Close(); return }

		if req.Host != cfg.HttpMimic.FakeDomain {
			conn.Write([]byte("HTTP/1.1 404 Not Found\r\n\r\n"))
			conn.Close(); return
		}

		// Fake Response
		resp := "HTTP/1.1 200 OK\r\nServer: nginx\r\nDate: " + time.Now().Format(time.RFC1123) + "\r\n"
		if cfg.HttpMimic.SessionCookie { resp += fmt.Sprintf("Set-Cookie: SID=%d; Path=/; Secure\r\n", rand.Int63()) }
		if cfg.HttpMimic.ChunkedEncoding { resp += "Transfer-Encoding: chunked\r\n" }
		resp += "\r\n"
		conn.Write([]byte(resp))
		conn.SetReadDeadline(time.Time{})
	}

	// SMUX Session
	smuxConf := getSmuxConfig(&cfg.Smux)
	session, err := smux.Server(conn, smuxConf)
	if err != nil { return }

	sessionMutex.Lock()
	if globalSession != nil { globalSession.Close() }
	globalSession = session
	sessionMutex.Unlock()

	if cfg.Verbose { log.Println("🔌 Tunnel Established") }
}

func startServerMapping(m PortMap, cfg *Config) {
	l, err := net.Listen(m.Type, m.Bind)
	if err != nil {
		log.Printf("❌ Map Bind Error %s: %v", m.Bind, err)
		return
	}
	log.Printf("🔗 Mapped %s -> Tunnel -> %s", m.Bind, m.Target)

	for {
		userConn, err := l.Accept()
		if err != nil { continue }
		
		applyAdvancedTCP(userConn, &cfg.Advanced)

		go func(uConn net.Conn) {
			defer uConn.Close()
			sessionMutex.Lock()
			sess := globalSession
			sessionMutex.Unlock()

			if sess == nil || sess.IsClosed() { return }

			stream, err := sess.OpenStream()
			if err != nil { return }
			defer stream.Close()

			// PROTOCOL: Target Address
			targetBytes := []byte(m.Target)
			stream.Write([]byte{byte(len(targetBytes))})
			stream.Write(targetBytes)

			pipe(uConn, stream)
		}(userConn)
	}
}

// ================= CLIENT =================

func runClient(cfg *Config) {
	for _, path := range cfg.Paths {
		for i := 0; i < path.ConnectionPool; i++ {
			go maintainPath(path, cfg)
		}
	}
	select {}
}

func maintainPath(path PathConfig, cfg *Config) {
	for {
		var conn net.Conn
		var err error
		d := net.Dialer{Timeout: time.Duration(path.DialTimeout) * time.Second}
		
		if path.Transport == "httpsmux" {
			conn, err = tls.DialWithDialer(&d, "tcp", path.Addr, &tls.Config{InsecureSkipVerify: true})
		} else {
			conn, err = d.Dial("tcp", path.Addr)
		}
		
		if err != nil {
			time.Sleep(time.Duration(path.RetryInterval) * time.Second)
			continue
		}

		applyAdvancedTCP(conn, &cfg.Advanced)

		// HTTP Mimicry Request
		if path.Transport == "httpmux" || path.Transport == "httpsmux" {
			req := fmt.Sprintf("GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: %s\r\n", 
				cfg.HttpMimic.FakePath, cfg.HttpMimic.FakeDomain, cfg.HttpMimic.UserAgent)
			for _, h := range cfg.HttpMimic.CustomHeaders { req += h + "\r\n" }
			req += "\r\n"
			conn.Write([]byte(req))

			buf := make([]byte, 1024)
			conn.Read(buf)
		}

		smuxConf := getSmuxConfig(&cfg.Smux)
		session, err := smux.Client(conn, smuxConf)
		if err != nil { conn.Close(); continue }

		if cfg.Verbose { log.Printf("✅ Connected to %s", path.Addr) }

		for {
			stream, err := session.AcceptStream()
			if err != nil { break }
			go handleClientStream(stream, cfg)
		}
		session.Close()
	}
}

func handleClientStream(stream net.Conn, cfg *Config) {
	defer stream.Close()

	lenBuf := make([]byte, 1)
	if _, err := stream.Read(lenBuf); err != nil { return }
	targetLen := int(lenBuf[0])
	
	targetBuf := make([]byte, targetLen)
	if _, err := io.ReadFull(stream, targetBuf); err != nil { return }
	targetAddr := string(targetBuf)

	targetConn, err := net.Dial("tcp", targetAddr)
	if err != nil { return }
	defer targetConn.Close()
	
	applyAdvancedTCP(targetConn, &cfg.Advanced)

	pipe(stream, targetConn)
}

func pipe(a, b io.ReadWriteCloser) {
	go io.Copy(a, b)
	io.Copy(b, a)
}