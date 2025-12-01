//go:build linux
// +build linux

package prio

import (
	"fmt"
	"net"
	"syscall"

	"github.com/vishvananda/netlink"
)

// SetupNSDefaultViaLTE sets a default route in the prio namespace pointing to the host-side LTE veth.
func SetupNSDefaultViaLTE(cfg Config, metric int) error {
	hostIP, _, err := net.ParseCIDR(cfg.LTEHostCIDR)
	if err != nil {
		return fmt.Errorf("parse LTEHostCIDR: %w", err)
	}
	return InNamespaceByName(cfg.Namespace, func() error {
		link, err := netlink.LinkByName(cfg.VethLTENS)
		if err != nil {
			return fmt.Errorf("link %s not found in ns %s: %w", cfg.VethLTENS, cfg.Namespace, err)
		}
		route := netlink.Route{
			LinkIndex: link.Attrs().Index,
			Dst:       nil, // default
			Gw:        hostIP,
			Scope:     netlink.SCOPE_UNIVERSE,
			Table:     syscall.RT_TABLE_MAIN,
			Priority:  metric,
			Flags:     int(netlink.FLAG_ONLINK),
		}
		if err := netlink.RouteReplace(&route); err != nil {
			return fmt.Errorf("replace ns default via %s: %w", hostIP, err)
		}
		return nil
	})
}

// RemoveRouting removes the prio namespace default route via LTE (best effort).
func RemoveRouting(cfg Config, metric int) error {
	hostIP, _, err := net.ParseCIDR(cfg.LTEHostCIDR)
	if err != nil {
		return fmt.Errorf("parse LTEHostCIDR: %w", err)
	}
	_ = InNamespaceByName(cfg.Namespace, func() error {
		link, err := netlink.LinkByName(cfg.VethLTENS)
		if err != nil {
			return nil
		}
		route := netlink.Route{
			LinkIndex: link.Attrs().Index,
			Dst:       nil,
			Gw:        hostIP,
			Table:     syscall.RT_TABLE_MAIN,
			Priority:  metric,
		}
		_ = netlink.RouteDel(&route)
		return nil
	})
	return nil
}
