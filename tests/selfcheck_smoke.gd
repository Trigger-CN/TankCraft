extends SceneTree

## v3.45 永久门禁：**测试自检**。
##
## 背景（审核报告 B2）：本项目反复栽在同一件事上 —— `_check_*` 验收函数
## **定义了却从未被调用**，于是 `*_OK` 绿灯只覆盖了名义上的断言集合：
##   - v3.44 修 `survival_smoke`：19 个 `_check_*` 里 `_init()` 只调 10 个；
##   - v3.45 审核又查出 `physics_smoke._check_performance()` 从未被调用。
## 两轮都是「人手数一遍」才发现，说明缺的是一条自动门禁。
##
## 判据（与实现无关，只看源码结构）：
##   对 `tests/*.gd` 里每个 `func _check_xxx(` 定义，统计 **同一名字在全文出现的次数**。
##   定义本身占 1 次，因此 **出现次数 < 2 就说明没有任何调用点**。
##   这条判据有个已知盲区：若某函数名恰好作为字符串出现在别处，会被算成 2 次。
##   为了不被这个盲区骗过，本测试**额外**要求名字出现在 `func` 之外的位置，
##   并且不把「只在注释里提到」算作调用（避开 `## ... _check_foo() ...` 这类写法）。
##
## 本门禁不替代跑测试，它只回答一个问题：**这套测试里有没有「睡觉的验收」**。

const TESTS_DIR := "res://tests"
const SELF_NAME := "selfcheck_smoke.gd"

var _failures: int = 0
var _checks: int = 0


func _init() -> void:
	var files := _gd_files(TESTS_DIR)
	_check(files.size() >= 25, "found_test_files", "count=%d" % files.size())

	var total_defs := 0
	var total_called := 0
	var sleeping: Array = []
	for file_name in files:
		if file_name == SELF_NAME:
			continue
		var path := TESTS_DIR.path_join(file_name)
		var text := _read_text(path)
		if text.is_empty():
			_check(false, "readable", path)
			continue
		var definitions := _defined_checks(text)
		total_defs += definitions.size()
		for func_name in definitions:
			var call_sites := _call_site_count(text, func_name)
			if call_sites > 0:
				total_called += 1
			else:
				sleeping.append("%s::%s" % [file_name, func_name])

	_check(sleeping.is_empty(), "no_sleeping_checks", "sleeping=%s" % str(sleeping))
	for entry in sleeping:
		printerr("SELFCHECK_UNCALLED %s" % entry)

	# 反向要求：门禁自己必须真的看过东西，否则「全绿」没有意义。
	_check(total_defs >= 120, "definition_scan_not_empty", "defs=%d" % total_defs)

	print("SELFCHECK_DONE checks=%d failures=%d files=%d defs=%d called=%d" % [
		_checks, _failures, files.size(), total_defs, total_called])
	if _failures == 0:
		print("SELFCHECK_OK")
		quit(0)
	else:
		printerr("SELFCHECK_FAIL count=%d" % _failures)
		quit(1)


func _check(condition: bool, tag: String, detail: String = "") -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	if detail.is_empty():
		printerr("SELFCHECK_CHECK_FAILED %s" % tag)
	else:
		printerr("SELFCHECK_CHECK_FAILED %s :: %s" % [tag, detail])


func _gd_files(dir_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not name.begins_with(".") and name.ends_with(".gd"):
			out.append(name)
		name = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	return file.get_as_text()


## 收集 `func _check_xxx(` 的函数名（去掉缩进后以 `func _check_` 开头）。
func _defined_checks(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	for raw_line in text.split("\n"):
		var line := raw_line.strip_edges()
		if not line.begins_with("func _check_"):
			continue
		var open := line.find("(")
		if open <= 5:
			continue
		var name := line.substr(5, open - 5).strip_edges()
		if not name.is_empty():
			out.append(name)
	return out


## 统计该函数名的**调用点**数量（不含定义行，不含注释行）。
##
## 做法：逐行判断，跳过以 `#` 开头的行（注释），再在其余行里找 `name(`。
## 定义行（`func name(`）不算调用点。
func _call_site_count(text: String, func_name: String) -> int:
	var needle := func_name + "("
	var calls := 0
	for raw_line in text.split("\n"):
		var line := raw_line.strip_edges()
		if line.is_empty():
			continue
		if line.begins_with("#"):
			continue
		if line.begins_with("func " + func_name + "("):
			continue
		if line.contains(needle):
			calls += 1
	return calls
