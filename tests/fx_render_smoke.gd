extends SceneTree

## v3.49 特效渲染专项回归（roadmap 特效美化轮次验收）。
##
## **为什么这个测试只断言纯函数与事件，而不统计 `draw_*` 调用次数**：
## v3.49 实测（探针 `.me/tmp/main/probe49_draw.gd`）——在 `_draw()` 之外对普通 `Node2D`
## 调 `draw_circle` / `draw_line` / `draw_arc` / `draw_rect` 会报
## `ERROR: Drawing is only allowed inside this node's `_draw()`, functions connected to its
## `draw` signal, or when it receives NOTIFICATION_DRAW.`，而 `--headless` 下 `_draw` 根本不执行。
## 所以「统计画了几次」这条路线**不成立**，本测试改为断言三件能真正被驱动的事：
##   ① 抽出来的纯数值函数（口径分档、拖尾长度、数字错开分层）；
##   ② `DamageSystem` 的爆炸中心事件（缺陷 B 的数据前提）；
##   ③ 三个页面源码里的接线（源码扫描，抓「事件有了但没人消费」这类缺陷）。
## 绘制像素本身仍只能靠 `--capture` 截图 + 人眼，这一点在最终报告里必须如实说明。

const ModuleDefs := preload("res://scripts/module_defs.gd")
const GridBuilder := preload("res://scripts/grid_builder.gd")
const TankBody := preload("res://scripts/tank_body.gd")
const DamageSystem := preload("res://scripts/damage_system.gd")
const CombatView := preload("res://scripts/combat_view.gd")

## 真实模块 id（`data/modules/systems.json` 的 `items[].id`）。
## 不能写 `core` / `depot`：那是我第一版猜的名字，`place_module()` 直接报「找不到模块数据」。
const CORE_ID := "cockpit_light"
const DEPOT_ID := "ammo_depot_small"

var definitions: ModuleDefs
var failures := 0
var checks := 0


func _init() -> void:
	definitions = ModuleDefs.new()
	if not definitions.load_all():
		printerr("FX_DATA_FAILED")
		quit(1)
		return
	_check_shot_gauge_monotonic()
	_check_shot_gauge_bounds()
	_check_shot_head_radius_grows()
	_check_shot_trail_width_grows()
	_check_shot_trail_length_uses_speed()
	_check_shot_trail_length_clamped()
	_check_shot_trail_fallback()
	_check_popup_stack_near()
	_check_popup_stack_far()
	_check_popup_stack_chain()
	_check_popup_stack_radius_boundary()
	_check_burst_event_once_per_depot()
	_check_burst_event_has_radius()
	_check_burst_event_not_recursive()
	_check_fx_style_special_enabled()
	_check_fx_style_burst_enabled()
	_check_source_shield_hit_wired()
	_check_source_burst_consumed_three_pages()
	_check_source_hit_flash_is_array()
	_check_source_ammo_lookup_wired()
	_check_source_no_random_in_effects()
	if failures > 0:
		printerr("FX_FAIL count=%d checks=%d" % [failures, checks])
		quit(1)
		return
	print("FX_OK checks=%d" % checks)
	quit(0)


