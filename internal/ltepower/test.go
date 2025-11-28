//go:build linux
// +build linux

package ltepower

import "fmt"

// RunLTEPowerIntegration은 main의 "test --ltepower" 요청으로 실행되는 통합 테스트 엔트리다.
// 실제 GPIO 디바이스에 접근하므로 운영 환경에서만 사용한다.
func RunLTEPowerIntegration() error {
	cfg := DefaultConfig()
	fmt.Printf("[ltepower test] starting with cfg: chip=%s offset=%d value=%d\n", cfg.GPIOChip, cfg.GPIOOffset, cfg.ValueOn)

	if err := PowerOn(cfg); err != nil {
		return fmt.Errorf("[ltepower test] failed: %w", err)
	}

	fmt.Println("[ltepower test] SUCCESS: power on completed")
	return nil
}
