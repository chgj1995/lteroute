//go:build linux
// +build linux

package wwan0

import (
	"fmt"
	"net"

	"github.com/vishvananda/netlink"
	"github.com/vishvananda/netns"
)

// ensureInterfaceInNamespace moves iface into target namespace if provided.
// If already present there, it is a no-op.
func ensureInterfaceInNamespace(iface string, target netns.NsHandle, targetName string) error {
	if iface == "" || target == 0 {
		return nil
	}
	// Already in target namespace?
	if err := withNamespaceHandle(target, func() error {
		_, err := netlink.LinkByName(iface)
		return err
	}); err == nil {
		return nil
	}

	link, err := netlink.LinkByName(iface)
	if err != nil {
		return fmt.Errorf("link %s not found in host ns (and not in %s): %w", iface, targetName, err)
	}
	if err := netlink.LinkSetNsFd(link, int(target)); err != nil {
		return fmt.Errorf("move %s to ns %s: %w", iface, targetName, err)
	}
	return nil
}

func ensureDefaultRoute(ns netns.NsHandle, iface string, gw net.IP, metric int) error {
	if ns == 0 || gw == nil {
		return nil
	}
	return withNamespaceHandle(ns, func() error {
		link, err := netlink.LinkByName(iface)
		if err != nil {
			return fmt.Errorf("link %s in ns: %w", iface, err)
		}
		rt := netlink.Route{
			LinkIndex: link.Attrs().Index,
			Gw:        gw,
			Priority:  metric,
		}
		if err := netlink.RouteReplace(&rt); err != nil {
			return fmt.Errorf("set default via %s on %s: %w", gw, iface, err)
		}
		return nil
	})
}

// withNamespaceHandle executes fn within the provided namespace, or current ns if zero handle.
func withNamespaceHandle(ns netns.NsHandle, fn func() error) error {
	if ns == 0 {
		return fn()
	}
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
