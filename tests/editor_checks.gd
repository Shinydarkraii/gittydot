@tool
extends EditorPlugin

const Cli := preload("res://addons/gittydot/util/git_cli.gd")
const Open := preload("res://addons/gittydot/util/editor_open.gd")
const Autosave := preload("res://addons/gittydot/util/script_autosave.gd")
const Colors := preload("res://addons/gittydot/dock/filesystem/filesystem_colors.gd")
const Flags := preload("res://addons/gittydot/util/git_status_flags.gd")
const Settings := preload("res://addons/gittydot/util/settings.gd")
const Preview := preload("res://addons/gittydot/dock/gutter/change_preview.gd")
const Gutter := preload("res://addons/gittydot/dock/gutter/diff_gutter.gd")
const GutterCommitGraph := preload("res://addons/gittydot/dock/widgets/commit_graph.gd")
const InlineDiff := preload("res://addons/gittydot/util/inline_diff.gd")
const InlineHighlights := preload("res://addons/gittydot/dock/gutter/inline_highlights.gd")
const DiffView := preload("res://addons/gittydot/dock/widgets/diff_view.gd")
const Console := preload("res://addons/gittydot/dock/widgets/git_console.gd")
const RepoSetup := preload("res://addons/gittydot/util/repo_setup.gd")
const Changes := preload("res://addons/gittydot/dock/panels/changes_panel.gd")
const ChangesScene := preload("res://addons/gittydot/dock/panels/changes_panel.tscn")
const Repo := preload("res://addons/gittydot/util/git_cli_repo.gd")
const Dialogs := preload("res://addons/gittydot/dock/widgets/dialogs.gd")
const WorkingDiff := preload("res://addons/gittydot/dock/widgets/working_diff.gd")
const SaveGuard := preload("res://addons/gittydot/dock/widgets/save_guard.gd")

class OldGitRepo:
	extends "res://addons/gittydot/util/git_cli_repo.gd"
	func git_version_text() -> String:
		return "git version 2.44.0.windows.1"

var checks := []
var _fork: EditorPlugin


func _enter_tree() -> void:
	_run.call_deferred()


func check(label: String, ok: bool) -> void:
	checks.append({"name": label, "passed": ok})
	print("GITTYDOT TEST ", "PASS " if ok else "FAIL ", label)


func _run() -> void:
	await get_tree().create_timer(1.0).timeout
	while EditorInterface.get_resource_filesystem().is_scanning():
		await get_tree().process_frame
	for node: Node in get_tree().root.find_children("*", "EditorPlugin", true, false):
		if node.get_script() != null and node.get_script().resource_path == "res://addons/gittydot/plugin.gd":
			_fork = node
			break
	check("fork is enabled", _fork != null and EditorInterface.is_plugin_enabled("res://addons/gittydot/plugin.cfg"))
	if _fork == null:
		_finish()
		return
	var repo: RefCounted = _fork.dock_instance._repo
	_check_monitor_safety(repo)
	if OS.get_cmdline_user_args().has("--gittydot-ui-only"):
		await _check_narrow_commit(repo)
		await _check_editable_diff(repo)
		_finish()
		return
	_check_startup_helpers()
	await _check_console_safety(repo)
	await _check_folder_actions(repo)
	await _check_narrow_commit(repo)
	var restore_patch: String = repo.get_diff("tracked.gd", true)
	check("existing partial staging preserved on startup", repo.get_file_bytes(":", "tracked.gd").get_string_from_utf8().contains("number := 2"))
	check("auto-stage and auto-add default off", not Settings.get_value("auto_stage_changes", false) and not Settings.get_value("auto_add_new_files", false))
	check("auto-save defaults on", _fork.autosave.enabled)
	var screen: Control = _fork.main_screen
	screen.open_path("tracked.gd")
	check("default central diff compares latest commit to working file", screen.diff_view._diff_text.contains("-var number := 1") and screen.diff_view._diff_text.contains("+var number := 3"))
	screen.open_path("new_file.gd")
	check("new file diff contains all added lines", screen.diff_view._diff_text.contains("+extends Node") and screen.diff_view._diff_text.contains("+var fresh := true"))
	check("new file diff is an addition", screen.diff_view._diff_text.contains("new file mode"))
	check("configuration files open without unsupported-editor error", Open.open_file(repo.get_repo_root(), "project.godot").is_empty() and screen.path == "project.godot")
	check("status badges distinguish modified and added files", Colors.status_badge(Flags.WT_MODIFIED) == "M" and Colors.status_badge(Flags.WT_NEW) == "A")
	check("conflict status outranks added status", Colors.status_badge(Flags.CONFLICTED | Flags.WT_NEW) == "!")
	var actual_tree: Tree = _fork.filesystem_colors._tree
	var row := _find_file(actual_tree.get_root(), "res://tracked.gd")
	check("main FileSystem shows M suffix on the real file", row != null and row.get_suffix(0).strip_edges() == "M")
	check("FileSystem filename stays unchanged", row != null and row.get_text(0) == "tracked.gd")
	check("external deletion blocks save", not Autosave.can_save("a", "", "b", false))
	check("external modification blocks save", not Autosave.can_save("a", "external", "local", true))
	check("matching external reload is accepted", Autosave.can_save("a", "external", "external", true))
	await _check_history_diff(repo)
	await _check_editable_diff(repo)

	var script := load("res://tracked.gd") as Script
	EditorInterface.edit_script(script)
	EditorInterface.set_main_screen_editor("Script")
	await get_tree().create_timer(0.3).timeout
	_fork.autosave.discover_tabs()
	var code := EditorInterface.get_script_editor().get_current_editor().get_base_editor() as CodeEdit
	check("script editor opened the actual script", code != null and code.text.contains("number := 3"))
	if code == null:
		_finish()
		return
	await _check_change_preview()
	await _check_layered_highlights()
	await _check_diff_panes()
	screen._mode.select(1)
	screen.open_path("tracked.gd")
	check("unstaged mode compares index against working file", screen.diff_view._diff_text.contains("-var number := 2") and screen.diff_view._diff_text.contains("+var number := 3"))
	await screen._on_hunk_action("stage", screen.diff_view._diff_text)
	check("central diff stages the selected patch", repo.get_file_bytes(":", "tracked.gd").get_string_from_utf8().contains("number := 3"))
	screen._mode.select(2)
	screen.refresh()
	check("staged mode compares commit against index", screen.diff_view._diff_text.contains("-var number := 1") and screen.diff_view._diff_text.contains("+var number := 3"))
	await screen._on_hunk_action("unstage", screen.diff_view._diff_text)
	check("central diff unstages the selected patch", repo.get_file_bytes(":", "tracked.gd").get_string_from_utf8().contains("number := 1"))
	# Restore the original fixture's partial staging, without touching the working buffer.
	var restored: Dictionary = repo.apply_patch(restore_patch, true, false)
	if not restored["ok"]:
		print("FIXTURE RESTORE ERROR ", restored)
	check("fixture partial staging restored", restored["ok"])
	code.set_caret_line(code.get_line_count() - 1)
	code.insert_text_at_caret("# saved automatically\n")
	await get_tree().create_timer(0.9).timeout
	check("editing a script saves without pressing Save", FileAccess.get_file_as_string("res://tracked.gd").contains("# saved automatically"))
	check("native saved marker is synchronized", code.get_version() == code.get_saved_version())
	check("auto-save does not stage the script", repo.get_file_bytes(":", "tracked.gd").get_string_from_utf8().contains("number := 2"))
	code.undo()
	await get_tree().create_timer(0.7).timeout
	check("undo remains available and is automatically saved", not FileAccess.get_file_as_string("res://tracked.gd").contains("# saved automatically"))
	code.insert_text_at_caret("# immediate stage\n")
	var commit_panel: Control = _fork.dock_instance._changes_panel
	commit_panel._set_staged(["tracked.gd"], true)
	check("staging flushes the pending editor save", repo.get_file_bytes(":", "tracked.gd").get_string_from_utf8().contains("# immediate stage"))
	code.undo()
	await get_tree().create_timer(0.6).timeout
	repo.unstage_file("tracked.gd")
	restored = repo.apply_patch(restore_patch, true, false)
	if not restored["ok"]:
		print("FIXTURE RESTORE ERROR ", restored)
	check("fixture index restored after staging flush", restored["ok"])

	_fork.autosave.set_enabled(false)
	code.insert_text_at_caret("# keep local draft\n")
	await get_tree().create_timer(0.6).timeout
	check("auto-save toggle pauses writes", not FileAccess.get_file_as_string("res://tracked.gd").contains("# keep local draft"))
	var external := FileAccess.open("res://tracked.gd", FileAccess.WRITE)
	external.store_string("extends Node\nvar number := 99\n")
	external.close()
	check("real external file modification blocks native save", not _fork.autosave.flush_pending())
	check("external content survives the blocked save", FileAccess.get_file_as_string("res://tracked.gd").contains("number := 99"))
	check("local buffer survives the blocked save", code.text.contains("# keep local draft"))

	var panel: Control = _fork.dock_instance._changes_panel
	check("commit actions wrap in a narrow dock", panel._commit_button.get_parent() is HFlowContainer)
	check("embedded dock diff is hidden", not panel._diff_view.visible and not panel._diff_toggle.visible)
	_fork._on_tool(0)
	var preferences := ConfigFile.new()
	check("auto-save preference is persisted locally", preferences.load(Settings.CONFIG_PATH) == OK and preferences.get_value("gittydot", "auto_save_scripts", true) == false)
	# Reset editor draft explicitly in the fixture before exercising plugin teardown.
	print("GITTYDOT TEARDOWN preparing external refresh")
	Open.refresh_external_change(repo.get_repo_root(), "tracked.gd")
	print("GITTYDOT TEARDOWN refresh returned")
	await get_tree().create_timer(0.2).timeout
	print("GITTYDOT TEARDOWN disabling plugin")
	EditorInterface.set_plugin_enabled("res://addons/gittydot/plugin.cfg", false)
	check("plugin disables and removes autosave hooks", Autosave.instance == null and not EditorInterface.is_plugin_enabled("res://addons/gittydot/plugin.cfg"))
	EditorInterface.set_plugin_enabled("res://addons/gittydot/plugin.cfg", true)
	check("plugin can be enabled again", Autosave.instance != null and EditorInterface.is_plugin_enabled("res://addons/gittydot/plugin.cfg"))
	# A clean editor buffer must not adopt an external disk change as its saving baseline.
	_fork = Autosave.instance.get_parent()
	check("auto-save preference survives plugin reload", not _fork.autosave.enabled)
	_fork.autosave.discover_tabs()
	var later := FileAccess.open("res://tracked.gd", FileAccess.WRITE)
	later.store_string("extends Node\nvar number := 100\n")
	later.close()
	_fork.autosave.discover_tabs()
	code.insert_text_at_caret("# stale editor draft\n")
	check("clean stale editor cannot overwrite an external modification", not _fork.autosave.flush_pending() and FileAccess.get_file_as_string("res://tracked.gd").contains("number := 100"))
	_fork.autosave.set_enabled(false)
	Open.refresh_external_change(repo.get_repo_root(), "tracked.gd")
	# Exercise commit and amend through the relocated UI controls in this disposable repo.
	Cli.run(repo.get_repo_root(), ["config", "user.name", "GittyDot Tests"])
	Cli.run(repo.get_repo_root(), ["config", "user.email", "gittydot-tests@localhost"])
	panel = _fork.dock_instance._changes_panel
	panel._set_staged(["tracked.gd"], true)
	panel._commit_message.text = "Integration commit from GittyDot"
	await panel._do_commit(false)
	check("commit panel creates the intended commit", String(repo.get_head_info().get("message", "")).strip_edges() == "Integration commit from GittyDot")
	var before_amend: String = Cli.run(repo.get_repo_root(), ["rev-list", "--count", "HEAD"])["text"].strip_edges()
	panel._amend_check.button_pressed = true
	panel._commit_message.text = "Amended integration commit"
	await panel._do_commit(false)
	check("amend changes the latest commit message", String(repo.get_head_info().get("message", "")).strip_edges() == "Amended integration commit")
	check("amend preserves the number of commits", Cli.run(repo.get_repo_root(), ["rev-list", "--count", "HEAD"])["text"].strip_edges() == before_amend)
	await _check_selected_amend(repo)
	var previous_plugin := _fork.get_instance_id()
	RepoSetup.reload_plugin()
	await get_tree().create_timer(0.2).timeout
	check("repository setup reloads GittyDot without enabling Godit", Autosave.instance != null and Autosave.instance.get_parent().get_instance_id() != previous_plugin and EditorInterface.is_plugin_enabled(RepoSetup.PLUGIN_PATH) and not EditorInterface.is_plugin_enabled("res://addons/godit/plugin.cfg"))
	_finish()


