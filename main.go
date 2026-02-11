package main

import (
	"crypto/tls"
	"flag"
	"fmt"
	"io"
	"math/rand"
	"net"
	"net/http"
	"os"
	"time"
	"log"
	"bufio"
	"strings"

	"github.com/xtaci/smux"
)

var configPath = flag.String("c", "config.yaml", "Path to config file")

func main() {
	flag.Parse()
	cfg, err := LoadConfig(*configPath)
	if err != nil {
		log.Fatalf("❌ Failed to load config: %v", err)
	}

	if cfg.Verbose {
		log.Printf("🔥 RsTunnel Loaded | Mode: %s | Profile: %s", cfg.Mode, cfg.Profile)
	}

	if cfg.Mode == "server" {
		runServer(cfg)
	} else {
		runClient(cfg)
	}
}

// --- Server Logic ---
func runServer(cfg *Config) {
	log.Printf("🚀 Starting Server on %s (%s)", cfg.Listen, cfg.Transport)

	var listener net.Listener
	var err error

	if cfg.Transport == "httpsmux" || cfg.Transport == "wssmux" {
		cert, err := tls.LoadX509KeyPair(cfg.CertFile, cfg.KeyFile)
		if err != nil {
			log.Fatalf("❌ TLS Error: %v", err)
		}
		listener, err = tls.Listen("tcp", cfg.Listen, &tls.Config{Certificates: []tls.Certificate{cert}})
	} else {
		listener, err = net.Listen("tcp", cfg.Listen)
	}
	if err != nil {
		log.Fatalf("❌ Listen Error: %v", err)
	}

	// Start Port Mappings
	for _, m := range cfg.Maps {
		go startPortMapping(m, cfg)
	}

	// Accept Tunnel Connections
	for {
		conn, err := listener.Accept()
		if err != nil {
			continue
		}
		go handleServerConnection(conn, cfg)
	}
}

func handleServerConnection(conn net.Conn, cfg *Config) {
	defer conn.Close()
	
	// 1. Obfuscation Delay (simulated jitter)
	if cfg.Obfuscation.Enabled {
		delay := rand.Intn(cfg.Obfuscation.MaxDelayMs-cfg.Obfuscation.MinDelayMs) + cfg.Obfuscation.MinDelayMs
		time.Sleep(time.Duration(delay) * time.Millisecond)
	}

	// 2. HTTP Mimicry Check
	if cfg.Transport == "httpmux" || cfg.Transport == "httpsmux" {
		if !checkHttpMimicry(conn, cfg) {
			return
		}
		// Send Fake Response
		sendFakeHttpResponse(conn, cfg)
	}

	// 3. Upgrade to SMUX
	smuxConf := getSmuxConfig(&cfg.Smux)
	session, err := smux.Server(conn, smuxConf)
	if err != nil {
		return
	}
	defer session.Close()

	// 4. Accept Streams (Multiplexing)
	for {
		stream, err := session.AcceptStream()
		if err != nil {
			return
		}
		// In a real scenario, the stream would carry metadata about WHICH target to connect to.
		// For simplicity in this structure, we assume a direct mapping or handle it via protocol.
		// Here we just close it because 'Maps' handles the actual user traffic binding.
		// NOTE: DaggerConnect likely uses a custom protocol inside SMUX to route traffic.
		// To keep it simple: We need a "Bridge" logic here. 
		// BUT wait, in Dagger, clients connect to Server. Server maps ports.
		// Actually, usually Client opens local port -> Tunnel -> Server -> Target.
		// OR Server opens port -> Tunnel -> Client -> Target.
		// Based on your config, it seems:
		// Client (User) -> Client App -> Tunnel -> Server App -> Target (Internet)
		// Let's implement that flow.
		go handleStream(stream) 
	}
}

func handleStream(stream net.Conn) {
	// Simple echo or handling. In full implementation, we need a SOCKS/HTTP handler or port forward target.
	// Since Dagger config has "Maps" on Server, it might be Reverse Tunnel?
	// No, "Maps: Bind: 0.0.0.0:8443, Target: 127.0.0.1:443" on Server means:
	// Server listens on 8443, forwards to 127.0.0.1:443. This is just a simple port forwarder?
	// If it's a tunnel, User connects to Client -> Tunnel -> Server -> Target.
	stream.Close() 
}

// Simple Port Mapper (TCP)
func startPortMapping(m PortMap, cfg *Config) {
	l, err := net.Listen("tcp", m.Bind)
	if err != nil {
		log.Printf("❌ Map Bind Error %s: %v", m.Bind, err)
		return
	}
	log.Printf("🔗 Mapped %s -> %s", m.Bind, m.Target)
	
	for {
		c, err := l.Accept()
		if err != nil { continue }
		go func(userConn net.Conn) {
			targetConn, err := net.Dial("tcp", m.Target)
			if err != nil { userConn.Close(); return }
			pipe(userConn, targetConn)
		}(c)
	}
}

