//go:build linux
// +build linux

package autoswitch

import (
	"context"
	"fmt"
	"net"
	"os/exec"
	"time"

	"github.com/vishvananda/netlink"
	"github.com/vishvananda/netns"
)

type Config struct {
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
	CheckIF          string // 헬스체크를 태울 인터페이스 (메인 경로 강제)
	ConntrackCIDR    string
	ConntrackCmd     string
}

func DefaultConfig() Config {
	return Config{
		Namespace:        "prio_ns",
		MainIF:           "veth-main-ns",
		MainGW:           "10.254.0.1",
		LTEIF:            "veth-lte-ns",
		LTEGW:            "10.254.1.1",
		MainMetricPref:   10,
		LTEMetricPref:    100,
		FailThreshold:    2,
		RecoverThreshold: 2,
		Interval:         3 * time.Second,
		CheckHost:        "8.8.8.8",
		CheckIF:          "veth-main-ns",
		ConntrackCIDR:    "10.254.1.0/30",
		ConntrackCmd:     "conntrack",
	}
}

func Run(ctx context.Context, cfg Config) error {
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
					failCnt = 0
					continue
				}
				failCnt++
				if failCnt >= cfg.FailThreshold {
					if err := switchToLTE(cfg); err != nil {
						return err
					}
					mode = "lte"
					failCnt = 0
					recoverCnt = 0
				}
			} else { // mode == lte
				if ok {
					recoverCnt++
					if recoverCnt >= cfg.RecoverThreshold {
						if err := switchToMain(cfg); err != nil {
							return err
						}
						flushConntrack(cfg)
						mode = "main"
						recoverCnt = 0
						failCnt = 0
					}
				} else {
					recoverCnt = 0
				}
			}
		}
	}
}

func switchToLTE(cfg Config) error {
	return inNamespace(cfg.Namespace, func() error {
		if err := setDefault(cfg.MainIF, cfg.MainGW, cfg.LTEMetricPref); err != nil {
			return fmt.Errorf("set main metric high: %w", err)
		}
		if err := setDefault(cfg.LTEIF, cfg.LTEGW, cfg.MainMetricPref); err != nil {
			return fmt.Errorf("set lte metric low: %w", err)
		}
		return nil
	})
}

func switchToMain(cfg Config) error {
	return inNamespace(cfg.Namespace, func() error {
		if err := setDefault(cfg.MainIF, cfg.MainGW, cfg.MainMetricPref); err != nil {
			return fmt.Errorf("set main metric low: %w", err)
		}
		if err := setDefault(cfg.LTEIF, cfg.LTEGW, cfg.LTEMetricPref); err != nil {
			return fmt.Errorf("set lte metric high: %w", err)
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

func flushConntrack(cfg Config) {
	if cfg.ConntrackCmd == "" {
		return
	}
	_ = exec.Command(cfg.ConntrackCmd, "-D", "-s", cfg.ConntrackCIDR).Run()
}

func inNamespace(name string, fn func() error) error {
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