func _check_selected_amend(repo: RefCounted) -> void:
	var versions := {"git version 2.44.9": false, "git version 2.45.0": true, "git version 2.45.0.windows.1": true, "git version 2.45.0-rc1": false, "git version 2.45.0.rc1": false, "git version 2.53.0.windows.3": true, "git version 3.0.0": true, "unknown": false}
	for version in versions:
		check("selected amend version check: " + version, Repo.selected_amend_version_supported(version) == versions[version])
	var ephemeral := CodeEdit.new()
	_fork.diff_gutter._pending_edits[ephemeral] = "res://tracked.gd"
	ephemeral.free()
	_fork.diff_gutter._refresh_pending()
	check("closed editor buffers are safely removed from pending gutter refreshes", _fork.diff_gutter._pending_edits.is_empty())
	var panel: Control = _fork.dock_instance._changes_panel
	var history: Control = _fork.history_dock_instance._history_panel
	var head: String = repo.get_head_oid()
	var target: String = Cli.run(repo.get_repo_root(), ["rev-parse", "HEAD~1"])["text"].strip_edges()
	history.refresh()
	history._on_commit_graph_commit_context_requested(target, Vector2.ZERO)
	var amend_index: int = history._context_menu.get_item_index(history.ID_AMEND)
	check("Log offers Amend alongside Reword, Fixup, Squash and Drop", amend_index >= 0 and history._context_menu.get_item_index(history.ID_REWORD) >= 0 and history._context_menu.get_item_index(history.ID_FIXUP) >= 0 and history._context_menu.get_item_index(history.ID_SQUASH) >= 0 and history._context_menu.get_item_index(history.ID_DROP) >= 0)
	history._context_menu.hide()
	panel._commit_message.text = "regular draft"
	history._on_context_menu_id_pressed(history.ID_AMEND)
	check("Log amend action prepares the exact target in Commit without rewriting history", panel._amend_check.button_pressed and panel._amend_target == target and repo.get_head_oid() == head)
	panel._amend_menu.get_popup().about_to_popup.emit()
	check("dropdown beside Amend offers latest and recent branch commits", panel._amend_menu.get_popup().item_count >= 4 and panel._amend_menu.get_popup().get_item_text(0) == "Latest commit")
	panel._repo = OldGitRepo.new()
	panel._repo.open(repo.get_repo_root())
	panel._commit_message.text = "preserve failed draft"
	var index_before: String = Cli.run(repo.get_repo_root(), ["write-tree"])["text"].strip_edges()
	await panel._do_commit(false)
	check("old Git fails before rewriting HEAD or changing staging", repo.get_head_oid() == head and Cli.run(repo.get_repo_root(), ["write-tree"])["text"].strip_edges() == index_before)
	check("version error preserves target and draft and unlocks controls", panel._amend_target == target and panel._commit_message.text == "preserve failed draft" and not panel._commit_busy and panel._commit_message.editable and not panel._amend_menu.disabled)
	check("version error reports detected and required Git versions", panel._error_dialog.dialog_text.contains("2.45.0") and panel._error_dialog.dialog_text.contains("2.44.0"))
	var error_id: int = panel._error_dialog.get_meta("console_entry_id", -1)
	Cli.record(["status"], 0, "a later command")
	panel._error_dialog.custom_action.emit(Dialogs.CONSOLE_ACTION)
	await get_tree().process_frame
	var console: Control = _fork.history_dock_instance._console
	check("Show details selects the Console tab and the specific diagnostic entry", _fork.history_dock_instance._tabs.current_tab == console.get_index() and console._entry_paragraphs.has(error_id) and console._output.get_parsed_text().contains("Detected: git version 2.44.0") and not panel._error_dialog.visible)
	panel._amend_check.button_pressed = false
	check("leaving Amend restores the regular commit draft", panel._commit_message.text == "regular draft" and panel._amend_target.is_empty())
	panel._commit_message.text = ""
	panel._repo = repo
	var temp_root: String = repo.get_repo_root().path_join(repo.get_repo_root().get_file() + "-temp-chatgpt")
	var amendment := Repo.new()
	amendment.open(temp_root.path_join("amend"))
	var rroot: String = amendment.get_repo_root()
	var old_target: String = Cli.run(rroot, ["rev-parse", "HEAD~1"])["text"].strip_edges()
	var before: String = amendment.get_head_oid()
	if not Repo.selected_amend_version_supported(amendment.git_version_text()):
		var blocked: Dictionary = amendment.amend_commit(old_target, "blocked amendment")
		check("actual older Git returns the compatibility error without changing history", not blocked["ok"] and blocked["error"].contains("2.45.0") and amendment.get_head_oid() == before and amendment.has_staged_changes())
		return
	panel._repo = amendment
	panel.prepare_amend(old_target)
	panel._commit_message.text = "Specific amended message"
	panel._do_commit.call_deferred(false)
	await get_tree().process_frame
	await get_tree().process_frame
	var confirm: ConfirmationDialog = null
	for dialog: ConfirmationDialog in panel.find_children("*", "ConfirmationDialog", true, false):
		if dialog.title == "Amend Selected Commit":
			confirm = dialog
	check("selected amendment asks before replay and disables duplicate submission", confirm != null and amendment.get_head_oid() == before and panel._commit_busy and panel._commit_button.disabled)
	if confirm == null:
		panel._repo = repo
		return
	confirm.canceled.emit()
	await get_tree().process_frame
	check("cancelling selected amendment preserves target, message and staged changes", amendment.get_head_oid() == before and amendment.has_staged_changes() and panel._amend_target == old_target and panel._commit_message.text == "Specific amended message" and not panel._commit_busy and panel._commit_message.editable)
	panel._do_commit.call_deferred(false)
	await get_tree().process_frame
	await get_tree().process_frame
	confirm = null
	for dialog: ConfirmationDialog in panel.find_children("*", "ConfirmationDialog", true, false):
		if dialog.title == "Amend Selected Commit":
			confirm = dialog
	check("cancelled amendment can be retried without rebuilding the draft", confirm != null and panel._commit_busy)
	if confirm == null:
		panel._repo = repo
		return
	confirm.confirmed.emit()
	await get_tree().process_frame
	check("Commit dock submits selected amendment and clears target after success", not panel._commit_busy and not panel._amend_check.button_pressed and panel._amend_target.is_empty() and panel._commit_message.text.is_empty() and amendment.get_head_oid() != before)
	panel._repo = repo
	panel.refresh()
	check("selected amendment preserves commit count and newer commit content", Cli.run(rroot, ["rev-list", "--count", "HEAD"])["text"].strip_edges() == "3" and amendment.get_file_bytes("HEAD", "later.txt").get_string_from_utf8() == "preserve later commit\n")
	check("full hash amends the intended commit despite duplicate subjects", Cli.run(rroot, ["log", "-1", "--format=%B", "HEAD~1"])["text"].strip_edges() == "Specific amended message" and Cli.run(rroot, ["log", "-1", "--format=%s", "HEAD~2"])["text"].strip_edges() == "Duplicate subject")
	check("selected amendment preserves original author", Cli.run(rroot, ["log", "-1", "--format=%an", "HEAD~1"])["text"].strip_edges() == "Original Author")
	check("only staged content is amended while unstaged and untracked drafts survive", amendment.get_file_bytes("HEAD~1", "target.txt").get_string_from_utf8() == "amended\n" and FileAccess.get_file_as_string(rroot.path_join("target.txt")) == "amended\nunstaged draft\n" and FileAccess.get_file_as_string(rroot.path_join("untracked.txt")) == "keep me\n" and not amendment.has_staged_changes())
	var root_oid: String = Cli.run(rroot, ["rev-parse", "HEAD~2"])["text"].strip_edges()
	var result: Dictionary = amendment.amend_commit(root_oid, "Root message amended")
	check("root commit supports message-only amendment with newer commits replayed", result["ok"] and Cli.run(rroot, ["log", "-1", "--format=%B", "HEAD~2"])["text"].strip_edges() == "Root message amended" and Cli.run(rroot, ["rev-list", "--count", "HEAD"])["text"].strip_edges() == "3")
	check("message-only amendment retains unstaged working content", FileAccess.get_file_as_string(rroot.path_join("target.txt")) == "amended\nunstaged draft\n")
	for case in ["amend_hook", "amend_merge", "amend_conflict", "amend_continue"]:
		var isolated := Repo.new()
		isolated.open(temp_root.path_join(case))
		var path: String = isolated.get_repo_root()
		var original: String = isolated.get_head_oid()
		var chosen: String = Cli.run(path, ["rev-parse", "HEAD~1"])["text"].strip_edges()
		if case == "amend_merge":
			chosen = Cli.run(path, ["rev-parse", "HEAD~2"])["text"].strip_edges()
		var index: String = Cli.run(path, ["write-tree"])["text"].strip_edges()
		result = isolated.amend_commit(chosen, "Amend case message")
		if case == "amend_hook":
			check("selected amendment honors a rejecting commit hook and preserves staging", not result["ok"] and result["error"].contains("blocked by test hook") and isolated.get_head_oid() == original and Cli.run(path, ["write-tree"])["text"].strip_edges() == index)
		elif case == "amend_merge":
			check("amend across merges fails without flattening or changing history", not result["ok"] and result["error"].contains("merge commit") and isolated.get_head_oid() == original and Cli.run(path, ["write-tree"])["text"].strip_edges() == index)
		else:
			check(case + " stops on real rebase conflicts with recovery information", not result["ok"] and result.get("conflicts", false) and isolated.get_operation_state()["kind"] == "rebase" and FileAccess.file_exists(isolated._amend_recovery_path()))
			if case == "amend_conflict":
				# Recovery survives creating a new repo object, as on editor reload.
				isolated = Repo.new()
				isolated.open(path)
				result = isolated.abort_operation()
				check("Abort removes the amendment helper and restores original history and staging", result["ok"] and isolated.get_head_oid() == original and Cli.run(path, ["write-tree"])["text"].strip_edges() == index and FileAccess.get_file_as_string(path.path_join("target.txt")) == "amended\n" and not FileAccess.file_exists(isolated._amend_recovery_path()))
			else:
				for step in 4:
					if isolated.get_operation_state()["kind"].is_empty():
						break
					var file := FileAccess.open(path.path_join("target.txt"), FileAccess.WRITE)
					file.store_string("amended\n")
					file.close()
					isolated.mark_resolved("target.txt")
					result = isolated.continue_operation()
				check("Continue completes selected amendment and clears recovery metadata", result["ok"] and isolated.get_operation_state()["kind"].is_empty() and not FileAccess.file_exists(isolated._amend_recovery_path()) and Cli.run(path, ["rev-list", "--count", "HEAD"])["text"].strip_edges() == "3")


