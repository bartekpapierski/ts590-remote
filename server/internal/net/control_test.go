package net

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"testing"

	"github.com/bartek/ts590-remote/server/internal/protocol"
)

// TestMsgWriterConcurrent verifies that concurrent sends from multiple
// goroutines (as happens between the unsolicited-event forwarder and the
// command dispatch loop) never interleave or corrupt JSON lines.
// Run with -race to catch unsynchronized writer access.
func TestMsgWriterConcurrent(t *testing.T) {
	var buf bytes.Buffer
	mw := &msgWriter{w: bufio.NewWriter(&buf)}

	const (
		goroutines   = 8
		perGoroutine = 250
	)
	var wg sync.WaitGroup
	for g := 0; g < goroutines; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < perGoroutine; i++ {
				mw.send(protocol.MsgCatResp(fmt.Sprintf("FA%011d;", i)))
			}
		}()
	}
	wg.Wait()
	if err := mw.w.Flush(); err != nil {
		t.Fatal(err)
	}

	lines := strings.Split(buf.String(), "\n")
	// The trailing newline yields one empty final element.
	if want := goroutines*perGoroutine + 1; len(lines) != want {
		t.Fatalf("got %d lines, want %d", len(lines), want)
	}
	for i, line := range lines {
		if line == "" {
			continue
		}
		var m protocol.Message
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			t.Fatalf("line %d is not valid JSON: %v (%q)", i, err, line)
		}
		if m.T != "cat_resp" {
			t.Fatalf("line %d has type %q, want cat_resp", i, m.T)
		}
	}
}
