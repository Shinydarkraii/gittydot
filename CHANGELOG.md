# GittyDot changelog

## 0.2.6 — 2026-11-14 — Correctness and Responsiveness Update

### Fixed

- Align editable side-by-side comparisons with blank display rows opposite insertions, deletions and unequal replacements. Both panes now scroll through the same visual rows, while line numbers retain their original source positions.
- Keep alignment gaps out of saved files, recovery drafts, clipboard selections and source Undo/Redo; preserve immediate saves before staging or switching files.
- Redraw character highlights after comparison resizing even when glyph positions remain unchanged.

- Failed staging no longer falls back to removing a file from the index. Failed unstaging on an established branch preserves the index; only a genuinely unborn branch uses cached removal. Checkbox, grouped, automatic and changelist operations report errors and refresh from the actual index.
- Establish an exact local scratch exclusion in existing repositories and linked worktrees, without editing tracked ignore files or automatically untracking existing scratch files. Refuse scratch storage when it cannot be safely excluded.
- Disconnect FileSystem collapse callbacks and suppress queued painting after teardown. Guard stale web-menu targets after file/repository changes. Release modal dialogs before awaited editor refresh actions resume.
- Serialize post-operation filesystem scans and scene reloads; preserve scenes that acquire unsaved edits while a refresh is pending, and cancel queued refreshes when the addon is disabled.
- Validate Unix descendant-query failures and PIDs before best-effort cancellation, and use a coarser process-completion wait while draining both pipes concurrently.
- Correct the GittyDot authentication hint and repository initialization description. Remove unused combined-dock code and obsolete detach/reattach helpers, while preserving upstream attribution, source identities and authored scenes.

### Performance

- Discover known native script tabs without repeated full-file reads; keep full content/conflict checks immediately before writing, including same-size, same-timestamp external edits.
- Compute changed-buffer gutter baselines and diffs on a bounded, coalescing background worker. Cache immutable HEAD blobs, reject stale file/buffer/HEAD results, defer hidden native tabs during scene workflows, retry failures, and cancel/join work on disable.

### Test tooling

- Add explicit trusted `--ca-bundle` and `--native-trust` options, validate PEM input before fixture setup, support both MinGW and UCRT Git bundle layouts, and retain TLS verification.
- Report exact Godot/Git versions, execution mode, trust source and skipped blocks with reasons. Graphical, headless and older-Git profiles have different assertion totals; 0.2.5's historical 282-check total was graphical with Git 2.53.0.

### Compatibility and limits

- Retains Godot 4.4+ as the minimum and includes the aligned comparison fix. Native Linux/macOS process-tree cleanup remains unverified; Windows tests cover injected Unix discovery failures and real cancellation with inherited helper pipes.
- Comparison panes use one caret and copy/paste for moving text; the native editor retains multi-caret and drag editing.

### Verification

- Windows graphical matrix: **355 passed / 1 skipped** per build on Godot **4.4.1, 4.5.2, 4.6.3, 4.7, 4.7.2 and 4.8 beta1**, using **Git 2.56.0**, with zero failures, script errors, startup diagnostics or engine errors in the final runs.
- Git 2.56.0 headless: **344 passed / 2 skipped**. Git 2.36.1 with an explicit trusted PEM: **339 passed / 2 skipped** graphical and **328 passed / 3 skipped** headless, with zero diagnostics. Skips identify graphical-only checks, native Unix cancellation and unsupported older-Git selected-history execution as applicable.
- Native TLS trust is unavailable on this test host; preflight reports the prerequisite instead of disabling verification. Supplied PEMs are validated before fixture setup. The currently available modern Git is 2.56.0; the historical 2.53.0 executable was not installed or rerun.

## 0.2.5 — 2026-10-23 — Compatability Update

### Added

- Support for Godot 4.4–4.6 alongside the existing 4.7 and 4.8 beta1 integration.
- Compatibility fallbacks for detecting unsaved scripts/scenes and saving through the native editor on versions without the newer APIs. Preserve Undo, native drafts and disk-conflict protection; stop Git operations if saving is unavailable.
- Full-document sizing for older CodeEdits using native text measurements, with optional line-number/content-fit properties detected before use.

### Fixed

- Missing `%HistoryPanel` and null `has_signal` errors when Godot initializes the Git Log dock again. Keep the existing Log/Console tabs and signal connections.
- Missing comparison highlighting, overview navigation and save registration after editor controls leave and re-enter the tree. Preserve text buffers, caret and Undo, and reuse gutters instead of accumulating duplicates.
- Plugin panel initialization while an authored scene is open, using scene ancestry rather than viewport membership.
- Test editor/settings isolation by exact Godot build and display scale.

### Compatibility

- Requires Godot 4.4 or newer. Verified Windows builds: **4.4.1, 4.5.2, 4.6.3, 4.7, 4.7.2 and 4.8 beta1**.
- Godot **4.0–4.3 remain unsupported** because required editor APIs are absent. Other platforms, .NET builds and unlisted engine builds remain unverified.

### Verification

- **282 graphical integration checks per verified build**, with zero failures, script errors, startup diagnostics or engine errors in the final runs (Windows / Git 2.53.0).
- **24 clean packaged startup/restart checks**, covering projects with and without a Git repository on all six verified builds.
- Earlier 0.1.0, 0.2.0 and 0.2.1 ZIPs were preserved unchanged and startup-assessed across all ten downloaded Godot builds; this is not full functional revalidation of those older releases.

## 0.2.1 — 2026-10-17 (preview)

Scope: broaden Godot version compatibility while retaining the 0.2.0 features. The 0.2.0 release is preserved separately; this build is not a final compatibility guarantee for all Godot 4.x versions.

### Implemented — 2026-10-17

- Keep Git Log initialization idempotent when Godot requests ready again after relocating the dock; preserve the runtime History/Console tabs and guard temporarily unavailable history signal bindings.
- Restore comparison highlighting and save registration when editor UI leaves and re-enters the tree. Reuse existing gutters and overview overlays.
- Use authored-scene ancestry to keep plugin panels initialized while native scenes are open.
- Isolate test editors and settings by engine version/build. Verified 277 graphical checks on Godot 4.7.2 and 4.8 beta1 on Windows / Git 2.53.0.

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
