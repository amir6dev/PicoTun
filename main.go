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

// --- Config Structures (Matching Dagger YAML) ---

type Config struct {
	Mode        string            `yaml:"mode"` // server, client
	Listen      string            `yaml:"listen,omitempty"`
	Transport   string            `yaml:"transport,omitempty"`
	PSK         string            `yaml:"psk"`
	Profile     string            `yaml:"profile"`
	Verbose     bool              `yaml:"verbose"`
	CertFile    string            `yaml:"cert_file,omitempty"`
	KeyFile     string            `yaml:"key_file,omitempty"`
	
	Maps        []PortMap         `yaml:"maps,omitempty"`   // Server Side Maps
	Paths       []PathConfig      `yaml:"paths,omitempty"`  // Client Side Paths
	
	Obfuscation ObfuscationConfig `yaml:"obfuscation"`
	HttpMimic   HttpMimicConfig   `yaml:"http_mimic"`
	Smux        SmuxConfig        `yaml:"smux"`
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
}

var (
	configPath    = flag.String("c", "/etc/DaggerConnect/config.yaml", "Path to config")
	globalSession *smux.Session
	sessionMutex  sync.Mutex
)

func main() {
	flag.Parse()
	
	// Load Config
	data, err := os.ReadFile(*configPath)
	if err != nil { log.Fatalf("❌ Config Load Error: %v", err) }
	
	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil { log.Fatalf("❌ YAML Error: %v", err) }

	if cfg.Verbose {
		log.Printf("🔥 DaggerConnect Core | Mode: %s | Transport: %s", cfg.Mode, cfg.Transport)
	}

	if cfg.Mode == "server" {
		runServer(&cfg)
	} else {
		runClient(&cfg)
	}
}

// ================= SERVER LOGIC (Reverse Tunnel) =================

func runServer(cfg *Config) {
	// 1. Listen for Incoming Tunnel Connections
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
		if cfg.Verbose { log.Printf("✅ Tunnel Listening on %s", cfg.Listen) }

		for {
			conn, err := ln.Accept()
			if err != nil { continue }
			go handleServerHandshake(conn, cfg)
		}
	}()

	// 2. Start Port Mappings (Reverse Forwarding)
	// Server listens on 'bind', sends data through tunnel to Client, Client dials 'target'
	for _, m := range cfg.Maps {
		go startServerListener(m)
	}

	select {} // Keep running
}

func handleServerHandshake(conn net.Conn, cfg *Config) {
	// Obfuscation Delay
	if cfg.Obfuscation.Enabled && cfg.Obfuscation.MinDelayMs > 0 {
		time.Sleep(time.Duration(cfg.Obfuscation.MinDelayMs) * time.Millisecond)
	}

	// HTTP Mimicry Validation
	if cfg.Transport == "httpmux" || cfg.Transport == "httpsmux" {
		conn.SetReadDeadline(time.Now().Add(5 * time.Second))
		br := bufio.NewReader(conn)
		req, err := http.ReadRequest(br)
		if err != nil { conn.Close(); return }

		if req.Host != cfg.HttpMimic.FakeDomain {
			conn.Write([]byte("HTTP/1.1 404 Not Found\r\n\r\n"))
			conn.Close(); return
		}

		// Send Fake 200 OK
		resp := "HTTP/1.1 200 OK\r\nServer: nginx\r\nDate: " + time.Now().Format(time.RFC1123) + "\r\n"
		if cfg.HttpMimic.SessionCookie { resp += fmt.Sprintf("Set-Cookie: SID=%d; Path=/; Secure\r\n", rand.Int63()) }
		resp += "\r\n"
		conn.Write([]byte(resp))
		conn.SetReadDeadline(time.Time{})
	}

	// Upgrade to SMUX
	smuxConf := smux.DefaultConfig()
	session, err := smux.Server(conn, smuxConf)
	if err != nil { return }

	// Store Session (Single Client Assumption for simplicity, or last wins)
	sessionMutex.Lock()
	if globalSession != nil { globalSession.Close() }
	globalSession = session
	sessionMutex.Unlock()
	
	if cfg.Verbose { log.Println("🔌 Tunnel Established") }
}

func startServerListener(m PortMap) {
	l, err := net.Listen(m.Type, m.Bind)
	if err != nil {
		log.Printf("❌ Map Bind Error %s: %v", m.Bind, err)
		return
	}
	log.Printf("🔗 Mapped %s -> Tunnel -> %s", m.Bind, m.Target)

	for {
		userConn, err := l.Accept()
		if err != nil { continue }

		go func(uConn net.Conn) {
			defer uConn.Close()
			sessionMutex.Lock()
			sess := globalSession
			sessionMutex.Unlock()

			if sess == nil || sess.IsClosed() { return }

			// Open stream inside tunnel
			stream, err := sess.OpenStream()
			if err != nil { return }
			defer stream.Close()

			// PROTOCOL: Send Target Address Length + Address
			targetBytes := []byte(m.Target)
			stream.Write([]byte{byte(len(targetBytes))})
			stream.Write(targetBytes)

			pipe(uConn, stream)
		}(userConn)
	}
}

// ================= CLIENT LOGIC =================

func runClient(cfg *Config) {
	for _, path := range cfg.Paths {
		for i := 0; i < path.ConnectionPool; i++ {
			go maintainClientConnection(path, cfg)
		}
	}
	select {}
}

func maintainClientConnection(path PathConfig, cfg *Config) {
	for {
		// 1. Dial Server
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

		// 2. HTTP Mimicry Handshake
		if path.Transport == "httpmux" || path.Transport == "httpsmux" {
			req := fmt.Sprintf("GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: %s\r\n", 
				cfg.HttpMimic.FakePath, cfg.HttpMimic.FakeDomain, cfg.HttpMimic.UserAgent)
			for _, h := range cfg.HttpMimic.CustomHeaders { req += h + "\r\n" }
			req += "\r\n"
			conn.Write([]byte(req))

			buf := make([]byte, 1024)
			conn.Read(buf) // Read 200 OK
		}

		// 3. Start SMUX Client
		session, err := smux.Client(conn, smux.DefaultConfig())
		if err != nil { conn.Close(); continue }

		if cfg.Verbose { log.Printf("✅ Connected to %s", path.Addr) }

		// 4. Accept Reverse Streams
		for {
			stream, err := session.AcceptStream()
			if err != nil { break }
			go handleReverseStream(stream)
		}
		session.Close()
	}
}

func handleReverseStream(stream net.Conn) {
	defer stream.Close()

	// Read Target Length & Address
	lenBuf := make([]byte, 1)
	if _, err := stream.Read(lenBuf); err != nil { return }
	targetLen := int(lenBuf[0])
	
	targetBuf := make([]byte, targetLen)
	if _, err := io.ReadFull(stream, targetBuf); err != nil { return }
	targetAddr := string(targetBuf)

	// Dial Local Target
	targetConn, err := net.Dial("tcp", targetAddr)
	if err != nil { return }
	defer targetConn.Close()

	pipe(stream, targetConn)
}

func pipe(a, b io.ReadWriteCloser) {
	go io.Copy(a, b)
	io.Copy(b, a)
}