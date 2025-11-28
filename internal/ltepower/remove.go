//go:build linux
// +build linux

package ltepower

// Remove turns LTE power off using the default PowerOff logic.
func Remove(cfg Config) error {
	return PowerOff(cfg)
}
