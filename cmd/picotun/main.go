package main

import (
	"flag"
	"log"
	"net/http"
	"strings"

	// ✅ فیکس: مسیر درست پکیج طبق go.mod
	"github.com/amir6dev/rstunnel/PicoTun"
)

func main() {
	configPath := flag.String("config", "/etc/picotun/config.yaml", "Path to config")
	flag.Parse()

	// توجه: اینجا پکیج ایمپورت شده PicoTun نامیده شده چون پوشه آن PicoTun است
	// اگر نام پکیج داخل فایل‌های Go "httpmux" است، باید alias تعریف کنید:
	// import httpmux "github.com/amir6dev/rstunnel/PicoTun"
	
	cfg, err := httpmux.LoadConfig(*configPath)
	if err != nil { log.Fatalf("Config error: %v", err) }
	
	if cfg.Mode == "server" {
		runServer(cfg)
	} else {
		runClient(cfg)
	}
}

func runServer(cfg *httpmux.Config) {
	if cfg.Listen == "" { cfg.Listen = "0.0.0.0:1010" }
	
	srv := httpmux.NewServer(cfg.SessionTimeout, &cfg.Mimic, &cfg.Obfs, cfg.PSK)

	if cfg.Forward != nil {
		for _, m := range cfg.Forward.TCP {
			bind, target, ok := splitMap(m)
			if ok { go srv.StartReverseTCP(bind, target) }
		}
	}

	http.HandleFunc("/tunnel", srv.HandleHTTP)
	log.Printf("🔥 Server running on %s", cfg.Listen)
	log.Fatal(http.ListenAndServe(cfg.Listen, nil))
}

func runClient(cfg *httpmux.Config) {
	cl := httpmux.NewClient(cfg.ServerURL, cfg.SessionID, &cfg.Mimic, &cfg.Obfs, cfg.PSK)
	rev := httpmux.NewClientReverse(cl.Transport)
	
	log.Printf("🚀 Client connected to %s", cfg.ServerURL)
	rev.Run()
}

func splitMap(s string) (string, string, bool) {
	parts := strings.Split(s, "->")
	if len(parts) != 2 { return "", "", false }
	bind := strings.TrimSpace(parts[0])
	if !strings.Contains(bind, ":") { bind = "0.0.0.0:" + bind }
	return bind, strings.TrimSpace(parts[1]), true
}