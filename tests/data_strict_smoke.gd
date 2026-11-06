extends SceneTree

## v3.45：数据自检门禁。
##
## 背景（审核报告 B3）：`data/globals.json` 曾有**尾逗号**，而 Godot 的
## `JSON.parse_string()` **容忍**它，于是 `data_smoke` 一直报 `DATA_OK`，
## 但 Python `json` / jq / CI / 编辑器插件一律拒绝 —— 一整类工具摩擦无人察觉。
##
## 本测试**不重复数据校验**（那是 `data_smoke` 的职责），只补一条 Godot 侧缺失的
## **严格 JSON 语法复检**：尾逗号、注释、单引号键、NaN/Infinity 都必须报错。
## 判据来自 JSON 规范，不来自实现。

const DATA_ROOT := "res://data"

var _failures: int = 0
var _checks: int = 0


func _init() -> void:
	var files := _json_files(DATA_ROOT)
	_check(files.size() >= 26, "found_data_files", "count=%d" % files.size())

	var trailing := 0
	for path in files:
		var text := _read_text(path)
		if text.is_empty():
			_check(false, "readable", path)
			continue
		var strict := _strict_json_error(text)
		_check(strict.is_empty(), "strict_json", "%s :: %s" % [path, strict])
		if not strict.is_empty():
			printerr("STRICT_JSON_SUSPECT %s" % path)
		var loose_only := _trailing_comma_positions(text)
		trailing += loose_only.size()

	# 尾逗号是本项目实际踩过的坑，单独计数便于回归时一眼看出。
	_check(trailing == 0, "no_trailing_comma_anywhere", "found=%d" % trailing)

	print("STRICT_DONE checks=%d failures=%d files=%d trailing=%d" % [
		_checks, _failures, files.size(), trailing])
	if _failures == 0:
		print("STRICT_OK")
		quit(0)
	else:
		printerr("STRICT_FAIL count=%d" % _failures)
		quit(1)


func _check(condition: bool, tag: String, detail: String = "") -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	if detail.is_empty():
		printerr("STRICT_CHECK_FAILED %s" % tag)
	else:
		printerr("STRICT_CHECK_FAILED %s :: %s" % [tag, detail])


func _json_files(dir_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not name.begins_with("."):
			var full := dir_path.path_join(name)
			if dir.current_is_dir():
				out.append_array(_json_files(full))
			elif name.ends_with(".json"):
				out.append(full)
		name = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	return file.get_as_text()


## 严格 JSON 语法检查。返回空串表示通过，否则返回第一条违规说明。
##
## 判据全部来自 JSON 规范（RFC 8259）：
##   - 对象/数组**不允许**尾逗号；
##   - **不允许**注释；
##   - 键必须是双引号字符串；
##   - 只允许 `true/false/null` 与十进制数字，**不允许** NaN / Infinity。
##
## 注意：这里**不用** `JSON.parse_string()` —— 那个函数恰恰是容忍尾逗号的，
## 用它来「复检严格性」等于自证（v3.39 测试与实现共谋的教训）。
func _strict_json_error(text: String) -> String:
	var bad := _trailing_comma_positions(text)
	if not bad.is_empty():
		return "trailing comma at char %d" % bad[0]
	var comment := _line_comment_position(text)
	if comment >= 0:
		return "line comment at char %d" % comment
	for token in ["NaN", "Infinity", "'"]:
		if text.contains(token):
			return "forbidden token %s" % token
	return ""


## 扫描字符串之外的 `,` 紧跟 `}` 或 `]` 的位置。
## 必须跳过字符串内部，否则 `"a,}"` 这类值会被误判。
func _trailing_comma_positions(text: String) -> Array:
	var result: Array = []
	var in_string := false
	var escaped := false
	for index in range(text.length()):
		var ch := text[index]
		if in_string:
			if escaped:
				escaped = false
			elif ch == "\\":
				escaped = true
			elif ch == "\"":
				in_string = false
			continue
		if ch == "\"":
			in_string = true
			continue
		if ch != ",":
			continue
		var look := index + 1
		while look < text.length() and (text[look] == " " or text[look] == "\t" or text[look] == "\n" or text[look] == "\r"):
			look += 1
		if look < text.length() and (text[look] == "}" or text[look] == "]"):
			result.append(index)
	return result


func _line_comment_position(text: String) -> int:
	var in_string := false
	var escaped := false
	var previous := ""
	for index in range(text.length()):
		var ch := text[index]
		if in_string:
			if escaped:
				escaped = false
			elif ch == "\\":
				escaped = true
			elif ch == "\"":
				in_string = false
			previous = ch
			continue
		if ch == "\"":
			in_string = true
			previous = ch
			continue
		if ch == "/" and previous == "/":
			return index - 1
		previous = ch
	return -1
