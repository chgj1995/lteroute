//go:build linux
// +build linux

package main

import (
	"context"
	"fmt"
	"os"

	"lteroute/internal/autoswitch"
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
	if err := autoswitch.Run(ctx, autoswitch.DefaultConfig()); err != nil {
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
	if err := prio.Cleanup(prio.DefaultConfig()); err != nil {
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
	}
	return removePersistent()
}

func runTest(args []string) error {
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
	}

	cfg := prio.DefaultConfig()
	for i := 0; i < len(args); i++ {
		if args[i] == "--veth_host" && i+1 < len(args) {
			cfg.VethMainHost = args[i+1]
			cfg.VethLTEHost = args[i+1] + "-lte"
			i++
		}
	}
	fmt.Printf("[test] creating host veths %s (main) and %s (lte) with default addrs\n", cfg.VethMainHost, cfg.VethLTEHost)
	nsHandle, err := prio.EnsureNamespace(cfg.Namespace)
	if err != nil {
		return fmt.Errorf("ensure namespace: %w", err)
	}
	defer nsHandle.Close()

	if err := prio.SetupHostVeths(cfg, nsHandle); err != nil {
		return fmt.Errorf("setup host veths: %w", err)
	}
	fmt.Println("[test] done")
	return nil
}

func argsFrom(i int) []string {
	if i >= len(os.Args) {
		return nil
	}
	return os.Args[i:]
}
