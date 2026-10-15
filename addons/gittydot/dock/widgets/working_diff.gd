@tool
extends VBoxContainer
## Full documents only: the editable buffer never contains diff padding or headers.

const EditorOpen := preload("res://addons/gittydot/util/editor_open.gd")
const Dialogs := preload("res://addons/gittydot/dock/widgets/dialogs.gd")
const GitCli := preload("res://addons/gittydot/util/git_cli.gd")
const DiffHunks := preload("res://addons/gittydot/util/diff_hunks.gd")
const InlineDiff := preload("res://addons/gittydot/util/inline_diff.gd")
const Highlights := preload("res://addons/gittydot/dock/gutter/inline_highlights.gd")
const SyntaxColors := preload("res://addons/gittydot/util/syntax_colors.gd")
const Settings := preload("res://addons/gittydot/util/settings.gd")
const UiScale := preload("res://addons/gittydot/util/ui_scale.gd")
const Palette := preload("res://addons/gittydot/util/diff_palette.gd")
const MAX_BYTES := 2 * 1024 * 1024
const MAX_LINES := 20000
const SAVE_DELAY := 0.35

signal file_saved
static var _instances: Array = []

var _split: HSplitContainer
var _panes: Array[ScrollContainer] = []
var _codes: Array[CodeEdit] = []
var _highlights: Array = []
var _timer: Timer
var _status: Label
var _save: Button
var _reload: Button
var _repo: RefCounted
var _absolute_path := ""
var _relative_path := ""
var _baseline := PackedByteArray()
var _bom := false
var _crlf := false
var _loading := false
var _syncing := false
var _saving := false
var _regions: Array = []
var _block_reason := ""
var _announced := ""
var _navigation_signature := ""
var _navigation: Array[Control] = []


func _init() -> void:
	size_flags_vertical = SIZE_EXPAND_FILL
	var bar := HBoxContainer.new()
	_status = Label.new()
	_status.size_flags_horizontal = SIZE_EXPAND_FILL
	_status.clip_text = true
	bar.add_child(_status)
	_save = Button.new()
	_save.text = "Save"
	_save.tooltip_text = "Save working file (Ctrl/Cmd+S); edits also save after 350 ms"
	_save.pressed.connect(func() -> void:
		if not flush():
			Dialogs.error(self, "Comparison save paused", _block_reason)
	)
	bar.add_child(_save)
	_reload = Button.new()
	_reload.text = "Reload"
	_reload.tooltip_text = "Reload the working file from disk; discard this pane's unsaved edits"
	_reload.pressed.connect(_reload_disk)
	bar.add_child(_reload)
	add_child(bar)
	_split = HSplitContainer.new()
	_split.size_flags_vertical = SIZE_EXPAND_FILL
	add_child(_split)
	for side in 2:
		var pane := ScrollContainer.new()
		pane.size_flags_horizontal = SIZE_EXPAND_FILL
		pane.size_flags_vertical = SIZE_EXPAND_FILL
		pane.custom_minimum_size.x = UiScale.px(120)
		# Reserve viewport-sized strips outside the full-document CodeEdit.
		# They stay visible even when the document scrolls horizontally.
		var style := StyleBoxEmpty.new()
		style.content_margin_left = UiScale.px(22)
		style.content_margin_right = UiScale.px(20)
		pane.add_theme_stylebox_override("panel", style)
		_split.add_child(pane)
		_panes.append(pane)
		var code := CodeEdit.new()
		code.editable = side == 1
		code.gutters_draw_line_numbers = true
		code.gutters_line_numbers_min_digits = 4
		code.scroll_fit_content_height = true
		code.scroll_fit_content_width = true
		code.wrap_mode = TextEdit.LINE_WRAPPING_NONE
		code.highlight_current_line = side == 1
		code.add_theme_color_override("font_readonly_color", code.get_theme_color("font_color"))
		pane.add_child(code)
		_codes.append(code)
		pane.resized.connect(_align.call_deferred)
		pane.get_h_scroll_bar().value_changed.connect(_sync_scroll.bind(side, true))
		pane.get_v_scroll_bar().value_changed.connect(_sync_scroll.bind(side, false))
	_codes[1].text_changed.connect(_edited)
	_codes[1].caret_changed.connect(_follow_caret.call_deferred)
	_codes[1].gui_input.connect(_on_input)
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.wait_time = SAVE_DELAY
	_timer.timeout.connect(_save_after_pause)
	add_child(_timer)


