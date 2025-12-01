//go:build linux
// +build linux

package natfw

import (
	"fmt"
	"os/exec"
)

type Config struct {
	SourceCIDR   string
	VethMainHost string
	OutboundIfs  []string
}

func DefaultConfig() Config {
	return Config{
		SourceCIDR:   "10.253.0.0/30",
		VethMainHost: "veth-main-host",
		OutboundIfs:  []string{"eth0", "wlan0"},
	}
}

// Setup enables ip_forward and installs iptables NAT/FORWARD rules (best effort).
func Setup(cfg Config) error {
	if err := run("sudo", "sysctl", "-w", "net.ipv4.ip_forward=1"); err != nil {
		fmt.Printf("[natfw] ip_forward enable failed: %v\n", err)
	}

	for _, out := range cfg.OutboundIfs {
		if err := run("sudo", "iptables", "-C", "FORWARD", "-i", cfg.VethMainHost, "-j", "ACCEPT"); err != nil {
			fmt.Printf("[natfw] FORWARD precheck (in %s): %v\n", cfg.VethMainHost, err)
		}
		if err := run("sudo", "iptables", "-A", "FORWARD", "-i", cfg.VethMainHost, "-j", "ACCEPT"); err != nil {
			fmt.Printf("[natfw] FORWARD add (in %s): %v\n", cfg.VethMainHost, err)
		}
		if err := run("sudo", "iptables", "-C", "FORWARD", "-o", cfg.VethMainHost, "-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED", "-j", "ACCEPT"); err != nil {
			fmt.Printf("[natfw] FORWARD precheck (out %s): %v\n", cfg.VethMainHost, err)
		}
		if err := run("sudo", "iptables", "-A", "FORWARD", "-o", cfg.VethMainHost, "-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED", "-j", "ACCEPT"); err != nil {
			fmt.Printf("[natfw] FORWARD add (out %s): %v\n", cfg.VethMainHost, err)
		}
		if err := run("sudo", "iptables", "-t", "nat", "-C", "POSTROUTING", "-s", cfg.SourceCIDR, "-o", out, "-j", "MASQUERADE"); err != nil {
			fmt.Printf("[natfw] NAT precheck (%s -> %s): %v\n", cfg.SourceCIDR, out, err)
		}
		if err := run("sudo", "iptables", "-t", "nat", "-A", "POSTROUTING", "-s", cfg.SourceCIDR, "-o", out, "-j", "MASQUERADE"); err != nil {
			fmt.Printf("[natfw] NAT add (%s -> %s): %v\n", cfg.SourceCIDR, out, err)
		}
	}
	return nil
}

// Cleanup tries to delete the rules added by Setup (best effort).
func Cleanup(cfg Config) {
	for _, out := range cfg.OutboundIfs {
		_ = run("sudo", "iptables", "-t", "nat", "-D", "POSTROUTING", "-s", cfg.SourceCIDR, "-o", out, "-j", "MASQUERADE")
		_ = run("sudo", "iptables", "-D", "FORWARD", "-o", cfg.VethMainHost, "-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED", "-j", "ACCEPT")
		_ = run("sudo", "iptables", "-D", "FORWARD", "-i", cfg.VethMainHost, "-j", "ACCEPT")
	}
}

func run(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	return cmd.Run()
}
