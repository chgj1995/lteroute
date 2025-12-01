//go:build linux
// +build linux

package prio

import (
	"fmt"
	"net"
	"syscall"

	"github.com/vishvananda/netlink"
	"github.com/vishvananda/netns"
)

// vethSpec collects interface names and optional addressing for a veth pair.
// The peer interface is moved into the target namespace when MovePeerToNS is true.
type vethSpec struct {
	HostName       string
	NsName         string
	HostCIDR       string
	NsCIDR         string
	EnsureLo       bool
	MovePeerToNS   bool
	NamespaceLabel string // best-effort label for error messages
}

// Setup creates the namespace, prepares veth pairs/addresses, and programs
// the default route via the main host veth inside the prio namespace.
// It is idempotent.
func Setup(cfg Config) error {
	nsHandle, err := EnsureNamespace(cfg.Namespace)
	if err != nil {
		return err
	}
	defer nsHandle.Close()

	if err := setupMainInterfaces(cfg, nsHandle); err != nil {
		return err
	}
	if err := setupLTEVeth(cfg, nsHandle); err != nil {
		return err
	}
	if err := setupRoutes(cfg, nsHandle); err != nil {
		return err
	}
	return nil
}

// SetupVethsOnly prepares veth pairs/addresses without programming routes.
func SetupVethsOnly(cfg Config) error {
	nsHandle, err := EnsureNamespace(cfg.Namespace)
	if err != nil {
		return err
	}
	defer nsHandle.Close()

	if err := setupMainInterfaces(cfg, nsHandle); err != nil {
		return err
	}
	if err := setupLTEVeth(cfg, nsHandle); err != nil {
		return err
	}
	return nil
}

func setupMainInterfaces(cfg Config, nsHandle netns.NsHandle) error {
	fmt.Println("[prio] ensuring main veth pair and addresses")
	if _, err := setupVethPair(vethSpec{
		HostName:       cfg.VethMainHost,
		NsName:         cfg.VethMainNS,
		HostCIDR:       cfg.MainCIDR,
		NsCIDR:         cfg.NSCIDR,
		EnsureLo:       true,
		MovePeerToNS:   true,
		NamespaceLabel: cfg.Namespace,
	}, nsHandle); err != nil {
		return fmt.Errorf("main veth: %w", err)
	}
	return nil
}

func setupLTEVeth(cfg Config, nsHandle netns.NsHandle) error {
	if _, err := setupVethPair(vethSpec{
		HostName:     cfg.VethLTEHost,
		NsName:       cfg.VethLTENS,
		HostCIDR:     cfg.LTEHostCIDR,
		NsCIDR:       cfg.LTENCIDR,
		MovePeerToNS: true,
	}, nsHandle); err != nil {
		return fmt.Errorf("ensure LTE veth pair: %w", err)
	}
	return nil
}

func setupRoutes(cfg Config, nsHandle netns.NsHandle) error {
	hostIP, _, err := net.ParseCIDR(cfg.MainCIDR)
	if err != nil {
		return fmt.Errorf("parse MainCIDR: %w", err)
	}
	return inNamespace(nsHandle, func() error {
		link, err := netlink.LinkByName(cfg.VethMainNS)
		if err != nil {
			return fmt.Errorf("link %s not found in ns %s: %w", cfg.VethMainNS, cfg.Namespace, err)
		}
		route := netlink.Route{
			LinkIndex: link.Attrs().Index,
			Dst:       nil, // default
			Gw:        hostIP,
			Scope:     netlink.SCOPE_UNIVERSE,
			Table:     syscall.RT_TABLE_MAIN,
			Priority:  cfg.DefaultRoute,
		}
		if err := netlink.RouteReplace(&route); err != nil {
			return fmt.Errorf("replace default route in ns: %w", err)
		}
		return nil
	})
}

// EnsureVethsUp checks that the expected veths exist and are up in host/ns.
// It errors if any are missing.
func EnsureVethsUp(cfg Config) error {
	nsHandle, err := netns.GetFromName(cfg.Namespace)
	if err != nil {
		return fmt.Errorf("netns %s: %w", cfg.Namespace, err)
	}
	defer nsHandle.Close()

	for _, name := range []string{cfg.VethMainHost, cfg.VethLTEHost} {
		if err := ensureLinkUp(name); err != nil {
			return err
		}
	}

	if err := inNamespace(nsHandle, func() error {
		for _, name := range []string{cfg.VethMainNS, cfg.VethLTENS} {
			if err := ensureLinkUp(name); err != nil {
				return err
			}
		}
		return nil
	}); err != nil {
		return err
	}

	return nil
}

