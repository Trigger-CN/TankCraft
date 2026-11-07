extends SceneTree

## v3.50 回归：模块被打掉之后**功能必须立刻失效**，并且三页都要有碎片掉落效果。
##
## 用户实机报告的缺陷：「炮管打掉之后还能发射」。
##
## 根因：`CannonBank.cannons` 与 `AmmoNetwork.parts` 是 `tank.parts` / `builder` 之外的
## **两份独立功能索引副本**，只在 `Duel.add_side()` / `Main._enter_drive()` 里构建一次。
## 部件被摧毁时 `DamageSystem` 只更新 `tank` / `builder` / 护盾表，从不重建这两份索引，
## 于是被打掉的炮管仍留在 `bank.cannons` 里（连 `loaded` / `reload_remaining` 都在）。
##
## 断言值全部来自 data/*.json 与用户可见需求，**不复用实现的中间量**：
##   - 「炮管没了就不能开火」直接断言 `Duel.fire()` 返回 0，这是玩家按左键的可见结果；
##   - 「剩下的炮管装填进度不丢」直接断言 `reload_remaining` / `shots_fired` 与摧毁前相等。
##
## 走 `damage.apply_part_damage()` 而不是 `tank.damage_part()`：后者会绕过 `_on_destroyed()`
## 的殉爆 / 脱落 / 结构变更通知链（v3.49 已因这个夹具缺陷吃过一次假红）。

const ModuleDefs := preload("res://scripts/module_defs.gd")
const GridBuilder := preload("res://scripts/grid_builder.gd")
const TankBody := preload("res://scripts/tank_body.gd")
const Duel := preload("res://scripts/duel.gd")

var definitions: ModuleDefs
var failures := 0

func _init() -> void:
	definitions = ModuleDefs.new()
	if not definitions.load_all():
		printerr("PARTDESTROY_DATA_FAILED")
		quit(1)
		return
	_check_cannon_leaves_bank()
	_check_last_cannon_blocks_fire()
	_check_survivor_keeps_load_state()
	_check_factory_leaves_network()
	_check_detach_refreshes_bank()
	_check_drive_page_wired()
	_check_debris_wired_three_pages()
	if failures > 0:
		printerr("PART_DESTROY_FAIL count=%d" % failures)
		quit(1)
		return
	print("PART_DESTROY_OK")
	quit(0)

# ─── 夹具 ─────────────────────────────────────────────────────────────────────

func _expect(condition: bool, tag: String) -> void:
	if condition:
		return
	failures += 1
	printerr("PART_DESTROY_FAIL %s" % tag)

func _expect_near(value: float, expected: float, tag: String) -> void:
	if absf(value - expected) <= 0.001:
		return
	failures += 1
	printerr("PART_DESTROY_FAIL %s value=%.4f expected=%.4f" % [tag, value, expected])

## 平台格必须按 4-连通顺序传入（`place_platform_cell()` 的要求）。
func _make_duel(cells: Array, entries: Array) -> Dictionary:
	var builder := GridBuilder.new()
	if not builder.setup(definitions):
		failures += 1
		printerr("PART_DESTROY_FAIL builder_setup")
		return {}
	builder.budget_enabled = false
	builder.credits_total = 1000000
	for raw in cells:
		var cell := Vector2i(raw)
		var platform_reason := builder.place_platform_cell(cell)
		if not platform_reason.is_empty():
			failures += 1
			printerr("PART_DESTROY_FAIL platform %d,%d %s" % [cell.x, cell.y, platform_reason])
			return {}
	for entry in entries:
		var layer := String(entry.get("layer", "module"))
		var reason := ""
		if layer == "mobility":
			reason = builder.place_mobility(String(entry["id"]), Vector2i(entry["cell"]), int(entry.get("rot", 0)))
		else:
			reason = builder.place_module(String(entry["id"]), Vector2i(entry["cell"]), int(entry.get("rot", 0)), int(entry.get("aim", 0)))
		if not reason.is_empty():
			failures += 1
			printerr("PART_DESTROY_FAIL place %s %s" % [entry["id"], reason])
			return {}
	var duel := Duel.new()
	if not duel.setup(definitions):
		failures += 1
		printerr("PART_DESTROY_FAIL duel_setup")
		return {}
	duel.load_arena("arena_standard")
	var spawn: Dictionary = duel.spawn_point("arena_standard", 0)
	if not duel.add_side(Duel.TAG_PLAYER, builder, Vector2(spawn["pos"]), float(spawn["rot"])):
		failures += 1
		printerr("PART_DESTROY_FAIL add_side")
		return {}
	return {"duel": duel, "builder": builder}

