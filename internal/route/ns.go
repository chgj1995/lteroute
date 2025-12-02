//go:build linux
// +build linux

package route

import (
	"fmt"
	"net"
	"strings"
	"syscall"

	"github.com/vishvananda/netlink"
	"github.com/vishvananda/netns"
)

// DefaultRoute describes a default route to ensure inside a network namespace.
type DefaultRoute struct {
	Namespace string
	Interface string
	Gateway   string // IP or CIDR string
	Metric    int
	OnLink    bool
}

func EnsureDefaultRoute(cfg DefaultRoute) error {
	gw, err := parseGateway(cfg.Gateway)
	if err != nil {
		return err
	}
	return inNamespaceByName(cfg.Namespace, func() error {
		link, err := netlink.LinkByName(cfg.Interface)
		if err != nil {
			return fmt.Errorf("link %s not found in ns %s: %w", cfg.Interface, cfg.Namespace, err)
		}
		route := netlink.Route{
			LinkIndex: link.Attrs().Index,
			Dst:       nil,
			Gw:        gw,
			Scope:     netlink.SCOPE_UNIVERSE,
			Table:     syscall.RT_TABLE_MAIN,
			Priority:  cfg.Metric,
		}
		if cfg.OnLink {
			route.Flags = int(netlink.FLAG_ONLINK)
		}
		if err := netlink.RouteReplace(&route); err != nil {
			return fmt.Errorf("replace default route in ns %s via %s: %w", cfg.Namespace, gw, err)
		}
		return nil
	})
}

// DeleteDefaultRoute removes a default route (best effort).
func DeleteDefaultRoute(cfg DefaultRoute) error {
	gw, err := parseGateway(cfg.Gateway)
	if err != nil {
		return err
	}
	_ = inNamespaceByName(cfg.Namespace, func() error {
		link, err := netlink.LinkByName(cfg.Interface)
		if err != nil {
			return nil
		}
		route := netlink.Route{
			LinkIndex: link.Attrs().Index,
			Dst:       nil,
			Gw:        gw,
			Table:     syscall.RT_TABLE_MAIN,
			Priority:  cfg.Metric,
		}
		_ = netlink.RouteDel(&route)
		return nil
	})
	return nil
}

func parseGateway(gw string) (net.IP, error) {
	if strings.TrimSpace(gw) == "" {
		return nil, fmt.Errorf("gateway must be provided")
	}
	if strings.Contains(gw, "/") {
		ip, _, err := net.ParseCIDR(gw)
		if err != nil {
			return nil, fmt.Errorf("parse gateway cidr %s: %w", gw, err)
		}
		return ip, nil
	}
	ip := net.ParseIP(gw)
	if ip == nil {
		return nil, fmt.Errorf("parse gateway ip %s: invalid", gw)
	}
	return ip, nil
}

func inNamespaceByName(name string, fn func() error) error {
	if strings.TrimSpace(name) == "" {
		return fmt.Errorf("namespace name must be provided")
	}
	nsHandle, err := netns.GetFromName(name)
	if err != nil {
		return err
	}
	defer nsHandle.Close()
	return inNamespace(nsHandle, fn)
}

func inNamespace(ns netns.NsHandle, fn func() error) error {
	orig, err := netns.Get()
	if err != nil {
		return fmt.Errorf("get current netns: %w", err)
	}
	defer orig.Close()

	if err := netns.Set(ns); err != nil {
		return fmt.Errorf("set netns: %w", err)
	}
	defer netns.Set(orig)

	return fn()
}
