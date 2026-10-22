extends RefCounted

## 瞬时动效层的唯一实现（v3.11 从 `main.gd` 抽出）。
##
## 抽出的理由：试驾 / 对局 / 生存三页原本各自持有一份 `Array` + push / tick / draw
## 三件套，数据结构完全相同（`{kind, pos, radius, colour, left, life}`）、逻辑几乎逐行
## 一致。v3.10 修掉的那个「对战页动效永不衰减」bug，正是因为三份副本各抄一遍、其中一份
## 把 tick 调到了另一个数组上。合成一个类之后，「忘记递减 `left`」在结构上不再可能。
##
## 纪律（与 design §2.3 / agent_note §8 一致）：
## - 倒计时只在固定步长里推进（`step()`），**绝不在 `_process` 里**；
## - 不使用 `randf` / `randi`，任何闪烁相位由调用方用 `sin(_time * …)` 提供；
## - 容器按插入顺序遍历，删除用「重建保留」而不是原地删除，保持确定性。

## 一条动效：`kind` 供绘制端分支，`pos` 是世界坐标（页面层负责转屏幕坐标），
## `radius` 以像素计，`left` / `life` 驱动淡出比例 `left / life`。
## `text` 可选：非空时绘制端当作**悬浮数字/文字**渲染（伤害提示用），空则照旧画圆环。
## 默认空字符串保证所有旧调用点的行为完全不变。
var entries: Array = []


## 追加一条动效。`life <= 0` 视为无效，直接忽略，避免绘制端出现除零。
func push(kind: String, at: Vector2, radius: float, colour: Color, life: float, text: String = "") -> void:
	if life <= 0.0:
		return
	entries.append({
		"kind": kind,
		"pos": at,
		"radius": radius,
		"colour": colour,
		"left": life,
		"life": life,
		"text": text,
	})


## 固定步长推进：递减 `left` 并丢弃已过期的项。
## 这是**唯一**允许修改 `left` 的地方——三页共用，不再有「调错 tick 对象」的可能。
func step(step_time: float) -> void:
	if entries.is_empty():
		return
	var kept: Array = []
	for raw_entry in entries:
		var entry: Dictionary = raw_entry
		entry["left"] = float(entry["left"]) - step_time
		if float(entry["left"]) > 0.0:
			kept.append(entry)
	entries = kept


func clear() -> void:
	entries.clear()


func is_empty() -> bool:
	return entries.is_empty()


func size() -> int:
	return entries.size()


## 淡出比例：1.0 = 刚生成，0.0 = 即将消失。绘制端据此缩放半径与 alpha。
func ratio(entry: Dictionary) -> float:
	var life := maxf(float(entry["life"]), 0.001)
	return clampf(float(entry["left"]) / life, 0.0, 1.0)
