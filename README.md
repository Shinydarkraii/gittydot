# GittyDot

Git tools integrated into the Godot editor, with an IntelliJ-inspired workflow for reviewing changes, staging files, committing, and browsing history.

GittyDot is a fork of [Godit](https://github.com/rychtar/godit) by Michal Rychtar, based on package version **1.1.1**. It keeps the upstream Git CLI backend and builds a different editor integration around it. The current GittyDot version is **0.1.0**.

## Features

- **Native FileSystem status:** modified, added, renamed, deleted, and conflicted files show status badges beside their names.
- **Commit dock:** staging checkboxes, changelists, commit messages, an amend target dropdown, commit, and push controls. Select a recent branch commit or right-click a commit in Git Log and choose **Amend This Commit…**.
- **File and folder actions:** right-click folders in Commit to add new files to Git, stage or unstage their displayed descendants, stash, revert, move to a changelist, copy their path, or add the folder to `.gitignore`. Files also expose **Add to .gitignore**, and the native FileSystem menu offers **Git: Add Folder to .gitignore**.
- **Central diff editor:** switch between **Side by side** and **Unified** beside **Open in Editor**. Working-file comparisons have an editable right pane, Save/Reload controls, auto-save and Undo. Split panes have a draggable divider and synchronized horizontal and vertical scrolling; scrollbars appear when needed.
- **Inline script changes:** adjacent changed lines share continuous gutter markers. Modified lines stay yellow, inserted text is green, and replacements receive stronger yellow/green emphasis.
- **Compact change previews:** click a gutter marker to inspect the previous version, navigate changes, roll back the hunk, or open its full diff. Modified text keeps modification colors; deleted lines use red.
- **Automatic script saving:** native Godot saves after a short editing pause, with Undo and saved markers preserved.
- **Git Log:** searchable commit graph, file history, stash comparisons, and historical diffs opened in the central editor.
- **Git console:** command history, literal output rendering, and confirmation before destructive commands. Error dialogs offer **Show details in Console**, which opens the Console tab at the corresponding failure, including version/validation errors that never launched Git.

Upstream branch, tag, remote, stash, merge, rebase, cherry-pick, conflict-resolution, blame, image-diff, and scene/config inspection tools remain available. See [UPSTREAM_README.md](UPSTREAM_README.md) for the original Godit feature overview; its installation and layout instructions describe the upstream plugin.

## Requirements

- **Godot 4.7.2 on Windows** is the verified configuration for this fork.
- `git` must be installed and available on the editor's `PATH`.
- Amending a selected **older** commit requires **Git 2.45.0 or newer** in GittyDot. Latest-commit amend retains its existing Git compatibility.
- The project must be inside a Git repository, or initialized through the plugin.
- Remote operations require working Git authentication.

Compatibility with other Godot versions and platforms has not been verified for GittyDot. Godit's upstream compatibility range does not establish compatibility for this fork.

## Installation

1. Download or clone this fork.
2. Copy the complete `addons/gittydot/` directory into your Godot project's `addons/` directory, and copy the repository's `LICENSE` into the installed `addons/gittydot/` folder.
3. Disable **Godit** if it is installed.
4. Enable **GittyDot** in **Project Settings > Plugins**.
5. Restart an already-open editor after replacing or updating the addon.

The resulting layout must include:

```text
your-project/
  project.godot
  addons/
    gittydot/
      plugin.cfg
      plugin.gd
      dock/
      util/
      ...
```

Keep the directory named `gittydot`: the plugin uses `res://addons/gittydot/` resource paths. Avoid placing an extra downloaded repository directory between `addons/` and `gittydot/`.

Enable only one of Godit and GittyDot. GittyDot does not require the Godot Git GDExtension plugin or an AI/editor assistant.

Add this pattern to the project's `.gitignore` for the plugin's local temporary files:

```gitignore
/*-temp-chatgpt/
```

New repositories initialized through GittyDot receive this pattern automatically.

## Workflow

### Review changes

Use the normal **FileSystem** dock to see file status. Select a changed file in **Commit**, choose **Git: Show Change** from the FileSystem context menu, or use **Show Diff** in a gutter preview to open the central **GittyDot** screen.

The default comparison is **Latest commit → Working file**, including both staged and unstaged changes. New files compare against an empty baseline and appear as additions.

Use the dropdown beside **Open in Editor** to choose **Side by side** or **Unified**. The choice is remembered for the project. Supported scripts and scenes open in their native Godot editors; other text/configuration files can be reviewed in GittyDot's diff view.

In **Side by side**, **Latest commit → Working file** and **Unstaged changes** let you edit the working file on the right. The left version stays read-only. Editable comparisons show complete documents without collapsed separators or padding lines; vertical scrolling follows corresponding source lines across insertions/deletions. Use **Save**, **Ctrl/Cmd+S**, or the default 350 ms auto-save. Undo remains available after saving, and saves leave staging untouched. Selecting a different file or starting a Git operation flushes pending comparison edits first.

Hunk/line patch buttons, collapsed context, whitespace/noise filtering and the structured **Scene/Settings** view are disabled in editable comparisons. Use **Unified** for read-only inspection and applicable patch actions, or the **Commit** checkboxes to stage files. Staged snapshots, commit/stash history, images, binary files and deleted files remain read-only. Editable text must be UTF-8, within the current project, up to 2 MiB and 20,000 lines; file symlinks stay read-only.

Comparison saves preserve UTF-8 BOMs, LF/CRLF style and a missing final newline. If the file changes externally, disappears, or has another unsaved draft in Godot's Script/Scene editor, saving pauses and keeps both versions. **Reload** explicitly discards the comparison draft; blocked/unsaved drafts are stored in the project-local temporary folder for recovery after plugin reload. Clean native script tabs are synchronized after saves. **Open in Editor** reloads a clean cached scene from the working file, while preserving unsaved native scenes.

### Stage and commit

In the **Commit** dock, select the files to stage, enter a commit message, and commit. Changelists, amend, and **Commit and Push** are also available.

To amend a specific commit, use the dropdown beside **Amend**, or right-click it in **Git Log > Amend This Commit…**. The dock loads its message and displays its short hash; edit the message and stage the changes you want to include. Reword, Fixup, Squash and Drop remain separate Log menu actions. Amending an older commit asks before replaying newer commits and changing their hashes. Amendments across merge commits are refused. The Git version is checked before any amendment changes the index or history; an unsupported version leaves the draft and target intact.

If replay encounters conflicts, resolve them and use **Continue**, or **Abort** to restore the original history with the amendment changes staged. Recovery information survives plugin reload. Failures expose **Show details in Console**; later commands do not change which diagnostic that button opens. No automatic force-push is performed.

Use **Unstaged changes** for index → working-file comparisons and **Staged changes** for latest-commit → index comparisons. Read-only inspection views expose applicable hunk/line staging, unstaging and revert actions. Editable working-file panes use Commit checkboxes for staging; the default latest-commit → working-file comparison does not apply patches directly, since they may not match a partially staged index.

Automatic staging, automatic adding of new files, and background fetch are **off by default**. Auto-save does not stage, commit, or push.

Right-click a file or folder and choose **Add to .gitignore** or **Add Folder to .gitignore**. The rule is anchored to the repository root, with filename wildcard characters escaped. Existing rules and files are preserved. Already tracked files remain tracked; ignoring them does not unstage or remove them from Git.

### Inspect history

Open **Git Log** in the bottom panel. A single click selects a changed file; **double-click or Enter** opens its diff in the central editor.

Commit diffs compare the selected commit with its first parent. Initial commits show additions, deleted historical files remain viewable, and stash comparisons use their recorded revisions. Historical diffs are read-only and retain the selected revision during background refreshes.

## Auto-save and preferences

Auto-save is **enabled by default** for project-backed scripts and editable working-file comparisons. It saves after **350 ms without another edit**, and flushes pending saves when the application loses focus or before staging. Native scripts save through Godot's ScriptEditor; comparison panes save their full text to the working file using a guarded atomic replacement. The Tools toggle controls both; Save/Ctrl+S remains available with auto-save disabled.

If a script changes externally or disappears, automatic saving pauses to preserve the disk version and editor draft. Resolve Godot's reload prompt or save manually. Unsaved changes in the native Scene editor, untitled scripts and embedded scripts continue to use the native save workflow; raw scene text edited in the comparison pane follows its working-file save flow.

Toggle auto-save, blame, and background fetch in **Project > Tools > GittyDot**. Preferences and changelists are local to each project under `.godot/gittydot/`.

## Git console and authentication

The console passes arguments directly to Git. Output is rendered as literal text, and its command log uses mutex-protected snapshots.

Confirmation is required before hard resets, destructive cleans, forced pushes, global/system configuration writes, and destructive or shell aliases. Cancelling preserves the typed command. Read-only queries and clean dry runs do not require destructive-command confirmation.

SSH uses per-invocation `ssh -o BatchMode=yes`. GittyDot does not change the editor's SSH environment or adopt repository `core.sshCommand` settings. Configure keys and hosts in your SSH configuration, or explicitly supply a trusted `GIT_SSH_COMMAND`; non-OpenSSH clients may also need `GIT_SSH_VARIANT`.

Noninteractive Git prompt/editor environment variables apply while the plugin is enabled and are restored on disable. Git hooks and helpers run with your permissions; GittyDot is not a sandbox for untrusted repositories.

## Local data

- Preferences and changelists: `.godot/gittydot/`.
- Diff, blame, and patch temporary files: `<project-name>-temp-chatgpt/gittydot/`.

The temporary-folder name comes from the development convention used for this fork. It is a local directory, not an integration or callback. Godot ignores it through `.gdignore`; Git ignores it when the installation's `.gitignore` pattern is present.

## Development and verification

The latest verified headless run passed **222 editor integration checks** on Godot 4.7.2 for Windows with Git 2.53.0 and no script errors. The suite covers saving and Undo, partial staging, commit/amend, historical comparisons, split-pane scrolling, gutter geometry, concurrent logging, console confirmation cancellation, plugin reloads, folder right-click actions, and literal ignore rules. Editable-comparison checks cover raw script/scene text, native-tab synchronization, scene reload, auto/manual save, file switching, BOM/CRLF preservation, external changes/deletion, competing native drafts, recovery and read-only snapshots. Selected-commit checks cover exact-hash targeting with duplicate subjects, root/message-only amendments, rejecting hooks, merge refusal, preserved unstaged edits, version errors, Console navigation, confirmation cancellation/retry, and conflict Continue/Abort recovery.

Verification requires Python 3, Git, and the target Godot executable. From the repository root, with `tools/test_gittydot.py` included:

```powershell
python tools/test_gittydot.py --godot 'C:\Tools\Godot\Godot.exe'
```

Replace the executable path with your installation. To run the hidden graphical editor checks and capture native highlights and split panes on Windows:

```powershell
python tools/test_gittydot.py --godot 'C:\Tools\Godot\Godot.exe' --visual
```

The runner creates a disposable project and Git repository inside the project-local temp folder. It does not stage or commit the source repository. Result JSON, logs, and graphical captures stay in each test fixture.

See [MAINTAINING.md](MAINTAINING.md) for implementation ownership, behavior contracts, and upstream-update guidance.

## Publishing and contributing

This repository contains the runtime addon under `addons/gittydot/`, verification sources under `tests/`, and the runner under `tools/`. Documentation, the upstream baseline, and the MIT license are kept once at the repository root. `*.uid` files are source resource identities and should remain tracked; generated `*.import` files should not. The root `.gdignore` prevents a containing Godot project from importing this repository as a second addon copy. Install only the addon directory and license. Keep game-specific scenes, assets, `.godot/` data, local settings, temporary fixtures, and generated exports out of the plugin distribution.

Report issues with the Godot version, operating system, reproduction steps, and relevant editor errors or screenshots. Changes to Git operations should preserve partial staging, editor drafts, and native Undo. Verify changes in an isolated test project before submitting a pull request.

## Current limitations

The planned **0.2.0** fixes are tracked in [ROADMAP.md](ROADMAP.md): narrow Commit dock alignment and visible staging checkboxes, editable-diff change signs and navigation, matching committed-diff colors, and reliable Open in Editor behavior.

- This is an early fork, not a complete reproduction of IntelliJ's Git interface.
- Multiple concurrent diff tabs, broader keyboard shortcuts, and further image/scene workflow polish remain planned work.
- Native FileSystem decorations depend on Godot's internal editor controls and need verification after engine upgrades.
- Automated checks do not establish remote authentication behavior, every inherited Git operation, or compatibility outside the verified configuration.

## Credits and license

GittyDot uses the [Godit](https://github.com/rychtar/godit) backend and existing Git widgets, originally authored by **Michal Rychtar**. GittyDot contributors maintain the editor integration and regression checks described here.

Released under the **MIT License**. The original copyright and license notice are preserved in [LICENSE](LICENSE). [UPSTREAM_README.md](UPSTREAM_README.md) preserves the upstream documentation; [upstream.json](upstream.json) records the source package baseline.
