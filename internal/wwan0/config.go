//go:build linux
// +build linux

//
package wwan0

import "net"

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
}

// DefaultConfig provides defaults matching the legacy scripts.
func DefaultConfig() Config {
	return Config{
		APN:       "iot.1nce.net",
		IPType:    "ipv4",
		Interface: "wwan0",
	}
}