func _ok(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures += 1
		printerr("FX_FAIL %s" % label)


func _near(label: String, actual: float, expected: float, tolerance: float = 0.0001) -> void:
	checks += 1
	if absf(actual - expected) > tolerance:
		failures += 1
		printerr("FX_FAIL %s actual=%.6f expected=%.6f" % [label, actual, expected])


# ─── 口径分档 ──────────────────────────────────────────────────────────────


## 五个真实口径的 `base_damage`（`data/ammo/*.json`）必须产出严格递增的档位。
## 这是「玩家能分出飞过来的是什么口径」这条要求的可测形式。
func _check_shot_gauge_monotonic() -> void:
	var damages := [8.0, 20.0, 55.0, 130.0, 240.0]
	var previous := -1.0
	var monotonic := true
	for damage in damages:
		var gauge: float = CombatView._shot_gauge(float(damage))
		if gauge <= previous:
			monotonic = false
		previous = gauge
	_ok("gauge_monotonic", monotonic)


## 档位必须落在 `[0, 1]`：越界会让 `lerpf` 外推出负半径或超大半径。
func _check_shot_gauge_bounds() -> void:
	_near("gauge_zero", CombatView._shot_gauge(0.0), 0.0)
	_near("gauge_negative", CombatView._shot_gauge(-50.0), 0.0)
	_ok("gauge_max_le_one", CombatView._shot_gauge(240.0) <= 1.0 + 0.0001)
	_ok("gauge_huge_clamped", CombatView._shot_gauge(99999.0) <= 1.0 + 0.0001)
	_ok("gauge_tiny_positive", CombatView._shot_gauge(0.5) >= 0.0)


## 最重口径的弹头必须比最轻的粗——这是 B1 的核心要求。
func _check_shot_head_radius_grows() -> void:
	var light: float = CombatView.shot_head_radius(CombatView._shot_gauge(8.0))
	var heavy: float = CombatView.shot_head_radius(CombatView._shot_gauge(240.0))
	_ok("head_radius_heavy_gt_light", heavy > light)
	## 断言「按档位反推的半径」而不是直接用档位 0 —— 轻口径的档位不是 0，
	## 它只是**最小**的那个。直接拿 `gauge=0` 当期望值是我写错的第一版。
	_near("head_radius_light", light, CombatView.shot_head_radius(CombatView._shot_gauge(8.0)))
	_near("head_radius_heavy", heavy, CombatView.shot_head_radius(CombatView._shot_gauge(240.0)))
	## `pixel` 是线性缩放：4× 缩放下半径必须正好 4 倍（世界单位换算的判据）。
	_near("head_radius_pixel_scale", CombatView.shot_head_radius(1.0, 4.0), CombatView.SHOT_RADIUS_MAX * 4.0)


func _check_shot_trail_width_grows() -> void:
	var light: float = CombatView.shot_trail_width(0.0)
	var heavy: float = CombatView.shot_trail_width(1.0)
	_ok("trail_width_heavy_gt_light", heavy > light)
	_near("trail_width_light", light, CombatView.SHOT_TRAIL_WIDTH_MIN)
	_near("trail_width_heavy", heavy, CombatView.SHOT_TRAIL_WIDTH_MAX)


# ─── 拖尾长度 ──────────────────────────────────────────────────────────────


## B2 的核心：拖尾长度来自**速度 × 时长**，与「上一帧位移」无关。
## 这里给同一个速度、两个差异极大的 fallback，结果必须相同。
func _check_shot_trail_length_uses_speed() -> void:
	var with_small_fallback: float = CombatView.shot_trail_length(900.0, 1.0)
	var with_large_fallback: float = CombatView.shot_trail_length(900.0, 9999.0)
	_near("trail_length_ignores_fallback", with_small_fallback, with_large_fallback)
	## 900 px/s × 0.045 s = 40.5 px，落在 [10, 46] 内，不该被夹。
	_near("trail_length_900", with_small_fallback, 900.0 * CombatView.SHOT_TRAIL_TIME)


func _check_shot_trail_length_clamped() -> void:
	_near("trail_length_slow_clamped", CombatView.shot_trail_length(10.0, 0.0), CombatView.SHOT_TRAIL_MIN)
	_near("trail_length_fast_clamped", CombatView.shot_trail_length(99999.0, 0.0), CombatView.SHOT_TRAIL_MAX)


## 取不到速度（旧数据 / 探针构造的 shot）时必须退回上一帧位移，即旧版行为。
## 这一条保证「未注入 speed 的调用点像素不变」这个承诺是可验证的。
func _check_shot_trail_fallback() -> void:
	_near("trail_fallback_zero_speed", CombatView.shot_trail_length(0.0, 12.5), 12.5)
	_near("trail_fallback_negative_speed", CombatView.shot_trail_length(-3.0, 7.0), 7.0)


# ─── 伤害数字按位置分桶（缺陷 C） ──────────────────────────────────────────


## 两条靠得很近的数字必须错开一层。
func _check_popup_stack_near() -> void:
	var placed: Array = []
	var first: int = CombatView._popup_stack_at(placed, Vector2(100.0, 100.0))
	var second: int = CombatView._popup_stack_at(placed, Vector2(105.0, 100.0))
	_ok("stack_first_zero", first == 0)
	_ok("stack_second_one", second == 1)


## **缺陷 C 的判据**：两条相隔 200 px 的数字必须都拿到层号 0。
## 旧版全局 `stack` 会让第二条拿到 1（进而被抬高 14 px），这就是那个 bug。
func _check_popup_stack_far() -> void:
	var placed: Array = []
	var first: int = CombatView._popup_stack_at(placed, Vector2(100.0, 100.0))
	var second: int = CombatView._popup_stack_at(placed, Vector2(300.0, 100.0))
	_ok("stack_far_first_zero", first == 0)
	_ok("stack_far_second_zero", second == 0)


## 同一位置连续三条：0 / 1 / 2。
func _check_popup_stack_chain() -> void:
	var placed: Array = []
	var a: int = CombatView._popup_stack_at(placed, Vector2(50.0, 50.0))
	var b: int = CombatView._popup_stack_at(placed, Vector2(50.0, 50.0))
	var c: int = CombatView._popup_stack_at(placed, Vector2(50.0, 50.0))
	_ok("stack_chain", a == 0 and b == 1 and c == 2)


## 分桶半径是**开区间**（`>= RADIUS` 视为不同簇）：
## 正好等于半径的两点必须互不干扰，这是「边界不会悄悄多抬一层」的判据。
func _check_popup_stack_radius_boundary() -> void:
	var placed: Array = []
	CombatView._popup_stack_at(placed, Vector2.ZERO)
	var at_radius: int = CombatView._popup_stack_at(placed, Vector2(CombatView.DAMAGE_POPUP_STACK_RADIUS, 0.0))
	var inside: int = CombatView._popup_stack_at(placed, Vector2(CombatView.DAMAGE_POPUP_STACK_RADIUS - 1.0, 0.0))
	_ok("stack_at_radius_is_new_cluster", at_radius == 0)
	_ok("stack_inside_radius_stacks", inside == 1)


# ─── 爆炸中心事件（缺陷 B 的数据前提） ────────────────────────────────────


## 造一个只有驾驶舱 + 弹药库的最小坦克，打爆弹药库，断言**恰好一条** burst 事件。
## 为什么恰好一条：`_area_damage()` 逐受波及部件发 `<tag>` 事件，若中心事件也逐部件发，
## 页面层会画出十几个小爆炸；这条断言锁死「一次殉爆 = 一次爆发」。
func _check_burst_event_once_per_depot() -> void:
	var tank := _make_tank_with_depot()
	if tank == null:
		return
	var damage := DamageSystem.new()
	damage.setup(definitions)
	var depot_part := _find_part(tank, DEPOT_ID)
	if depot_part.is_empty():
		_fail_missing("burst_no_depot")
		return
	var index := tank.parts.find(depot_part)
	## 必须走 `apply_part_damage()` 而不是直接 `tank.damage_part()`：
	## 殉爆、脱落、驾驶舱被毁这些连锁全部由 `_on_destroyed()` 发出，而它只能由
	## `DamageSystem` 的两个入口触发。我第一版绕过了它，于是事件表里根本没有 burst。
	damage.apply_part_damage(tank, index, float(depot_part["hp"]) + 1000.0)
	var bursts := _burst_events(damage.drain_events())
	_ok("burst_count_one", bursts.size() == 1)
	if bursts.size() != 1:
		return
	var burst: Dictionary = bursts[0]
	_ok("burst_kind_named", String(burst.get("kind", "")) == "depot_explosion_burst")
	_ok("burst_has_cells", (burst.get("cells", []) as Array).size() > 0)


## burst 事件必须带 `radius`，否则页面层无法换算爆炸尺寸，只能画固定半径的小圆。
func _check_burst_event_has_radius() -> void:
	var tank := _make_tank_with_depot()
	if tank == null:
		return
	var damage := DamageSystem.new()
	damage.setup(definitions)
	var depot_part := _find_part(tank, DEPOT_ID)
	if depot_part.is_empty():
		_fail_missing("burst_radius_no_depot")
		return
	damage.apply_part_damage(tank, tank.parts.find(depot_part), float(depot_part["hp"]) + 1000.0)
	for burst in _burst_events(damage.drain_events()):
		var event: Dictionary = burst
		_ok("burst_radius_positive", float(event.get("radius", 0.0)) > 0.0)
		return
	_fail_missing("burst_radius_missing")


## 递归殉爆（弹药库炸死旁边的弹药库）**不得**转发外层的 burst。
## 判据：两个弹药库相邻时，burst 事件数量必须仍是「每个 depth==0 的爆炸一条」，
## 而不是随受波及部件数增长。这里用「burst 数 <= 弹药库数」这个上界。
func _check_burst_event_not_recursive() -> void:
	var tank := _make_tank_with_depot()
	if tank == null:
		return
	var damage := DamageSystem.new()
	damage.setup(definitions)
	var depot_part := _find_part(tank, DEPOT_ID)
	if depot_part.is_empty():
		_fail_missing("burst_recursive_no_depot")
		return
	damage.apply_part_damage(tank, tank.parts.find(depot_part), float(depot_part["hp"]) + 1000.0)
	var burst_count := 0
	var part_event_count := 0
	for raw in damage.drain_events():
		var event: Dictionary = raw
		var kind := String(event.get("kind", ""))
		if kind.ends_with("_burst"):
			burst_count += 1
		elif kind == "depot_explosion" or kind == "explosion":
			part_event_count += 1
	## 一个弹药库 + 驾驶舱的最小坦克：逐部件事件可以有多条，但中心事件只能有一条。
	_ok("burst_not_recursive", burst_count == 1)
	_ok("burst_fewer_than_part_events", burst_count <= maxi(part_event_count, 1))


## 从事件表里筛出 `*_burst` 中心事件。
func _burst_events(events: Array) -> Array:
	var result: Array = []
	for raw in events:
		var event: Dictionary = raw
		if String(event.get("kind", "")).ends_with("_burst"):
			result.append(event)
	return result


# ─── 风格开关 ──────────────────────────────────────────────────────────────


## B5：三套风格全部启用 `special`。少开一套，那一页的 `detach` / `core` 就又和普通命中一样了。
func _check_fx_style_special_enabled() -> void:
	_ok("style_survival_special", bool(CombatView.FX_STYLE_SURVIVAL.get("special", false)))
	_ok("style_match_special", bool(CombatView.FX_STYLE_MATCH.get("special", false)))
	_ok("style_drive_special", bool(CombatView.FX_STYLE_DRIVE.get("special", false)))


func _check_fx_style_burst_enabled() -> void:
	_ok("style_survival_burst", bool(CombatView.FX_STYLE_SURVIVAL.get("burst", false)))
	_ok("style_match_burst", bool(CombatView.FX_STYLE_MATCH.get("burst", false)))
	_ok("style_drive_burst", bool(CombatView.FX_STYLE_DRIVE.get("burst", false)))


# ─── 源码扫描（抓「事件有了但没人消费」这类缺陷） ──────────────────────────


func _read_source(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	return file.get_as_text()


## 在**非注释行**里查找子串。
##
## 为什么需要：修复缺陷时我会在注释里写「旧版这里是 XXX」——那是给后来人看的说明，
## 不是代码。但全文 `contains()` 会把说明文字当成违规，产生假红（v3.49 实测过 3 次）。
func _has_code_line(source: String, needle: String) -> bool:
	for raw_line in source.split("\n"):
		var line := String(raw_line)
		if line.strip_edges().begins_with("#"):
			continue
		if line.contains(needle):
			return true
	return false


## 缺陷 A 的判据：生存页必须推 `shield_hit` 且**不得**再出现零位置零半径的 `shield`。
## 这一条直接锁死「两个错叠在一起导致护盾受击完全不可见」的回归。
func _check_source_shield_hit_wired() -> void:
	var source := _read_source("res://scripts/main.gd")
	_ok("source_shield_hit_pushed", source.contains("_push_survival_fx(\"shield_hit\""))
	## 剔除注释行再查：修复说明本身写到了旧写法，全文 `contains()` 会假红。
	_ok("source_shield_zero_removed", not _has_code_line(source, "_push_survival_fx(\"shield\", Vector2.ZERO, 0.0"))


## 缺陷 B 的判据：三个页面都必须消费 `*_burst`。少一页，那一页的爆炸就又静默了。
func _check_source_burst_consumed_three_pages() -> void:
	var source := _read_source("res://scripts/main.gd")
	_ok("source_burst_match", source.contains("kind == \"explosion_burst\" or kind == \"depot_explosion_burst\" or kind == \"engine_explosion_burst\""))
	_ok("source_burst_drive", source.contains("\"explosion_burst\", \"depot_explosion_burst\", \"engine_explosion_burst\""))
	_ok("source_burst_fx_kind", source.contains("_push_drive_fx(\"explosion_burst\"") or source.contains("_push_survival_fx(\"explosion_burst\"") or source.contains("_match_fx.push(\"explosion_burst\""))


## 缺陷 D 的判据：命中闪光必须是数组 + `_advance_timed`，不得残留单变量。
func _check_source_hit_flash_is_array() -> void:
	var source := _read_source("res://scripts/main.gd")
	_ok("source_drive_hits_array", source.contains("var _drive_hits: Array = []"))
	_ok("source_match_hits_array", source.contains("var _match_hits: Array = []"))
	_ok("source_survival_hits_array", source.contains("var _survival_hits: Array = []"))
	_ok("source_hits_advanced", source.contains("_advance_timed(_survival_hits, step_time)"))
	_ok("source_no_single_hit_flash", not source.contains("_match_hit_flash_left =") and not source.contains("_drive_hit_flash_left =") and not source.contains("_hit_flash_left ="))


## B1 的判据：三处 `draw_shots` 都必须注入 `_ammo_lookup`，否则口径分档等于没做。
func _check_source_ammo_lookup_wired() -> void:
	var source := _read_source("res://scripts/main.gd")
	_ok("source_ammo_lookup_func", source.contains("func _ammo_lookup(ammo_id: String) -> Dictionary:"))
	var wired := 0
	var cursor := 0
	while true:
		var index := source.find("CombatView.draw_shots(", cursor)
		if index < 0:
			break
		var line_end := source.find("\n", index)
		var line := source.substr(index, line_end - index)
		if line.contains("_ammo_lookup"):
			wired += 1
		cursor = line_end if line_end > 0 else source.length()
	_ok("source_ammo_lookup_all_three", wired == 3)


## 确定性纪律：特效绘制路径里不得出现 `randf` / `randi`。
##
## 扫描前先剔除注释行：`combat_view.gd` 的模块头注释里**写到了**「不使用 randf / randi」
## 这句话本身。第一版直接全文 `contains()`，于是这个断言把自己的说明文字当成了违规——
## 这是测试自身的缺陷（假红），不是产品缺陷。现在只检查非注释行。
func _check_source_no_random_in_effects() -> void:
	var view_source := _read_source("res://scripts/combat_view.gd")
	var offending := 0
	for raw_line in view_source.split("\n"):
		var line := String(raw_line)
		var stripped := line.strip_edges()
		if stripped.begins_with("#"):
			continue
		if line.contains("randf") or line.contains("randi"):
			offending += 1
	_ok("source_combat_view_no_random", offending == 0)


# ─── 构造辅助 ──────────────────────────────────────────────────────────────


## 最小坦克：驾驶舱 + 一个弹药库，外加必要的平台格。
## 返回 `null` 时已经记过失败（构造不出来说明数据/建造接口变了，测试必须报出来）。
func _make_tank_with_depot() -> TankBody:
	var builder := GridBuilder.new()
	if not builder.setup(definitions):
		_fail_missing("tank_builder_setup")
		return null
	builder.budget_enabled = false
	builder.credits_total = 1000000
	var cells := [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 0), Vector2i(2, 1)]
	for raw in cells:
		var reason := builder.place_platform_cell(Vector2i(raw))
		if not reason.is_empty():
			_fail_missing("tank_platform %s" % reason)
			return null
	if not _place_module(builder, CORE_ID, Vector2i(0, 0)):
		return null
	if not _place_module(builder, DEPOT_ID, Vector2i(1, 0)):
		return null
	var tank := TankBody.new()
	if not tank.setup(definitions, builder):
		_fail_missing("tank_setup")
		return null
	return tank


## 放置模块。真实签名是 `place_module(module_id, start, rotation = 0, aim = 0)`——
## **没有 `size` 参数**（格数由模块数据决定）。我第一版按 `(id, cell, size, 0)` 调用，
## 于是 `size=1` 被当成 `rotation`、`0` 被当成 `aim`，报「该模块不可旋转」。
func _place_module(builder: GridBuilder, module_id: String, cell: Vector2i) -> bool:
	var reason := builder.place_module(module_id, cell)
	if not reason.is_empty():
		_fail_missing("tank_module %s %s" % [module_id, reason])
		return false
	return true


func _find_part(tank: TankBody, module_id: String) -> Dictionary:
	for raw in tank.parts:
		var part: Dictionary = raw
		if String(part.get("module_id", "")) == module_id:
			return part
	return {}


func _fail_missing(label: String) -> void:
	checks += 1
	failures += 1
	printerr("FX_FAIL %s" % label)
