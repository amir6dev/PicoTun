package main

import (
	"crypto/tls"
	"flag"
	"fmt"
	"io"
	"math/rand"
	"net"
	"strings"
	"time"

	"github.com/xtaci/smux"
)

var (
	listenAddr = flag.String("l", ":443", "Tunnel Port")
	userAddr   = flag.String("u", ":1432", "User Port")
	mode       = flag.String("m", "httpmux", "Mode: httpmux/httpsmux")
	profile    = flag.String("profile", "balanced", "Profile")
	certFile   = flag.String("cert", "", "Cert File")
	keyFile    = flag.String("key", "", "Key File")
	fakeHost   = flag.String("host", "www.google.com", "Fake Host")
	fakePath   = flag.String("path", "/search", "Fake Path")
)

var globalSession *smux.Session

func main() {
	flag.Parse()
	fmt.Printf("🔥 Bridge Started | Mode: %s | Profile: %s\n", *mode, *profile)

	smuxConfig := getSmuxConfig(*profile)
	var listener net.Listener
	var err error

	if *mode == "httpsmux" {
		if *certFile == "" || *keyFile == "" {
			panic("❌ Cert/Key required for httpsmux")
		}
		cert, err := tls.LoadX509KeyPair(*certFile, *keyFile)
		if err != nil { panic(err) }
		listener, err = tls.Listen("tcp", *listenAddr, &tls.Config{Certificates: []tls.Certificate{cert}})
	} else {
		listener, err = net.Listen("tcp", *listenAddr)
	}
	if err != nil { panic(err) }

	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil { continue }
			go handleHandshake(conn, smuxConfig)
		}
	}()

	userListener, err := net.Listen("tcp", *userAddr)
	if err != nil { panic(err) }

	for {
		uConn, err := userListener.Accept()
		if err != nil { continue }
		if globalSession == nil || globalSession.IsClosed() {
			uConn.Close()
			continue
		}
		stream, err := globalSession.OpenStream()
		if err != nil {
			uConn.Close()
			continue
		}
		go pipe(uConn, stream)
	}
}

func handleHandshake(conn net.Conn, config *smux.Config) {
	conn.SetDeadline(time.Now().Add(10 * time.Second))
	buf := make([]byte, 4096)
	n, err := conn.Read(buf)
	if err != nil { conn.Close(); return }

	reqData := string(buf[:n])
	if !strings.Contains(reqData, *fakeHost) {
		conn.Close()
		return
	}

	header := fmt.Sprintf("HTTP/1.1 200 OK\r\n"+
		"Date: %s\r\n"+
		"Content-Type: text/html\r\n"+
		"Transfer-Encoding: chunked\r\n"+
		"Server: gws\r\n\r\n", time.Now().Format(time.RFC1123))
	
	conn.Write([]byte(header))
	conn.SetDeadline(time.Time{})

	sess, err := smux.Client(conn, config)
	if err != nil { conn.Close(); return }
	globalSession = sess
	fmt.Println("✅ Upstream Connected!")
}

func getSmuxConfig(p string) *smux.Config {
	c := smux.DefaultConfig()
	switch p {
	case "aggressive":
		c.KeepAliveInterval = 5 * time.Second
		c.MaxReceiveBuffer = 16 * 1024 * 1024
	case "gaming":
		c.KeepAliveInterval = 1 * time.Second
	default:
		c.KeepAliveInterval = 10 * time.Second
	}
	return c
}

func pipe(a, b io.ReadWriteCloser) {
	defer a.Close()
	defer b.Close()
	io.Copy(a, b)
	io.Copy(b, a)
}