func _ready() -> void:
	_instances.append(self)
	for side in 2:
		var code := _codes[side]
		var layer := Highlights.new()
		layer.workspace_side = _highlights.size()
		layer.attach(code, true)
		_highlights.append(layer)
		# Runtime-only UI: an overlay must draw after the overflowing CodeEdit.
		# Top-level Controls are excluded from ScrollContainer content sizing.
		var navigation := NavigationLayer.new()
		navigation.view = self
		navigation.side = side
		navigation.set_as_top_level(true)
		navigation.z_as_relative = false
		navigation.clip_contents = true
		_panes[side].add_child(navigation)
		_navigation.append(navigation)


static func flush_all() -> bool:
	for view in _instances.duplicate():
		if is_instance_valid(view) and not view.flush():
			return false
	return true


static func dirty_paths() -> PackedStringArray:
	var paths := PackedStringArray()
	for view in _instances:
		if is_instance_valid(view) and view.is_dirty():
			paths.append(ProjectSettings.localize_path(view._absolute_path))
	return paths


static func apply_auto_save_policy() -> void:
	for view in _instances:
		if is_instance_valid(view):
			view._update_status()
			if Settings.get_value("auto_save_scripts", true) and view.is_dirty():
				view._timer.start()


static func native_dirty(path: String) -> bool:
	var local := ProjectSettings.localize_path(path)
	if local in EditorInterface.get_unsaved_scenes():
		return true
	var scripts := EditorInterface.get_script_editor()
	return scripts != null and local in scripts.get_unsaved_files()


## Existing, project-local, losslessly decoded text only; binaries stay in DiffView.
static func eligible(context: Dictionary) -> bool:
	if not context.get("editable_worktree", false) or context.get("new_rev", "") != "" or context.get("repo", null) == null:
		return false
	var path: String = context["repo"].get_repo_root().path_join(context.get("path", "")).simplify_path()
	var local := ProjectSettings.localize_path(path)
	if not local.begins_with("res://") or not FileAccess.file_exists(path):
		return false
	var folder := DirAccess.open(path.get_base_dir())
	if folder == null or folder.is_link(path.get_file()):
		return false
	return is_text(FileAccess.get_file_as_bytes(path)) and is_text(context["repo"].get_file_bytes(context.get("old_rev", "HEAD"), context.get("old_path", context["path"])))


static func is_text(bytes: PackedByteArray) -> bool:
	if bytes.size() > MAX_BYTES or bytes.count(10) > MAX_LINES:
		return false
	var i := 0
	while i < bytes.size():
		var first: int = bytes[i]
		if first < 128:
			if first < 32 and first not in [9, 10, 13]:
				return false
			i += 1
			continue
		var length := 2 if first >= 194 and first <= 223 else (3 if first >= 224 and first <= 239 else (4 if first >= 240 and first <= 244 else 0))
		if length == 0 or i + length > bytes.size():
			return false
		for j in range(1, length):
			if bytes[i + j] < 128 or bytes[i + j] > 191:
				return false
		var second: int = bytes[i + 1]
		if (first == 224 and second < 160) or (first == 237 and second >= 160) or (first == 240 and second < 144) or (first == 244 and second > 143):
			return false
		i += length
	return true


