# TS-590 Remote

Remote control for the [Kenwood TS-590S](https://www.kenwood.com/i/products/info/amateur/ts_590s.html) HF transceiver over a network — a Go server that sits next to the rig and a native macOS (SwiftUI) client you can run from anywhere.

The server talks CAT over the rig's USB serial port and bridges its USB audio interface as a low-latency Opus stream over UDP. You get full remote operation: frequency and mode control, PTT, and two-way audio.

```
┌──────────────┐  CAT (serial)   ┌──────────────┐   TCP JSON   ┌────────────────┐
│  TS-590S     │◄───────────────►│  Go server   │◄────────────►│  macOS client  │
│  (radio site)│  RX/TX audio    │  PortAudio   │   UDP Opus   │  (SwiftUI)     │
└──────────────┘                 └──────────────┘              └────────────────┘
```

## Features

- **CAT control** — frequency, mode, power, and PTT commands, with rig state broadcast to the client (`cat_event`).
- **Live audio** — full-duplex Opus streaming (20 ms frames, 48 kHz mono by default), adaptive jitter buffers on both ends (grow on dropouts, shrink when over-filled), and a downlink pause (`audio_rx`) that leaves control + TX running.
- **Live telemetry** — a toggleable stats panel shows network (link/RTT/packet counts) and streaming/buffer conditions for both the downlink (RX) and uplink (TX-to-rig) audio paths; server uplink stats are pushed over the control channel every 5 s.
- **Authentication** — PSK handshake before any control or audio traffic is accepted.
- **Portable** — the server ships as a single static-ish Go binary, a headless build (no PortAudio/Opus), and a Docker image; the client is a standard SwiftPM package.

## Repository layout

```
server/   Go server (cmd/server, internal/{audio,config,net,protocol,radio})
client/   Swift macOS client (SwiftPM package, SwiftUI)
docs/     Agent/domain docs (issue tracker + domain conventions)
```

## Prerequisites

### Server

- Go 1.26+ with **cgo** (for PortAudio + libopus). On Debian/Ubuntu:

  ```sh
  apt install gcc pkg-config portaudio19-dev libopus-dev libopusfile-dev
  ```

- A TS-590S with its USB cable connected (CAT + audio).

### Client

- macOS 13+ with [Homebrew opus](https://formulae.brew.sh/formula/opus) (`brew install opus`). The SwiftPM settings reference the Homebrew include/lib paths directly — don't symlink or vendor opus headers.

## Server: build and run

```sh
cd server
cp server.yaml.example server.yaml    # then edit: serial port, device, PSK
CGO_ENABLED=1 go build -o ts590-server ./cmd/server
./ts590-server -config server.yaml
```

- Debug logging: `TS590_DEBUG=1 ./ts590-server -config server.yaml`
- Headless build (control/CAT/auth only, no PortAudio/Opus): `go build -tags noaudio -o ts590-server ./cmd/server`
- Tests: `go test ./internal/...` (audio tests need the full build; `go test -tags noaudio ./...` covers the rest), `go vet ./...`

### Docker

```sh
docker build -t ts590-server .    # from server/
docker run -v /dev/ttyACM0:/dev/ttyACM0 -p 5900:5900/tcp -p 5901:5901/udp ts590-server
```

### Configuration (`server.yaml`)

| Key | Default | Description |
| --- | --- | --- |
| `radio.port` | — | Serial CAT port (`COM11` on Windows, `/dev/ttyACM0` on Linux) |
| `radio.baud` | `115200` | CAT baud rate |
| `radio.powerOnConnect` | `false` | Power the rig on when the server starts |
| `audio.device` | — | Substring match for the TS-590S USB audio device name (e.g. `"TS-590"`) |
| `audio.sampleRate` | `48000` | Sample rate (Hz) |
| `audio.channels` | `1` | Channel count |
| `audio.opusFrameMs` | `20` | Opus frame size (ms) |
| `audio.opusBitrate` | `48000` | Opus bitrate (bps) |
| `audio.jitterFrames` | `2` | Uplink jitter buffer pre-buffer depth (frames) |
| `audio.jitterMinFrames` | `1` | Lower bound the uplink jitter depth is clamped to |
| `audio.jitterMaxFrames` | `64` | Upper bound the uplink jitter depth is clamped to |
| `network.controlAddr` | `0.0.0.0:5900` | Control TCP listen address |
| `network.audioAddr` | `0.0.0.0:5901` | Audio UDP listen address |
| `network.psk` | `change-me` | Pre-shared key; **change it for any real use** |

Audio parameters are clamped to the device's capabilities and the effective values are reported back to the client, which re-configures itself accordingly.

## Client: build and run

```sh
cd client
swift build
./bundle.sh     # produces client/RemoteRig.app (required: the bare binary crashes with -10877)
open RemoteRig.app
```

- Tests: `swift test` (note: only `swift test`, not `swift build`, rebuilds the Clang module with the right header flags — a missing `-I` flag shows up there).
- The app persists host/port/PSK and audio device IDs in UserDefaults. Stale audio device IDs are validated against available devices on launch.

## Wire protocol

- **Control**: TCP, line-delimited JSON (`\n`), one `Msg` per line. The client sends `{"t":"auth","token":"<psk>"}` first; the server replies `auth_ok` or `auth_fail`. Message types: `cat`/`cat_resp`/`cat_event`, `state`, `audio` (start/stop), `audio_params`, `audio_rx`, `ptt`/`ptt_ack`, `state_req`, `error`.
- **Audio**: UDP. Each datagram is a 2-byte big-endian sequence number followed by an Opus payload. The client opens the socket on `port + 1` and sends a 2-byte hello so the server learns its address.

## Security

- The only protection is the PSK, which travels in plaintext — run the server on a trusted network or behind a VPN/TLS tunnel. Default PSK is `change-me`; never deploy with it.
- Consider firewall rules restricting 5900/5901 to known clients.

## License

MIT — see [LICENSE](LICENSE).
