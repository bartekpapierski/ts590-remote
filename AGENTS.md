# AGENTS.md

Remote control for the Kenwood TS-590S: a Go server (radio site) and a Swift
macOS client. Two independent components, no shared build/test/CI glue.

## Layout

```
server/   Go server (cmd/server, internal/{audio,config,net,protocol,radio})
client/   Swift macOS client (Package.swift, Sources/RemoteRig, Tests/RemoteRigTests)
```

## Server (Go)

- Entrypoint: `server/cmd/server/main.go`. Module: `github.com/bartek/ts590-remote/server`
  (`server/go.mod`, `go 1.26.4`).
- **Requires cgo** for PortAudio + libopus. On Debian/Ubuntu install
  `gcc pkg-config portaudio19-dev libopus-dev libopusfile-dev`.
- Build: `CGO_ENABLED=1 go build -o ts590-server ./cmd/server` (run from `server/`).
- Audio-free build (control/CAT/auth only, no PortAudio/Opus):
  `go build -tags noaudio -o ts590-server ./cmd/server`.
- Run: `./ts590-server -config server.yaml`. Config path defaults to `server.yaml`.
- Debug logging: `TS590_DEBUG=1 ./ts590-server -config server.yaml`.
- Docker: `docker build -t ts590-server .` (from `server/`). Run with the serial
  device passed through, e.g.
  `docker run -v /dev/ttyACM0:/dev/ttyACM0 -p 5900:5900/tcp -p 5901:5901/udp ts590-server`.
- Tests: `go test ./internal/...` (tests in `server/internal/*_test.go`).
  Covers: radio command parsing (`freqStr`, `parseFreq`, `digitsAfter`, mode tables),
  `radio.Send`/`handleLine` reply-or-event matching through a scripted fake port
  (`isQueryCmd`, `timeoutFor`, query echo / reject / fire-and-forget / timeout),
  audio param clamping (`ClampParams`, `FrameSize`), jitter buffer (`seqDelta`, put/get,
  lost-packet skipping, wraparound), protocol message builders, config loading with
  defaults, and — in `net` — table-driven `dispatch` (every message type through the
  `RadioIf`/`AudioIf` seams, run with `-race`), `handle` auth + CAT + event forwarding
  over `net.Pipe`, and concurrent `msgWriter` integrity.
- Audio test files are tagged `!noaudio`; `go test -tags noaudio ./...` also passes
  (verifies the headless build compiles and its stub Manager behaves).
- `go vet ./...` is the only additional static check.

### Architecture
- `radio.Radio` — serial CAT driver. Set commands (`FA…;`) are fire-and-forget
  (400 ms wait for a `?` error reply); query commands (`FA;`) wait up to 1.5 s
  (10 s for `PS` power). Unsolicited output is broadcast as `cat_event`.
- `audio.Manager` / `audio.Stream` — PortAudio full-duplex Opus bridge. The rig's
  RX/TX USB audio devices are matched by name substring (`audio.device`).
  Requested Opus params are clamped to device capabilities; the effective params
  are sent back to the client in `audio_params` (client must re-configure).
- `net.ControlServer` — TCP, line-delimited JSON. PSK auth first, then dispatches
  `cat`, `audio`, `audio_rx`, `ptt`, `state_req`. It consumes the consumer-side
  `net.RadioIf` / `net.AudioIf` seams (not concrete `*radio.Radio` / `*audio.Manager`),
  so dispatch and handle are testable against fakes without hardware; `main.go` builds
  the seams explicitly (an explicit nil interface when the radio fails to open).
- `net.UDPServer` — UDP audio, also behind `net.AudioIf`. Learns the client's source
  address from the first packet (or a 2-byte hello) before sending downlink.

## Client (Swift)

- Entrypoint: `client/Sources/RemoteRig/RemoteRigApp.swift` (SwiftUI). Package
  `RemoteRig`, targets `OpusC` (C libopus bindings), `OpusWrapper`, `RemoteRig`.
- **Requires Homebrew opus** at `/opt/homebrew/opt/opus`. The header search
  path `-Xcc -I/opt/homebrew/include` must be set via `swiftSettings` on every
  target that (transitively) imports `OpusC` — `cSettings` on `OpusC` itself
  do NOT reach the lazy Clang module build, and `swift build` alone won't
  catch a missing flag (only `swift test` re-builds the module without it).
  Do not symlink/vendor opus headers into `Sources/OpusC/include/`; that was
  a fragile local hack that broke cross-machine builds.
- Build: `cd client && swift build`.
- **Must be bundled into a .app** before running. The bare binary crashes with
  `-10877` because CoreAudio (HALOutput) only registers its audio-unit factories
  inside a bundle. Run `./bundle.sh` (after `swift build`) to produce
  `client/RemoteRig.app` with `libopus.0.dylib` copied into `Contents/Frameworks`.
- Tests: `swift test` (tests in `Tests/RemoteRigTests/`).
  Covers: message parsing (`Msg.parse`, `Msg.jsonLine`), model event parsing
  (`applyEvent`, `modeName`, `modeDigit`), device ID validation, frequency
  clamping, nudge arithmetic, and the audio stop lifecycle (engine teardown
  on `audio stopped` and on disconnect).

### Wire protocol
- Control: TCP, JSON lines (`\n`-delimited), one `Msg` per line. Fields use
  `omitempty`; the type is in `t`.
- Audio: UDP. Each datagram = 2-byte big-endian sequence number + Opus payload.
- Auth: client sends `{"t":"auth","token":"<psk>"}` first; server replies
  `auth_ok` / `auth_fail`.
- Key message types: `auth_ok`, `auth_fail`, `cat`/`cat_resp`/`cat_event`,
  `state`, `audio` (start/stop), `audio_params`, `audio_rx`, `ptt`/`ptt_ack`,
  `state_req`, `error`.
- The client opens the audio UDP socket to `port + 1` (control is `port`, default
  5900 → audio 5901). It sends a 2-byte hello so the server learns its address.

## Common gotchas

- PSK lives in `server.yaml` (`network.psk`) and is mirrored in the client UI
  (UserDefaults). Default `"change-me"` — change it for any real use.
- The client persists host/port/psk and audio device IDs in UserDefaults.
- `audio_rx` pause stops downlink (RX) only; control + TX keep working.
- Server audio start is idempotent: a second `audio start` returns the current
  params with `adjusted=false`.
- The uplink jitter buffer drops late frames and skips lost ones (jumps the play
  head to the oldest buffered frame); there is no packet-loss concealment, so a
  lost mic frame becomes a silent output frame.
- The client re-uses the control TCP connection for everything; audio UDP is
  opened lazily only when audio starts.
- `setFreq` clamps negative frequencies to 0 (both `freqA` and the CAT string).
- Stale audio device IDs in UserDefaults are validated against currently available
  devices and reset to 0 (Default) if not found.
- Picker errors (invalid selection tags) are prevented by eagerly loading audio
  device lists in `SettingsView` and validating device IDs in `RemoteRigModel.init()`.

## Agent skills

### Issue tracker

Issues live as GitHub issues in this repo. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary — `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout — `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.