static func decode(bytes: PackedByteArray) -> String:
	var payload := bytes.slice(3) if bytes.size() >= 3 and bytes.slice(0, 3) == PackedByteArray([239, 187, 191]) else bytes
	return payload.get_string_from_utf8().replace("\r\n", "\n")


func show_file(context: Dictionary) -> void:
	_repo = context["repo"]
	_relative_path = context["path"]
	var absolute: String = _repo.get_repo_root().path_join(_relative_path).simplify_path()
	var disk := FileAccess.get_file_as_bytes(absolute)
	_loading = true
	if absolute != _absolute_path:
		_absolute_path = absolute
		_adopt_baseline(disk)
		_codes[1].text = decode(disk)
		_codes[1].tag_saved_version()
		_restore_draft()
		for pane in _panes:
			pane.scroll_horizontal = 0
			pane.scroll_vertical = 0
	elif not is_dirty() and disk != _baseline:
		_adopt_baseline(disk)
		EditorOpen._replace_text_keeping_view(_codes[1], decode(disk))
		_codes[1].tag_saved_version()
	_codes[0].text = decode(_repo.get_file_bytes(context.get("old_rev", "HEAD"), context.get("old_path", _relative_path)))
	_codes[1].editable = true
	_loading = false
	var language := SyntaxColors.language_for(_relative_path) if Settings.get_value("diff_syntax", true) else ""
	for code in _codes:
		var highlighter := WorkingSyntax.new()
		highlighter.language = language
		highlighter.default_color = Color(0.78, 0.78, 0.8)
		highlighter.side = _codes.find(code)
		code.syntax_highlighter = highlighter
	_update_diff()
	_update_status()


func is_dirty() -> bool:
	return not _absolute_path.is_empty() and is_instance_valid(_codes[1]) and _codes[1].text != decode(_baseline)


func _adopt_baseline(bytes: PackedByteArray) -> void:
	_baseline = bytes
	_bom = bytes.size() >= 3 and bytes.slice(0, 3) == PackedByteArray([239, 187, 191])
	_crlf = bytes.get_string_from_utf8().contains("\r\n")
	_block_reason = ""
	_announced = ""


func _edited() -> void:
	if _loading:
		return
	_update_status()
	_regions.clear() # Never expose clickable stale ranges while recomputing.
	_navigation_signature = ""
	for pane in _panes:
		pane.queue_redraw()
	_timer.start()
	_align.call_deferred()


func _save_after_pause() -> void:
	_update_diff()
	if Settings.get_value("auto_save_scripts", true):
		flush()


func _encoded() -> PackedByteArray:
	var text := _codes[1].text.replace("\r\n", "\n")
	if _crlf:
		text = text.replace("\n", "\r\n")
	var bytes := PackedByteArray([239, 187, 191]) if _bom else PackedByteArray()
	bytes.append_array(text.to_utf8_buffer())
	return bytes


