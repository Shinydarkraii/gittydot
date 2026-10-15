# GittyDot changelog

## 0.2.0 — 2026-10-15

- Keep Commit labels anchored left and staging checkboxes visible down to 200 logical pixels. Compact the sync toolbar, wrap commit actions, and expose truncated paths/names in tooltips.
- Add fixed, non-editable +/− gutters, grouped range bars and deletion boundaries to editable comparisons.
- Add a viewport-sized change overview with click navigation and viewport indicators. Preserve caret, source, Undo and synchronized scrolling.
- Share addition/deletion backgrounds and intraline colors between editable and committed comparisons. Preserve native Script editor decoration colors.
- Enable Open in Editor for existing/new/untracked project scripts, flush pending comparison edits, refresh clean cached scripts and preserve native drafts. Explain unavailable cases.

Verification: 265 graphical integration checks; focused UI checks at 100% and 150% scale; no script, startup or engine errors in the final runs. Tested on Windows with Godot 4.7.2 and Git 2.53.0. Save/recovery, partial staging, historical/index read-only comparisons and the existing Git backend remain covered.

- Windows compatibility follow-up: scope filesystem-monitor safeguards to Git children, covering Git 2.36.1 as well as newer Git. A 34-check graphical compatibility run passed on 2.36.1.

## 0.1.0

Initial GittyDot release based on Godit 1.1.1. Includes Commit/FileSystem integration, central comparisons, editable working files, automatic script saving, inline changes, history and selected-commit amendment.