func _check_narrow_commit(repo: RefCounted) -> void:
	var shell := PanelContainer.new()
	shell.position = Vector2(8, 8)
	shell.z_index = 100
	var background := StyleBoxFlat.new()
	background.bg_color = Color(0.14, 0.14, 0.16)
	shell.add_theme_stylebox_override("panel", background)
	EditorInterface.get_base_control().add_child(shell)
	var panel := ChangesScene.instantiate()
	shell.add_child(panel)
	panel.set_repo(repo)
	panel._changelist_option.set_item_text(0, "Changelist: a very long name that must truncate at the end")
	panel._sync_bar._branch_button.text = "⎇ feature/a-very-long-branch-name"
	panel._sync_bar._branch_button.set_meta("full_text", panel._sync_bar._branch_button.text)
	for width in [320, 260, 220, 200]:
		shell.size = Vector2(width * EditorInterface.get_editor_scale(), 720)
		for frame in 5:
			await get_tree().process_frame
		var tree: Tree = panel._tree
		check("Commit dock fits %d logical pixels without losing its left edge or checkbox column" % width, tree.global_position.x >= shell.global_position.x and tree.get_global_rect().end.x <= shell.get_global_rect().end.x + 1 and panel.get_node("Layout").global_position.x >= shell.global_position.x and panel.get_node("Layout").size.x <= shell.size.x + 1)
		if OS.get_cmdline_user_args().has("--gittydot-visual"):
			RenderingServer.force_draw(false)
			var image := shell.get_viewport().get_texture().get_image().get_region(Rect2i(Vector2i(shell.global_position), Vector2i(shell.size)))
			image.save_png("res://commit-%d.png" % width)
	shell.queue_free()
	await get_tree().process_frame


