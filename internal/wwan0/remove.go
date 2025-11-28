//go:build linux
// +build linux

package wwan0

import (
	"fmt"

	"github.com/vishvananda/netlink"
)

// Remove cleans up the wwan interface: flushes addresses and brings it down.
func Remove(cfg Config) error {
	iface := cfg.Interface
	link, err := netlink.LinkByName(iface)
	if err != nil {
		return fmt.Errorf("link %s: %w", iface, err)
	}

	if err := flushAddrs(link); err != nil {
		return fmt.Errorf("flush addresses on %s: %w", iface, err)
	}
	if err := netlink.LinkSetDown(link); err != nil {
		return fmt.Errorf("set %s down: %w", iface, err)
	}
	return nil
}