## Compare bytes immediately before an atomic replacement. Never touch the index.
func flush() -> bool:
	if _saving:
		return false
	if not is_dirty():
		if not _absolute_path.is_empty():
			_clear_recovery()
		return true
	_timer.stop()
	if native_dirty(_absolute_path):
		return _blocked("Save or discard this file's edits in Godot's Script/Scene editor first. Both drafts have been kept.")
	if not FileAccess.file_exists(_absolute_path):
		return _blocked("The file was deleted outside this comparison. Your draft is kept; restore the file or use Reload.")
	var disk := FileAccess.get_file_as_bytes(_absolute_path)
	var bytes := _encoded()
	if disk != _baseline and disk != bytes:
		return _blocked("The file changed on disk. Your draft is kept; use Reload to discard it and load the disk version.")
	if disk != bytes:
		var temporary: String = _repo._temp_dir().path_join("working-save-%d.tmp" % get_instance_id())
		var file := FileAccess.open(temporary, FileAccess.WRITE)
		if file == null:
			return _blocked("Couldn't create the temporary file for saving.")
		file.store_buffer(bytes)
		var write_error := file.get_error()
		file.close()
		if write_error != OK or FileAccess.get_file_as_bytes(temporary) != bytes:
			DirAccess.remove_absolute(temporary)
			return _blocked("Couldn't write the complete file. The original is unchanged.")
		if FileAccess.get_file_as_bytes(_absolute_path) != disk or native_dirty(_absolute_path):
			DirAccess.remove_absolute(temporary)
			return _blocked("The file changed while saving. Your draft is kept.")
		var permissions := FileAccess.get_unix_permissions(_absolute_path)
		if permissions >= 0:
			FileAccess.set_unix_permissions(temporary, permissions)
		var replaced := DirAccess.rename_absolute(temporary, _absolute_path)
		if replaced != OK:
			DirAccess.remove_absolute(temporary)
			return _blocked("Couldn't replace the working file (error %d). Check its permissions." % replaced)
	_saving = true
	_adopt_baseline(bytes)
	_codes[1].tag_saved_version()
	_clear_recovery()
	# Keep clean native script/text tabs in sync, while their Undo stays usable.
	EditorOpen.sync_open_scripts()
	if _relative_path.get_extension() not in ["tscn", "tres", "scn", "res"]:
		EditorInterface.get_resource_filesystem().update_file(ProjectSettings.localize_path(_absolute_path))
	_saving = false
	_update_diff()
	_update_status()
	file_saved.emit()
	return true


func _blocked(reason: String) -> bool:
	_block_reason = reason
	if reason != _announced:
		_announced = reason
		GitCli.record([], 1, _relative_path + "\n" + reason, "Comparison save paused")
	_save_recovery()
	_update_status()
	return false


func _update_status() -> void:
	var dirty := is_dirty()
	var automatic: bool = Settings.get_value("auto_save_scripts", true)
	_status.text = "Not saved · " + _block_reason if dirty and not _block_reason.is_empty() else (("Saving…" if automatic else "Unsaved · Ctrl/Cmd+S to save") if dirty else ("Working file · editable · auto-save" if automatic else "Working file · editable · Ctrl/Cmd+S to save"))
	_status.tooltip_text = _status.text + "\nFull file shown. Left is read-only; hunk actions and collapsed context are disabled while editing."
	_status.modulate = Color(1, 0.72, 0.5) if dirty and not _block_reason.is_empty() else Color(1, 1, 1, 0.7)
	_save.disabled = not dirty


func _reload_disk() -> void:
	if is_dirty() and not await Dialogs.confirm(self, "Reload Working File", "Discard this comparison's unsaved edits and load the current file from disk?", "Reload"):
		return
	if not FileAccess.file_exists(_absolute_path):
		Dialogs.error(self, "Reload failed", "The file no longer exists. Your draft has been kept.")
		return
	var disk := FileAccess.get_file_as_bytes(_absolute_path)
	if not is_text(disk):
		Dialogs.error(self, "Reload failed", "The file is no longer supported text. Your draft has been kept.")
		return
	_loading = true
	_adopt_baseline(disk)
	_codes[1].text = decode(disk)
	_codes[1].tag_saved_version()
	_loading = false
	_clear_recovery()
	_update_diff()
	_update_status()


func _update_diff() -> void:
	if _repo == null or _absolute_path.is_empty() or _highlights.size() != 2:
		return
	_regions = DiffHunks.parse_regions(_repo.diff_texts(_codes[0].text, _codes[1].text))
	var layers := [{}, {}]
	for region: Dictionary in _regions:
		var first: int = maxi(0, region["new_start"] - 1)
		var current := PackedStringArray()
		for line in range(first, mini(first + region["new_count"], _codes[1].get_line_count())):
			current.append(_codes[1].get_line(line))
		var changed := InlineDiff.build(region["old_lines"], current)
		for side in 2:
			var rows: Array = changed["old" if side == 0 else "new"]
			var start: int = maxi(0, region["old_start" if side == 0 else "new_start"] - 1)
			for offset in rows.size():
				layers[side][start + offset] = rows[offset]
	for side in 2:
		_highlights[side].set_rows(layers[side])
		if _codes[side].syntax_highlighter is WorkingSyntax:
			_codes[side].syntax_highlighter.changed_lines = layers[side]
			_codes[side].syntax_highlighter.clear_highlighting_cache()
		_panes[side].queue_redraw()
	_navigation_signature = ""
	_align.call_deferred()


