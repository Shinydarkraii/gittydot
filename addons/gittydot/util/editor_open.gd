## Opens a repo-relative path in whichever editor Godot normally uses for
## it — same as double-clicking it in the FileSystem dock. Shared by
## changes_panel.gd and history_panel.gd. No class_name: internal helper,
## addressed via preload (see git_status_flags.gd for why).
extends RefCounted

## Registered by the fork: unsupported text/configuration files open in the central diff screen.
static var open_raw_file: Callable


## Enablement uses disk presence for scripts, including files not yet imported.
static func unavailable_reason(repo_root: String, path: String) -> String:
	var local := ProjectSettings.localize_path(repo_root.path_join(path).simplify_path())
	if path.is_empty() or not local.begins_with("res://"):
		return "This file is outside the current Godot project."
	if not FileAccess.file_exists(local):
		return "The current working file is missing or deleted."
	if local.get_extension() in ["gd", "cs", "tscn", "scn"] or ResourceLoader.exists(local):
		return ""
	return "This file has no native Godot editor. Use the comparison to inspect it."


## The repo root isn't necessarily the Godot project root, so this resolves
## through an absolute path rather than assuming path is already
## res://-relative. Returns an error message to show, or "" on success.
static func open_file(repo_root: String, path: String) -> String:
	var abs_path := repo_root.path_join(path).simplify_path()
	var res_path := ProjectSettings.localize_path(abs_path)
	if not res_path.begins_with("res://"):
		return "This file is outside the current Godot project:\n%s" % abs_path
	if not FileAccess.file_exists(res_path):
		return "The current working file is missing or deleted:\n%s" % res_path
	if res_path.get_extension() in ["gd", "cs"]:
		# Preserve native drafts; refresh clean tabs before reusing the cached script.
		sync_open_scripts()
		var native := EditorInterface.get_script_editor()
		var dirty: bool = native != null and res_path in unsaved_scripts()
		var script := ResourceLoader.load(res_path, "Script", ResourceLoader.CACHE_MODE_REUSE if dirty else ResourceLoader.CACHE_MODE_REPLACE) as Script
		if script == null:
			return "Failed to load script:\n%s" % res_path
		EditorInterface.edit_script(script)
		EditorInterface.set_main_screen_editor("Script")
		return ""

	if res_path.get_extension() in ["tscn", "scn"]:
		EditorInterface.open_scene_from_path(res_path)
		return ""

	if not ResourceLoader.exists(res_path):
		if open_raw_file.is_valid() and FileAccess.file_exists(res_path):
			open_raw_file.call(path, 1)
			return ""
		return "This file cannot be opened in the current editor:\n%s" % res_path

	var resource := load(res_path)
	if resource == null:
		return "Failed to load:\n%s" % res_path

	if resource is Script:
		EditorInterface.edit_script(resource)
		EditorInterface.set_main_screen_editor("Script")
	else:
		EditorInterface.edit_resource(resource)
	return ""


## Like open_file(), but for scripts/text also jumps to line (1-based).
static func open_file_at_line(repo_root: String, path: String, line: int) -> String:
	var res_path := ProjectSettings.localize_path(repo_root.path_join(path))
	if res_path.begins_with("res://") and ResourceLoader.exists(res_path):
		var resource := load(res_path)
		if resource is Script:
			EditorInterface.edit_script(resource, maxi(1, line), 0)
			EditorInterface.set_main_screen_editor("Script")
			return ""
		var error := open_file(repo_root, path)
		# edit_script() only takes scripts; a text file (.md, .json...) is opened as a resource and its tab's caret moved here.
		if error.is_empty() and current_tab_path() == res_path:
			var code_edit := EditorInterface.get_script_editor().get_current_editor().get_base_editor() as CodeEdit
			if code_edit != null:
				code_edit.set_caret_line(clampi(line - 1, 0, code_edit.get_line_count() - 1))
				code_edit.center_viewport_to_caret()
		return error
	return open_file(repo_root, path)


## Reloads a file the editor doesn't know changed on disk (after revert, resolve...); its script tab is rewritten even with unsaved edits, since discarding them is the point.
static func refresh_external_change(repo_root: String, path: String) -> void:
	refresh_external_changes(repo_root, [path])


