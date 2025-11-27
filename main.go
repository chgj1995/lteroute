//go:build linux
// +build linux

package main

import (
	"context"
	"fmt"
	"os"

	"lteroute/internal/autoswitch"
	"lteroute/internal/ltepower"
	"lteroute/internal/ntpns"
	"lteroute/internal/prio"
	"lteroute/internal/tailscale"
	"lteroute/internal/wwan0"
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == "remove" {
		if err := removePersistent(); err != nil {
			fmt.Fprintf(os.Stderr, "remove failed: %v\n", err)
			os.Exit(1)
		}
		return
	}

	// 1) GPIO로 LTE 모듈 전원 온
	if err := ltepower.PowerOn(ltepower.DefaultConfig()); err != nil {
		fmt.Fprintf(os.Stderr, "turn-on-lte failed: %v\n", err)
		os.Exit(1)
	}

	// 2) wwan0 연결/설정 (mmcli 기반)
	if _, err := wwan0.ConnectAndConfigure(wwan0.DefaultConfig()); err != nil {
		fmt.Fprintf(os.Stderr, "wwan0 configure failed: %v\n", err)
		os.Exit(1)
	}

	// 3) prio 네임스페이스 및 veth 구성 (/30 포함)
	if err := prio.Setup(prio.DefaultConfig()); err != nil {
		fmt.Fprintf(os.Stderr, "prio setup failed: %v\n", err)
		os.Exit(1)
	}

	// 4) autoswitch 루프 시작 (메인↔LTE 우선순위 전환)
	ctx := context.Background()
	if err := autoswitch.Run(ctx, autoswitch.DefaultConfig()); err != nil {
		fmt.Fprintf(os.Stderr, "autoswitch failed: %v\n", err)
		os.Exit(1)
	}

	// 5) tailscale 설치/오버라이드 및 tailscale0 확인/기본 DNS 정리
	if err := tailscale.Install(tailscale.DefaultConfig()); err != nil {
		fmt.Fprintf(os.Stderr, "tailscale install failed: %v\n", err)
		os.Exit(1)
	}
	if err := tailscale.ConfigureRouting(tailscale.DefaultConfig()); err != nil {
		fmt.Fprintf(os.Stderr, "tailscale configure failed: %v\n", err)
		os.Exit(1)
	}

	// 6) prio_ns 내부 NTP 타이머 설정
	if err := ntpns.Install(ntpns.DefaultConfig()); err != nil {
		fmt.Fprintf(os.Stderr, "ntp install failed: %v\n", err)
		os.Exit(1)
	}
}

func removePersistent() error {
	if err := tailscale.Remove(tailscale.DefaultConfig()); err != nil {
		return fmt.Errorf("tailscale remove: %w", err)
	}
	if err := ntpns.Uninstall(ntpns.DefaultConfig()); err != nil {
		return fmt.Errorf("ntp remove: %w", err)
	}
	return nil
}
