//go:build linux
// +build linux

//
package wwan0

import (
	"fmt"

	"github.com/vishvananda/netlink"
)

func applyInterfaceConfig(iface string, b bearerDetails) error {
	link, err := netlink.LinkByName(iface)
	if err != nil {
		return fmt.Errorf("link %s: %w", iface, err)
	}

	// Flush old addresses and apply new.
	if err := flushAddrs(link); err != nil {
		return fmt.Errorf("flush addresses on %s: %w", iface, err)
	}
	for _, ipnet := range b.Addrs {
		a := &netlink.Addr{IPNet: &ipnet}
		if err := netlink.AddrAdd(link, a); err != nil {
			return fmt.Errorf("add addr %s to %s: %w", ipnet.String(), iface, err)
		}
	}

	if b.MTU > 0 {
		if err := netlink.LinkSetMTU(link, b.MTU); err != nil {
			return fmt.Errorf("set MTU %d on %s: %w", b.MTU, iface, err)
		}
	}

	if err := netlink.LinkSetUp(link); err != nil {
		return fmt.Errorf("set %s up: %w", iface, err)
	}

	return nil
}

func flushAddrs(link netlink.Link) error {
	addrs, err := netlink.AddrList(link, netlink.FAMILY_ALL)
	if err != nil {
		return err
	}
	for _, addr := range addrs {
		_ = netlink.AddrDel(link, &addr)
	}
	return nil
}