func _align() -> void:
	if not is_inside_tree() or not visible:
		return
	# Reset overrides before measuring, then retain equal pixel ranges on both sides.
	for code in _codes:
		code.custom_minimum_size = Vector2.ZERO
	var height := maxf(_codes[0].get_minimum_size().y, _codes[1].get_minimum_size().y)
	var overflow := 0.0
	var widths := []
	for side in 2:
		var width := _panes[side].size.x - UiScale.px(42) - (_panes[side].get_v_scroll_bar().size.x if _panes[side].get_v_scroll_bar().visible else 0.0)
		widths.append(width)
		overflow = maxf(overflow, _codes[side].get_minimum_size().x - width)
	for side in 2:
		_codes[side].custom_minimum_size = Vector2(widths[side] + maxf(0.0, overflow), height)
		_panes[side].get_minimum_size()
		_panes[side].queue_sort()


func _sync_scroll(value: float, side: int, horizontal: bool) -> void:
	if _syncing:
		return
	_syncing = true
	if horizontal:
		_panes[1 - side].get_h_scroll_bar().value = value
	else:
		var height := float(_codes[side].get_line_height())
		var line := value / height
		var mapped := map_line(line, side)
		_panes[1 - side].get_v_scroll_bar().value = mapped * height
	_syncing = false
	for pane in _panes:
		pane.queue_redraw()


func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	var signature := str([_panes[0].size, _panes[1].size, _panes[0].global_position, _panes[1].global_position, _panes[0].scroll_vertical, _panes[1].scroll_vertical])
	if signature != _navigation_signature:
		_navigation_signature = signature
		for side in _navigation.size():
			var depth := 1
			var ancestor: Node = _panes[side]
			while ancestor != null:
				if ancestor is CanvasItem:
					depth += ancestor.z_index
					if not ancestor.z_as_relative:
						break
				ancestor = ancestor.get_parent()
			_navigation[side].z_index = mini(4095, depth)
			_navigation[side].global_position = _panes[side].global_position
			_navigation[side].size = _panes[side].size
			_navigation[side].queue_redraw()


func _overview_rect(side: int) -> Rect2:
	return Rect2(_panes[side].size.x - UiScale.px(18), 0, UiScale.px(16), maxf(1, _panes[side].size.y - UiScale.px(16)))


func _range(region: Dictionary, side: int) -> Vector2i:
	var count: int = region["old_count" if side == 0 else "new_count"]
	var start: int = region["old_start" if side == 0 else "new_start"]
	return Vector2i(maxi(0, start - 1 if count > 0 else start), count)


