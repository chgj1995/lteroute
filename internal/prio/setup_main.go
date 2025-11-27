//go:build linux
// +build linux

//
package prio

import (
	"fmt"
	"net"
	"syscall"

	"github.com/vishvananda/netlink"
	"github.com/vishvananda/netns"
)

// Setup creates the namespace and veth pairs, assigns addresses where defined,
// and brings the links up. It is idempotent.
func Setup(cfg Config) error {
	hostIP, _, err := net.ParseCIDR(cfg.MainCIDR)
	if err != nil {
		return fmt.Errorf("parse MainCIDR: %w", err)
	}
	_, _, err = net.ParseCIDR(cfg.NSCIDR)
	if err != nil {
		return fmt.Errorf("parse NSCIDR: %w", err)
	}

	nsHandle, err := netns.GetFromName(cfg.Namespace)
	if err != nil {
		// Assume not exists; create.
		if _, errCreate := netns.NewNamed(cfg.Namespace); errCreate != nil {
			return fmt.Errorf("create netns %s: %w", cfg.Namespace, errCreate)
		}
		nsHandle, err = netns.GetFromName(cfg.Namespace)
		if err != nil {
			return fmt.Errorf("get netns %s after create: %w", cfg.Namespace, err)
		}
	}
	defer nsHandle.Close()

	if err := setupMainVeth(cfg, nsHandle, hostIP); err != nil {
		return err
	}
	if err := setupLTEVeth(cfg, nsHandle); err != nil {
		return err
	}

	return nil
}

func setupMainVeth(cfg Config, nsHandle netns.NsHandle, hostIP net.IP) error {
	// Ensure main veth exists; create if missing.
	hostLink, err := netlink.LinkByName(cfg.VethMainHost)
	if err != nil {
		veth := &netlink.Veth{
			LinkAttrs: netlink.LinkAttrs{
				Name: cfg.VethMainHost,
				MTU:  1500,
			},
			PeerName: cfg.VethMainNS,
		}
		if err := netlink.LinkAdd(veth); err != nil {
			return fmt.Errorf("create veth %s<->%s: %w", cfg.VethMainHost, cfg.VethMainNS, err)
		}
		hostLink = veth
	}

	// Move peer into namespace.
	movePeerIntoNS(cfg.VethMainNS, nsHandle)

	// Host side address + up.
	if err := ensureAddr(hostLink, cfg.MainCIDR); err != nil {
		return fmt.Errorf("assign %s to %s: %w", cfg.MainCIDR, cfg.VethMainHost, err)
	}
	if err := netlink.LinkSetUp(hostLink); err != nil {
		return fmt.Errorf("set %s up: %w", cfg.VethMainHost, err)
	}

	// Namespace side config.
	return inNamespace(nsHandle, func() error {
		link, err := netlink.LinkByName(cfg.VethMainNS)
		if err != nil {
			return fmt.Errorf("link %s not found in ns %s: %w", cfg.VethMainNS, cfg.Namespace, err)
		}
		if err := ensureAddr(link, cfg.NSCIDR); err != nil {
			return fmt.Errorf("assign %s to %s in ns: %w", cfg.NSCIDR, cfg.VethMainNS, err)
		}
		if err := netlink.LinkSetUp(link); err != nil {
			return fmt.Errorf("set %s up in ns: %w", cfg.VethMainNS, err)
		}
		// loopback up
		if lo, loErr := netlink.LinkByName("lo"); loErr == nil {
			_ = netlink.LinkSetUp(lo)
		}
		// default route via host with metric (no onlink flag needed with /30).
		route := netlink.Route{
			LinkIndex: link.Attrs().Index,
			Dst:       nil, // default
			Gw:        hostIP,
			Scope:     netlink.SCOPE_UNIVERSE,
			Priority:  cfg.DefaultRoute,
			Table:     syscall.RT_TABLE_MAIN,
		}
		if err := netlink.RouteReplace(&route); err != nil {
			return fmt.Errorf("replace default route in ns: %w", err)
		}
		return nil
	})
}
