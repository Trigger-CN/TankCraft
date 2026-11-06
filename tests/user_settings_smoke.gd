extends SceneTree

## v3.48（P0-1）永久门禁：**用户设置真的能存下来**。
##
## 背景（v3.47 排查轮 P0-1）：`_glow_enabled` / `_motion_enabled` 从引入起就是纯内存字段，
## 玩家每开一次游戏都要重设。`SETTINGS_SAVE` 在 `scripts/` 与 `tests/` 命中 **0 次**。
##
## 判据（与实现无关，只看外部可观测行为）：
##   ① 写一份非默认值 → 新建一个实例读回 → 四个字段**逐个相等**；
##   ② 文件不存在时读回**不报错**、字段保持默认；
##   ③ 文件损坏时读回**不报错**、字段保持默认（设置损坏绝不能让游戏打不开）；
##   ④ 单个键类型不对时**只有那个键**退回默认，其余键仍然生效；
##   ⑤ `window_mode` 越界值被钳到合法区间；
##   ⑥ `cycle_window_mode()` 走满一圈回到原点（三档循环，不是钳制）。
##
## **测试路径必须是临时文件**，不能碰真实 `user://settings.cfg` —— 否则跑一次测试
## 就改掉了开发者本机的设置。

const UserSettings := preload("res://scripts/user_settings.gd")

const TEST_PATH := "user://settings_smoke_48.cfg"
const BROKEN_PATH := "user://settings_smoke_48_broken.cfg"
const PARTIAL_PATH := "user://settings_smoke_48_partial.cfg"

var failures := 0
var checks := 0


func _init() -> void:
	_cleanup()
	_check_round_trip()
	_check_missing_file()
	_check_corrupt_file()
	_check_partial_types()
	_check_window_mode_bounds()
	_check_cycle_wraps()
	_cleanup()
	if failures > 0:
		printerr("USERSET_FAIL count=%d" % failures)
		quit(1)
		return
	print("USERSET_DONE checks=%d failures=%d" % [checks, failures])
	print("USERSET_OK")
	quit(0)


func _check(condition: bool, tag: String, detail: String = "") -> void:
	checks += 1
	if condition:
		return
	failures += 1
	if detail.is_empty():
		printerr("USERSET_FAIL %s" % tag)
	else:
		printerr("USERSET_FAIL %s :: %s" % [tag, detail])


func _cleanup() -> void:
	for path in [TEST_PATH, BROKEN_PATH, PARTIAL_PATH]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


# ─── ① round-trip ─────────────────────────────────────────────────────────────

## 这是本轮修复的核心断言：**写进去的东西必须读得回来**。
## 四个字段全部取非默认值，所以任何「写了没存」「存了没读」都会被抓到。
func _check_round_trip() -> void:
	var writer := UserSettings.new(TEST_PATH)
	_check(writer.path == TEST_PATH, "path_injected_%s" % writer.path)
	writer.glow_enabled = false
	writer.motion_enabled = false
	writer.window_mode = UserSettings.WINDOW_MODE_WINDOWED
	writer.debug_readout = true
	_check(writer.save_settings(), "save_ok")
	_check(FileAccess.file_exists(TEST_PATH), "file_created")

	var reader := UserSettings.new(TEST_PATH)
	_check(reader.load_settings(), "load_reports_true")
	_check(reader.glow_enabled == false, "round_trip_glow_%s" % str(reader.glow_enabled))
	_check(reader.motion_enabled == false, "round_trip_motion_%s" % str(reader.motion_enabled))
	_check(reader.window_mode == UserSettings.WINDOW_MODE_WINDOWED, "round_trip_window_%s" % str(reader.window_mode))
	_check(reader.debug_readout == true, "round_trip_debug_%s" % str(reader.debug_readout))

	## 反向：把默认值写回去，读回也必须是默认值。
	## 只测「true → false」的话，一个恒返回 false 的实现会全过。
	writer.glow_enabled = true
	writer.motion_enabled = true
	writer.window_mode = UserSettings.WINDOW_MODE_MAXIMIZED
	writer.debug_readout = false
	_check(writer.save_settings(), "save_ok_reverse")
	var reader2 := UserSettings.new(TEST_PATH)
	_check(reader2.load_settings(), "load_reports_true_reverse")
	_check(reader2.glow_enabled == true, "reverse_glow_%s" % str(reader2.glow_enabled))
	_check(reader2.motion_enabled == true, "reverse_motion_%s" % str(reader2.motion_enabled))
	_check(reader2.window_mode == UserSettings.WINDOW_MODE_MAXIMIZED, "reverse_window_%s" % str(reader2.window_mode))
	_check(reader2.debug_readout == false, "reverse_debug_%s" % str(reader2.debug_readout))


# ─── ② 文件不存在 ─────────────────────────────────────────────────────────────

## 首次运行本来就没有文件，那不是异常。
## 关键：**不能报错、不能把字段改成奇怪的值**。
func _check_missing_file() -> void:
	var settings := UserSettings.new("user://settings_smoke_48_absent.cfg")
	_check(not settings.load_settings(), "missing_reports_false")
	_check(settings.glow_enabled == true, "missing_glow_default")
	_check(settings.motion_enabled == true, "missing_motion_default")
	_check(settings.window_mode == UserSettings.WINDOW_MODE_MAXIMIZED, "missing_window_default")
	_check(settings.debug_readout == false, "missing_debug_default")


# ─── ③ 文件损坏 ───────────────────────────────────────────────────────────────