func _draw_navigation(side: int, canvas: Control) -> void:
	var pane := _panes[side]
	var code := _codes[side]
	var overview := _overview_rect(side)
	var line_height := float(code.get_line_height())
	var total := float(maxi(1, code.get_line_count()))
	canvas.draw_rect(Rect2(0, 0, UiScale.px(22), pane.size.y), Color(0.1, 0.1, 0.1))
	canvas.draw_rect(Rect2(pane.size.x - UiScale.px(20), 0, UiScale.px(20), pane.size.y), Color(0.1, 0.1, 0.1))
	canvas.draw_rect(overview, Color(1, 1, 1, 0.04))
	var font := code.get_theme_font("font")
	var font_size := code.get_theme_font_size("font_size")
	var top := code.get_theme_stylebox("normal" if code.editable else "read_only").get_margin(SIDE_TOP)
	for region: Dictionary in _regions:
		var span := _range(region, side)
		var removed: bool = side == 0 or span.y == 0
		var color := Palette.REMOVED_TEXT if removed else Palette.ADDED_TEXT
		var marker_y := minf(overview.end.y - UiScale.px(3), overview.position.y + span.x / total * overview.size.y)
		canvas.draw_rect(Rect2(overview.position.x + 2, marker_y, overview.size.x - 4, maxf(UiScale.px(3), span.y / total * overview.size.y)), color)
		var y := top + span.x * line_height - pane.scroll_vertical
		var end := y + maxi(1, span.y) * line_height
		var clipped := Rect2(UiScale.px(2), maxf(0, y), UiScale.px(3), maxf(0, minf(overview.end.y, end) - maxf(0, y)))
		if clipped.has_area():
			canvas.draw_rect(clipped, color)
		if span.y == 0:
			if y >= 0 and y < overview.end.y:
				canvas.draw_line(Vector2(2, y + 1), Vector2(UiScale.px(20), y + 1), color, UiScale.px(2))
		else:
			for line in range(maxi(span.x, int(pane.scroll_vertical / line_height)), mini(span.x + span.y, int((pane.scroll_vertical + overview.end.y) / line_height) + 1)):
				var baseline := top + (line + 1) * line_height - pane.scroll_vertical - font.get_descent(font_size)
				if baseline >= font.get_ascent(font_size) and baseline <= overview.end.y:
					canvas.draw_string(font, Vector2(UiScale.px(7), baseline), "−" if removed else "+", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
	var first := clampf(pane.scroll_vertical / line_height / total * overview.size.y, 0, maxf(0, overview.size.y - UiScale.px(3)))
	var height := minf(overview.size.y - first, pane.size.y / line_height / total * overview.size.y)
	canvas.draw_rect(Rect2(overview.position.x, first, overview.size.x, maxf(UiScale.px(3), height)), Color(0.7, 0.78, 1, 0.65), false, 1)


func _navigation_input(event: InputEvent, side: int) -> void:
	if event is not InputEventMouseButton or event.button_index != MOUSE_BUTTON_LEFT or not event.pressed:
		return
	var overview := _overview_rect(side)
	var pane := _panes[side]
	var line := -1.0
	if overview.has_point(event.position):
		line = (event.position.y - overview.position.y) / overview.size.y * _codes[side].get_line_count()
	elif event.position.x < UiScale.px(22):
		line = (event.position.y + pane.scroll_vertical) / _codes[side].get_line_height()
	else:
		return
	var nearest := -1
	var distance := INF
	for region: Dictionary in _regions:
		var span := _range(region, side)
		var delta := absf(line - clampf(line, span.x, span.x + span.y))
		if delta < distance:
			distance = delta
			nearest = span.x
	if nearest >= 0:
		# Navigation changes scroll only, preserving selection, caret and Undo.
		pane.scroll_vertical = maxi(0, int(nearest * _codes[side].get_line_height() - pane.size.y * 0.3))
		if side < _navigation.size():
			_navigation[side].accept_event()


## Nearest corresponding source line, without inserting editable phantom rows.
func map_line(line: float, side: int) -> float:
	var delta := 0.0
	for region: Dictionary in _regions:
		var source: int = region["old_start" if side == 0 else "new_start"]
		var count: int = region["old_count" if side == 0 else "new_count"]
		var target: int = region["new_start" if side == 0 else "old_start"]
		var other_count: int = region["new_count" if side == 0 else "old_count"]
		var start := float(source - 1 if count > 0 else source)
		var to := float(target - 1 if other_count > 0 else target)
		if line < start:
			break
		if count > 0 and line < start + count:
			return maxf(0.0, to + minf(line - start, maxf(0.0, other_count - 1)))
		delta = to + other_count - start - count
	return maxf(0.0, line + delta)


func scroll_to_line(line: int) -> void:
	_codes[1].set_caret_line(clampi(line - 1, 0, _codes[1].get_line_count() - 1))
	_follow_caret()


func _follow_caret() -> void:
	if _loading or not visible:
		return
	var code := _codes[1]
	var rect := Rect2(code.get_rect_at_line_column(code.get_caret_line(), code.get_caret_column()))
	if rect.size.y <= 0:
		return
	var pane := _panes[1]
	if rect.position.y < pane.scroll_vertical:
		pane.scroll_vertical = int(rect.position.y)
	elif rect.end.y > pane.scroll_vertical + pane.size.y - 20:
		pane.scroll_vertical = int(rect.end.y - pane.size.y + 24)
	if rect.position.x < pane.scroll_horizontal:
		pane.scroll_horizontal = int(rect.position.x)
	elif rect.end.x > pane.scroll_horizontal + pane.size.x - 20:
		pane.scroll_horizontal = int(rect.end.x - pane.size.x + 24)


func _on_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_S and (event.ctrl_pressed or event.meta_pressed):
		_codes[1].accept_event()
		if not flush():
			Dialogs.error(self, "Comparison save paused", _block_reason)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and is_inside_tree() and Settings.get_value("auto_save_scripts", true):
		flush()


func _recovery_path() -> String:
	return _repo._temp_dir().path_join("working-draft-" + _absolute_path.sha256_text() + ".json")


func _save_recovery() -> void:
	if not is_dirty():
		return
	var file := FileAccess.open(_recovery_path(), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"path": _absolute_path, "baseline": Marshalls.raw_to_base64(_baseline), "text": _codes[1].text}))
		file.close()


