//go:build linux
// +build linux

//
package prio

import (
	"fmt"

	"github.com/vishvananda/netlink"
	"github.com/vishvananda/netns"
)

func setupLTEVeth(cfg Config, nsHandle netns.NsHandle) error {
	// Ensure LTE veth pair exists and move ns side (addresses can be set later).
	if err := ensureVethPair(cfg.VethLTEHost, cfg.VethLTENS, nsHandle); err != nil {
		return fmt.Errorf("ensure LTE veth pair: %w", err)
	}

	// Assign LTE /30 if configured.
	if cfg.LTEHostCIDR != "" && cfg.LTENCIDR != "" {
		hostLTE, err := netlink.LinkByName(cfg.VethLTEHost)
		if err != nil {
			return fmt.Errorf("link %s not found: %w", cfg.VethLTEHost, err)
		}
		if err := ensureAddr(hostLTE, cfg.LTEHostCIDR); err != nil {
			return fmt.Errorf("assign %s to %s: %w", cfg.LTEHostCIDR, cfg.VethLTEHost, err)
		}
		if err := netlink.LinkSetUp(hostLTE); err != nil {
			return fmt.Errorf("set %s up: %w", cfg.VethLTEHost, err)
		}
		if err := inNamespace(nsHandle, func() error {
			link, err := netlink.LinkByName(cfg.VethLTENS)
			if err != nil {
				return fmt.Errorf("link %s not found in ns: %w", cfg.VethLTENS, err)
			}
			if err := ensureAddr(link, cfg.LTENCIDR); err != nil {
				return fmt.Errorf("assign %s to %s in ns: %w", cfg.LTENCIDR, cfg.VethLTENS, err)
			}
			if err := netlink.LinkSetUp(link); err != nil {
				return fmt.Errorf("set %s up in ns: %w", cfg.VethLTENS, err)
			}
			return nil
		}); err != nil {
			return err
		}
	}
	return nil
}
