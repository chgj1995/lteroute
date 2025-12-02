//go:build linux
// +build linux

package wwan0

import (
	"fmt"

	"github.com/vishvananda/netns"
)

// ConnectAndConfigure ensures the modem is connected via mmcli, parses bearer IPv4
// details, moves the interface into the target namespace, and applies IP/MTU there.
func ConnectAndConfigure(cfg Config) (Info, error) {
	var info Info
	fmt.Println("[wwan0] start connect & configure")
	cli := newMMCLIClient(cfg)

	var targetNS netns.NsHandle
	var err error
	if cfg.Namespace != "" {
		targetNS, err = netns.GetFromName(cfg.Namespace)
		if err != nil {
			return info, fmt.Errorf("get netns %s: %w", cfg.Namespace, err)
		}
		defer targetNS.Close()
	}

	modemPath, err := findModemWithWait(cli, cfg)
	if err != nil {
		return info, err
	}

	if err := ensureConnected(cli, modemPath, cfg.APN, cfg.IPType); err != nil {
		return info, err
	}

	bearerPath, err := pickDataBearer(cli, modemPath, cfg)
	if err != nil {
		return info, err
	}

	bearer, err := waitBearerConfig(cli, bearerPath, cfg)
	if err != nil {
		return info, err
	}

	if bearer.Interface == "" {
		bearer.Interface = cfg.Interface
	}

	if err := ensureInterfaceInNamespace(bearer.Interface, targetNS, cfg.Namespace); err != nil {
		return info, err
	}

	if err := withNamespaceHandle(targetNS, func() error {
		return applyInterfaceConfig(bearer.Interface, bearer)
	}); err != nil {
		return info, err
	}

	// Set default via wwan0 with higher metric so veth-main-ns remains preferred.
	if err := ensureDefaultRoute(targetNS, bearer.Interface, bearer.Gateway, 100); err != nil {
		return info, err
	}

	info.Interface = bearer.Interface
	info.MTU = bearer.MTU
	info.Gateway = bearer.Gateway
	info.DNS = bearer.DNS
	info.Addrs = bearer.Addrs
	fmt.Printf("[wwan0] configured iface=%s addr=%v gw=%v mtu=%d\n", info.Interface, info.Addrs, info.Gateway, info.MTU)
	return info, nil
}
