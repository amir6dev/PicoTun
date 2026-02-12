package httpmux

import (
	"bytes"
	"crypto/rand"
	"io"
	"net/http"
	"sync"
	"time"
)

type Server struct {
	SessionMgr    *SessionManager
	Mimic         *MimicConfig
	Obfs          *ObfsConfig
	PSK           string
	
	// مدیریت سشن فعال برای Reverse Tunnel
	activeSessMu sync.RWMutex
	activeSess   *Session
}

func NewServer(timeoutSec int, mimic *MimicConfig, obfs *ObfsConfig, psk string) *Server {
	if timeoutSec <= 0 { timeoutSec = 15 }
	return &Server{
		SessionMgr: NewSessionManager(time.Duration(timeoutSec) * time.Second),
		Mimic:      mimic,
		Obfs:       obfs,
		PSK:        psk,
	}
}

// ثبت سشن فعال برای دریافت ترافیک Reverse
func (s *Server) setActiveSession(sess *Session) {
	s.activeSessMu.Lock()
	defer s.activeSessMu.Unlock()
	s.activeSess = sess
}

func (s *Server) getActiveSession() *Session {
	s.activeSessMu.RLock()
	defer s.activeSessMu.RUnlock()
	return s.activeSess
}

func (s *Server) HandleHTTP(w http.ResponseWriter, r *http.Request) {
	sessionID := extractSessionID(r)
	if _, err := r.Cookie("SESSION"); err != nil {
		http.SetCookie(w, &http.Cookie{Name: "SESSION", Value: sessionID, Path: "/"})
	}

	sess := s.SessionMgr.GetOrCreate(sessionID)
	
	// ✅ فیکس: آپدیت کردن سشن فعال به آخرین کلاینت متصل شده
	s.setActiveSession(sess)

	// خواندن بادی درخواست
	reqBody, _ := io.ReadAll(r.Body)
	_ = r.Body.Close()

	// Decrypt Logic
	reqBody = StripObfuscation(reqBody, s.Obfs)
	plain, err := DecryptPSK(reqBody, s.PSK)
	if err != nil {
		// ✅ فیکس: لاگ خطا ندهیم که لاگ پر شود، فقط قطع کنیم
		http.Error(w, "Forbidden", 403)
		return
	}

	// پردازش فریم‌ها
	reader := bytes.NewReader(plain)
	for {
		fr, err := ReadFrame(reader)
		if err != nil { break }
		s.handleFrame(sess, fr)
	}

	// ارسال پاسخ (Drain Outgoing)
	var out bytes.Buffer
	max := 128 // محدودیت بچ برای جلوگیری از تاخیر
	for i := 0; i < max; i++ {
		select {
		case fr := <-sess.Outgoing:
			_ = WriteFrame(&out, fr)
		default:
			i = max
		}
	}

	enc, err := EncryptPSK(out.Bytes(), s.PSK)
	if err != nil { return }
	
	resp := ApplyObfuscation(enc, s.Obfs)
	ApplyDelay(s.Obfs)
	w.Write(resp)
}

func (s *Server) handleFrame(sess *Session, fr *Frame) {
	switch fr.Type {
	case FramePing:
		select {
		case sess.Outgoing <- &Frame{StreamID: 0, Type: FramePong}:
		default:
		}
	case FrameData:
		serverLinksMu.Lock()
		link := serverLinks[fr.StreamID]
		serverLinksMu.Unlock()
		if link != nil {
			link.c.Write(fr.Payload)
		}
	case FrameClose:
		serverLinksMu.Lock()
		link := serverLinks[fr.StreamID]
		delete(serverLinks, fr.StreamID)
		serverLinksMu.Unlock()
		if link != nil {
			link.c.Close()
		}
	}
}

func extractSessionID(r *http.Request) string {
	if c, _ := r.Cookie("SESSION"); c != nil && c.Value != "" { return c.Value }
	return "sess-" + RandString(12)
}

func RandString(n int) string {
	const chars = "abcdefghijklmnopqrstuvwxyz0123456789"
	b := make([]byte, n)
	rand.Read(b)
	for i := range b { b[i] = chars[int(b[i])%len(chars)] }
	return string(b)
}