//go:build linux
// +build linux

package prio

import (
	"context"
	"fmt"
	"net"
	"os/exec"
	"time"

	"github.com/vishvananda/netlink"
	"github.com/vishvananda/netns"
)

// AutoConfig controls the autoswitch loop inside the prio namespace.
type AutoConfig struct {
	Namespace        string
	MainIF           string
	MainGW           string
	LTEIF            string
	LTEGW            string
	MainMetricPref   int
	LTEMetricPref    int
	FailThreshold    int
	RecoverThreshold int
	Interval         time.Duration
	CheckHost        string
	CheckIF          string // netns 내에서 체크에 사용할 인터페이스 (메인 강제)
	ConntrackCIDR    string
	ConntrackCmd     string
}

func DefaultAutoConfig() AutoConfig {
	return AutoConfig{
		Namespace:        "prio_ns",
		MainIF:           "veth-main-ns",
		MainGW:           "10.253.0.1",
		LTEIF:            "wwan0",
		LTEGW:            "",
		MainMetricPref:   10,
		LTEMetricPref:    100,
		FailThreshold:    2,
		RecoverThreshold: 2,
		Interval:         3 * time.Second,
		CheckHost:        "8.8.8.8",
		CheckIF:          "veth-main-ns",
		ConntrackCIDR:    "10.253.1.0/30",
		ConntrackCmd:     "conntrack",
	}
}

// RunAutoswitch runs the main<->LTE default route switching loop within the prio namespace.
func RunAutoswitch(ctx context.Context, cfg AutoConfig) error {
	mode := "main"
	failCnt := 0
	recoverCnt := 0

	t := time.NewTicker(cfg.Interval)
	defer t.Stop()

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-t.C:
			ok := checkConnectivity(cfg.Namespace, cfg.CheckHost, cfg.CheckIF)
			if mode == "main" {
				if ok {
					fmt.Println("[autoswitch] main healthy")
					failCnt = 0
					continue
				}
				failCnt++
				fmt.Printf("[autoswitch] main check failed (%d/%d)\n", failCnt, cfg.FailThreshold)
				if failCnt >= cfg.FailThreshold {
					if err := switchToLTE(cfg); err != nil {
						fmt.Printf("[autoswitch] switch to LTE failed: %v (will retry)\n", err)
					} else {
						fmt.Println("[autoswitch] switched to LTE (main standby)")
						mode = "lte"
					}
					failCnt = 0
					recoverCnt = 0
				}
			} else { // mode == lte
				if ok {
					recoverCnt++
					fmt.Printf("[autoswitch] main recovery check ok (%d/%d)\n", recoverCnt, cfg.RecoverThreshold)
					if recoverCnt >= cfg.RecoverThreshold {
						if err := switchToMain(cfg); err != nil {
							fmt.Printf("[autoswitch] switch to main failed: %v (will retry)\n", err)
						} else {
							flushConntrack(cfg)
							fmt.Println("[autoswitch] switched to main (LTE standby)")
							mode = "main"
							recoverCnt = 0
							failCnt = 0
						}
					}
				} else {
					fmt.Println("[autoswitch] main still down on recovery check")
					recoverCnt = 0
				}
			}
		}
	}
}

func switchToLTE(cfg AutoConfig) error {
	fmt.Println("[autoswitch] lowering LTE metric, raising main metric")
	return withNamespace(cfg.Namespace, func() error {
		if err := setDefault(cfg.MainIF, cfg.MainGW, cfg.LTEMetricPref); err != nil {
			return fmt.Errorf("set main metric high: %w", err)
		}
		if cfg.LTEGW != "" {
			if err := setDefault(cfg.LTEIF, cfg.LTEGW, cfg.MainMetricPref); err != nil {
				return fmt.Errorf("set lte metric low: %w", err)
			}
		}
		return nil
	})
}

func switchToMain(cfg AutoConfig) error {
	fmt.Println("[autoswitch] raising LTE metric, lowering main metric")
	return withNamespace(cfg.Namespace, func() error {
		if err := setDefault(cfg.MainIF, cfg.MainGW, cfg.MainMetricPref); err != nil {
			return fmt.Errorf("set main metric low: %w", err)
		}
		if cfg.LTEGW != "" {
			if err := setDefault(cfg.LTEIF, cfg.LTEGW, cfg.LTEMetricPref); err != nil {
				return fmt.Errorf("set lte metric high: %w", err)
			}
		}
		return nil
	})
}

func setDefault(iface, gw string, metric int) error {
	link, err := netlink.LinkByName(iface)
	if err != nil {
		return fmt.Errorf("link %s: %w", iface, err)
	}
	route := netlink.Route{
		LinkIndex: link.Attrs().Index,
		Gw:        net.ParseIP(gw),
		Priority:  metric,
	}
	return netlink.RouteReplace(&route)
}

func checkConnectivity(nsName, host, iface string) bool {
	args := []string{"netns", "exec", nsName, "ping", "-c", "1", "-W", "1"}
	if iface != "" {
		args = append(args, "-I", iface)
	}
	args = append(args, host)
	cmd := exec.Command("ip", args...)
	return cmd.Run() == nil
}

func flushConntrack(cfg AutoConfig) {
	if cfg.ConntrackCmd == "" {
		return
	}
	_ = exec.Command(cfg.ConntrackCmd, "-D", "-s", cfg.ConntrackCIDR).Run()
}

func withNamespace(name string, fn func() error) error {
	target, err := netns.GetFromName(name)
	if err != nil {
		return err
	}
	defer target.Close()

	orig, err := netns.Get()
	if err != nil {
		return err
	}
	defer orig.Close()

	if err := netns.Set(target); err != nil {
		return err
	}
	defer netns.Set(orig)

	return fn()
}
