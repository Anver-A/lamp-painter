# Lamp Painter

A Factorio 2.1 mod for recolouring lamps in bulk.

Click the lamp button in the shortcut bar (or press **Alt+L**) and drag over your lamps:

- Drag to select, Shift-drag to add, right-drag to remove.
- Live preview on the real lamps. **Apply** keeps it; **Cancel**, Esc or closing the window puts everything back.
- RGB sliders, number and hex entry, the 9 vanilla lamp-signal colours, saved presets (right-click to delete) and a colour picker.
- Mode: Leave as is / Normal / Always on.
- Circuit-controlled lamps are skipped by default, with an option to include them.
- Ghost lamps: the colour is stored on the ghost and applied when it's built.
- "Undo last paint" button (mods can't add to the game's Ctrl+Z).
- Pin the window to keep it open while you do other things.
- Large selections are spread over several ticks, so there's no stutter.
- Multiplayer-safe; each player has their own edit and presets.

## Layout

| Path | What it is |
|---|---|
| `lamp-painter/` | The mod itself (this folder is what gets zipped and uploaded) |
| `lamp-painter-test/` | Test-only mod with an automated in-game test scenario |
| `tools/run-tests.sh` | Runs the automated test headless in a throwaway data folder |
| `tools/package.sh` | Builds `dist/lamp-painter_<version>.zip` |
| `tools/thumbnail.swift` | Renders `thumbnail.png` from the game's own sprites |

## Testing

```bash
tools/run-tests.sh
```

Needs Factorio 2.1 with Space Age installed (Steam path on macOS by default; pass another binary path as the first argument).
The test drives the mod's own event handlers, because selection events cannot be raised by script. Prints
`LP-TEST phase1 passed, checks=N` on success.

The mod has a debug remote interface and strict-globals checking for the tests; both are active only when
`lamp-painter-test` is enabled, never in normal play.

## Releasing

1. Bump `version` in `lamp-painter/info.json` and add an entry to `lamp-painter/changelog.txt`.
2. `tools/run-tests.sh`
3. `tools/package.sh`, then upload the zip on the mod portal.

## Licence

MIT
