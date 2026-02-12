package httpmux

import (
	"crypto/tls"
	"net"
	"net/http"
	"time"

	"golang.org/x/net/http2"
)

type Client struct {
	Transport *HTTPMuxTransport
}

func NewClient(serverURL, sessionID string, mimic *MimicConfig, obfs *ObfsConfig, psk string) *Client {
	pool := 3
	conns := make([]*HTTPConn, pool)

	for i := 0; i < pool; i++ {
		tr := &http.Transport{
			Proxy: http.ProxyFromEnvironment,
			DialContext: (&net.Dialer{
				Timeout:   10 * time.Second,
				KeepAlive: 30 * time.Second,
			}).DialContext,
			TLSClientConfig: &tls.Config{
				MinVersion: tls.VersionTLS12,
			},
			ForceAttemptHTTP2: true,
			MaxIdleConns:      100,
			IdleConnTimeout:   90 * time.Second,
		}

		_ = http2.ConfigureTransport(tr)

		conns[i] = &HTTPConn{
			Client: &http.Client{
				Transport: tr,
				Timeout:   25 * time.Second,
			},
			Mimic:     mimic,
			Obfs:      obfs,
			PSK:       psk,
			SessionID: sessionID,
			ServerURL: serverURL,
		}
	}

	mt := NewHTTPMuxTransport(conns, HTTPMuxConfig{
		FlushInterval: 200 * time.Millisecond,
		MaxBatch:      64,
	})

	_ = mt.Start()
	return &Client{Transport: mt}
}