func _check_editable_diff(repo: RefCounted) -> void:
	var screen: Control = _fork.main_screen
	EditorInterface.set_main_screen_editor("GittyDot")
	Settings.set_value("diff_side_by_side", true)
	screen._mode.select(0)
	screen.open_path("editable.txt")
	var view: Control = screen.diff_view._working_view
	var right: CodeEdit = view._codes[1]
	for frame in 6:
		await get_tree().process_frame
	check("working-file comparisons expose an editable right pane and read-only baseline", view.visible and right.editable and not view._codes[0].editable and not screen.diff_view._split.visible)
	check("editable pane contains the full source without collapsed context or diff signs", right.text == FileAccess.get_file_as_string("res://editable.txt") and right.get_line_count() == 103 and not right.text.contains("unchanged lines"))
	check("editable comparison retains syntax, line numbers and highlighted modifications", right.gutters_draw_line_numbers and right.syntax_highlighter != null and view._highlights[1].rows.has(2) and view._highlights[1].rows.has(41))
	check("editable comparison disables collapsed-context and hunk filtering options", screen.diff_view._options_button.get_popup().is_item_disabled(screen.diff_view._options_button.get_popup().get_item_index(DiffView.OPT_CONTEXT_3)))
	# The native headless main screen can be narrower than both minimum panes.
	var shell := PanelContainer.new()
	shell.position = Vector2(16, 12)
	shell.z_index = 100
	var background := StyleBoxFlat.new()
	background.bg_color = Color(0.14, 0.14, 0.16)
	shell.add_theme_stylebox_override("panel", background)
	shell.size = Vector2(1000, 380)
	EditorInterface.get_base_control().add_child(shell)
	var scrolling := WorkingDiff.new()
	shell.add_child(scrolling)
	scrolling.show_file(screen.diff_view._context)
	for frame in 6:
		await get_tree().process_frame
	check("editable text panes use separate horizontal and vertical overflow scrollbars", scrolling._panes.all(func(pane: ScrollContainer) -> bool: return pane.get_h_scroll_bar().visible and pane.get_v_scroll_bar().visible))
	scrolling._panes[1].scroll_horizontal = 80
	check("editable comparison horizontal scrolling is synchronized", scrolling._panes[0].scroll_horizontal == 80)
	scrolling._panes[1].scroll_vertical = int(scrolling._codes[1].get_line_height() * 60)
	check("editable comparison vertical scrolling follows matching source lines across insertions", absf(float(scrolling._panes[0].scroll_vertical) / scrolling._codes[1].get_line_height() - scrolling.map_line(60, 1)) < 0.2)
	var width: float = scrolling._panes[0].size.x
	scrolling._split.split_offset = 90
	for frame in 4:
		await get_tree().process_frame
	check("editable panes retain an adjustable divider", absf(scrolling._panes[0].size.x - width) > 30)
	var left_end: float = scrolling._panes[0].get_h_scroll_bar().max_value - scrolling._panes[0].get_h_scroll_bar().page
	var right_end: float = scrolling._panes[1].get_h_scroll_bar().max_value - scrolling._panes[1].get_h_scroll_bar().page
	check("editable panes retain a common horizontal end range after resize", absf(left_end - right_end) <= 1.0)
	var source_before: String = scrolling._codes[1].text
	var caret_before: int = scrolling._codes[1].get_caret_line()
	# Put a deletion at EOF and a replacement near the end of the baseline.
	scrolling._codes[0].text = scrolling._codes[0].text.replace("line 90: original", "line 90: previous") + "deleted final line\n"
	scrolling._update_diff()
	check("working diff uses committed addition and deletion palette without changing native script colors", scrolling._highlights[0].workspace_side == 0 and scrolling._highlights[1].workspace_side == 1 and DiffView.DiffRows.COLOR_ADDED_BG == preload("res://addons/gittydot/util/diff_palette.gd").ADDED_BG)
	check("overview includes start middle end and deletion-only changes", scrolling._regions.size() >= 4 and scrolling._regions.any(func(region: Dictionary) -> bool: return region["new_count"] == 0))
	var overview: Rect2 = scrolling._overview_rect(1)
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = Vector2(overview.get_center().x, overview.end.y - 2)
	scrolling._navigation[1]._gui_input(click)
	check("clicking overview reveals end changes without moving caret or editing source", scrolling._panes[1].scroll_vertical > scrolling._codes[1].get_line_height() * 70 and scrolling._codes[1].text == source_before and scrolling._codes[1].get_caret_line() == caret_before)
	click.position.y = 1
	scrolling._navigation_input(click, 1)
	check("clicking overview returns to beginning changes", scrolling._panes[1].scroll_vertical == 0)
	scrolling._panes[1].scroll_horizontal = 150
	check("overview stays anchored to the visible pane during horizontal overflow", scrolling._overview_rect(1) == overview)
	check("navigation overlays accept strip clicks while leaving source editing unobstructed", scrolling._navigation[1]._has_point(overview.get_center()) and not scrolling._navigation[1]._has_point(scrolling._navigation[1].size * 0.5))
	var automatic: bool = Settings.get_value("auto_save_scripts", true)
	Settings.set_value("auto_save_scripts", false)
	var draft: CodeEdit = scrolling._codes[1]
	draft.set_caret_line(60)
	draft.insert_text_at_caret("an inserted navigation test line\n")
	await get_tree().process_frame
	check("editing immediately invalidates stale overview ranges", scrolling._regions.is_empty())
	await get_tree().create_timer(0.45).timeout
	check("overview recomputes after successive edits without saving when auto-save is off", not scrolling._regions.is_empty() and scrolling.is_dirty() and FileAccess.get_file_as_string("res://editable.txt") == source_before)
	draft.undo()
	await get_tree().process_frame
	scrolling._timer.stop()
	scrolling._update_diff()
	check("Undo restores source and rebuilds navigation without a write", draft.text == source_before and not scrolling.is_dirty() and not scrolling._regions.is_empty())
	Settings.set_value("auto_save_scripts", automatic)
	if OS.get_cmdline_user_args().has("--gittydot-visual"):
		scrolling._panes[1].scroll_horizontal = 0
		scrolling._panes[1].scroll_vertical = scrolling._codes[1].get_line_height() * 37
		for frame in 4:
			await get_tree().process_frame
		RenderingServer.force_draw(false)
		var capture := shell.get_viewport().get_texture().get_image().get_region(Rect2i(Vector2i(shell.global_position), Vector2i(shell.size)))
		check("graphical editor captures the editable working-file panes", capture != null and not capture.is_empty() and capture.save_png("res://editable-working-diff.png") == OK)
		var viewport_image := shell.get_viewport().get_texture().get_image()
		var colored := true
		for side in 2:
			var rect: Rect2 = scrolling._overview_rect(side)
			var total: int = scrolling._codes[side].get_line_count()
			var region: Dictionary = scrolling._regions[1]
			var span: Vector2i = scrolling._range(region, side)
			var point: Vector2i = Vector2i(scrolling._panes[side].global_position + Vector2(rect.position.x + 5, floorf(float(span.x) / total * rect.size.y) + 1))
			var expected := preload("res://addons/gittydot/util/diff_palette.gd").REMOVED_TEXT if side == 0 or span.y == 0 else preload("res://addons/gittydot/util/diff_palette.gd").ADDED_TEXT
			var pixel := viewport_image.get_pixelv(point)
			colored = colored and absf(pixel.r - expected.r) < 0.02 and absf(pixel.g - expected.g) < 0.02 and absf(pixel.b - expected.b) < 0.02
		check("overview renders shared diff colors in both visible viewport strips", colored)
		scrolling._panes[1].scroll_vertical = 0
		for frame in 4:
			await get_tree().process_frame
		RenderingServer.force_draw(false)
		viewport_image = shell.get_viewport().get_texture().get_image()
		var blocks_match := true
		var spans_match := true
		for side in 2:
			var code: CodeEdit = scrolling._codes[side]
			var palette := preload("res://addons/gittydot/util/diff_palette.gd")
			var base: Color = code.get_theme_stylebox("normal" if code.editable else "read_only").bg_color
			var expected_bg: Color = base.blend(palette.REMOVED_BG if side == 0 else palette.ADDED_BG)
			var y: float = code.global_position.y + code.get_rect_at_line_column(2, 0).position.y
			var point := Vector2i(scrolling._panes[side].global_position.x + scrolling._panes[side].size.x - 70, y + 2)
			var pixel := viewport_image.get_pixelv(point)
			blocks_match = blocks_match and _near_color(pixel, expected_bg)
			var expected_hl: Color = expected_bg.blend(palette.REMOVED_HL if side == 0 else palette.ADDED_HL)
			var found_span := false
			for block: Dictionary in scrolling._highlights[side].geometry.get(2, []):
				var rect: Rect2 = block["rect"]
				for x in range(int(rect.position.x), int(rect.end.x)):
					var sample := Vector2i(code.global_position + Vector2(x, rect.position.y + 1))
					if _near_color(viewport_image.get_pixelv(sample), expected_hl):
						found_span = true
			spans_match = spans_match and found_span
		check("editable replacement backgrounds render the shared committed-diff palette", blocks_match)
		check("editable replacement spans render the shared committed-diff palette", spans_match)
		viewport_image.get_region(Rect2i(Vector2i(shell.global_position), Vector2i(shell.size))).save_png("res://editable-working-replacement.png")
	shell.queue_free()
	await get_tree().process_frame
	var original := right.text
	if OS.get_cmdline_user_args().has("--gittydot-ui-only"):
		return # Layout/navigation loop; saving, native scenes and scripts use the full suite.
	var staged: PackedByteArray = repo.get_file_bytes(":", "editable.txt")
	right.set_caret_line(2)
	right.set_caret_column(right.get_line(2).length())
	right.insert_text_at_caret(" edited in diff")
	await get_tree().create_timer(0.6).timeout
	check("typing in the right pane automatically saves the working file", FileAccess.get_file_as_string("res://editable.txt").contains("edited in diff") and not view.is_dirty())
	check("saving the editable comparison preserves partial staging", repo.get_file_bytes(":", "editable.txt") == staged and not staged.get_string_from_utf8().contains("edited in diff"))
	check("refresh after editable save preserves caret and Undo", right.get_caret_line() == 2 and right.has_undo() and right.get_version() == right.get_saved_version())
	right.undo()
	await get_tree().create_timer(0.6).timeout
	check("Undo in the editable pane saves the original working text", right.text == original and FileAccess.get_file_as_string("res://editable.txt") == original)
	# Staging must flush a keystroke without waiting for debounce.
	right.insert_text_at_caret(" immediate stage")
	_fork.dock_instance._changes_panel._set_staged(["editable.txt"], true)
	check("staging immediately flushes the comparison buffer", repo.get_file_bytes(":", "editable.txt").get_string_from_utf8().contains("immediate stage") and not view.is_dirty())
	right.undo()
	view.flush()
	repo.unstage_file("editable.txt")
	screen._mode.select(2)
	screen._mode.item_selected.emit(2)
	check("index comparisons stay read-only", not view.visible and not right.editable and not screen.diff_view._context.get("editable_worktree", true))
	screen._mode.select(0)
	screen._mode.item_selected.emit(0)
	screen.diff_view.set_side_by_side(false)
	check("Unified remains a read-only inspection view", not view.visible and screen.diff_view._scroll.visible and not right.editable)
	screen.diff_view.set_side_by_side(true)
	check("returning to side by side restores editability", view.visible and right.editable)
	right.set_caret_line(2)
	right.insert_text_at_caret("pending switch ")
	screen.open_path("editable_crlf.txt")
	check("switching files flushes pending edits before changing the comparison", FileAccess.get_file_as_string("res://editable.txt").contains("pending switch") and screen.path == "editable_crlf.txt")
	for frame in 6:
		await get_tree().process_frame
	check("short editable files hide unnecessary scrollbars", view._panes.all(func(pane: ScrollContainer) -> bool: return not pane.get_h_scroll_bar().visible and not pane.get_v_scroll_bar().visible))
	right.set_caret_line(0)
	right.set_caret_column(6)
	right.insert_text_at_caret(" changed")
	var key := InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_S
	key.ctrl_pressed = true
	view._on_input(key)
	check("Ctrl+S saves immediately and preserves UTF-8 BOM, CRLF and missing final newline", FileAccess.get_file_as_bytes("res://editable_crlf.txt") == PackedByteArray([239, 187, 191]) + "before changed\r\nlast".to_utf8_buffer())
	var prior := FileAccess.get_file_as_bytes("res://editable_crlf.txt")
	right.insert_text_at_caret(" local draft")
	var file := FileAccess.open("res://editable_crlf.txt", FileAccess.WRITE)
	file.store_string("external change\n")
	file.close()
	check("external disk changes block comparison saves without losing either draft", not view.flush() and FileAccess.get_file_as_string("res://editable_crlf.txt") == "external change\n" and right.text.contains("local draft"))
	screen.open_path("new_file.gd")
	check("a blocked comparison save prevents navigating away from its draft", screen.path == "editable_crlf.txt" and view.is_dirty())
	for dialog: AcceptDialog in screen.diff_view.find_children("*", "AcceptDialog", true, false):
		if dialog.title == "Comparison save paused":
			dialog.confirmed.emit()
	# Restore the known baseline explicitly; the editor must then be savable.
	file = FileAccess.open("res://editable_crlf.txt", FileAccess.WRITE)
	file.store_buffer(prior)
	file.close()
	check("restoring the expected disk baseline allows saving the kept draft", view.flush() and FileAccess.get_file_as_string("res://editable_crlf.txt").contains("local draft"))
	right.insert_text_at_caret(" after deletion")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("res://editable_crlf.txt"))
	check("external deletion blocks autosave rather than recreating a deleted file", not view.flush() and not FileAccess.file_exists("res://editable_crlf.txt") and right.text.contains("after deletion"))
	var recovery: String = view._recovery_path()
	check("blocked comparison draft is retained in project-local recovery storage", FileAccess.file_exists(recovery))
	file = FileAccess.open("res://editable_crlf.txt", FileAccess.WRITE)
	file.store_buffer(view._baseline)
	file.close()
	var recovery_shell := PanelContainer.new()
	EditorInterface.get_base_control().add_child(recovery_shell)
	var recovered := WorkingDiff.new()
	recovery_shell.add_child(recovered)
	recovered.show_file(screen.diff_view._context)
	check("unsaved comparison drafts recover into a new editor session without automatic overwrite", recovered.is_dirty() and recovered._codes[1].text == right.text and FileAccess.get_file_as_bytes("res://editable_crlf.txt") == view._baseline)
	recovered.flush()
	recovery_shell.queue_free()
	await get_tree().process_frame
	view.flush()
	check("successful recovery save removes the stored draft", not FileAccess.file_exists(recovery))
	# Prepare the native scene fixture outside the custom main screen's draw pass.
	EditorInterface.set_main_screen_editor("2D")
	await get_tree().process_frame
	while EditorInterface.get_resource_filesystem().is_scanning():
		await get_tree().process_frame
	# Native scene loading runs an editor progress loop. Enter it from idle,
	# not inside process_frame/import notifications dispatched by that same loop.
	EditorInterface.open_scene_from_path.call_deferred("res://editable_scene.tscn")
	for frame in 4:
		await get_tree().process_frame
	screen.open_path("editable_scene.tscn")
	right.set_caret_line(right.get_line_count() - 1)
	right.insert_text_at_caret("metadata/test_value = 2\n")
	check("scene text is editable while the structured Scene view is disabled", view.visible and right.editable and screen.diff_view._scene_toggle.disabled)
	view.flush()
	check("editing scene text writes the raw working file", FileAccess.get_file_as_string("res://editable_scene.tscn").contains("metadata/test_value = 2"))
	screen._open_native()
	await get_tree().process_frame
	check("Open in Editor reloads a clean cached scene after comparison edits", EditorInterface.get_edited_scene_root().get_meta("test_value", null) == 2)
	screen.open_comparison({"kind": "commit", "path": "editable_scene.tscn", "oid": repo.get_head_oid(), "old_rev": repo.parent_or_empty_tree(repo.get_head_oid()), "new_rev": repo.get_head_oid()})
	check("viewing scene history does not expose a writable working pane", not view.visible and not right.editable)
	screen.open_path("editable_binary.bin")
	check("binary files remain read-only", not view.visible and not right.editable and screen.diff_view._empty_label.visible)
	check("unsupported UTF-8, surrogate sequences and binary controls are rejected", not WorkingDiff.is_text(PackedByteArray([192, 175])) and not WorkingDiff.is_text(PackedByteArray([237, 160, 128])) and not WorkingDiff.is_text(PackedByteArray([0, 1])) and WorkingDiff.is_text("Unicode café\n".to_utf8_buffer()))
	# Keep native script drafts and comparison drafts separate when both are dirty.
	var autosave_before: bool = _fork.autosave.enabled
	_fork.autosave.set_enabled(false)
	EditorInterface.edit_script(load("res://tracked.gd"))
	await get_tree().create_timer(0.1).timeout
	var native: CodeEdit = EditorInterface.get_script_editor().get_current_editor().get_base_editor()
	screen.open_path("tracked.gd")
	var disk_before := FileAccess.get_file_as_string("res://tracked.gd")
	native.insert_text_at_caret("# native draft\n")
	right.insert_text_at_caret("# comparison draft\n")
	check("simultaneous native and comparison drafts block saving without overwriting either", not view.flush() and native.text.contains("native draft") and right.text.contains("comparison draft") and FileAccess.get_file_as_string("res://tracked.gd") == disk_before)
	screen._open_native()
	check("Open in Editor preserves competing native and comparison drafts", native.text.contains("native draft") and right.text.contains("comparison draft") and FileAccess.get_file_as_string("res://tracked.gd") == disk_before)
	for dialog: AcceptDialog in screen.diff_view.find_children("*", "AcceptDialog", true, false):
		if dialog.title == "Comparison save paused":
			dialog.confirmed.emit()
	check("Git operations are blocked while a comparison draft cannot be saved", not SaveGuard.flush_scripts() and SaveGuard.unsaved_files().has("res://tracked.gd"))
	native.undo()
	right.undo()
	view.flush()
	_fork.autosave.set_enabled(autosave_before)
	check("undoing the conflicting draft clears its recovery record", not view.is_dirty() and not FileAccess.file_exists(view._recovery_path()))
	right.insert_text_at_caret("# saved from comparison\n")
	view.flush()
	check("comparison save synchronizes a clean native script tab and its saved marker", native.text == right.text and native.get_version() == native.get_saved_version())
	check("comparison save synchronizes the native script resource source", String(EditorInterface.get_script_editor().get_current_script().source_code).replace("\r\n", "\n") == right.text)
	right.undo()
	view.flush()
	check("comparison Undo also updates the clean native script tab", native.text == right.text and not native.text.contains("saved from comparison"))
	Settings.set_value("auto_save_scripts", false)
	WorkingDiff.apply_auto_save_policy()
	var before_manual := FileAccess.get_file_as_string("res://tracked.gd")
	right.insert_text_at_caret("# manual comparison save\n")
	await get_tree().create_timer(0.6).timeout
	check("the auto-save preference also pauses comparison writes", view.is_dirty() and FileAccess.get_file_as_string("res://tracked.gd") == before_manual and view._status.text.contains("Unsaved"))
	view._on_input(key)
	check("manual Save remains available with auto-save disabled", not view.is_dirty() and FileAccess.get_file_as_string("res://tracked.gd").contains("manual comparison save"))
	right.undo()
	view.flush()
	# Explicit opening must flush edits even while automatic saving is disabled.
	for script_path in ["tracked.gd", "new_file.gd", "created_after_import.gd"]:
		if script_path == "created_after_import.gd":
			var fresh := FileAccess.open("res://" + script_path, FileAccess.WRITE)
			fresh.store_string("extends Node\nvar just_created := true\n")
			fresh.close()
		screen.open_path(script_path)
		check("Open in Editor enables a project script: " + script_path, not screen._open_button.disabled)
		right.set_caret_line(0)
		right.set_caret_column(0)
		right.insert_text_at_caret("# pending open\n")
		screen._open_native()
		await get_tree().process_frame
		var opened: CodeEdit = EditorInterface.get_script_editor().get_current_editor().get_base_editor()
		check("Open in Editor flushes manual comparison edits and opens updated source: " + script_path, not view.is_dirty() and opened.text == right.text and opened.text.contains("pending open") and Open.current_tab_path() == "res://" + script_path)
		right.undo()
		view.flush()
	check("missing files explain why Open in Editor is unavailable", not Open.unavailable_reason(repo.get_repo_root(), "deleted.txt").is_empty())
	check("out-of-project files cannot be opened", not Open.unavailable_reason(repo.get_repo_root(), "../outside.gd").is_empty())
	Settings.set_value("auto_save_scripts", true)
	WorkingDiff.apply_auto_save_policy()