func _restore_draft() -> void:
	if not FileAccess.file_exists(_recovery_path()):
		return
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(_recovery_path()))
	if data is Dictionary and data.get("path", "") == _absolute_path and data.get("text", null) is String:
		_adopt_baseline(Marshalls.base64_to_raw(data.get("baseline", "")))
		_codes[1].text = data["text"]
		_block_reason = "Recovered unsaved comparison edits. Review them, then Save or Reload."


func _clear_recovery() -> void:
	if FileAccess.file_exists(_recovery_path()):
		DirAccess.remove_absolute(_recovery_path())


func _exit_tree() -> void:
	_instances.erase(self)
	if is_dirty() and (not Settings.get_value("auto_save_scripts", true) or not flush()):
		_save_recovery()
	for layer in _highlights:
		layer.detach()
	_highlights.clear()


class NavigationLayer:
	extends Control
	var view: Control
	var side := 0
	func _has_point(point: Vector2) -> bool:
		return Rect2(Vector2.ZERO, size).has_point(point) and (point.x < UiScale.px(22) or point.x >= size.x - UiScale.px(20))
	func _draw() -> void:
		if is_instance_valid(view) and view.is_visible_in_tree():
			view._draw_navigation(side, self)
	func _gui_input(event: InputEvent) -> void:
		view._navigation_input(event, side)
	func _get_tooltip(_point: Vector2) -> String:
		return "Click a change sign or overview marker to reveal that change. The outline shows the current viewport."


class WorkingSyntax:
	extends SyntaxHighlighter
	var language := ""
	var default_color := Color.WHITE
	var side := 0
	var changed_lines := {}
	func _get_line_syntax_highlighting(line: int) -> Dictionary:
		var base := default_color
		if changed_lines.has(line):
			base = Palette.REMOVED_TEXT if side == 0 else Palette.ADDED_TEXT
			if not language.is_empty():
				base = base.lerp(Color(0.9, 0.9, 0.92), 0.55)
		var result := {0: {"color": base}}
		for span in SyntaxColors.spans(get_text_edit().get_line(line), language):
			result[span[0]] = {"color": span[2]}
			result[span[0] + span[1]] = {"color": base}
		return result
