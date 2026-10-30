# Cadence

A local work log for macOS 26 that fills itself from what you already do, asks you only for judgment, and turns every workday into evidence a manager's agent can check. It lives in one dot in your menu bar.

- Local only: the app has no network entitlement, so macOS blocks it from opening a connection.
- No admin rights: nothing needs sudo, Docker or an Apple account.
- An honest proof file: a hash-chained export that labels each entry as observed, collected, agent or self.

Status: phase 0 (bootstrap). Not ready for use.

## Build

- `make check` on Linux or macOS with Swift 6.2 or later. It is the gate before every push.
- `make spike` on the Mac. It checks the platform claims listed in docs/SPIKES.md.

## Docs

- [docs/SPEC.md](docs/SPEC.md): the specification, the source of truth
- [docs/PLAN.md](docs/PLAN.md): every task with its tier and done-when
- [docs/SPIKES.md](docs/SPIKES.md): platform claims and their evidence

License: Apache-2.0, see [LICENSE](LICENSE).
