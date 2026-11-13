@tool
extends CodeEdit
## A projected diff document. Padding exists only here; the child CodeEdit owns
## the real source and its native Undo history. Saving/copying use source offsets.

signal source_changed
signal source_caret_changed

var _source := CodeEdit.new()
var source_rows: Array = [] # Display row -> source line, or -1 for a gap.
var _source_row_lookup := {}
var _next_source: Array = []
var _line_offsets: Array = []
var _last_text := ""
var _rendering := false
var _number_gutter := -1
var _native_menu := Callable()


func _init() -> void:
	_source.hide()
	add_child(_source)
	caret_multiple = false
	drag_and_drop_selection_enabled = false
	gutters_draw_line_numbers = false
	add_gutter()
	_number_gutter = get_gutter_count() - 1
	set_gutter_name(_number_gutter, "gittydot_source_numbers")
	set_gutter_type(_number_gutter, TextEdit.GUTTER_TYPE_STRING)
	text_changed.connect(_display_changed)
	caret_changed.connect(_caret_changed)
	gui_input.connect(_source_input)
	var menu := get_menu()
	for connection: Dictionary in menu.get_signal_connection_list("id_pressed"):
		var callback: Callable = connection["callable"]
		if callback.get_object() == self:
			_native_menu = callback
			menu.id_pressed.disconnect(callback)
			break
	menu.id_pressed.connect(_menu_action)
	menu.about_to_popup.connect(_update_menu)
	set_source_text("")


func get_source_text() -> String:
	# TextEdit defers text_changed. Stage/Save/file-switch actions can run in
	# the same frame as an edit, so consume that edit before exposing source.
	if not _rendering and text != _last_text:
		_display_changed()
	return _source.text


func set_source_text(value: String, reset_history := true) -> void:
	var caret := Vector2i(_source.get_caret_line(), _source.get_caret_column())
	if reset_history:
		_source.text = value
	elif value != _source.text:
		_source.deselect()
		_source.begin_complex_operation()
		_source.remove_text(0, 0, _source.get_line_count() - 1, _source.get_line(_source.get_line_count() - 1).length())
		_source.set_caret_line(0)
		_source.set_caret_column(0)
		_source.insert_text_at_caret(value)
		_source.end_complex_operation()
		_source.set_caret_line(mini(caret.x, _source.get_line_count() - 1))
		_source.set_caret_column(caret.y)
	set_alignment(range(_source.get_line_count()))


func mark_source_saved() -> void:
	_source.tag_saved_version()
	tag_saved_version()


func source_to_row(line: int) -> int:
	return _source_row_lookup.get(clampi(line, 0, _source.get_line_count() - 1), maxi(0, source_rows.size() - 1))


func row_to_source(row: int) -> int:
	row = clampi(row, 0, maxi(0, source_rows.size() - 1))
	return mini(_next_source[row], _source.get_line_count() - 1)


func set_source_caret(line: int, column := 0) -> void:
	_source.set_caret_line(clampi(line, 0, _source.get_line_count() - 1))
	_source.set_caret_column(column)
	set_caret_line(source_to_row(_source.get_caret_line()))
	set_caret_column(_source.get_caret_column())