## 标准船体：两门炮 + 一条工厂→直管→炮管的供弹链。
func _make_gunship() -> Dictionary:
	var cells: Array = []
	for y in range(2):
		for x in range(6):
			cells.append(Vector2i(x, y))
	return _make_duel(cells, [
		{"id": "track_light", "cell": Vector2i(0, 0), "layer": "mobility"},
		{"id": "engine_small", "cell": Vector2i(1, 1)},
		{"id": "cockpit_light", "cell": Vector2i(2, 1)},
		{"id": "ammo_factory_20", "cell": Vector2i(3, 0)},
		{"id": "conveyor_straight", "cell": Vector2i(4, 0)},
		{"id": "cannon_20", "cell": Vector2i(5, 0)},
		{"id": "cannon_20", "cell": Vector2i(5, 1)},
	])

## 主块 2×2（驾驶舱在 (4,4)）+ 单格脖颈 (6,4) + 远端 2×2（炮管在 (7,4)）。
func _make_neck_rig() -> Dictionary:
	return _make_duel([
		Vector2i(4, 4), Vector2i(5, 4), Vector2i(4, 5), Vector2i(5, 5),
		Vector2i(6, 4),
		Vector2i(7, 4), Vector2i(8, 4), Vector2i(7, 5), Vector2i(8, 5),
	], [
		{"id": "cockpit_light", "cell": Vector2i(4, 4)},
		{"id": "cannon_20", "cell": Vector2i(7, 4)},
	])

func _part_index_at(tank: TankBody, cell: Vector2i, kind: String = "") -> int:
	for index in range(tank.parts.size()):
		var part: Dictionary = tank.parts[index]
		if not kind.is_empty() and String(part["kind"]) != kind:
			continue
		if cell in (part["cells"] as Array):
			return index
	return -1

func _bank_index_at(bank, cell: Vector2i) -> int:
	for index in range(bank.cannons.size()):
		if Vector2i(bank.cannons[index]["cell"]) == cell:
			return index
	return -1

## 走 `apply_part_damage()`：它会触发 `_on_destroyed()` 的殉爆 / 脱落 / 结构变更通知链。
func _destroy_at(duel, cell: Vector2i, kind: String = "module") -> void:
	var tank: TankBody = duel.tank_of(Duel.TAG_PLAYER)
	var count := tank.parts.size()
	for index in range(count):
		var part: Dictionary = tank.parts[index]
		if cell not in (part["cells"] as Array):
			continue
		if kind == "module" and String(part["kind"]) != TankBody.KIND_MODULE:
			continue
		if kind == "platform" and String(part["kind"]) != TankBody.KIND_PLATFORM_CELL:
			continue
		duel.damage_of(Duel.TAG_PLAYER).apply_part_damage(tank, index, 1.0e9, "destroyed")
		return
	failures += 1
	printerr("PART_DESTROY_FAIL missing_part %s" % str(cell))

# ─── 断言 1：被打掉的炮管必须离开 `CannonBank.cannons` ────────────────────────

