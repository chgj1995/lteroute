//go:build linux
// +build linux

//
package ltepower

import (
	"fmt"
	"os"

	gpiod "github.com/warthog618/go-gpiocdev"
)

const consumerName = "turn-on-lte"

// Config holds GPIO parameters.
type Config struct {
	GPIOChip   string
	GPIOOffset int
	ValueOn    int
}

// DefaultConfig uses fixed defaults (will be replaced by config file later).
func DefaultConfig() Config {
	return Config{
		GPIOChip:   "gpiochip4",
		GPIOOffset: 1,
		ValueOn:    1,
	}
}

// PowerOn toggles the configured GPIO to ValueOn once, using libgpiod.
func PowerOn(cfg Config) error {
	if _, err := os.Stat("/dev/" + cfg.GPIOChip); err != nil {
		return fmt.Errorf("gpio chip %s not available: %w", cfg.GPIOChip, err)
	}

	if err := setGPIO(cfg); err != nil {
		return fmt.Errorf("failed to set GPIO: %w", err)
	}
	fmt.Printf("GPIO %s offset %d set to %d\n", cfg.GPIOChip, cfg.GPIOOffset, cfg.ValueOn)
	return nil
}

func setGPIO(cfg Config) error {
	chip, err := gpiod.NewChip(cfg.GPIOChip, gpiod.WithConsumer(consumerName))
	if err != nil {
		return fmt.Errorf("open chip %s: %w", cfg.GPIOChip, err)
	}
	defer chip.Close()

	line, err := chip.RequestLine(cfg.GPIOOffset, gpiod.AsOutput(cfg.ValueOn))
	if err != nil {
		return fmt.Errorf("request line %d: %w", cfg.GPIOOffset, err)
	}
	defer line.Close()

	if err := line.SetValue(cfg.ValueOn); err != nil {
		return fmt.Errorf("set value %d: %w", cfg.ValueOn, err)
	}
	return nil
}
