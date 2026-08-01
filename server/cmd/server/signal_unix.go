//go:build !windows

package main

import (
	"os"
	"syscall"
)

func extraSignals() []os.Signal {
	return []os.Signal{syscall.SIGTERM}
}
