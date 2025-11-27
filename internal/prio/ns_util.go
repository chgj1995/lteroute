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

func ensureAddr(link netlink.Link, cidr string) error {
	_, ipNet, err := net.ParseCIDR(cidr)
	if err != nil {
		return fmt.Errorf("parse cidr %s: %w", cidr, err)
	}
	addr := &netlink.Addr{IPNet: ipNet}

	addrs, err := netlink.AddrList(link, netlink.FAMILY_ALL)
	if err == nil {
		for _, a := range addrs {
			if a.IPNet.String() == ipNet.String() {
				return nil
			}
		}
	}
	if err := netlink.AddrAdd(link, addr); err != nil && !isAddrExists(err) {
		return err
	}
	return nil
}

func isAddrExists(err error) bool {
	if err == nil {
		return false
	}
	// netlink may wrap syscall.EEXIST.
	return err.Error() == "file exists" || err == syscall.EEXIST
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

func movePeerIntoNS(name string, ns netns.NsHandle) {
	peerLink, err := netlink.LinkByName(name)
	if err != nil {
		return
	}
	_ = netlink.LinkSetNsFd(peerLink, int(ns))
}

func ensureVethPair(hostName, nsName string, ns netns.NsHandle) error {
	hostLink, err := netlink.LinkByName(hostName)
	if err != nil {
		veth := &netlink.Veth{
			LinkAttrs: netlink.LinkAttrs{
				Name: hostName,
				MTU:  1500,
			},
			PeerName: nsName,
		}
		if err := netlink.LinkAdd(veth); err != nil {
			return fmt.Errorf("create veth %s<->%s: %w", hostName, nsName, err)
		}
		hostLink = veth
	}

	movePeerIntoNS(nsName, ns)

	if err := netlink.LinkSetUp(hostLink); err != nil {
		return fmt.Errorf("set %s up: %w", hostName, err)
	}

	return inNamespace(ns, func() error {
		link, err := netlink.LinkByName(nsName)
		if err != nil {
			return fmt.Errorf("link %s not found in ns: %w", nsName, err)
		}
		if err := netlink.LinkSetUp(link); err != nil {
			return fmt.Errorf("set %s up in ns: %w", nsName, err)
		}
		return nil
	})
}
