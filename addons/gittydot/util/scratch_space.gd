extends RefCounted
## Project-local scratch, excluded through the repository's resolved info/exclude.
const Cli := preload("res://addons/gittydot/util/git_cli.gd")
static var _owners := {}
static var _tracked_checks := {}
static var _verified := {}
static var last_error := ""


static func prepare(project: String) -> String:
	last_error = ""
	project = project.simplify_path().trim_suffix("/")
	var temp := project.path_join(project.get_file() + "-temp-chatgpt/gittydot")
	var marker := project
	while not DirAccess.dir_exists_absolute(marker.path_join(".git")) and not FileAccess.file_exists(marker.path_join(".git")):
		var parent := marker.get_base_dir()
		if parent == marker or parent.is_empty():
			marker = ""
			break
		marker = parent
	if not marker.is_empty():
		var git_marker := marker.path_join(".git")
		var identity := git_marker + (FileAccess.get_file_as_string(git_marker) if FileAccess.file_exists(git_marker) else "")
		if not _owners.has(identity):
			var exclude := Cli.run(marker, ["rev-parse", "--git-path", "info/exclude"])
			var index := Cli.run(marker, ["rev-parse", "--git-path", "index"])
			if exclude["exit_code"] != 0 or index["exit_code"] != 0:
				return _fail("Couldn't resolve GittyDot's local scratch exclusion.")
			_owners[identity] = {"exclude": _absolute(marker, exclude["text"].strip_edges()), "index": _absolute(marker, index["text"].strip_edges())}
		var owner: Dictionary = _owners[identity]
		if not exclude_directory(marker, temp, owner["exclude"], owner["index"]):
			return ""
	if DirAccess.make_dir_recursive_absolute(temp) != OK:
		return _fail("Couldn't create GittyDot scratch directory: " + temp)
	var ignore := temp.path_join(".gdignore")
	if not FileAccess.file_exists(ignore):
		var file := FileAccess.open(ignore, FileAccess.WRITE)
		if file == null:
			return _fail("Couldn't protect the scratch directory from Godot imports: " + temp)
		file.close()
	return temp


static func _absolute(root: String, path: String) -> String:
	return path.simplify_path() if path.is_absolute_path() else root.path_join(path).simplify_path()


static func exclude_directory(root: String, temp: String, exclude: String, index: String) -> bool:
	if not temp.begins_with(root.trim_suffix("/") + "/"):
		_fail("Scratch directory must belong to its resolved repository.")
		return false
	var relative := temp.substr(root.trim_suffix("/").length() + 1)
	var stamp := str(FileAccess.get_modified_time(index)) + ":" + str(_size(index))
	var key := index + "|" + relative
	if _tracked_checks.get(key, "") != stamp:
		var tracked := Cli.run(root, ["ls-files", "--", ":(literal)" + relative + "/"])
		if tracked["exit_code"] != 0 or not tracked["text"].is_empty():
			_fail("Scratch files are already tracked, or the index couldn't be checked. Review " + relative + "; GittyDot will not untrack or delete them.")
			return false
		_tracked_checks[key] = stamp
	var rule := "/"
	for character in relative:
		if character in ["\\", " ", "#", "!", "*", "?", "[", "]"]:
			rule += "\\"
		rule += character
	rule += "/"
	var existing := FileAccess.get_file_as_bytes(exclude) if FileAccess.file_exists(exclude) else PackedByteArray()
	var ignore_signature := ""
	var parent := temp
	while parent.begins_with(root):
		var ignore := parent.path_join(".gitignore")
		if FileAccess.file_exists(ignore):
			ignore_signature += ignore + "|" + FileAccess.get_file_as_bytes(ignore).hex_encode() + "|"
		if parent == root:
			break
		parent = parent.get_base_dir()
	var signature := existing.hex_encode() + "|" + ignore_signature
	var verify_key := exclude + "|" + temp
	if _verified.get(verify_key, "") == signature:
		return true
	# Compare bytes: preserve unrelated entries, comments and their encoding.
	if not ("0a" + existing.hex_encode() + "0a").contains(("\n" + rule + "\n").to_utf8_buffer().hex_encode()):
		if DirAccess.make_dir_recursive_absolute(exclude.get_base_dir()) != OK:
			_fail("Couldn't create Git's local exclusion directory.")
			return false
		var file := FileAccess.open(exclude, FileAccess.READ_WRITE if FileAccess.file_exists(exclude) else FileAccess.WRITE_READ)
		if file == null:
			_fail("Couldn't exclude GittyDot scratch files in " + exclude)
			return false
		file.seek_end()
		file.store_string(("\n" if not existing.is_empty() and existing[-1] != 10 else "") + rule + "\n")
		var error := file.get_error()
		file.close()
		if error != OK:
			_fail("Couldn't write the complete local scratch exclusion.")
			return false
	# A higher-priority .gitignore negation can override info/exclude. Refuse
	# scratch rather than silently making a recovery draft committable.
	if Cli.run(root, ["check-ignore", "--no-index", "--quiet", "--", relative + "/.gittydot-probe"])["exit_code"] != 0:
		_fail("Git did not exclude the scratch directory. Check conflicting ignore rules for " + relative)
		return false
	_verified[verify_key] = FileAccess.get_file_as_bytes(exclude).hex_encode() + "|" + ignore_signature
	return true


static func _size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ) if FileAccess.file_exists(path) else null
	return file.get_length() if file != null else -1


static func _fail(message: String) -> String:
	last_error = message
	Cli.record([], -1, message, "Scratch operation paused")
	return ""
