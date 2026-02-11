package main

import (
	"os"
	"gopkg.in/yaml.v3"
)

type Config struct {
	Mode      string            `yaml:"mode"` // server, client
	Listen    string            `yaml:"listen,omitempty"` // for server
	Transport string            `yaml:"transport,omitempty"`
	PSK       string            `yaml:"psk"`
	Profile   string            `yaml:"profile"`
	Verbose   bool              `yaml:"verbose"`
	
	// Server Specific
	Maps []PortMap `yaml:"maps,omitempty"`
	
	// Client Specific
	Paths []PathConfig `yaml:"paths,omitempty"`

	// Common
	Obfuscation ObfuscationConfig `yaml:"obfuscation"`
	HttpMimic   HttpMimicConfig   `yaml:"http_mimic"`
	Smux        SmuxConfig        `yaml:"smux"`
	Advanced    AdvancedConfig    `yaml:"advanced"`
	
	// TLS
	CertFile string `yaml:"cert_file,omitempty"`
	KeyFile  string `yaml:"key_file,omitempty"`
}

type PortMap struct {
	Type   string `yaml:"type"` // tcp, udp
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
	ConnectionTimeout int `yaml:"connection_timeout"`
}

func LoadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cfg Config
	err = yaml.Unmarshal(data, &cfg)
	return &cfg, err
}