func _check_cannon_leaves_bank() -> void:
	var rig := _make_gunship()
	if rig.is_empty():
		return
	var duel = rig["duel"]
	var bank = duel.bank_of(Duel.TAG_PLAYER)
	_expect(bank.cannons.size() == 2, "bank_two_cannons_%d" % bank.cannons.size())
	_expect(_bank_index_at(bank, Vector2i(5, 1)) >= 0, "bank_has_second_cannon")

	_destroy_at(duel, Vector2i(5, 1))
	_expect(bank.cannons.size() == 1, "bank_after_destroy_%d" % bank.cannons.size())
	_expect(_bank_index_at(bank, Vector2i(5, 1)) < 0, "bank_dropped_destroyed_cannon")
	_expect(_bank_index_at(bank, Vector2i(5, 0)) >= 0, "bank_kept_live_cannon")
	# 管路网络里同一条事实也必须同步：`AmmoNetwork.parts` 是另一份副本。
	_expect(duel.network_of(Duel.TAG_PLAYER).cannon_states().size() == 1,
		"net_cannon_states_%d" % duel.network_of(Duel.TAG_PLAYER).cannon_states().size())

# ─── 断言 2：最后一个炮管没了 → 再也打不出炮弹（用户可见结果） ────────────────

func _check_last_cannon_blocks_fire() -> void:
	var rig := _make_gunship()
	if rig.is_empty():
		return
	var duel = rig["duel"]
	var bank = duel.bank_of(Duel.TAG_PLAYER)
	# 先把两门炮都上膛，证明「能开火」不是因为它一直是空的。
	_expect(bank.load_all() == 2, "fire_preloaded_%d" % bank.load_all())
	_expect(duel.can_fire(Duel.TAG_PLAYER), "fire_possible_before")

	_destroy_at(duel, Vector2i(5, 0))
	_destroy_at(duel, Vector2i(5, 1))
	_expect(bank.cannons.is_empty(), "fire_cannons_empty_%d" % bank.cannons.size())
	_expect(not duel.can_fire(Duel.TAG_PLAYER), "fire_cannot_fire_after")
	_expect(duel.fire(Duel.TAG_PLAYER) == 0, "fire_emits_nothing_after")

# ─── 断言 3：重建不丢状态 —— 活着的炮管装填进度必须原样保留 ──────────────────

func _check_survivor_keeps_load_state() -> void:
	var rig := _make_gunship()
	if rig.is_empty():
		return
	var duel = rig["duel"]
	var bank = duel.bank_of(Duel.TAG_PLAYER)
	var keeper := _bank_index_at(bank, Vector2i(5, 0))
	_expect(keeper >= 0, "keep_index_found")
	if keeper < 0:
		return
	# 打一发让两门炮都进入冷却，再走 0.1 s：`reload_remaining` 变成「部分冷却」。
	bank.load_all()
	bank.fire("cal_20")
	bank.step(0.1)
	var reload_before := float(bank.cannons[keeper]["reload_remaining"])
	var shots_before := int(bank.cannons[keeper]["shots_fired"])
	var reload_s := float(bank.cannons[keeper]["reload_s"])
	_expect(reload_before > 0.0 and reload_before < reload_s, "keep_mid_cooldown_%.4f" % reload_before)

	_destroy_at(duel, Vector2i(5, 1))
	var now := _bank_index_at(bank, Vector2i(5, 0))
	_expect(now >= 0, "keep_survivor_present")
	if now < 0:
		return
	_expect_near(float(bank.cannons[now]["reload_remaining"]), reload_before, "keep_reload_preserved")
	_expect(int(bank.cannons[now]["shots_fired"]) == shots_before, "keep_shots_preserved_%d" % int(bank.cannons[now]["shots_fired"]))
	_expect(not bool(bank.cannons[now]["loaded"]), "keep_loaded_preserved")

# ─── 断言 4：弹药制造装置被打掉 → 网络里不再有它 ──────────────────────────────

func _check_factory_leaves_network() -> void:
	var rig := _make_gunship()
	if rig.is_empty():
		return
	var duel = rig["duel"]
	var network = duel.network_of(Duel.TAG_PLAYER)
	_expect(_has_module(network.module_states(), "ammo_factory_20"), "net_factory_present_before")
	## 正向对照用**炮管**而不是直管：`module_states()` 只报制造/存量/改进/炮管四种角色，
	## 管路件（conveyor）与引擎/驾驶舱它一律跳过，拿它当「还在不在」的判据会假红（v3.50 实测）。
	_expect(_has_module(network.module_states(), "cannon_20"), "net_cannon_present_before")

	_destroy_at(duel, Vector2i(3, 0))
	_expect(not _has_module(network.module_states(), "ammo_factory_20"), "net_factory_gone_after")
	# 正向对照：同一份网络里别的模块必须还在（证明不是「整份清空」造成的假通过）。
	_expect(_has_module(network.module_states(), "cannon_20"), "net_cannon_still_there")