// setupVethPair ensures the veth pair exists, moves the peer into the target
// namespace, applies optional addresses, and brings links up.
func setupVethPair(spec vethSpec, ns netns.NsHandle) (netlink.Link, error) {
	if spec.HostName == "" || spec.NsName == "" {
		return nil, fmt.Errorf("veth names must be provided")
	}

	// Prefer init netns (pid 1) so creation happens in root even if caller is inside a netns.
	rootNS, err := netns.GetFromPid(1)
	if err != nil {
		rootNS, _ = netns.Get()
	}
	defer rootNS.Close()

	// Ensure stale links are removed both in root and target ns before creating.
	cleanupVethNames(spec, ns, rootNS)

	var hostLink netlink.Link

	if err := inNamespace(rootNS, func() error {
		var err error
		hostLink, err = netlink.LinkByName(spec.HostName)
		if err != nil {
			veth := &netlink.Veth{
				LinkAttrs: netlink.LinkAttrs{
					Name: spec.HostName,
					MTU:  1500,
				},
				PeerName: spec.NsName,
			}
			if err := netlink.LinkAdd(veth); err != nil {
				return fmt.Errorf("create veth %s<->%s: %w", spec.HostName, spec.NsName, err)
			}
			hostLink, err = netlink.LinkByName(spec.HostName)
			if err != nil {
				return fmt.Errorf("refetch %s after create: %w", spec.HostName, err)
			}
		}

		if spec.HostCIDR != "" {
			if err := ensureAddr(hostLink, spec.HostCIDR); err != nil {
				return fmt.Errorf("assign %s to %s: %w", spec.HostCIDR, spec.HostName, err)
			}
		}
		return nil
	}); err != nil {
		return nil, err
	}

	if spec.MovePeerToNS {
		if err := inNamespace(rootNS, func() error {
			var moveErr error
			hostLink, moveErr = movePeerVeth(spec.HostName, spec.NsName, ns)
			return moveErr
		}); err != nil {
			return nil, err
		}

		if err := inNamespace(ns, func() error {
			link, err := netlink.LinkByName(spec.NsName)
			if err != nil {
				return fmt.Errorf("link %s not found in ns %s: %w", spec.NsName, spec.NamespaceLabel, err)
			}
			if spec.NsCIDR != "" {
				if err := ensureAddr(link, spec.NsCIDR); err != nil {
					return fmt.Errorf("assign %s to %s in ns: %w", spec.NsCIDR, spec.NsName, err)
				}
			}
			if spec.EnsureLo {
				// Best-effort loopback up for workloads that assume it.
				if lo, loErr := netlink.LinkByName("lo"); loErr == nil {
					_ = netlink.LinkSetUp(lo)
				}
			}
			return nil
		}); err != nil {
			return nil, err
		}
	}

	return hostLink, nil
}

// cleanupVethNames best-effort deletes interfaces with the same names in root and target ns.
func cleanupVethNames(spec vethSpec, ns netns.NsHandle, root netns.NsHandle) {
	_ = inNamespace(root, func() error {
		for _, name := range []string{spec.HostName, spec.NsName} {
			if link, err := netlink.LinkByName(name); err == nil {
				_ = netlink.LinkDel(link)
			}
		}
		return nil
	})

	if spec.MovePeerToNS {
		_ = inNamespace(ns, func() error {
			for _, name := range []string{spec.HostName, spec.NsName} {
				if link, err := netlink.LinkByName(name); err == nil {
					_ = netlink.LinkDel(link)
				}
			}
			return nil
		})
	}
}

func ensureAddr(link netlink.Link, cidr string) error {
	ip, ipNet, err := net.ParseCIDR(cidr)
	if err != nil {
		return fmt.Errorf("parse cidr %s: %w", cidr, err)
	}
	// net.ParseCIDR returns IPNet.IP as the network address; use the host IP instead.
	addr := &netlink.Addr{
		IPNet: &net.IPNet{
			IP:   ip,
			Mask: ipNet.Mask,
		},
	}

	// Flush existing addresses to avoid stale/incorrect assignments.
	addrs, err := netlink.AddrList(link, netlink.FAMILY_ALL)
	if err == nil {
		for _, a := range addrs {
			_ = netlink.AddrDel(link, &a)
		}
	}

	if err := netlink.AddrAdd(link, addr); err != nil && err != syscall.EEXIST {
		return err
	}
	return nil
}

func ensureLinkUp(name string) error {
	link, err := netlink.LinkByName(name)
	if err != nil {
		return fmt.Errorf("link %s: %w", name, err)
	}
	if err := netlink.LinkSetUp(link); err != nil {
		return fmt.Errorf("set %s up: %w", name, err)
	}
	return nil
}

// movePeerVeth moves the peer into the target namespace and brings both ends up.
func movePeerVeth(hostName, nsName string, ns netns.NsHandle) (netlink.Link, error) {
	if peerLink, err := netlink.LinkByName(nsName); err == nil {
		if err := netlink.LinkSetNsFd(peerLink, int(ns)); err != nil {
			return nil, fmt.Errorf("move %s into ns: %w", nsName, err)
		}
	}

	hostLink, err := netlink.LinkByName(hostName)
	if err != nil {
		return nil, fmt.Errorf("host link %s missing after move: %w", hostName, err)
	}
	if err := netlink.LinkSetUp(hostLink); err != nil {
		return nil, fmt.Errorf("set %s up: %w", hostName, err)
	}

	if err := inNamespace(ns, func() error {
		link, err := netlink.LinkByName(nsName)
		if err != nil {
			return fmt.Errorf("link %s not found in ns: %w", nsName, err)
		}
		if err := netlink.LinkSetUp(link); err != nil {
			return fmt.Errorf("set %s up in ns: %w", nsName, err)
		}
		return nil
	}); err != nil {
		return nil, err
	}

	return hostLink, nil
}