func _near_color(actual: Color, expected: Color) -> bool:
	return absf(actual.r - expected.r) < 0.02 and absf(actual.g - expected.g) < 0.02 and absf(actual.b - expected.b) < 0.02


func _check_history_diff(repo: RefCounted) -> void:
	var history: Control = _fork.history_dock_instance._history_panel
	var screen: Control = _fork.main_screen
	var oid: String = repo.read_head_oid()
	history.show_commit(oid)
	var file := _find_history_file(history._files_tree.get_root(), "historical.gd")
	check("selected commit lists its historical file", file != null)
	if file == null:
		return
	screen.open_path("tracked.gd")
	file.select(0)
	await get_tree().process_frame
	check("single-click in Git Log leaves the central file unchanged", screen.path == "tracked.gd")
	check("Git Log does not show a diff under the graph", history._file_diff_box == null or not history._file_diff_box.visible)
	history._files_tree.item_activated.emit()
	check("double-click in Git Log opens the selected commit diff centrally", screen.path == "historical.gd" and screen.is_visible_in_tree())
	check("historical diff compares parent to selected commit instead of working file", screen.diff_view._diff_text.contains("-var historical := 10") and screen.diff_view._diff_text.contains("+var historical := 20") and not screen.diff_view._diff_text.contains("historical := 99"))
	check("historical diff labels the selected commit", screen._path_label.text.contains(oid.substr(0, 8)) and screen.diff_view._context["new_rev"] == oid)
	check("historical diff exposes no staging or rollback actions", screen.diff_view._context["actions"].is_empty() and not screen._mode.visible)
	check("historical comparisons keep working-file editing disabled", not screen.diff_view._working_view.visible and not screen.diff_view._working_view._codes[1].editable)
	await screen._on_hunk_action("stage", screen.diff_view._diff_text)
	check("historical diff cannot change partial staging", repo.get_file_bytes(":", "tracked.gd").get_string_from_utf8().contains("number := 2"))
	screen._on_polled({})
	check("background polling preserves the historical comparison", screen.diff_view._context["new_rev"] == oid and screen.diff_view._diff_text.contains("+var historical := 20"))
	file = _find_history_file(history._files_tree.get_root(), "deleted.txt")
	file.select(0)
	history._files_tree.item_activated.emit()
	check("deleted historical files open as diffs without needing a working copy", screen.path == "deleted.txt" and screen.diff_view._diff_text.contains("-Only available in history") and screen._open_button.disabled)
	var root: String = Cli.run(repo.get_repo_root(), ["rev-list", "--max-parents=0", "HEAD"])["text"].strip_edges()
	history.show_commit(root)
	file = _find_history_file(history._files_tree.get_root(), "tracked.gd")
	file.select(0)
	history._files_tree.item_activated.emit()
	check("initial commit opens a full-file addition in the central diff", screen.diff_view._diff_text.contains("new file mode") and screen.diff_view._diff_text.contains("+var number := 1") and screen.diff_view._context["old_rev"] == repo.empty_tree_oid())
	# Stash-style rows carry their own base/target (including untracked stash commits).
	file.set_metadata(0, {"path": "historical.gd", "base": root, "target": oid})
	history._files_tree.item_activated.emit()
	check("explicit historical revisions retain their base and target", screen.diff_view._context["old_rev"] == root and screen.diff_view._context["new_rev"] == oid and screen.diff_view._diff_text.contains("+var historical := 20"))
	history._graph.select_oid(GutterCommitGraph.WORKTREE_OID)
	file = _find_history_file(history._files_tree.get_root(), "tracked.gd")
	file.select(0)
	history._files_tree.item_activated.emit()
	check("uncommitted log row opens latest-commit versus working-file diff", screen.path == "tracked.gd" and screen._mode.visible and screen._mode.selected == 0 and screen.diff_view._diff_text.contains("+var number := 3"))
	check("historical inspection preserves the working file", FileAccess.get_file_as_string("res://historical.gd").contains("historical := 99"))
	EditorInterface.set_main_screen_editor("Script")


func _find_history_file(item: TreeItem, path: String) -> TreeItem:
	if item == null:
		return null
	var metadata: Variant = item.get_metadata(0)
	if metadata is Dictionary and metadata.get("path", "") == path:
		return item
	var child := item.get_first_child()
	while child != null:
		var found := _find_history_file(child, path)
		if found != null:
			return found
		child = child.get_next()
	return null


func _check_change_preview() -> void:
	# Exercise real Control layout and interactions without touching an authored script.
	var code := CodeEdit.new()
	EditorInterface.get_base_control().add_child(code)
	code.size = Vector2(1400, 500)
	code.text = "extends Node\nvar number := 3\n# an extra line\n"
	code.gutters_draw_line_numbers = true
	code.set_meta(Gutter.META_REL_PATH, "tracked.gd")
	code.set_meta(Gutter.META_RES_PATH, "res://tracked.gd")
	var regions := [{"old_start": 2, "old_count": 1, "new_start": 2, "new_count": 2, "old_lines": PackedStringArray(["var number := 1"])}]
	code.set_meta(Gutter.META_REGIONS, regions)
	var native_background := Color(0.2, 0.3, 0.4, 0.2)
	code.set_line_background_color(1, native_background)
	native_background = code.get_line_background_color(1)
	await get_tree().process_frame
	_fork.diff_gutter.show_preview(code, 0)
	await get_tree().process_frame
	await get_tree().process_frame
	var preview: Control = _fork.diff_gutter._preview
	check("short gutter preview fits its contents instead of filling the editor", preview.visible and preview.size.x < code.size.x * 0.6)
	check("gutter actions sit below the previous code", preview._toolbar.position.y >= preview._old_view.position.y + preview._old_view.size.y)
	check("opening a gutter preview leaves the buffer unchanged", code.text == "extends Node\nvar number := 3\n# an extra line\n")
	preview.close()
	check("closing restores existing editor line backgrounds", code.get_line_background_color(1).is_equal_approx(native_background) and code.get_line_background_color(2).a == 0)
	await get_tree().process_frame
	_fork.diff_gutter.show_preview(code, 0)
	preview = _fork.diff_gutter._preview
	preview._toolbar.get_child(4).pressed.emit()
	check("compact Show Diff action opens the correct file in the central viewer", _fork.main_screen.path == "tracked.gd" and _fork.diff_gutter._preview == null)
	_fork.diff_gutter.show_preview(code, 0)
	preview = _fork.diff_gutter._preview
	preview._toolbar.get_child(2).pressed.emit()
	check("compact rollback restores only the selected change", code.text == "extends Node\nvar number := 1\n")
	code.undo()
	check("compact rollback remains undoable", code.text == "extends Node\nvar number := 3\n# an extra line\n")
	code.set_meta(Gutter.META_REGIONS, regions)
	code.set_line_background_color(1, native_background)
	_fork.diff_gutter.show_preview(code, 0)
	code.set_caret_line(0)
	code.set_caret_column(0)
	code.insert_text_at_caret("# inserted above the preview\n")
	await get_tree().process_frame
	check("editing above a preview closes it without leaving a tint on shifted lines", _fork.diff_gutter._preview == null and code.get_line_background_color(2).is_equal_approx(native_background) and code.get_line_background_color(3).a == 0)
	# Added changes have only the toolbar, with no empty previous-code area.
	code.text = "extends Node\n# added\n"
	code.set_meta(Gutter.META_REGIONS, [{"old_start": 1, "old_count": 0, "new_start": 2, "new_count": 1, "old_lines": PackedStringArray()}])
	_fork.diff_gutter.show_preview(code, 0)
	await get_tree().process_frame
	preview = _fork.diff_gutter._preview
	check("added-line preview is a compact toolbar", preview._old_view == null and preview.size.y < code.get_line_height() * 3)
	var escape := InputEventKey.new()
	escape.pressed = true
	escape.keycode = KEY_ESCAPE
	preview._on_code_edit_gui_input(escape)
	check("Escape closes the gutter preview", _fork.diff_gutter._preview == null)
	await get_tree().process_frame
	# A long original line scrolls inside the card, even in a narrow editor.
	code.size = Vector2(340, 500)
	code.set_meta(Gutter.META_REGIONS, [{"old_start": 2, "old_count": 1, "new_start": 2, "new_count": 0, "old_lines": PackedStringArray(["# previous " + "long line ".repeat(60)])}])
	_fork.diff_gutter.show_preview(code, 0)
	await get_tree().process_frame
	await get_tree().process_frame
	preview = _fork.diff_gutter._preview
	check("long deleted-line preview stays inside a narrow editor", preview.position.x >= 0 and preview.position.x + preview.size.x <= code.size.x)
	check("deleted-line preview retains all previous text", preview._old_view.text.ends_with("long line ".repeat(60)))
	_fork.diff_gutter.close_preview()
	code.queue_free()
	EditorInterface.set_main_screen_editor("Script")
	await get_tree().process_frame


