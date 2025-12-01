//go:build linux
// +build linux

package prio

import (
	"os"

	"github.com/vishvananda/netlink"
	"github.com/vishvananda/netns"
)

// Remove deletes the namespace, host-side veths, and /etc/netns/<ns>.
// Best-effort; missing resources are ignored.
func Remove(cfg Config) error {
	deleteIfaces := []string{
		cfg.VethMainHost,
		cfg.VethMainNS,
		cfg.VethLTEHost,
		cfg.VethLTENS,
	}

	// Delete host and ns veths best-effort.
	for _, name := range deleteIfaces {
		if link, err := netlink.LinkByName(name); err == nil {
			_ = netlink.LinkDel(link)
		}
	}

	// Delete namespace.
	_ = netns.DeleteNamed(cfg.Namespace)

	// Remove /etc/netns/<ns> dir if empty/exists.
	_ = os.RemoveAll("/etc/netns/" + cfg.Namespace)

	return nil
}
