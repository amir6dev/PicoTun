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
	"time"

	"github.com/xtaci/smux"
	"gopkg.in/yaml.v3"
)

var configPath = flag.String("c", "config.yaml", "Path to config file")

func main() {
	flag.Parse()
	
	// Load Config
	data, err := os.ReadFile(*configPath)
	if err != nil {
		log.Fatalf("❌ Config Load Error: %v", err)
	}
	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		log.Fatalf("❌ YAML Parse Error: %v", err)
	}

	if cfg.Verbose {
		log.Printf("🔥 RsTunnel Core Running | Mode: %s | Transport: %s", cfg.Mode, cfg.Transport)
	}

	if cfg.Mode == "server" {
		runServer(&cfg)
	} else {
		runClient(&cfg)
	}
}

// --- SERVER LOGIC ---
func runServer(cfg *Config) {
	var ln net.Listener
	var err error

	// 1. Setup Listener
	if cfg.Transport == "httpsmux" || cfg.Transport == "wssmux" {
		cert, err := tls.LoadX509KeyPair(cfg.CertFile, cfg.KeyFile)
		if err != nil {
			log.Fatalf("❌ TLS Cert Error: %v", err)
		}
		ln, err = tls.Listen("tcp", cfg.Listen, &tls.Config{Certificates: []tls.Certificate{cert}})
	} else {
		ln, err = net.Listen("tcp", cfg.Listen)
	}

	if err != nil {
		log.Fatalf("❌ Bind Error: %v", err)
	}

	// 2. Start Port Mappings (Forwarders)
	for _, m := range cfg.Maps {
		go startMapping(m)
	}

	// 3. Accept Connections
	log.Printf("✅ Server Listening on %s", cfg.Listen)
	for {
		conn, err := ln.Accept()
		if err != nil { continue }
		go handleServerConn(conn, cfg)
	}
}

func handleServerConn(conn net.Conn, cfg *Config) {
	defer conn.Close()

	// Mimicry Check
	if cfg.Transport == "httpmux" || cfg.Transport == "httpsmux" {
		conn.SetReadDeadline(time.Now().Add(5 * time.Second))
		br := bufio.NewReader(conn)
		req, err := http.ReadRequest(br)
		if err != nil {
			return 
		}
		
		// Validate Host/Path to behave like real server
		if req.Host != cfg.HttpMimic.FakeDomain {
			// Sends 404 and closes (Avoids detection)
			conn.Write([]byte("HTTP/1.1 404 Not Found\r\n\r\n"))
			return
		}

		// Send 200 OK Mimicry
		resp := "HTTP/1.1 200 OK\r\n"
		resp += "Server: nginx\r\n"
		resp += "Date: " + time.Now().Format(time.RFC1123) + "\r\n"
		resp += "Content-Type: text/html\r\n"
		if cfg.HttpMimic.SessionCookie {
			resp += fmt.Sprintf("Set-Cookie: SESSIONID=%d; Path=/; Secure\r\n", rand.Int63())
		}
		resp += "\r\n"
		conn.Write([]byte(resp))
		conn.SetReadDeadline(time.Time{}) // Disable deadline
	}

	// Upgrade to SMUX
	smuxConfig := smux.DefaultConfig()
	smuxConfig.KeepAliveInterval = time.Duration(cfg.Smux.KeepAlive) * time.Second
	
	sess, err := smux.Server(conn, smuxConfig)
	if err != nil { return }
	defer sess.Close()

	for {
		stream, err := sess.AcceptStream()
		if err != nil { return }
		
		// In a real reverse tunnel (Dagger style), 
		// the client initiates connection.
		// For Port Mapping to work:
		// Server listens on BIND port -> SMUX Stream -> Client connects to TARGET.
		// BUT here, client code creates paths to server.
		// This implies Server is the "Bridge".
		// We need a mechanism to route traffic.
		// For simplicity in this structure: Server accepts stream and handles it.
		stream.Close() // Placeholder for complex routing logic
	}
}

func startMapping(m PortMap) {
	l, err := net.Listen(m.Type, m.Bind)
	if err != nil {
		log.Printf("❌ Mapping Failed: %v", err)
		return
	}
	log.Printf("🔗 Map Started: %s -> %s", m.Bind, m.Target)
	for {
		c, err := l.Accept()
		if err != nil { continue }
		go func(local net.Conn) {
			remote, err := net.Dial(m.Type, m.Target)
			if err != nil { local.Close(); return }
			pipe(local, remote)
		}(c)
	}
}

// --- CLIENT LOGIC ---
func runClient(cfg *Config) {
	for _, path := range cfg.Paths {
		for i := 0; i < path.ConnectionPool; i++ {
			go maintainPath(path, cfg)
		}
	}
	select {} // Block main thread
}

func maintainPath(path PathConfig, cfg *Config) {
	for {
		conn, err := dial(path)
		if err != nil {
			time.Sleep(time.Duration(path.RetryInterval) * time.Second)
			continue
		}

		// HTTP Mimicry Handshake
		if path.Transport == "httpmux" || path.Transport == "httpsmux" {
			req := fmt.Sprintf("GET %s HTTP/1.1\r\n", cfg.HttpMimic.FakePath)
			req += fmt.Sprintf("Host: %s\r\n", cfg.HttpMimic.FakeDomain)
			req += fmt.Sprintf("User-Agent: %s\r\n", cfg.HttpMimic.UserAgent)
			req += "\r\n"
			conn.Write([]byte(req))
			
			// Read 200 OK
			buf := make([]byte, 1024)
			conn.Read(buf)
		}

		// SMUX Client
		smuxConfig := smux.DefaultConfig()
		sess, err := smux.Client(conn, smuxConfig)
		if err != nil {
			conn.Close()
			continue
		}
		
		log.Printf("✅ Tunnel Connected: %s", path.Addr)
		<-sess.CloseChan() // Wait until closed
	}
}

func dial(p PathConfig) (net.Conn, error) {
	d := net.Dialer{Timeout: time.Duration(p.DialTimeout) * time.Second}
	if p.Transport == "httpsmux" {
		return tls.DialWithDialer(&d, "tcp", p.Addr, &tls.Config{InsecureSkipVerify: true})
	}
	return d.Dial("tcp", p.Addr)
}

func pipe(a, b io.ReadWriteCloser) {
	defer a.Close(); defer b.Close()
	go io.Copy(a, b); io.Copy(b, a)
}