func _check_layered_highlights() -> void:
	var old := "func get_finish() -> Area2D:"
	var current := "func get_finish() -> Area3D:"
	var rows := InlineDiff.build(PackedStringArray([old, "# original"]), PackedStringArray([current, "# original plus a comment"]))
	var replaced: Array = rows["new"][0]["spans"]
	var inserted: Array = rows["new"][1]["spans"]
	check("middle replacement highlights exactly the changed character", replaced.size() == 1 and replaced[0]["kind"] == "replaced" and current.substr(replaced[0]["start"], replaced[0]["length"]) == "3")
	check("end insertion highlights only the appended text", inserted.size() == 1 and inserted[0]["kind"] == "inserted" and inserted[0]["start"] == "# original".length() and inserted[0]["length"] == " plus a comment".length())
	check("previous version highlights the corresponding removed character", rows["old"][0]["spans"].size() == 1 and old.substr(rows["old"][0]["spans"][0]["start"], rows["old"][0]["spans"][0]["length"]) == "2")
	check("modified previous lines use modification emphasis", rows["old"][0]["kind"] == "modified_old" and rows["old"][0]["spans"][0]["kind"] == "replaced")
	var article := InlineDiff.build(PackedStringArray(["# plus an Area2D"]), PackedStringArray(["# plus a Area2D"]))
	var article_span: Dictionary = article["new"][0]["spans"][0]
	check("intraline deletion marks the surviving a at its boundary", article_span["kind"] == "replaced" and article["new"][0]["text"].substr(article_span["start"], article_span["length"]) == "a")
	var single := InlineDiff.build(PackedStringArray(["# plus Area2D"]), PackedStringArray(["# plus aArea2D"]))
	check("single added a has an insertion span", single["new"][0]["spans"].size() == 1 and single["new"][0]["spans"][0]["kind"] == "inserted" and single["new"][0]["text"].substr(single["new"][0]["spans"][0]["start"], 1) == "a")
	var aligned := InlineDiff.build(PackedStringArray([old]), PackedStringArray(["# inserted before", current]))
	check("inserted lines do not shift replacement pairing", aligned["new"][0]["kind"] == "added" and aligned["new"][1]["kind"] == "modified" and aligned["new"][1]["spans"][0]["kind"] == "replaced")
	check("separate edits leave unchanged text between them unhighlighted", InlineDiff.edits("aa + bb", "ax + by").size() == 2)
	check("identical text creates no inline highlight", InlineDiff.edits("unchanged", "unchanged").is_empty())
	var unicode := InlineDiff.edits("café猫", "café犬")
	check("unicode changes use editor character columns", unicode.size() == 1 and unicode[0]["new_start"] == 4 and unicode[0]["new_length"] == 1)
	check("large changed lines use a bounded fallback", InlineDiff.edits("a".repeat(1000), "b".repeat(1000)).size() == 1)
	check("replacement emphasis is stronger and distinct from insertion emphasis", InlineHighlights.span_color("replaced").a > InlineHighlights.span_color("inserted").a and InlineHighlights.span_color("replaced").r != InlineHighlights.span_color("inserted").r)
	var code := CodeEdit.new()
	EditorInterface.get_base_control().add_child(code)
	code.size = Vector2(1000, 450)
	code.text = current + "\n# original plus a comment\n"
	var native := Color(0.2, 0.3, 0.4, 0.2)
	code.set_line_background_color(0, native)
	var renderer := InlineHighlights.new()
	renderer.attach(code, true)
	renderer.set_rows({0: rows["new"][0], 1: rows["new"][1]})
	for frame in 5:
		await get_tree().process_frame
	var blocks: Array = renderer.geometry.get(0, [])
	var expected_x := code.get_rect_at_line_column(0, 0).position.x + code.get_theme_font("font").get_string_size(current.substr(0, current.find("3")), HORIZONTAL_ALIGNMENT_LEFT, -1, code.get_theme_font_size("font_size")).x
	check("replacement bounds cover the changed glyph rather than its preceding caret", not blocks.is_empty() and absf(blocks[0]["rect"].position.x - expected_x) <= 1.5)
	var appended: Array = renderer.geometry.get(1, [])
	var final_glyph := Rect2(code.get_rect_at_line_column(1, code.get_line(1).length()))
	check("appended highlight includes the final glyph and full row height", not appended.is_empty() and appended[-1]["rect"].encloses(final_glyph) and appended[-1]["rect"].size.y == code.get_line_height())
	var first := Gutter._bar_rect(0, Rect2(0, 10, 14, code.get_line_height()), code)
	var second := Gutter._bar_rect(1, Rect2(0, 10 + code.get_line_height(), 14, code.get_line_height()), code)
	check("adjacent changed lines share one continuous gutter bar", is_equal_approx(first.end.y, second.position.y))
	check("layered highlights leave native line colors and text intact", code.get_line_background_color(0).is_equal_approx(native) and code.text == current + "\n# original plus a comment\n")
	code.set_h_scroll(100)
	for frame in 4:
		await get_tree().process_frame
	check("highlight geometry stays clipped to the text viewport", renderer.geometry.values().all(func(items: Array) -> bool: return items.all(func(block: Dictionary) -> bool: return renderer._text_bounds().encloses(block["rect"]))))
	code.set_caret_line(0)
	code.insert_text_at_caret("# edit\n")
	check("editing immediately clears stale span geometry", renderer.rows.is_empty() and renderer.geometry.is_empty())
	renderer.detach()
	check("renderer teardown removes drawing hooks", not code.draw.is_connected(renderer._capture_geometry))
	code.queue_free()
	await get_tree().process_frame
	if "--gittydot-visual" in OS.get_cmdline_user_args():
		await _capture_visual_preview(rows, old, current)


func _capture_visual_preview(rows: Dictionary, old: String, current: String) -> void:
	var code := CodeEdit.new()
	code.theme = EditorInterface.get_editor_theme()
	code.position = Vector2(16, 12)
	code.size = Vector2(968, 280)
	code.add_theme_color_override("background_color", Color(0.103, 0.103, 0.103))
	code.add_theme_color_override("current_line_color", Color.TRANSPARENT)
	code.gutters_draw_line_numbers = true
	code.add_theme_font_size_override("font_size", 18)
	var actual: CodeEdit = _fork.diff_gutter.current_code_edit()
	code.add_theme_font_override("font", actual.get_theme_font("font"))
	code.text = current + "\n# original plus a comment\n\treturn null\n"
	var syntax := Preview.OldLinesHighlighter.new()
	syntax.language = "gdscript"
	code.syntax_highlighter = syntax
	EditorInterface.get_base_control().add_child(code)
	# Let the initial deferred text-set notification run before installing decorations.
	await get_tree().process_frame
	await get_tree().process_frame
	_fork.diff_gutter._install_gutter(code)
	code.set_meta(Gutter.META_REL_PATH, "tracked.gd")
	var region := {"new_start": 1, "new_count": 2, "old_start": 1, "old_count": 2, "old_lines": PackedStringArray([old, "# original"])}
	code.set_meta(Gutter.META_REGIONS, [region])
	code.set_meta(Gutter.META_FLAGS, Gutter._flags_for([region]))
	code.get_meta(InlineHighlights.META).set_rows({0: rows["new"][0], 1: rows["new"][1]})
	_fork.diff_gutter.show_preview(code, 0)
	for frame in 8:
		await get_tree().process_frame
	RenderingServer.force_draw(false)
	var root_capture := code.get_viewport().get_texture().get_image()
	var capture := root_capture.get_region(Rect2i(Vector2i(code.global_position), Vector2i(code.size)))
	check("graphical renderer captures the actual native preview", capture != null and not capture.is_empty() and capture.save_png("res://inline-highlights.png") == OK)
	if capture != null and not capture.is_empty():
		var replacement := code.get_rect_at_line_column(0, current.find("3") + 1)
		var unchanged := code.get_rect_at_line_column(0, 0)
		var inserted := code.get_rect_at_line_column(1, "# original".length() + 2)
		var replace_pixel := capture.get_pixelv(replacement.position + Vector2i(1, 1))
		var neutral_pixel := capture.get_pixelv(unchanged.position + Vector2i(1, 1))
		var insert_pixel := capture.get_pixelv(inserted.position + Vector2i(1, 1))
		check("replacement background is brighter than the quiet line tint", replace_pixel.get_luminance() > neutral_pixel.get_luminance() + 0.03)
		check("insertion background is green over the modified line", insert_pixel.g > insert_pixel.b + 0.025 and insert_pixel.get_luminance() > neutral_pixel.get_luminance() + 0.02)
		var final := code.get_rect_at_line_column(1, code.get_line(1).length())
		var final_pixel := capture.get_pixelv(final.position + Vector2i(maxi(1, final.size.x - 2), 1))
		check("green insertion reaches the right edge of the final character", final_pixel.g > final_pixel.b + 0.025)
		var before := _fork.diff_gutter._preview._old_view as CodeEdit
		var before_rect := before.get_rect_at_line_column(0, old.find("2") + 1)
		var before_pixel := capture.get_pixelv(Vector2i(before.global_position - code.global_position) + before_rect.position + Vector2i(1, 1))
		check("previous replacement uses yellow green emphasis rather than red", before_pixel.g > before_pixel.b + 0.025 and before_pixel.g > before_pixel.r * 0.8)
	_fork.diff_gutter.close_preview()
	code.queue_free()
	await get_tree().process_frame