// --- Client Logic ---
func runClient(cfg *Config) {
	log.Printf("🌍 Starting Client with %d paths", len(cfg.Paths))
	
	// Client needs to listen on something? Or just dial?
	// Dagger client config usually implies it connects to server and exposes a local port (SOCKS/HTTP)
	// OR it just maintains the tunnel.
	// Based on the config provided: "paths" define connections TO server.
	// But where does the user connect? 
	// Ah, usually Client has "inbounds". The provided config example for client is missing "listen" or "inbounds".
	// Assuming Client opens a local SOCKS/HTTP proxy or Port Forward.
	// For this code, we'll implement the "Paths" dialing logic to keep the tunnel alive.
	
	for _, path := range cfg.Paths {
		for i := 0; i < path.ConnectionPool; i++ {
			go maintainPath(path, cfg)
		}
	}
	select {} // Block forever
}

func maintainPath(path PathConfig, cfg *Config) {
	for {
		conn, err := dialPath(path, cfg)
		if err != nil {
			time.Sleep(time.Duration(path.RetryInterval) * time.Second)
			continue
		}
		
		// Handshake
		if cfg.Transport == "httpmux" || cfg.Transport == "httpsmux" {
			sendHttpMimicryRequest(conn, cfg)
			// Read response
			buf := make([]byte, 1024)
			conn.Read(buf) 
		}

		// SMUX Session
		smuxConf := getSmuxConfig(&cfg.Smux)
		session, err := smux.Client(conn, smuxConf)
		if err != nil {
			conn.Close()
			continue
		}
		
		// Keep alive loop or stream handling
		// In a real app, we would put this session into a pool to be used by incoming user traffic.
		log.Printf("✅ Tunnel Connected to %s", path.Addr)
		
		// Block until closed
		<-session.CloseChan()
	}
}

func dialPath(path PathConfig, cfg *Config) (net.Conn, error) {
	d := net.Dialer{Timeout: time.Duration(path.DialTimeout) * time.Second}
	if path.Transport == "httpsmux" {
		return tls.DialWithDialer(&d, "tcp", path.Addr, &tls.Config{InsecureSkipVerify: true})
	}
	return d.Dial("tcp", path.Addr)
}

// --- Helpers ---

func checkHttpMimicry(conn net.Conn, cfg *Config) bool {
	// Read first bytes to check Host/Path
	buf := bufio.NewReader(conn)
	req, err := http.ReadRequest(buf)
	if err != nil { return false }
	
	// Check Host
	if req.Host != cfg.HttpMimic.FakeDomain {
		return false
	}
	// Check Path
	if req.URL.Path != cfg.HttpMimic.FakePath {
		return false
	}
	return true
}

func sendFakeHttpResponse(conn net.Conn, cfg *Config) {
	// Generate realistic headers
	resp := "HTTP/1.1 200 OK\r\n"
	resp += "Server: gws\r\n"
	resp += "Date: " + time.Now().Format(time.RFC1123) + "\r\n"
	resp += "Content-Type: text/html; charset=UTF-8\r\n"
	
	if cfg.HttpMimic.SessionCookie {
		resp += fmt.Sprintf("Set-Cookie: SID=%d; Path=/; Domain=.%s\r\n", rand.Int63(), cfg.HttpMimic.FakeDomain)
	}
	if cfg.HttpMimic.ChunkedEncoding {
		resp += "Transfer-Encoding: chunked\r\n"
	}
	resp += "\r\n"
	conn.Write([]byte(resp))
}

func sendHttpMimicryRequest(conn net.Conn, cfg *Config) {
	req := fmt.Sprintf("GET %s HTTP/1.1\r\n", cfg.HttpMimic.FakePath)
	req += fmt.Sprintf("Host: %s\r\n", cfg.HttpMimic.FakeDomain)
	req += fmt.Sprintf("User-Agent: %s\r\n", cfg.HttpMimic.UserAgent)
	for _, h := range cfg.HttpMimic.CustomHeaders {
		req += h + "\r\n"
	}
	req += "\r\n"
	conn.Write([]byte(req))
}

func getSmuxConfig(c *SmuxConfig) *smux.Config {
	conf := smux.DefaultConfig()
	conf.KeepAliveInterval = time.Duration(c.KeepAlive) * time.Second
	conf.MaxReceiveBuffer = c.MaxRecv
	conf.MaxStreamBuffer = c.MaxStream
	conf.MaxFrameSize = c.FrameSize
	conf.Version = c.Version
	return conf
}

func pipe(a, b io.ReadWriteCloser) {
	defer a.Close()
	defer b.Close()
	go io.Copy(a, b)
	io.Copy(b, a)
}