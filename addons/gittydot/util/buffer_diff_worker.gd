extends RefCounted
## One cancellable worker, at most one queued snapshot per tab (32 total).
const Cli := preload("res://addons/gittydot/util/git_cli.gd")
const Hunks := preload("res://addons/gittydot/util/diff_hunks.gd")
signal completed(request: Dictionary, result: Dictionary)
var _pending := {}
var _job: RefCounted
var _current := {}
var _cache := {} # Worker-only immutable OID/path blobs, bounded to 64 entries.
var _stopped := false
var metrics := {"requests": 0, "head_fetches": 0, "diff_launches": 0, "scratch_writes": 0, "worker_usec": 0}


func submit(request: Dictionary) -> void:
	if _stopped:
		return
	_pending[request["key"]] = request.duplicate(true)
	while _pending.size() > 32:
		_pending.erase(_pending.keys()[0])
	_start_next()


func _start_next() -> void:
	if _stopped or _job != null or _pending.is_empty():
		return
	var key: int = _pending.keys()[0]
	var request: Dictionary = _pending[key]
	_pending.erase(key)
	_current = request
	_job = Cli.Job.new()
	_job.finished.connect(_done.bind(request), CONNECT_ONE_SHOT)
	_job.start_task(_compute.bind(request))


func _done(result: Dictionary, request: Dictionary) -> void:
	_job = null
	_current = {}
	if _stopped:
		return
	metrics["requests"] += 1
	for key in ["head_fetches", "diff_launches", "scratch_writes", "worker_usec"]:
		metrics[key] += result.get(key, 0)
	completed.emit(request, result)
	_start_next()


func stop() -> void:
	_stopped = true
	_pending.clear()
	if _job != null:
		_job.abandon()
		if not _job.descendant_discovery_complete:
			Cli.record([], -1, "Parent cancellation attempted; descendant cleanup could not be verified.", "Gutter worker shutdown")
		_job = null
	_cache.clear()
	_current = {}


func busy() -> bool:
	return _job != null or not _pending.is_empty()


func has_request(key: int, signature: String) -> bool:
	return (_current.get("key", -1) == key and _current.get("signature", "") == signature) or (_pending.has(key) and _pending[key]["signature"] == signature)


func _compute(job: RefCounted, request: Dictionary) -> Dictionary:
	var started := Time.get_ticks_usec()
	var result := {"ok": false, "regions": [], "head_fetches": 0, "diff_launches": 0, "scratch_writes": 0, "worker_usec": 0}
	var root: String = request["root"]
	var cache_key: String = root + "|" + request["head"] + "|" + request["path"]
	var baseline: Variant = _cache.get(cache_key)
	var fetched := false
	if baseline == null:
		result["head_fetches"] = 1
		var shown := Cli.execute("git", Cli.argv(root, ["show", (request["head"] if not request["head"].is_empty() else "HEAD") + ":" + request["path"]]), job)
		if shown["exit_code"] == 0:
			baseline = shown["out"].get_string_from_utf8()
			fetched = true
		elif not job.cancelled():
			var status := Cli.execute("git", Cli.argv(root, ["status", "--porcelain=v1", "--", request["path"]]), job)
			if status["exit_code"] != 0:
				return result
			var text: String = status["out"].get_string_from_utf8().strip_edges()
			if text.begins_with("??") or text.begins_with("A"):
				baseline = "" # Never cache absence: a rename/status change can alter it.
				result["missing"] = true
			else:
				result["ok"] = true
				result["missing"] = true
				return result
	if job.cancelled():
		return result
	var stamp := "%d_%d_%d" % [OS.get_process_id(), get_instance_id(), Time.get_ticks_usec()]
	var old_path: String = request["scratch"].path_join("buffer-old-" + stamp + ".tmp")
	var new_path: String = request["scratch"].path_join("buffer-new-" + stamp + ".tmp")
	var paths := [old_path, new_path]
	var written := true
	for pair in [[old_path, _normalized(baseline)], [new_path, request["text"]]]:
		var file := FileAccess.open(pair[0], FileAccess.WRITE)
		if file == null:
			written = false
			break
		file.store_string(pair[1])
		written = written and file.get_error() == OK
		file.close()
		result["scratch_writes"] += 1
	if written and not job.cancelled():
		result["diff_launches"] = 1
		var diff := Cli.execute("git", Cli.argv(root, ["diff", "--no-index", "--no-color", "--no-ext-diff", "-U0", "--", old_path, new_path]), job)
		if diff["exit_code"] in [0, 1] and not job.cancelled():
			result["ok"] = true
			result["regions"] = Hunks.parse_regions(diff["out"].get_string_from_utf8())
			if fetched:
				_cache[cache_key] = baseline
				while _cache.size() > 64:
					_cache.erase(_cache.keys()[0])
	for path: String in paths:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	result["worker_usec"] = Time.get_ticks_usec() - started
	return result


static func _normalized(text: String) -> String:
	text = text.replace("\r\n", "\n")
	return text if text.is_empty() or text.ends_with("\n") else text + "\n"