func _check_diff_panes() -> void:
	Settings.set_value("diff_side_by_side", true)
	var diff := DiffView.new()
	diff.theme = EditorInterface.get_editor_theme()
	var shell := PanelContainer.new()
	var background := StyleBoxFlat.new()
	background.bg_color = Color(0.12, 0.12, 0.12)
	shell.add_theme_stylebox_override("panel", background)
	shell.position = Vector2(16, 12)
	shell.size = Vector2(1000, 380)
	EditorInterface.get_base_control().add_child(shell)
	shell.add_child(diff)
	var text := "diff --git a/pane.gd b/pane.gd\n--- a/pane.gd\n+++ b/pane.gd\n@@ -1,41 +1,42 @@\n"
	for row in 40:
		text += " # context %d\n" % row
	text += "-# old " + "long ".repeat(80) + "\n+# new " + "long ".repeat(120) + "\n+# added\n"
	diff.show_diff(text, {"path": "pane.gd", "actions": ["stage"]})
	for frame in 8:
		await get_tree().process_frame
	check("side by side uses two separate scroll panes and a draggable divider", diff._split.visible and not diff._scroll.visible and diff._split.get_child_count() == 2 and diff._panes[0] != diff._panes[1])
	check("both panes show horizontal and vertical scrollbars for overflowing content", diff._panes.all(func(pane: ScrollContainer) -> bool: return pane.get_h_scroll_bar().visible and pane.get_v_scroll_bar().visible))
	check("inserted lines retain matching row positions in both panes", diff._pane_rows[0]._display.size() == diff._pane_rows[1]._display.size() and diff._pane_rows[0].custom_minimum_size.y == diff._pane_rows[1].custom_minimum_size.y)
	diff._panes[0].scroll_vertical = 100
	diff._panes[0].scroll_horizontal = 70
	check("scrolling the old pane synchronizes both axes", diff._panes[1].scroll_vertical == 100 and diff._panes[1].scroll_horizontal == 70)
	diff._panes[1].scroll_vertical = 150
	diff._panes[1].scroll_horizontal = 110
	check("scrolling the new pane synchronizes both axes", diff._panes[0].scroll_vertical == 150 and diff._panes[0].scroll_horizontal == 110)
	var previous := diff._panes[0].size.x
	diff._split.split_offset = 140
	for frame in 6:
		await get_tree().process_frame
	check("divider changes pane widths without changing row alignment", absf(previous - diff._panes[0].size.x) > 50 and diff._pane_rows[0]._row_height == diff._pane_rows[1]._row_height)
	var left_max := diff._panes[0].get_h_scroll_bar().max_value - diff._panes[0].get_h_scroll_bar().page
	var right_max := diff._panes[1].get_h_scroll_bar().max_value - diff._panes[1].get_h_scroll_bar().page
	check("unequal panes retain the same horizontal scroll range", absf(left_max - right_max) <= 1)
	diff._panes[0].get_h_scroll_bar().value = left_max
	check("horizontal synchronization reaches the far edge on both sides", absf(diff._panes[1].get_h_scroll_bar().value - left_max) <= 1)
	var old_row := diff._pane_rows[0]
	var removed := -1
	for row in old_row._rows.size():
		if old_row._rows[row]["type"] == "removed":
			removed = row
	old_row._selected[removed] = true
	check("selection across versions shares the same patch rows", diff._pane_rows[1]._selected.has(removed) and old_row._selected_in_hunk(0, true).size() == 2)
	if "--gittydot-visual" in OS.get_cmdline_user_args():
		diff._panes[0].scroll_horizontal = 0
		diff._panes[0].scroll_vertical = 700
		for frame in 3:
			await get_tree().process_frame
		RenderingServer.force_draw(false)
		var capture := diff.get_viewport().get_texture().get_image().get_region(Rect2i(Vector2i(diff.global_position), Vector2i(diff.size)))
		check("graphical renderer captures the split diff panes", capture.save_png("res://split-diff.png") == OK)
	diff.show_diff("diff --git a/short.gd b/short.gd\n--- a/short.gd\n+++ b/short.gd\n@@ -1 +1 @@\n-# before\n+# after\n", {"path": "short.gd"})
	for frame in 8:
		await get_tree().process_frame
	if "--gittydot-visual" in OS.get_cmdline_user_args():
		RenderingServer.force_draw(false)
		await get_tree().create_timer(0.1).timeout
	check("short content hides both axes of scrollbars", diff._panes.all(func(pane: ScrollContainer) -> bool: return not pane.get_h_scroll_bar().visible and not pane.get_v_scroll_bar().visible))
	Settings.set_value("diff_side_by_side", false)
	diff._rerender()
	check("unified diff remains available", diff._scroll.visible and not diff._split.visible)
	Settings.set_value("diff_side_by_side", true)
	shell.queue_free()
	await get_tree().process_frame


func _check_startup_helpers() -> void:
	var icon: Texture2D = _fork._get_plugin_icon()
	var side := maxi(1, roundi(16 * EditorInterface.get_editor_scale()))
	check("plugin artwork loads at toolbar size without raw-resource warnings", icon != null and icon.get_size() == Vector2(side, side))
	var root := ProjectSettings.globalize_path("res://").trim_suffix("/")
	var scratch := root.path_join(root.get_file() + "-temp-chatgpt/cli-path with spaces")
	DirAccess.make_dir_recursive_absolute(scratch)
	check("optional CLI candidates exclude missing executables", RepoSetup.gh_candidates("Windows", scratch).is_empty())
	var file := FileAccess.open(scratch.path_join("gh.exe" if OS.get_name() == "Windows" else "gh"), FileAccess.WRITE)
	file.store_string("Discovery fixture, never executed")
	file.close()
	var separator := ";" if OS.get_name() == "Windows" else ":"
	var search_path := '"' + scratch + '"' + separator + scratch
	var candidates := RepoSetup.gh_candidates(OS.get_name(), search_path)
	check("CLI discovery keeps paths with spaces and deduplicates PATH entries", candidates.size() == 1 and candidates[0] == scratch.path_join("gh.exe" if OS.get_name() == "Windows" else "gh"))
	check("Windows CLI discovery never adds macOS fallback locations", RepoSetup.gh_candidates("Windows", "").is_empty())


func _check_monitor_safety(repo: RefCounted) -> void:
	var versions := {"git version 2.36.1.windows.1": true, "git version 2.37.0.windows.1": false, "git version 2.53.0.windows.3": false, "unknown": true}
	for version in versions:
		check("legacy Windows monitor guard: " + version, Cli.legacy_windows_monitor(version) == versions[version])
	if OS.get_name() != "Windows":
		return
	var root: String = repo.get_repo_root()
	Cli.run(root, ["config", "--local", "core.useBuiltinFSMonitor", "true"])
	check("Git children disable the inherited experimental Windows monitor", Cli.run(root, ["config", "--bool", "--get", "core.useBuiltinFSMonitor"])["text"].strip_edges() == "false")
	check("monitor safeguard does not rewrite repository configuration", Cli.execute("git", PackedStringArray(["-C", root, "config", "--local", "--get", "core.useBuiltinFSMonitor"]))["out"].get_string_from_utf8().strip_edges() == "true")
	Cli.run(root, ["config", "--local", "core.useBuiltinFSMonitor", "false"])
	var args := Cli.argv(root, ["status", "--porcelain"])
	check("old Git disables modern monitor flag while supported Git retains opt-in behavior", args.has("core.fsmonitor=false") == Cli._old_windows_git)


func _check_console_safety(repo: RefCounted) -> void:
	var cases := {
		"reset --hard HEAD": true,
		"-C elsewhere reset --hard": true,
		"-c core.quotePath=false reset --hard": true,
		"clean -fdx": true,
		"clean --dry-run": false,
		"clean -ndx": false,
		"clean -f -- -n": true,
		"push -vf origin main": true,
		"push --force-with-lease origin main": true,
		"push origin +main:main": true,
		"push origin main": false,
		"config --global user.name Someone": true,
		"config --global --unset user.name": true,
		"config --global --get user.name": false,
		"config --global user.name": false,
		"config --global user.name get": true,
		"config --global -- user.name --get": true,
		"commit -m 'alias.example=literal'": false,
		"-c alias.wipe='reset --hard' wipe": true,
	}
	for line in cases:
		check("console confirmation: " + line, not Console.confirmation_reason(Console.split_args(line)).is_empty() == cases[line])
	var ssh_before: Variant = OS.get_environment("GIT_SSH_COMMAND") if OS.has_environment("GIT_SSH_COMMAND") else null
	Cli.restore_environment()
	Cli.prepare_environment()
	check("plugin enable leaves the editor SSH environment unchanged", (OS.get_environment("GIT_SSH_COMMAND") if OS.has_environment("GIT_SSH_COMMAND") else null) == ssh_before)
	var root: String = repo.get_repo_root()
	Cli.run(root, ["config", "core.sshCommand", "untrusted-repository-command"])
	var command: String = Cli.run(root, ["config", "--get", "core.sshCommand"])["text"].strip_edges()
	check("GittyDot overrides repository SSH commands only for its child Git process", command == "ssh -o BatchMode=yes")
	check("repository SSH config is preserved on disk", Cli.execute("git", PackedStringArray(["-C", root, "config", "--local", "--get", "core.sshCommand"]))["out"].get_string_from_utf8().strip_edges() == "untrusted-repository-command")
	Cli.run(root, ["config", "--unset", "core.sshCommand"])
	Cli.clear_log()
	var initial_revision: int = Cli.log_snapshot()["revision"]
	var threads: Array[Thread] = []
	for worker in 4:
		var thread := Thread.new()
		thread.start(func() -> void:
			for entry in 150:
				Cli.record(["worker", str(worker), str(entry)], 0, "background output")
		)
		threads.append(thread)
	var coherent := true
	while threads.any(func(thread: Thread) -> bool: return thread.is_alive()):
		var snapshot := Cli.log_snapshot()
		coherent = coherent and snapshot["entries"].size() <= Cli.LOG_LIMIT and snapshot["entries"].all(func(entry: Dictionary) -> bool: return entry.has("time") and entry.has("args") and entry.has("exit_code") and entry.has("text"))
		await get_tree().process_frame
	for thread in threads:
		thread.wait_to_finish()
	var finished := Cli.log_snapshot()
	check("concurrent logging keeps complete bounded snapshots", coherent and finished["entries"].size() == Cli.LOG_LIMIT and finished["revision"] == initial_revision + 600)
	Cli.clear_log()
	check("clearing the log leaves earlier snapshots detached", finished["entries"].size() == Cli.LOG_LIMIT and Cli.log_snapshot()["entries"].is_empty())
	var console := Console.new()
	EditorInterface.get_base_control().add_child(console)
	console.set_repo(repo)
	Cli.record(["log"], 0, "[b]literal[/b] [url=https://example.invalid]markup[/url]")
	console._update()
	check("console prints untrusted output as literal text", console._output.get_parsed_text().contains("[b]literal[/b]") and console._output.get_parsed_text().contains("[url=https://example.invalid]"))
	Cli.run(root, ["config", "alias.wipe", "reset --hard"])
	Cli.run(root, ["config", "alias.shellwipe", "!git reset --hard"])
	check("destructive and shell aliases require confirmation", not console._confirmation_reason(PackedStringArray(["wipe"])).is_empty() and not console._confirmation_reason(PackedStringArray(["shellwipe"])).is_empty())
	Cli.run(root, ["config", "--unset", "alias.wipe"])
	Cli.run(root, ["config", "--unset", "alias.shellwipe"])
	var before_file := FileAccess.get_file_as_string("res://tracked.gd")
	var before_revision: int = Cli.log_snapshot()["revision"]
	console._input.text = "reset --hard HEAD"
	console._run.call_deferred()
	await get_tree().process_frame
	await get_tree().process_frame
	var dialogs := console.find_children("*", "ConfirmationDialog", true, false)
	check("destructive console command waits for a decision before launching Git", dialogs.size() == 1 and repo.current_job == null and console._run_button.disabled and Cli.log_snapshot()["revision"] == before_revision)
	if not dialogs.is_empty():
		dialogs[0].canceled.emit()
		await get_tree().process_frame
		check("cancelling confirmation preserves the file and command draft", FileAccess.get_file_as_string("res://tracked.gd") == before_file and console._input.text == "reset --hard HEAD" and console._input.editable and not console._run_button.disabled and Cli.log_snapshot()["revision"] == before_revision)
	console.queue_free()
	Cli.clear_log()
	await get_tree().process_frame