func _has_module(states: Array, module_id: String) -> bool:
	for raw in states:
		if String((raw as Dictionary)["module_id"]) == module_id:
			return true
	return false

# ─── 断言 5：detach（脖颈被切断）也必须刷新 ──────────────────────────────────

func _check_detach_refreshes_bank() -> void:
	var rig := _make_neck_rig()
	if rig.is_empty():
		return
	var duel = rig["duel"]
	var bank = duel.bank_of(Duel.TAG_PLAYER)
	_expect(bank.cannons.size() == 1, "detach_cannon_before_%d" % bank.cannons.size())
	_expect(_bank_index_at(bank, Vector2i(7, 4)) >= 0, "detach_cannon_on_far_island")

	_destroy_at(duel, Vector2i(6, 4), "platform")
	_expect(_part_index_at(duel.tank_of(Duel.TAG_PLAYER), Vector2i(7, 4)) < 0, "detach_far_cannon_removed")
	_expect(bank.cannons.is_empty(), "detach_bank_refreshed_%d" % bank.cannons.size())
	_expect(duel.network_of(Duel.TAG_PLAYER).cannon_states().is_empty(), "detach_net_refreshed")

# ─── 断言 6：试驾页必须接线（否则试驾里炮管被打掉仍能开火） ──────────────────

func _check_drive_page_wired() -> void:
	var source := _read_source("res://scripts/main.gd")
	_expect(_has_code_line(source, "func _drive_refresh_structure()"), "drive_refresh_fn")
	_expect(_has_code_line(source, "damage.structure_changed = Callable(self, \"_drive_refresh_structure\")"), "drive_refresh_wired")
	_expect(_has_code_line(source, "bank.reload_from_body()"), "drive_reload_bank")
	_expect(_has_code_line(source, "network.rebuild(builder)"), "drive_rebuild_network")

# ─── 断言 7：三页都要推 `part_debris`，绘制层必须有分支 ──────────────────────

func _check_debris_wired_three_pages() -> void:
	var main_source := _read_source("res://scripts/main.gd")
	# 三页各一处：对局（`_match_fx.push`）/ 生存 / 试驾（`_push_survival_fx`、`_push_drive_fx`）。
	_expect(_has_code_line(main_source, "_match_fx.push(\"part_debris\""), "debris_match_page")
	_expect(_has_code_line(main_source, "_push_survival_fx(\"part_debris\""), "debris_survival_page")
	_expect(_has_code_line(main_source, "_push_drive_fx(\"part_debris\""), "debris_drive_page")
	var view_source := _read_source("res://scripts/combat_view.gd")
	_expect(_has_code_line(view_source, "if kind == \"part_debris\":"), "debris_kind_branch")
	_expect(_has_code_line(view_source, "static func draw_part_debris("), "debris_draw_fn")
	_expect(_has_code_line(view_source, "const PART_DEBRIS_TIME"), "debris_time_const")
	_expect(_has_code_line(view_source, "const PART_DEBRIS_RADIUS_PER_CELL"), "debris_radius_const")
	# 确定性纪律：碎片不许引入随机源。
	_expect(not _has_code_line(view_source, "randf"), "debris_no_randf")
	_expect(not _has_code_line(view_source, "randi"), "debris_no_randi")

# ─── 源码读取（注释行不算代码：修复说明本身会写到这些串） ────────────────────

func _read_source(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		failures += 1
		printerr("PART_DESTROY_FAIL read_%s" % path)
		return ""
	return file.get_as_text()

func _has_code_line(source: String, needle: String) -> bool:
	for raw_line in source.split("\n"):
		var line := String(raw_line)
		if line.strip_edges().begins_with("#"):
			continue
		if line.contains(needle):
			return true
	return false
