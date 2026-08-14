# ADR-0002: Rig is the canonical term

Status: Accepted

Date: 2026-08-10

## Context

`CONTEXT.md` canonizes **Rig** for the TS-590S transceiver. The codebase names
were split: `protocol.RadioState`, `net.RadioIf`, the client `RadioState`, the
Go package `radio`, the config YAML key `radio:`, and the app name `RemoteRig`.
A future reader would trip on the drift and "fix" it inconsistently.

## Decision

Align the domain-facing types to **Rig**: `protocol.RigState`, `net.RigIf`, and
the client's `RigState`. Keep the Go package `radio` and its `Radio` type, and
keep the user-facing YAML key `radio:` unchanged — the package name is
idiomatic Go for a CAT driver, and the config key is a contract that existing
`server.yaml` files depend on. The app name `RemoteRig` stays.

## Consequences

- Renaming the `radio` package or the `radio:` YAML key is deliberately out of
  scope; do not "fix" it.
- The wire protocol is untouched: JSON keys (`freqA`, `state`, …) and message
  types were unaffected by the rename.