func _commit_item(item: TreeItem, kind: String, value: String) -> TreeItem:
	var meta: Variant = item.get_metadata(0)
	if meta is Dictionary and meta.get("kind", "") == kind and meta.get("dir" if kind == "folder" else "path", "") == value:
		return item
	var child := item.get_first_child()
	while child != null:
		var found := _commit_item(child, kind, value)
		if found != null:
			return found
		child = child.get_next()
	return null


func _check_folder_actions(repo: RefCounted) -> void:
	# Use the actual production panel in a visible area; the native editor's
	# dock tab can be hidden in headless runs and then has no scroll range.
	var panel: Control = ChangesScene.instantiate()
	EditorInterface.get_base_control().add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2(16, 12)
	panel.size = Vector2(900, 600)
	panel.set_repo(repo)
	for frame in 3:
		await get_tree().process_frame
	var tree: Tree = panel._tree
	var folder := _commit_item(tree.get_root(), "folder", "folder_actions/deep")
	check("Commit folders retain their exact repository path", folder != null and folder.get_metadata(0)["dir"] == "folder_actions/deep")
	if folder == null:
		return
	panel._show_context_menu_for_item(folder, Vector2(30, 30))
	check("tracked folders offer ignore stage unstage stash and revert actions", panel._context_menu.get_item_index(Changes.ID_IGNORE_FOLDER) >= 0 and panel._context_menu.get_item_index(Changes.ID_STAGE_PATHS) >= 0 and panel._context_menu.get_item_index(Changes.ID_UNSTAGE_PATHS) >= 0 and panel._context_menu.get_item_index(Changes.ID_STASH_GROUP) >= 0 and panel._context_menu.get_item_index(Changes.ID_REVERT_ALL) >= 0)
	check("folder action is scoped to its displayed descendant files", panel._context_target["paths"].size() == 2 and panel._context_target["paths"].has("folder_actions/deep/one.txt") and not panel._context_target["paths"].has("tracked.gd"))
	panel._context_menu.hide()
	panel._on_context_menu_id_pressed(Changes.ID_UNSTAGE_PATHS)
	await get_tree().process_frame
	check("folder unstage clears its index changes and preserves unrelated partial staging", repo.get_file_bytes(":", "folder_actions/deep/one.txt").get_string_from_utf8() == "original one\n" and repo.get_file_bytes(":", "tracked.gd").get_string_from_utf8().contains("number := 2"))
	check("folder unstage preserves both working files", FileAccess.get_file_as_string("res://folder_actions/deep/one.txt") == "edited one\n" and FileAccess.get_file_as_string("res://folder_actions/deep/two.txt") == "edited two\n")
	folder = _commit_item(tree.get_root(), "folder", "folder_actions/deep")
	panel._show_context_menu_for_item(folder, Vector2(30, 30))
	check("unstage is disabled when the folder has no staged changes", panel._context_menu.is_item_disabled(panel._context_menu.get_item_index(Changes.ID_UNSTAGE_PATHS)))
	panel._context_menu.hide()
	panel._on_context_menu_id_pressed(Changes.ID_STAGE_PATHS)
	await get_tree().process_frame
	check("folder stage stages both descendants without changing other staging", repo.get_file_bytes(":", "folder_actions/deep/one.txt").get_string_from_utf8() == "edited one\n" and repo.get_file_bytes(":", "folder_actions/deep/two.txt").get_string_from_utf8() == "edited two\n" and repo.get_file_bytes(":", "tracked.gd").get_string_from_utf8().contains("number := 2"))
	# Restore the folder fixture's original partially staged state.
	repo.unstage_file("folder_actions/deep/two.txt")
	panel.refresh()
	folder = _commit_item(tree.get_root(), "folder", "ignore_actions/deep")
	# Keep the hit-test row onscreen even when the headless editor cannot
	# draw the Tree's scroll range. This is the actual nonselectable folder.
	var branch := folder
	while branch.get_parent() != null:
		var sibling := branch.get_parent().get_first_child()
		while sibling != null:
			sibling.visible = sibling == branch
			sibling = sibling.get_next()
		branch = branch.get_parent()
	var ancestor := folder.get_parent()
	while ancestor != null:
		ancestor.collapsed = false
		ancestor = ancestor.get_parent()
	tree.scroll_to_item(folder)
	for frame in 5:
		await get_tree().process_frame
	var area: Rect2 = tree.get_item_area_rect(folder, Changes.TEXT_COLUMN)
	var click := InputEventMouseButton.new()
	click.pressed = true
	click.button_index = MOUSE_BUTTON_RIGHT
	click.position = Vector2(area.position.x + 10, area.get_center().y)
	tree.gui_input.emit(click)
	check("right clicking a nonselectable folder opens its actual menu", not folder.is_selectable(Changes.TEXT_COLUMN) and panel._context_menu.visible and panel._context_target.get("dir", "") == "ignore_actions/deep")
	panel._context_menu.hide()
	var original_ignore := FileAccess.get_file_as_string("res://.gitignore")
	panel._on_context_menu_id_pressed(Changes.ID_IGNORE_FOLDER)
	var ignored := FileAccess.get_file_as_string("res://.gitignore")
	check("folder ignore appends an anchored directory rule and preserves existing rules", ignored.begins_with(original_ignore) and ignored.contains("/ignore_actions/deep/\n"))
	check("folder ignore hides its new descendants without matching another nested folder", Cli.run(repo.get_repo_root(), ["check-ignore", "--", "ignore_actions/deep/new[1].tmp"])["exit_code"] == 0 and Cli.run(repo.get_repo_root(), ["check-ignore", "--", "elsewhere/ignore_actions/deep/keep.tmp"])["exit_code"] != 0)
	check("ignoring a folder never deletes its files", FileAccess.file_exists("res://ignore_actions/deep/new[1].tmp"))
	panel._ignore_path("ignore_actions/deep/")
	check("repeating ignore does not duplicate the rule", FileAccess.get_file_as_string("res://.gitignore") == ignored)
	var file := _commit_item(tree.get_root(), "file", "folder_actions/deep/one.txt")
	panel._show_context_menu_for_item(file, Vector2(30, 30))
	check("tracked files expose Add to gitignore", panel._context_menu.get_item_index(Changes.ID_IGNORE) >= 0)
	panel._context_menu.hide()
	panel._on_context_menu_id_pressed(Changes.ID_IGNORE)
	check("ignoring a tracked file leaves its index content and disk content intact", repo.get_file_bytes(":", "folder_actions/deep/one.txt").get_string_from_utf8() == "edited one\n" and FileAccess.get_file_as_string("res://folder_actions/deep/one.txt") == "edited one\n")
	panel._ignore_path("elsewhere/ignore_actions/deep/keep.tmp")
	check("file ignore is literal and not a basename wildcard", Cli.run(repo.get_repo_root(), ["check-ignore", "--", "elsewhere/ignore_actions/deep/keep.tmp"])["exit_code"] == 0)
	check("ignore patterns escape wildcard characters and spaces", Changes.ignore_pattern("cache [1]/file?.tmp") == "/cache\\ \\[1\\]/file\\?.tmp")
	check("ignore patterns reject root traversal and extra lines", Changes.ignore_pattern("../outside").is_empty() and Changes.ignore_pattern("/").is_empty() and Changes.ignore_pattern("file\nother").is_empty())
	folder = _commit_item(tree.get_root(), "folder", "add_actions/deep")
	panel._show_context_menu_for_item(folder, Vector2(30, 30))
	check("new folders offer Add to Git and ignore", panel._context_menu.get_item_index(Changes.ID_ADD_FOLDER_TO_VCS) >= 0 and panel._context_menu.get_item_index(Changes.ID_IGNORE_FOLDER) >= 0)
	panel._context_menu.hide()
	panel._on_context_menu_id_pressed(Changes.ID_ADD_FOLDER_TO_VCS)
	check("folder Add to Git stages its new descendants", repo.get_file_bytes(":", "add_actions/deep/new.tmp").get_string_from_utf8() == "untracked content\n")
	repo.unstage_file("add_actions/deep/new.tmp")
	panel.refresh()
	check("FileSystem treats directory selections as directory ignore rules with or without trailing slash", _fork.filesystem_menu._ignore_targets(PackedStringArray(["res://folder_actions/deep", "res://add_actions/deep/"])) == ["folder_actions/deep/", "add_actions/deep/"])
	check("FileSystem does not offer a rule that ignores the repository root", _fork.filesystem_menu._ignore_targets(PackedStringArray(["res://"])).is_empty())
	# Leave the fixture's .gitignore unchanged for the remaining editor checks.
	var restore := FileAccess.open("res://.gitignore", FileAccess.WRITE)
	restore.store_string(original_ignore)
	restore.close()
	panel.refresh()
	panel.queue_free()
	await get_tree().process_frame


func _find_file(item: TreeItem, path: String) -> TreeItem:
	if item == null:
		return null
	if item.get_metadata(0) == path:
		return item
	var child := item.get_first_child()
	while child != null:
		var found := _find_file(child, path)
		if found != null:
			return found
		child = child.get_next()
	return null


func _finish() -> void:
	var failed := checks.filter(func(item: Dictionary) -> bool: return not item["passed"])
	var result := {"checks": checks, "passed": checks.size() - failed.size(), "failed": failed.size()}
	var file := FileAccess.open("res://integration-result.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "\t"))
	file.close()
	print("GITTYDOT RESULT ", JSON.stringify(result))
	get_tree().quit(0 if failed.is_empty() else 1)
