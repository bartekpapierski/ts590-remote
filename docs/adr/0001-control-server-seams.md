# ADR-0001: ControlServer consumes seams, not hardware

Status: Accepted

Date: 2026-08-10

## Context

The server's entire behavior surface — `net.ControlServer.dispatch` — was untestable
without hardware. It held concrete `*radio.Radio` (constructible only from a real
serial port) and `*audio.Manager` (PortAudio + Opus). The only test in the package
covered `msgWriter` concurrency, leaving auth, every command path, and every error
path unverified. The `noaudio` build worked around this with a parallel stub *type*
rather than a seam.

## Decision

Define two small consumer-side interfaces in the `net` package:

- `RadioIf` — `Send`, `SetPTT`, `GetState`, `Events()`, satisfied by `*radio.Radio`
  in production and by fakes in tests.
- `AudioIf` — `Start`, `Stop`, `Running`, `PauseRx`, `RxPaused`, `PushUplink`,
  satisfied by `*audio.Manager` in production, by the `noaudio` stub, and by fakes.

`ControlServer` and `UDPServer` hold these interfaces, not the concrete types. The
composition root (`main.go`) builds the seams explicitly — notably an *explicit nil
interface* when the radio fails to open, because a typed nil `*radio.Radio` wrapped
in an interface would silently defeat the `c.radio == nil` guard. `dispatch` keeps
its current shape and is now table-testable against fakes; `handle` is exercised
end-to-end over `net.Pipe`.

## Consequences

- `dispatch` and `handle` are covered by tests with no hardware in the loop.
- The `noaudio` stub is no longer a special-cased parallel type — it is one more
  implementation of `AudioIf`.
- The dead `udp *UDPServer` field on `ControlServer` was removed.
- The interface is the test surface; adding a `ControlServer` feature means extending
  a fake, not spinning up hardware.
