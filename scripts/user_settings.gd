extends RefCounted

## v3.48 P0-1：用户设置的持久化载体。
##
## 背景（v3.47 排查轮 P0-1）：`_glow_enabled` / `_motion_enabled` 从引入起就是**纯内存字段**，
## 每次启动都回到默认值，且界面上没有任何提示说明它是临时的。玩家每开一次游戏就要重设一次。
##
## 设计约束：
## 1. **只做「读 / 写一份键值」这一件事**，不碰任何引擎节点、不读 `data/*.json`。
##    这样 headless 测试能在临时路径上跑完整 round-trip，而不会污染真实用户目录。
## 2. 路径**可注入**（构造参数），默认 `user://settings.cfg`。
## 3. **不认识的值一律退回默认，不报错**：设置文件的损坏绝不能让游戏打不开
##    —— 它只是一份偏好记录，不是玩法数据。
## 4. 缺键 / 缺段 / 类型不对，全部按「用默认值」处理，同样不报错。

const DEFAULT_PATH := "user://settings.cfg"
const SECTION := "display"

## 窗口模式档位。**下标即存档值**，因此只能在末尾追加、不得重排。
## 说明：这三项是**界面档位名**（与 `MATCH_DIFFICULTY_LABEL` 同一类），不是玩法数值，
## 所以按既有惯例留在代码里；真正需要进 `data/*.json` 的是玩法常量与数值范围。
const WINDOW_MODE_MAXIMIZED := 0
const WINDOW_MODE_FULLSCREEN := 1
const WINDOW_MODE_WINDOWED := 2
const WINDOW_MODES := ["最大化", "全屏", "窗口化"]

var path: String = DEFAULT_PATH

## 辉光：写进 `WorldEnvironment.environment.glow_enabled`。
var glow_enabled: bool = true
## 动效：菜单脉冲 / 试驾车体倾斜 / 履带相位。
var motion_enabled: bool = true
## 窗口模式，取 `WINDOW_MODE_*`。
var window_mode: int = WINDOW_MODE_MAXIMIZED
## 调试读数：在背景层右上角显示帧率 / 当前页 / 相机读数。默认关。
var debug_readout: bool = false


func _init(settings_path: String = DEFAULT_PATH) -> void:
	path = settings_path


## 从 `path` 读一次。返回是否读到了文件（**不是**「值是否全部有效」）。
## 文件不存在 / 打不开 / 内容损坏，一律保留当前（默认）值并返回 false。
func load_settings() -> bool:
	var config := ConfigFile.new()
	var error := config.load(path)
	if error != OK:
		return false
	glow_enabled = _read_bool(config, "glow_enabled", glow_enabled)
	motion_enabled = _read_bool(config, "motion_enabled", motion_enabled)
	debug_readout = _read_bool(config, "debug_readout", debug_readout)
	var raw_mode: Variant = config.get_value(SECTION, "window_mode", window_mode)
	if raw_mode is int or raw_mode is float:
		window_mode = clampi(int(raw_mode), 0, WINDOW_MODES.size() - 1)
	return true


## 把当前值写回 `path`。父目录不存在时尝试建一层（`user://` 本身总是存在，
## 但测试会传临时路径，所以这一步不能省）。返回是否写入成功。
func save_settings() -> bool:
	var config := ConfigFile.new()
	config.set_value(SECTION, "glow_enabled", glow_enabled)
	config.set_value(SECTION, "motion_enabled", motion_enabled)
	config.set_value(SECTION, "window_mode", window_mode)
	config.set_value(SECTION, "debug_readout", debug_readout)
	var directory := path.get_base_dir()
	if not directory.is_empty() and not DirAccess.dir_exists_absolute(directory):
		DirAccess.make_dir_recursive_absolute(directory)
	return config.save(path) == OK


## 窗口模式档位的显示名。越界下标钳到合法范围，绝不返回空串
## —— 空串会让设置页那一行看上去像「没有值」，玩家会以为是坏了。
func window_mode_label() -> String:
	return WINDOW_MODES[clampi(window_mode, 0, WINDOW_MODES.size() - 1)]


## 切到下一档并返回新的档位下标。**循环**而不是钳制：只有三档，
## 循环比「到头没反应」更容易理解，也不会让玩家以为按键失效。
func cycle_window_mode() -> int:
	window_mode = (window_mode + 1) % WINDOW_MODES.size()
	return window_mode


func _read_bool(config: ConfigFile, key: String, fallback: bool) -> bool:
	var raw: Variant = config.get_value(SECTION, key, fallback)
	if raw is bool:
		return bool(raw)
	## 手改过的文件可能写成 0 / 1。接受它，但不接受字符串 "true" ——
	## 那说明文件被别的东西写坏了，宁可退回默认值。
	if raw is int or raw is float:
		return float(raw) != 0.0
	return fallback
