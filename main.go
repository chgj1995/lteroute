//go:build linux
// +build linux

package main

import (
	"context"
	"fmt"
	"net"
	"os"

	"github.com/vishvananda/netlink"

	"lteroute/internal/ltepower"
	"lteroute/internal/natfw"
	"lteroute/internal/ntpns"
	"lteroute/internal/prio"
	"lteroute/internal/tailscale"
	"lteroute/internal/wwan0"
)

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "remove":
			if err := runRemove(argsFrom(2)); err != nil {
				fmt.Fprintf(os.Stderr, "[remove] failed: %v\n", err)
				os.Exit(1)
			}
			return
		case "test":
			if err := runTest(argsFrom(2)); err != nil {
				fmt.Fprintf(os.Stderr, "[test] failed: %v\n", err)
				os.Exit(1)
			}
			return
		}
	}

	fmt.Println("[main] powering on LTE via GPIO...")
	if err := ltepower.PowerOn(ltepower.DefaultConfig()); err != nil {
		fmt.Fprintf(os.Stderr, "turn-on-lte failed: %v\n", err)
		os.Exit(1)
	}

	fmt.Println("[main] configuring wwan0 via mmcli...")
	if _, err := wwan0.ConnectAndConfigure(wwan0.DefaultConfig()); err != nil {
		fmt.Fprintf(os.Stderr, "wwan0 configure failed: %v\n", err)
		os.Exit(1)
	}

	fmt.Println("[main] setting up prio namespace and veth...")
	if err := prio.Setup(prio.DefaultConfig()); err != nil {
		fmt.Fprintf(os.Stderr, "prio setup failed: %v\n", err)
		os.Exit(1)
	}

	fmt.Println("[main] applying NAT/forwarding rules...")
	_ = natfw.Setup(natfw.DefaultConfig())

	fmt.Println("[main] starting autoswitch loop...")
	ctx := context.Background()
	if err := prio.RunAutoswitch(ctx, prio.DefaultAutoConfig()); err != nil {
		fmt.Fprintf(os.Stderr, "autoswitch failed: %v\n", err)
		os.Exit(1)
	}

	fmt.Println("[main] installing tailscale override...")
	if err := tailscale.Install(tailscale.DefaultConfig()); err != nil {
		fmt.Fprintf(os.Stderr, "tailscale install failed: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("[main] configuring tailscale routing...")
	if err := tailscale.ConfigureRouting(tailscale.DefaultConfig()); err != nil {
		fmt.Fprintf(os.Stderr, "tailscale configure failed: %v\n", err)
		os.Exit(1)
	}

	fmt.Println("[main] installing ntp timer in namespace...")
	if err := ntpns.Install(ntpns.DefaultConfig()); err != nil {
		fmt.Fprintf(os.Stderr, "ntp install failed: %v\n", err)
		os.Exit(1)
	}
}

func removePersistent() error {
	fmt.Println("[remove] clearing tailscale override...")
	if err := tailscale.Remove(tailscale.DefaultConfig()); err != nil {
		return fmt.Errorf("tailscale remove: %w", err)
	}
	fmt.Println("[remove] removing ntp timer/service...")
	if err := ntpns.Uninstall(ntpns.DefaultConfig()); err != nil {
		return fmt.Errorf("ntp remove: %w", err)
	}
	fmt.Println("[remove] removing NAT/forwarding rules...")
	natfw.Cleanup(natfw.DefaultConfig())
	fmt.Println("[remove] cleaning prio namespace/veth...")
	if err := prio.Remove(prio.DefaultConfig()); err != nil {
		return fmt.Errorf("prio cleanup: %w", err)
	}
	fmt.Println("[remove] powering off LTE GPIO...")
	if err := ltepower.PowerOff(ltepower.DefaultConfig()); err != nil {
		return fmt.Errorf("lte power off: %w", err)
	}
	return nil
}

func runRemove(args []string) error {
	for _, a := range args {
		if a == "--wwan0" {
			if err := wwan0.Remove(wwan0.DefaultConfig()); err != nil {
				return fmt.Errorf("wwan0 remove: %w", err)
			}
			fmt.Println("[remove] wwan0 interface cleanup done")
			return nil
		}
		if a == "--ltepower" {
			if err := ltepower.Remove(ltepower.DefaultConfig()); err != nil {
				return fmt.Errorf("ltepower remove: %w", err)
			}
			fmt.Println("[remove] ltepower power off done")
			return nil
		}
		if a == "--prio" {
			cfg := prio.DefaultConfig()
			if err := prio.Remove(cfg); err != nil {
				return fmt.Errorf("prio remove: %w", err)
			}
			fmt.Println("[remove] prio namespace/veth cleanup done")
			return nil
		}
		if a == "--route" {
			cfg := prio.DefaultConfig()
			if err := prio.RemoveRouting(cfg, 100); err != nil {
				return fmt.Errorf("route cleanup: %w", err)
			}
			fmt.Println("[remove] prio routing cleanup done")
			return nil
		}
	}
	return removePersistent()
}

func runTest(args []string) error {
	// test 서브커맨드는 main 로직을 한 단계씩 실행/검증하기 위한 것이며,
	// 테스트를 위해 리소스를 추가로 삭제/재생성하지 않는다.
	for _, a := range args {
		if a == "--wwan0" {
			if err := wwan0.RunWWAN0Integration(); err != nil {
				return err
			}
			return nil
		}
		if a == "--ltepower" {
			if err := ltepower.RunLTEPowerIntegration(); err != nil {
				return err
			}
			return nil
		}
		if a == "--prio" {
			cfg := prio.DefaultConfig()
			nsHandle, err := prio.EnsureNamespace(cfg.Namespace)
			if err != nil {
				return fmt.Errorf("ensure namespace: %w", err)
			}
			nsHandle.Close()
			fmt.Printf("[test] prio namespace ensured: %s\n", cfg.Namespace)
			return nil
		}
		if a == "--veth" {
			cfg := prio.DefaultConfig()
			if err := prio.SetupVethsOnly(cfg); err != nil {
				return fmt.Errorf("setup veths: %w", err)
			}
			fmt.Printf("[test] prio veths created: %s (main), %s (lte)\n", cfg.VethMainHost, cfg.VethLTEHost)
			return nil
		}
		if a == "--route" {
			cfg := prio.DefaultConfig()
			// Assume veths/ns already prepared (e.g., via --prio/--veth). Just configure routing.
			if err := prio.EnsureVethsUp(cfg); err != nil {
				return fmt.Errorf("prio veth check: %w", err)
			}
			// Bring up wwan0 and configure.
			info, usedExisting, err := wwanInfoOrConfigure()
			if err != nil {
				return fmt.Errorf("wwan0 configure: %w", err)
			}
			if usedExisting {
				fmt.Printf("[test] using existing wwan0 config addr=%v gw=%v\n", info.Addrs, info.Gateway)
			}
			if err := prio.SetupNSDefaultViaLTE(cfg, 100); err != nil {
				return fmt.Errorf("prio ns default via lte: %w", err)
			}
			fmt.Printf("[test] prio namespace default via %s; main stays preferred\n", cfg.VethLTENS)
			return nil
		}
	}

	return fmt.Errorf("unknown test target; use --wwan0, --ltepower, --prio, or --route")
}

func argsFrom(i int) []string {
	if i >= len(os.Args) {
		return nil
	}
	return os.Args[i:]
}

// wwanInfoOrConfigure tries to reuse existing wwan0 config; if absent, it runs ConnectAndConfigure.
func wwanInfoOrConfigure() (wwan0.Info, bool, error) {
	var info wwan0.Info
	if link, err := netlink.LinkByName("wwan0"); err == nil {
		addrs, _ := netlink.AddrList(link, netlink.FAMILY_V4)
		var ipnets []net.IPNet
		for _, a := range addrs {
			if a.IPNet != nil {
				ipnets = append(ipnets, *a.IPNet)
			}
		}
		routes, _ := netlink.RouteListFiltered(netlink.FAMILY_V4, &netlink.Route{LinkIndex: link.Attrs().Index}, netlink.RT_FILTER_OIF)
		var gw net.IP
		for _, r := range routes {
			if r.Dst == nil && r.Gw != nil {
				gw = r.Gw
				break
			}
		}
		if len(ipnets) > 0 && gw != nil {
			info.Interface = "wwan0"
			info.Addrs = ipnets
			info.Gateway = gw
			info.MTU = link.Attrs().MTU
			return info, true, nil
		}
	}
	// fallback to full setup
	i, err := wwan0.ConnectAndConfigure(wwan0.DefaultConfig())
	return i, false, err
}
