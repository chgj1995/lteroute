//go:build linux
// +build linux

package wwan0

import (
	"net"
	"time"
)

// Info captures basic network parameters for an LTE interface.
type Info struct {
	Interface string
	Addrs     []net.IPNet
	Gateway   net.IP
	MTU       int
	DNS       []net.IP
}

// Config controls how wwan0 is brought up.
type Config struct {
	APN    string
	IPType string
	// Interface name to configure (default: wwan0).
	Interface string
	// Modem detection wait parameters.
	ModemWaitRetries  int
	ModemWaitInterval time.Duration
	// Bearer connection wait parameters.
	ConnectWaitRetries  int
	ConnectWaitInterval time.Duration
}

// DefaultConfig provides defaults matching the legacy scripts.
func DefaultConfig() Config {
	return Config{
		APN:                 "iot.1nce.net",
		IPType:              "ipv4",
		Interface:           "wwan0",
		ModemWaitRetries:    40,
		ModemWaitInterval:   1 * time.Second,
		ConnectWaitRetries:  30,
		ConnectWaitInterval: 1 * time.Second,
	}
}