## refresh_external_change() for several repo-relative paths at once.
static func refresh_external_changes(repo_root: String, paths: Array) -> void:
	# Also covers a file revert_file() just deleted outright.
	EditorInterface.get_resource_filesystem().scan()
	var discarded := PackedStringArray()
	for path: String in paths:
		var res_path := ProjectSettings.localize_path(repo_root.path_join(path))
		if not res_path.begins_with("res://"):
			continue
		if res_path.get_extension() in ["tscn", "scn"]:
			if res_path in EditorInterface.get_open_scenes() and FileAccess.file_exists(res_path):
				EditorInterface.reload_scene_from_path(res_path)
			continue
		discarded.append(res_path)
		# CACHE_MODE_REPLACE re-reads it if it's already loaded (open script tab, resource used by an open scene...).
		if ResourceLoader.exists(res_path):
			ResourceLoader.load(res_path, "", ResourceLoader.CACHE_MODE_REPLACE)
	sync_open_scripts(discarded)


## Same as refresh_external_change(), but for an operation that can touch
## the whole working tree (checkout_commit, reset_branch_to, ...) rather
## than one known path.
static func refresh_all_external_changes() -> void:
	EditorInterface.get_resource_filesystem().scan()
	for scene_path in EditorInterface.get_open_scenes():
		# Unsaved new scenes have no path, and a checkout may have deleted the file.
		if not scene_path.is_empty() and FileAccess.file_exists(scene_path):
			EditorInterface.reload_scene_from_path(scene_path)
	sync_open_scripts()


## Script and text file tabs keep their own buffer, so reloading the resource doesn't change what's shown; this rewrites each open tab whose file changed on disk (one undoable edit, caret and scroll kept, tab stays "saved"). Tabs with unsaved edits are left alone unless listed in discarded.
static func sync_open_scripts(discarded := PackedStringArray()) -> void:
	var script_editor := EditorInterface.get_script_editor()
	if script_editor == null:
		return
	var tabs := _open_tabs(script_editor)
	for tab: Dictionary in tabs:
		var path: String = tab["path"]
		var code_edit := (tab["editor"] as ScriptEditorBase).get_base_editor() as CodeEdit
		if code_edit == null or not FileAccess.file_exists(path):
			continue
		if code_edit.get_version() != code_edit.get_saved_version() and not discarded.has(path):
			continue # unsaved edits in the tab: leave them, Godot asks on its own
		var disk := FileAccess.get_file_as_string(path)
		if code_edit.text == disk:
			continue
		_replace_text_keeping_view(code_edit, disk)
		if tab["script"] != null:
			tab["script"].source_code = disk


## res:// path of the script editor's current tab, a script or a text file (.md, .json...); "" for help pages and built-in scripts.
static func current_tab_path() -> String:
	var script_editor := EditorInterface.get_script_editor()
	var current: ScriptEditorBase = script_editor.get_current_editor() if script_editor != null else null
	if current == null:
		return ""
	if current.get_class() == "ScriptTextEditor":
		var script := script_editor.get_current_script()
		return script.resource_path if script != null and not script.resource_path.contains("::") else ""
	for tab: Dictionary in _open_tabs(script_editor):
		if tab["editor"] == current:
			return tab["path"]
	return ""


## [{"editor", "path", "script" (null for a text file)}] for every script and text file tab with a file behind it.
static func _open_tabs(script_editor: ScriptEditor) -> Array:
	var tabs: Array = []
	var editors: Array = script_editor.get_open_script_editors()
	# get_open_scripts() lists only the ScriptTextEditor tabs, in tab order — pair it with those editors.
	var scripts: Array = script_editor.get_open_scripts()
	var script_editors := editors.filter(func(e: Node) -> bool: return e.get_class() == "ScriptTextEditor")
	for i in mini(scripts.size(), script_editors.size()):
		var script: Script = scripts[i]
		if script != null and not script.resource_path.is_empty() and not script.resource_path.contains("::"):
			tabs.append({ "editor": script_editors[i], "path": script.resource_path, "script": script })
	# Text files (.md, .json, .txt...) have no API giving their path; the script list's items carry it as the tooltip and the tab index as metadata.
	var text_editors := {}
	for editor: Node in editors:
		if editor.get_class() == "TextEditor":
			text_editors[editor.get_index()] = editor
	if not text_editors.is_empty():
		for list: ItemList in script_editor.find_children("*", "ItemList", true, false):
			for i in list.item_count:
				var tab_index: Variant = list.get_item_metadata(i)
				var path := list.get_item_tooltip(i)
				if tab_index is int and text_editors.has(tab_index) and path.begins_with("res://"):
					tabs.append({ "editor": text_editors[tab_index], "path": path, "script": null })
					text_editors.erase(tab_index)
	return tabs