func set_alignment(rows: Array) -> void:
	var caret := Vector2i(_source.get_caret_line(), _source.get_caret_column())
	var selection := _source_selection() if has_selection() else PackedInt32Array()
	var lines := _source.text.split("\n")
	var projected := PackedStringArray()
	for line: int in rows:
		projected.append(lines[line] if line >= 0 and line < lines.size() else "")
	if projected.is_empty():
		projected.append("")
		rows = [-1]
	var value := "\n".join(projected)
	_rendering = true
	source_rows = rows.duplicate()
	_source_row_lookup.clear()
	_next_source.resize(source_rows.size())
	var next := lines.size()
	for row in range(source_rows.size() - 1, -1, -1):
		if source_rows[row] >= 0:
			next = source_rows[row]
			_source_row_lookup[next] = row
		_next_source[row] = next
	_line_offsets.clear()
	var offset := 0
	for line in lines:
		_line_offsets.append(offset)
		offset += line.length() + 1
	if text != value:
		text = value
	_last_text = value
	var font := get_theme_font("font")
	var font_size := get_theme_font_size("font_size")
	set_gutter_width(_number_gutter, int(font.get_string_size(str(_source.get_line_count()) + " ", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x))
	for row in source_rows.size():
		set_line_gutter_text(row, _number_gutter, str(source_rows[row] + 1) if source_rows[row] >= 0 else "")
		set_line_gutter_item_color(row, _number_gutter, get_theme_color("line_number_color"))
	set_caret_line(source_to_row(caret.x))
	set_caret_column(caret.y)
	if not selection.is_empty():
		var from := _position(_source.text, selection[0])
		var to := _position(_source.text, selection[1])
		select(source_to_row(from.x), from.y, source_to_row(to.x), to.y)
	_rendering = false
	_update_menu()


func _offset_at(row: int, column: int) -> int:
	if row >= 0 and row < source_rows.size() and _next_source[row] >= _source.get_line_count():
		return _source.text.length()
	var line := row_to_source(row)
	return _line_offsets[line] + (clampi(column, 0, _source.get_line(line).length()) if row >= 0 and row < source_rows.size() and source_rows[row] >= 0 else 0)


static func _position(value: String, offset: int) -> Vector2i:
	var before := value.left(offset)
	var line := before.count("\n")
	return Vector2i(line, before.length() - before.rfind("\n") - 1)


func _source_selection() -> PackedInt32Array:
	return PackedInt32Array([_offset_at(get_selection_from_line(), get_selection_from_column()), _offset_at(get_selection_to_line(), get_selection_to_column())])


func selected_source_text() -> String:
	if not has_selection():
		return ""
	var selection := _source_selection()
	return _source.text.substr(selection[0], maxi(0, selection[1] - selection[0]))


func _display_changed() -> void:
	if _rendering or text == _last_text:
		return
	var before := _last_text
	var after := text
	var first := 0
	while first < mini(before.length(), after.length()) and before[first] == after[first]:
		first += 1
	var tail := 0
	while tail < mini(before.length(), after.length()) - first and before[before.length() - tail - 1] == after[after.length() - tail - 1]:
		tail += 1
	var start := _position(before, first)
	var finish := _position(before, before.length() - tail)
	var from := _offset_at(start.x, start.y)
	var to := _offset_at(finish.x, finish.y)
	var inserted := after.substr(first, after.length() - first - tail)
	var raw_before := _source.text
	var from_position := _position(raw_before, from)
	var to_position := _position(raw_before, to)
	# Typing into a spacer creates a real source line; deleting only a spacer
	# changes no source. Padding itself is never copied into the replacement.
	var spacer_line: bool = start.x < source_rows.size() and source_rows[start.x] < 0 and from == to and not inserted.is_empty()
	var caret_offset := from + inserted.length()
	if spacer_line:
		if from < raw_before.length() and not inserted.ends_with("\n"):
			inserted += "\n"
		elif from == raw_before.length() and not raw_before.is_empty() and not raw_before.ends_with("\n"):
			inserted = "\n" + inserted
			caret_offset += 1
	_source.deselect()
	_source.begin_complex_operation()
	_source.remove_text(from_position.x, from_position.y, to_position.x, to_position.y)
	_source.set_caret_line(from_position.x)
	_source.set_caret_column(from_position.y)
	_source.insert_text_at_caret(inserted)
	_source.end_complex_operation()
	var caret := _position(_source.text, caret_offset)
	_source.set_caret_line(caret.x)
	_source.set_caret_column(caret.y)
	# Keep old spacer anchors until the debounced diff supplies fresh alignment.
	var gap_lines := {}
	var shift := inserted.count("\n") - raw_before.substr(from, to - from).count("\n")
	for row in source_rows.size():
		if source_rows[row] < 0:
			var line: int = _next_source[row]
			var anchor := clampi(line + (shift if line > from_position.x else 0), 0, _source.get_line_count())
			gap_lines[anchor] = gap_lines.get(anchor, 0) + 1
	var rows := []
	for line in _source.get_line_count() + 1:
		for gap in gap_lines.get(line, 0):
			rows.append(-1)
		if line < _source.get_line_count():
			rows.append(line)
	set_alignment(rows)
	if raw_before != _source.text:
		source_changed.emit()
		source_caret_changed.emit()


func _caret_changed() -> void:
	if _rendering or text != _last_text:
		return
	var position := _position(_source.text, _offset_at(get_caret_line(), get_caret_column()))
	if position == Vector2i(_source.get_caret_line(), _source.get_caret_column()):
		return # A deferred projection notification must not scroll back to the caret.
	_source.set_caret_line(position.x)
	_source.set_caret_column(position.y)
	source_caret_changed.emit()


func undo_source() -> void:
	get_source_text()
	_source.undo()
	set_alignment(range(_source.get_line_count()))
	source_changed.emit()
	source_caret_changed.emit()


func redo_source() -> void:
	get_source_text()
	_source.redo()
	set_alignment(range(_source.get_line_count()))
	source_changed.emit()
	source_caret_changed.emit()


func _source_input(event: InputEvent) -> void:
	if event is not InputEventKey or not event.pressed:
		return
	# Indenting a selection edits several disjoint ranges. Apply it to source,
	# so native indentation cannot turn the spacer rows into real blank lines.
	if editable and event.keycode == KEY_TAB and has_selection() and not event.ctrl_pressed and not event.meta_pressed:
		var selection := _source_selection()
		var from := _position(_source.text, selection[0])
		var to := _position(_source.text, selection[1])
		_source.select(from.x, from.y, to.x, to.y)
		if event.shift_pressed:
			_source.unindent_lines()
		else:
			_source.indent_lines()
		set_alignment(range(_source.get_line_count()))
		select(from.x, 0, to.x, _source.get_line(to.x).length())
		source_changed.emit()
		source_caret_changed.emit()
		accept_event()
		return
	if editable and not has_selection() and not event.alt_pressed and not event.ctrl_pressed and not event.meta_pressed and _delete_across_gap(event.keycode):
		accept_event()
		return
	if not (event.ctrl_pressed or event.meta_pressed):
		return
	if event.keycode == KEY_Z and editable:
		redo_source() if event.shift_pressed else undo_source()
	elif event.keycode == KEY_Y and editable:
		redo_source()
	elif event.keycode == KEY_C and has_selection():
		DisplayServer.clipboard_set(selected_source_text())
	elif event.keycode == KEY_X and has_selection() and editable:
		DisplayServer.clipboard_set(selected_source_text())
		delete_selection()
	else:
		return
	accept_event()


func _delete_across_gap(key: int) -> bool:
	var row := get_caret_line()
	var column := get_caret_column()
	var backwards: bool = key == KEY_BACKSPACE and column == 0 and row > 0 and source_rows[row - 1] < 0
	var forwards: bool = key == KEY_DELETE and column == get_line(row).length() and row + 1 < source_rows.size() and source_rows[row + 1] < 0
	if not backwards and not forwards:
		return false
	var offset := _offset_at(row, column)
	var from := _position(_source.text, maxi(0, offset - 1) if backwards else offset)
	var to := _position(_source.text, offset if backwards else mini(_source.text.length(), offset + 1))
	_source.deselect()
	_source.begin_complex_operation()
	_source.remove_text(from.x, from.y, to.x, to.y)
	_source.set_caret_line(from.x)
	_source.set_caret_column(from.y)
	_source.end_complex_operation()
	set_alignment(range(_source.get_line_count()))
	source_changed.emit()
	source_caret_changed.emit()
	return true


func _menu_action(id: int) -> void:
	match id:
		TextEdit.MENU_UNDO: undo_source()
		TextEdit.MENU_REDO: redo_source()
		TextEdit.MENU_COPY: DisplayServer.clipboard_set(selected_source_text())
		TextEdit.MENU_CUT:
			DisplayServer.clipboard_set(selected_source_text())
			delete_selection()
		_:
			if _native_menu.is_valid():
				_native_menu.call(id)


func _update_menu() -> void:
	var menu := get_menu()
	for pair in [[TextEdit.MENU_UNDO, _source.has_undo()], [TextEdit.MENU_REDO, _source.has_redo()]]:
		var index := menu.get_item_index(pair[0])
		if index >= 0:
			menu.set_item_disabled(index, not editable or not pair[1])