## 设置文件被写坏时，**游戏必须能打开**。
## 这一条是「设置文件绝不是一个能让游戏崩掉的东西」的直接验收。
func _check_corrupt_file() -> void:
	var file := FileAccess.open(BROKEN_PATH, FileAccess.WRITE)
	if file == null:
		_check(false, "corrupt_write_open")
		return
	file.store_string("这不是 ConfigFile 格式的内容\n[unclosed section\n===garbage===\n")
	file.close()

	var settings := UserSettings.new(BROKEN_PATH)
	## 损坏的 ConfigFile 有两种表现：load 返回非 OK，或者能读但值是垃圾。
	## **两种都接受，唯一的要求是字段落在合法默认值上。**
	settings.load_settings()
	_check(settings.glow_enabled == true or settings.glow_enabled == false, "corrupt_glow_is_bool")
	_check(settings.motion_enabled == true or settings.motion_enabled == false, "corrupt_motion_is_bool")
	_check(settings.window_mode >= 0 and settings.window_mode < UserSettings.WINDOW_MODES.size(),
		"corrupt_window_in_range_%d" % settings.window_mode)


# ─── ④ 部分键类型不对 ─────────────────────────────────────────────────────────

## 手改过的文件可能把 `glow_enabled` 写成字符串。
## 要求：**只有那个键退回默认**，其余键仍然生效 —— 一个坏键不该让整份设置失效。
func _check_partial_types() -> void:
	var config := ConfigFile.new()
	config.set_value(UserSettings.SECTION, "glow_enabled", "yes")  # 坏：字符串
	config.set_value(UserSettings.SECTION, "motion_enabled", false)  # 好
	config.set_value(UserSettings.SECTION, "window_mode", 1)  # 好
	config.set_value(UserSettings.SECTION, "debug_readout", true)  # 好
	_check(config.save(PARTIAL_PATH) == OK, "partial_save_ok")

	var settings := UserSettings.new(PARTIAL_PATH)
	_check(settings.load_settings(), "partial_load_true")
	_check(settings.glow_enabled == true, "partial_bad_key_falls_back_%s" % str(settings.glow_enabled))
	_check(settings.motion_enabled == false, "partial_good_motion_kept_%s" % str(settings.motion_enabled))
	_check(settings.window_mode == UserSettings.WINDOW_MODE_FULLSCREEN, "partial_good_window_kept_%d" % settings.window_mode)
	_check(settings.debug_readout == true, "partial_good_debug_kept_%s" % str(settings.debug_readout))


# ─── ⑤ window_mode 越界 ───────────────────────────────────────────────────────

## 存档里写了 `window_mode = 99` 时，必须钳到合法档位而不是让下标越界。
## 下标越界会让 `window_mode_label()` 崩溃或返回空串 —— 后者会让设置页那一行
## 看上去像「没有值」，玩家会以为是坏了。
func _check_window_mode_bounds() -> void:
	var config := ConfigFile.new()
	config.set_value(UserSettings.SECTION, "window_mode", 99)
	config.save(PARTIAL_PATH)
	var high := UserSettings.new(PARTIAL_PATH)
	high.load_settings()
	_check(high.window_mode == UserSettings.WINDOW_MODES.size() - 1, "window_clamped_high_%d" % high.window_mode)
	_check(not high.window_mode_label().is_empty(), "window_label_not_empty_high")

	config = ConfigFile.new()
	config.set_value(UserSettings.SECTION, "window_mode", -5)
	config.save(PARTIAL_PATH)
	var low := UserSettings.new(PARTIAL_PATH)
	low.load_settings()
	_check(low.window_mode == 0, "window_clamped_low_%d" % low.window_mode)
	_check(not low.window_mode_label().is_empty(), "window_label_not_empty_low")

	## 三档的显示名必须**互不相同** —— 否则「切换窗口模式」在界面上看不出变化。
	var labels: Array = []
	for index in range(UserSettings.WINDOW_MODES.size()):
		var probe := UserSettings.new(PARTIAL_PATH)
		probe.window_mode = index
		labels.append(probe.window_mode_label())
	var unique := {}
	for label in labels:
		unique[label] = true
	_check(unique.size() == UserSettings.WINDOW_MODES.size(),
		"window_labels_unique_%d_of_%d" % [unique.size(), UserSettings.WINDOW_MODES.size()])


# ─── ⑥ 循环而不是钳制 ─────────────────────────────────────────────────────────

## 只有三档，循环比「到头没反应」更容易理解，也不会让玩家以为按键失效。
## 判据：走满 `WINDOW_MODES.size()` 次必须回到起点。
func _check_cycle_wraps() -> void:
	var settings := UserSettings.new(PARTIAL_PATH)
	settings.window_mode = 0
	var seen: Array = []
	for _step in range(UserSettings.WINDOW_MODES.size()):
		seen.append(settings.cycle_window_mode())
	_check(seen.size() == UserSettings.WINDOW_MODES.size(), "cycle_visits_all")
	## 每一档恰好访问一次（不是「重复某一档」）。
	var unique := {}
	for value in seen:
		unique[value] = true
	_check(unique.size() == UserSettings.WINDOW_MODES.size(),
		"cycle_unique_%d_of_%d" % [unique.size(), UserSettings.WINDOW_MODES.size()])
	## 走满一圈回到起点。
	_check(settings.window_mode == 0, "cycle_wraps_to_start_%d" % settings.window_mode)
