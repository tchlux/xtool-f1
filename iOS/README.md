# xTool F1 App

Personal iOS app for sending simple projects to my xTool F1 Laser Engraver.

# Project Instructions

- This project uses `sc` for source control.
- `AGENTS.md` is a symbolic link to this `README.md`; update this file when changing agent/project instructions.
- Do not run source-control mutating commands (`sc add`, `sc rm`, `sc mv`, `sc commit`, `sc amend`, or equivalents) while implementation or testing is still in progress. Wait until the work is done and verified, then stage the complete coherent change set.
- Do not commit unless explicitly told to commit. After implementation and testing, leave changes staged or unstaged as requested so they can be reviewed first.
- Every time a commit is created, first add a new log file in `logs/` using the next available number, like `logs/2.md`, `logs/3.md`, and so on.
- Start each log with the current date and time, then summarize the actions included in the commit.
- After implementation or testing work, always conclude by running `./run-phone.sh` before reporting completion so the app is installed/launched for review.
- Do not report that an iOS feature works unless the actual installed app path was verified on-device. If only shared core code, a CLI probe, build success, install success, or launch success was verified, say exactly that and treat the on-device UI path as unverified.
- Before changing the photo editor, read `docs/editor-known-failure-modes.md` and avoid the documented failure modes.
- Before changing print preview or G-code preview rendering, read `docs/print-preview-known-failure-modes.md` and preserve the documented DPI and timing guardrails.

## Project Goals

- Build a private iOS app for my own xTool F1.
- Represent each project as instruction data: raster photos, text/vector objects, per-object placement, laser settings, and print/frame paths.
- Provide a send mechanism from the app to the machine.
- Keep firing gated by the machine itself: the physical `go` action must happen on the F1.
- Support preview/framing mode, where the blue diode traces outlines at very low power.
- Prefer the official/local protocol when available.
- If protocol behavior is unclear, observe XCS/LightBurn traffic before removing or changing capabilities.

## Current Hardware

- Machine: `xTool F1`
- Laser model: `455-10W / 1064-2W`
- Firmware: `40.51.013.2020.01.ht5`
- Plug-in version: `1.1.47`
- LAN IP: `192.168.1.199`
- Work area: `115 x 115 mm`
- Serial number: observed in xTool UI, intentionally not recorded here.

Do not update firmware casually. This F1 is below xTool's newer restricted-protocol firmware cutoff and still exposes the older LightBurn-compatible path.

## Current Protocol Status

- Open ports: `80`, `8780`, `8080`, `8081`
- New protocol port `28900`: refused
- Official LightBurn config uses TCP port `8780`
- LightBurn device type: `TCP`
- Blue laser select: `M114S1`
- IR laser select: `M114S2`
- LightBurn start G-code: `$L`, `G90`, `G0 F240000`
- LightBurn end G-code: `M116A127B127`, `G90`, `M6`, `$P`
- App framing uses the XCS "walk border" HTTP path (`/processing/upload` with `gcodeType=frame`, `autoStart=1`, `loopPrint=1`), not `$L`/`M3` on port `8780`.
- App printing uses the XCS HTTP path (`/processing/upload` with `gcodeType=processing`) and status polling on `/cnc/status`.
- TCP port `8780` remains the LightBurn-compatible CLI/raw sender path.

## Current Implementation

SwiftUI iOS app plus SwiftPM core/CLI for the current F1 firmware.

- App UI: Projects, Library, History, and Log tabs.
- Projects contain raster photos, text objects, and vector/basic-shape objects with per-object placement, enablement, laser, speed, power, and raster DPI settings.
- The project editor supports multi-select canvas move/resize/rotation, raster photo edits, text/vector editing, outline creation, sequential/simultaneous print preview, and outline/box framing.
- Local persistence uses `FileAppStore` under the app Documents `xToolF1/` folder with `store.json`, `Images/`, and generated project G-code/preview files.
- XCS imports are supported for F1 bitmap/path/text objects; repeated imports are skipped by fingerprint.
- App print upload uses the F1/XCS HTTP `/processing/upload` path with `gcodeType=processing`; framing uses the same route with `gcodeType=frame`.
- App stop uses `/processing/stop`; the print workflow monitors `/cnc/status` and still requires the physical side button to start firing.
- The CLI remains useful for generating or sending a simple `.xtoolproject.json` over the LightBurn-compatible TCP path.

Generate CLI G-code without sending:

```sh
swift run xtool-f1 sample.xtoolproject.json
```

Send CLI G-code explicitly:

```sh
swift run xtool-f1 --send --host 192.168.1.199 sample.xtoolproject.json
```

The sample project is marked `"preview": true`, which caps generated power at 1%.

## Test Protocol

Use the smallest tier that can see the failure you care about:

```sh
./test.sh quick
./test.sh core
./test.sh all
```

- `quick`: fast SwiftPM signal for pure raster/editor logic, protocol parsing, geometry, discovery, and other cheap invariants.
- `core`: full SwiftPM core suite, including slower G-code preview, print preview, frame, store, migration, and history coverage.
- `all`: full core suite plus essential simulator launch scenarios. It intentionally does not launch the phone.

Use app launch scenarios to reconstruct UI states without brittle UI automation:

```sh
./test.sh sim editor-smoke
./test.sh sim editor-visual
./test.sh sim canvas-smoke
./test.sh sim preview-project
./test.sh sim first-project
./test.sh phone normal
./test.sh phone canvas-smoke
./test.sh phone preview-project
./run-sim.sh --state Tests/LaunchStates/text-editor-redesign.json
./run-sim.sh --state Tests/LaunchStates/vector-editor-redesign.json
./run-sim.sh --state Tests/LaunchStates/canvas-delete-rotate.json
```

Supported scenarios are `normal`, `editor-smoke`, `editor-visual`, `canvas-smoke`, `preview-project`, and `first-project`. `run-sim.sh --state <json>` can launch any saved state from `Tests/LaunchStates/`. Prefer these scenario launches over broad simulated UI flows. They seed deterministic state, enter the app through the real launch path, and avoid coupling tests to small SwiftUI layout changes.

Healthy UI test hygiene:

- Keep semantic behavior in `quick` or `core` whenever possible.
- Use `editor-smoke` for non-rendering editor state transitions.
- Use `editor-visual` only for layout-sensitive editor rendering checks.
- Use `canvas-smoke` when changing canvas geometry, selection handles, or rotation behavior.
- Use `preview-project` and `first-project` to manually inspect and reconstruct targeted states as the app grows.
- Do not add assertions that fail only because labels, spacing, order, or minor layout shifted unless that shift breaks the workflow being tested.
- After implementation or testing work, run `./run-phone.sh` so the current app is installed and launched on the connected iPhone.

## Downloaded Resources

`downloaded-resources/` is intentionally ignored by `sc`. It contains local reference artifacts used to verify xTool behavior without re-downloading large files:

- `xTool-Studio-arm64-1.2.11.dmg`: macOS xTool Studio installer used to inspect the official F1 extension.
- `xtool-exts/F1/index.js`: extracted xTool Studio F1 extension bundle; useful for finding API routes such as walk-border/framing.
- `xtool-exts/F1/package.json`: F1 extension metadata.
- `xtool-f1-guide.pdf`: official xTool F1 guide.
- `xtool-software.html`: captured xTool software download page that referenced the Studio DMG.
