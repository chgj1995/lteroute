//go:build linux
// +build linux

//
package prio

// Config holds parameters for the prio namespace and veth pairs.
type Config struct {
	Namespace    string
	VethMainHost string
	VethMainNS   string
	VethLTEHost  string
	VethLTENS    string
	MainCIDR     string
	NSCIDR       string
	LTEHostCIDR  string
	LTENCIDR     string
	DefaultRoute int // metric
}

// DefaultConfig mirrors the legacy shell defaults with the new naming.
func DefaultConfig() Config {
	return Config{
		Namespace:    "prio_ns",
		VethMainHost: "veth-main-host",
		VethMainNS:   "veth-main-ns",
		VethLTEHost:  "veth-lte-host",
		VethLTENS:    "veth-lte-ns",
		MainCIDR:     "10.254.0.1/30",
		NSCIDR:       "10.254.0.2/30",
		LTEHostCIDR:  "10.254.1.1/30",
		LTENCIDR:     "10.254.1.2/30",
		DefaultRoute: 10,
	}
}
