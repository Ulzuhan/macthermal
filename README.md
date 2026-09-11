# macthermal

A dependency-free macOS **CLI** and **menu-bar app** that read **temperature**
and **fan speed** straight from the System Management Controller (SMC) via
IOKit — then analyze them (grouping, hotspot detection, fan utilization, and a
plain-English verdict).

Works on both **Apple Silicon** (M-series, hundreds of on-die sensors) and
**Intel** Macs. No `sudo`, no third-party libraries.

> Contributing or using an AI assistant on this repo? See [AGENTS.md](AGENTS.md)
> for build/test commands, architecture, and the non-obvious gotchas.

## Install

Via the Homebrew tap:

```sh
brew install guillerDev/tap/macthermal            # CLI
brew install --cask guillerDev/tap/macthermal     # menu-bar app
```

The menu-bar app is ad-hoc signed (not notarized), so on first launch macOS
Gatekeeper will block it. Approve it once by right-clicking the app in Finder
and choosing **Open**, or run:

```sh
xattr -dr com.apple.quarantine "/Applications/MacThermal.app"
```

Prefer building from source? See **[Build](#build)** below.

## Build

```sh
make            # CLI  -> ./macthermal
make gui        # GUI  -> ./MacThermal.app (menu-bar app)
make open       # build the app and launch it
make test       # core + monitor startup tests (no SMC hardware needed)
make install    # copy the CLI to /usr/local/bin (PREFIX=... to change)
```

Requires the Xcode command-line tools (`xcode-select --install`).

You can also build the CLI/tests with SwiftPM (`swift build`, `swift run
macthermal`) or open `Package.swift` in Xcode. The menu-bar `.app` is built only
by `make gui`. See **[docs/BUILDING.md](docs/BUILDING.md)** for all three build
paths and when to use each.

## Usage

```sh
macthermal                 # grouped summary + assessment
macthermal --all           # every individual temperature sensor
macthermal --watch 1       # live dashboard, refresh every 1s (Ctrl-C to quit)
macthermal --json | jq .   # machine-readable output
macthermal --help
```

### Example

```
TEMPERATURE
  CPU      65.8°C  avg 54.2°C · 49 sensors · normal
  GPU      56.9°C  avg 51.9°C · 4 sensors · cool
  Memory   49.0°C  avg 47.2°C · 7 sensors · cool
  Battery  35.8°C  avg 35.8°C · 3 sensors · cool
  ─ hotspot 65.8°C at TCMz · overall avg 45.6°C · normal

FANS
  Fan 1   2317 rpm [████············]  24% · 1200–5779 rpm · low
  Fan 2   2515 rpm [████············]  26% · 1200–6241 rpm · low

All temperatures nominal. System is cool and idle-to-light.
```

Fanless Macs (e.g. MacBook Air) report no fans, which is expected.

## MacThermal Pro app

`make gui` builds `MacThermal.app` — a native menu-bar agent and diagnostic
dashboard (`LSUIElement`, no permanent Dock icon). The menu bar shows the hottest
temperature and opens a compact panel; **Open Dashboard** reveals the full app.

The Pro dashboard adds:

- local temperature and fan history with native Swift Charts, including
  independent peak/average lines and a persistent Overall/CPU/GPU/Memory/
  Battery/Ambient selector,
- an automatic thermal timeline for threshold crossings, pressure escalation,
  and recovery,
- configurable sustained-temperature and OS thermal-pressure notifications,
- throttling detection based on macOS' reported thermal-pressure state,
- CPU/process correlation to identify likely heat contributors,
- current-vs-previous and incident start-vs-end comparisons,
- a manual recorder plus optional automatic incident capture for
  serious/critical macOS pressure or a sustained hotspot above the configured
  threshold,
- renameable incident recordings for workloads and symptoms,
- standalone, dark-mode HTML diagnostic reports with privacy-safe system
  context, plus detailed CSV sample exports.

All history and incidents stay under `~/Library/Application Support/MacThermal`.
Automatic recordings stop only after a configurable recovery period, once
pressure is clear and the hotspot is below a recovery margin, so a brief
fluctuation does not split one thermal episode into several files. Each one
also includes up to two minutes of pre-trigger history to preserve the lead-up.
Active recordings use a recoverable incremental journal, and long episodes are
split at a configurable duration so they cannot grow without bound in memory.
Automatic recording has a master switch independent from notifications and
manual recording. Incident retention and maximum recording count are
configurable in Settings.
High-resolution incident samples stay in the incident journal; the general
history always keeps its selected 15/30/60-second cadence so comparisons remain
statistically balanced.
Reports include the Mac model identifier, macOS version, architecture, memory,
and logical core count, but never the serial number, account name, or computer
name.
Process correlation is presented as investigative evidence, not proof of
causation. No network service or third-party dependency is used.

The compact menu panel includes:

- a configurable menu-bar reading for the hottest sensor, CPU, or GPU,
- the OS thermal-pressure and throttling state,
- the hottest temperature per component (CPU / GPU / memory / battery / …),
- per-fan RPM with a utilization bar,
- incident recording, dashboard, refresh, and launch-at-login controls. Settings
  live in the dashboard toolbar and remain available with the standard `⌘,`
  shortcut.

The **Open at Login** checkbox registers the app as a login item via the modern
`SMAppService` API (macOS 13+) — no helper bundle, nothing to configure by hand.

It shares the exact same SMC reader as the CLI (`Sources/MacThermalCore/Sensors.swift`); the
IOKit connection is isolated in an `actor` so all sensor reads happen off the
main thread and only immutable snapshots reach SwiftUI.

```sh
make open          # build + launch
# to run at login: open the panel and tick "Open at Login"
```

The app is ad-hoc code-signed during the build so it runs locally on Apple
Silicon without a developer certificate.

## How it works

- Opens the `AppleSMC` IOKit service and calls it with the kernel's
  `SMCParamStruct` ABI (`Sources/SMC.swift`).
- Enumerates every SMC key (`#KEY` → indexed reads), keeps the temperature
  sensors (`T…` keys, `flt`/`sp78` types, plausible 1–130 °C range), and reads
  the fan block (`FNum`, `F<i>Ac/Mn/Mx/Tg`).
- Decodes the SMC fixed-point / float encodings, then categorizes sensors by
  key prefix (`Tp`/`Te` cores, `Tg` GPU, `TB` battery, …) for the summary.
- Caches the key list and each key's type/size for the life of the SMC
  connection (neither changes at runtime). The first capture enumerates every
  key (~2,300 on Apple Silicon); every refresh after that reads only the known
  sensor values — roughly a **25× speedup**, which matters for the menu-bar app
  and `--watch`, both of which refresh continuously.

### Note on the struct layout

The kernel's `SMCParamStruct` is exactly **80 bytes**. Swift collapses the
trailing padding of nested C structs (yielding 76 bytes), which makes the
IOKit call fail with `kIOReturnBadArgument`. `SMC.swift` therefore uses a
**flattened struct with explicit padding fields** to reproduce the C ABI
(`pLimit@12`, `result@40`, `data32@44`, `bytes@48`).

## Thresholds

| Temperature | Status   | Fan utilization | Status   |
|-------------|----------|-----------------|----------|
| < 60 °C     | cool     | < 5 %           | idle     |
| < 78 °C     | normal   | < 50 %          | low      |
| < 90 °C     | warm     | < 85 %          | elevated |
| < 100 °C    | hot      | ≥ 85 %          | maxing   |
| ≥ 100 °C    | critical |                 |          |

These are heuristics for a quick health read, not vendor-spec throttle points.

## Releasing

Cutting a release is just pushing a version tag; CI builds, publishes a GitHub
Release, and updates the Homebrew tap. See **[docs/RELEASING.md](docs/RELEASING.md)**
for the full process and the one-time tap-token setup.
