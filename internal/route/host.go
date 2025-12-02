//go:build linux
// +build linux

package route

import (
	"fmt"
	"os/exec"
	"strings"
)

// HostConfig controls host-side forwarding/NAT rules for prio traffic.
type HostConfig struct {
	SourceCIDR   string
	VethMainHost string
	OutboundIfs  []string
}

func DefaultHostConfig() HostConfig {
	return HostConfig{
		SourceCIDR:   "10.253.0.0/30",
		VethMainHost: "veth-main-host",
		OutboundIfs:  []string{"eth0", "wlan0"},
	}
}

// SetupHost enables ip_forward and installs iptables NAT/FORWARD rules (best effort).
func SetupHost(cfg HostConfig) error {
	if err := run("sudo", "sysctl", "-w", "net.ipv4.ip_forward=1"); err != nil {
		fmt.Printf("[route] ip_forward enable failed: %v\n", err)
	}

	for _, out := range mergeOutboundIfs(cfg.OutboundIfs) {
		if err := run("sudo", "iptables", "-C", "FORWARD", "-i", cfg.VethMainHost, "-j", "ACCEPT"); err != nil {
			fmt.Printf("[route] FORWARD precheck (in %s): %v\n", cfg.VethMainHost, err)
		}
		if err := run("sudo", "iptables", "-A", "FORWARD", "-i", cfg.VethMainHost, "-j", "ACCEPT"); err != nil {
			fmt.Printf("[route] FORWARD add (in %s): %v\n", cfg.VethMainHost, err)
		}
		if err := run("sudo", "iptables", "-C", "FORWARD", "-o", cfg.VethMainHost, "-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED", "-j", "ACCEPT"); err != nil {
			fmt.Printf("[route] FORWARD precheck (out %s): %v\n", cfg.VethMainHost, err)
		}
		if err := run("sudo", "iptables", "-A", "FORWARD", "-o", cfg.VethMainHost, "-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED", "-j", "ACCEPT"); err != nil {
			fmt.Printf("[route] FORWARD add (out %s): %v\n", cfg.VethMainHost, err)
		}
		if err := run("sudo", "iptables", "-t", "nat", "-C", "POSTROUTING", "-s", cfg.SourceCIDR, "-o", out, "-j", "MASQUERADE"); err != nil {
			fmt.Printf("[route] NAT precheck (%s -> %s): %v\n", cfg.SourceCIDR, out, err)
		}
		if err := run("sudo", "iptables", "-t", "nat", "-A", "POSTROUTING", "-s", cfg.SourceCIDR, "-o", out, "-j", "MASQUERADE"); err != nil {
			fmt.Printf("[route] NAT add (%s -> %s): %v\n", cfg.SourceCIDR, out, err)
		}
	}
	return nil
}

// CleanupHost tries to delete the rules added by SetupHost (best effort).
func CleanupHost(cfg HostConfig) {
	for _, out := range mergeOutboundIfs(cfg.OutboundIfs) {
		_ = run("sudo", "iptables", "-t", "nat", "-D", "POSTROUTING", "-s", cfg.SourceCIDR, "-o", out, "-j", "MASQUERADE")
		_ = run("sudo", "iptables", "-D", "FORWARD", "-o", cfg.VethMainHost, "-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED", "-j", "ACCEPT")
		_ = run("sudo", "iptables", "-D", "FORWARD", "-i", cfg.VethMainHost, "-j", "ACCEPT")
	}
}

func run(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	return cmd.Run()
}

// mergeOutboundIfs combines static OutboundIfs with detected default-route interfaces.
func mergeOutboundIfs(static []string) []string {
	seen := make(map[string]struct{})
	var out []string

	add := func(iface string) {
		if iface == "" {
			return
		}
		if _, ok := seen[iface]; ok {
			return
		}
		seen[iface] = struct{}{}
		out = append(out, iface)
	}

	for _, s := range static {
		add(s)
	}
	for _, d := range detectDefaultRouteIfs() {
		add(d)
	}
	return out
}

// detectDefaultRouteIfs returns interfaces referenced by the default route (best effort).
func detectDefaultRouteIfs() []string {
	out, err := exec.Command("ip", "route", "show", "default").CombinedOutput()
	if err != nil {
		return nil
	}
	lines := strings.Split(string(out), "\n")
	var ifs []string
	for _, l := range lines {
		fields := strings.Fields(l)
		for i := 0; i < len(fields); i++ {
			if fields[i] == "dev" && i+1 < len(fields) {
				ifs = append(ifs, fields[i+1])
			}
		}
	}
	return ifs
}