static func _replace_text_keeping_view(code_edit: CodeEdit, text: String) -> void:
	var caret_line := code_edit.get_caret_line()
	var caret_column := code_edit.get_caret_column()
	var scroll := code_edit.scroll_vertical
	code_edit.begin_complex_operation()
	var last := code_edit.get_line_count() - 1
	code_edit.remove_text(0, 0, last, code_edit.get_line(last).length())
	code_edit.insert_text(text, 0, 0)
	code_edit.end_complex_operation()
	code_edit.tag_saved_version()
	code_edit.set_caret_line(mini(caret_line, code_edit.get_line_count() - 1))
	code_edit.set_caret_column(caret_column)
	code_edit.scroll_vertical = scroll


## Older editors expose dirty text buffers but not ScriptEditor.get_unsaved_files.
static func unsaved_scripts() -> PackedStringArray:
	var editor := EditorInterface.get_script_editor()
	if editor == null:
		return PackedStringArray()
	if editor.has_method("get_unsaved_files"):
		return editor.call("get_unsaved_files")
	var paths := PackedStringArray()
	for tab: Dictionary in _open_tabs(editor):
		var code := tab["editor"].get_base_editor() as CodeEdit
		if code != null and code.get_version() != code.get_saved_version():
			paths.append(tab["path"])
	return paths


## Prefer the public API. Older editors mark dirty scenes in their scene-tab titles.
## Match the scene strip by its native class, and fail conservatively if its layout
## cannot be identified: never silently treat an unknown open scene as saved.
static func unsaved_scenes() -> PackedStringArray:
	if EditorInterface.has_method("get_unsaved_scenes"):
		return EditorInterface.call("get_unsaved_scenes")
	var paths := EditorInterface.get_open_scenes()
	for strip: Node in EditorInterface.get_base_control().find_children("*", "EditorSceneTabs", true, false):
		for tabs: TabBar in strip.find_children("*", "TabBar", true, false):
			if tabs.tab_count != paths.size():
				continue
			var dirty := PackedStringArray()
			for i in paths.size():
				if tabs.get_tab_title(i).ends_with("(*)"):
					dirty.append(paths[i])
			return dirty
	return paths


## Before save_all_scripts was exposed, the native editor already connected its
## autosave timer to the same implementation. Reuse that exact callable without
## changing its timer/settings or taking the menu's unrelated reload-prompt path.
## If the native callback cannot be identified, fail and keep the buffers dirty.
static func save_all_scripts() -> bool:
	var editor := EditorInterface.get_script_editor()
	if editor == null:
		return true
	if editor.has_method("save_all_scripts"):
		editor.call("save_all_scripts")
		return true
	if unsaved_scripts().is_empty():
		return true
	for timer: Timer in editor.find_children("*", "Timer", true, false):
		for connection: Dictionary in timer.get_signal_connection_list("timeout"):
			var callback: Callable = connection["callable"]
			if callback.get_object() == editor and callback.get_method() in [&"_autosave_scripts", &"ScriptEditor::_autosave_scripts"]:
				callback.call()
				return true
	return false


static func optional_property(object: Object, property: StringName, value: Variant) -> bool:
	for entry: Dictionary in object.get_property_list():
		if entry["name"] == property:
			object.set(property, value)
			return true
	return false


## Content fitting was added after 4.4. Measure native shaped line widths and
## gutters on older editors, keeping scrollbars outside the full text buffer.
static func code_content_size(code: CodeEdit) -> Vector2:
	var style := code.get_theme_stylebox("normal")
	var width := 0.0
	for line in code.get_line_count():
		width = maxf(width, code.get_line_width(line))
	return Vector2(width + code.get_total_gutter_width() + style.get_minimum_size().x + code.get_v_scroll_bar().get_minimum_size().x,
		code.get_line_height() * code.get_line_count() + style.get_minimum_size().y + code.get_h_scroll_bar().get_minimum_size().y)
