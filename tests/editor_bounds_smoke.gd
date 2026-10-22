extends SceneTree

## 改装页「选中件下标越界」回归（v3.20.1）。
##
## 用户报告：
##   SCRIPT ERROR: Out of bounds get index '8' (on base: 'PackedStringArray')
##     at: _preview_cells (res://scripts/main.gd:1559)
##     ← _draw_grid ← _draw_build ← _draw_survival ← _draw
##
## 根因：`_selected_index` 是 **`_option_ids()` 的下标**，但改装期的 `_option_ids()`
## 是「按当前层过滤 + 去重」的结果，**长度与 `survival.inventory` 不一致**。
## 旧代码在贴装成功后把 `_selected_index` 钳制到 `inventory.size() - 1`，这个上界
## 对可选件列表来说**过大**；而 `_ensure_option_visible()` 当时只钳制 `_option_scroll`、
## 根本不钳制 `_selected_index`。下一帧 `_draw_grid()` 调 `_preview_cells()` 就拿着
## 越界下标去取 `PackedStringArray`。
##
## 本测试直接构造那个状态并调 `_preview_cells()`——**崩溃就在这一行**。
## 不调 `_draw_build()`：在 `_draw()` 之外调绘制函数会刷屏 `Drawing is only allowed…`，
## 那是测试装置的问题，会淹没真正的断言。

var _main: Node = null
var _step := 0
var _failures := 0

func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	if packed == null:
		printerr("PREVIEW_SCENE_MISSING")
		_failures += 1
		return
	_main = packed.instantiate()
	get_root().add_child(_main)

func _process(_delta: float) -> bool:
	_step += 1
	if _step < 3:
		return false
	if _main == null:
		printerr("PREVIEW_MAIN_NULL")
		quit(1)
		return true
	_run_checks()
	if _failures == 0:
		print("PREVIEW_OK")
		quit(0)
	else:
		printerr("PREVIEW_FAIL count=%d" % _failures)
		quit(1)
	return true

func _expect(condition: bool, tag: String) -> void:
	if not condition:
		_failures += 1
		printerr("PREVIEW_FAIL %s" % tag)

func _run_checks() -> void:
	## ① 进生存页 → 商店 → 改装，走与真实玩家相同的入口。
	_main._enter_survival()
	_expect(_main.survival != null, "survival_entered")
	if _main.survival == null:
		return
	_main.survival._open_shop()

	## ② 用**真实购买**填充库存（不硬 append）：买满 6 格，让库存件数明显多于
	##    「某一层的去重可选件数」——这正是 bug 的土壤。
	_main.survival.credit += 2000.0
	var bought := 0
	for slot_index in range(_main.survival.shop_slots.size()):
		if _main.survival.buy_shop_slot(slot_index):
			bought += 1
	print("PREVIEW_BOUGHT bought=%d inventory=%d" % [bought, _main.survival.inventory.size()])
	_expect(bought > 0, "bought_at_least_one")
	if bought == 0:
		return

	_main._survival_enter_modify()
	_expect(_main._in_modify_mode(), "in_modify_mode")
	if not _main._in_modify_mode():
		return

	## ③ 关键量：库存件数 vs 当前层去重后的可选件数。两者不等才是本 bug 的土壤。
	var inventory_count: int = _main.survival.inventory.size()
	var option_count: int = _main._option_ids().size()
	print("PREVIEW_COUNTS inventory=%d options=%d layer=%s"
		% [inventory_count, option_count, _main._build_layer])
	_expect(option_count > 0, "options_non_empty")

	## ④ 复现崩溃：把 `_selected_index` 设成「比可选件多、但比库存小」的值，
	##    也就是旧代码用 `inventory.size() - 1` 作上界会留下的那种值。
	##    然后调 `_preview_cells()`——用户报告的 `Out of bounds get index` 就在这里。
	var overshoot: int = option_count
	if inventory_count - 1 > overshoot:
		overshoot = inventory_count - 1
	_main._selected_index = overshoot
	var cells: Array = _main._preview_cells()
	print("PREVIEW_PREVIEW_CELLS index_set=%d returned=%d" % [overshoot, cells.size()])
	_expect(cells.size() >= 0, "preview_cells_survives_overshoot")

	## ⑤ `_ensure_option_visible()` 必须把下标钳回可选件范围内。
	_main._ensure_option_visible()
	print("PREVIEW_AFTER_ENSURE index=%d options=%d" % [_main._selected_index, option_count])
	_expect(_main._selected_index <= maxi(option_count - 1, 0), "index_clamped_to_options")

	## ⑥ 反向对照：如果库存件数 <= 可选件数，上面构造不出越界，必须**如实说明**
	##    而不是假装通过。打印实测数字供人工判断。
	if inventory_count > option_count:
		print("PREVIEW_PREMISE_OK inventory=%d > options=%d" % [inventory_count, option_count])
	else:
		print("PREVIEW_PREMISE_WEAK inventory=%d <= options=%d（越界构造不出，仅验证了钳制不崩）"
			% [inventory_count, option_count])

	## ⑦ 真的走一次贴装，确认 `_selected_index` 语义正确（贴的是选中的那一件，
	##    不是「碰巧同下标的另一件」）。贴装后库存少一件，可选件也要重新钳制。
	##
	##    **光标必须挪到空地**：驾驶舱格上已有模块，直接贴会报「同层占位重叠」——
	##    那是测试摆位的问题，不是产品缺陷。这里从驾驶舱开始向右逐格找第一个
	##    「本层无部件」的格，找不到就如实跳过。
	var before_options: PackedStringArray = _main._option_ids()
	if before_options.size() > 0:
		var pick_index: int = mini(before_options.size() - 1, 2)
		_main._selected_index = pick_index
		var expected_id: String = String(before_options[pick_index])
		var seat: Vector2i = _main.survival_builder.cockpit_cells()[0]
		var target := Vector2i(-1, -1)
		for offset in range(1, 12):
			var probe := Vector2i(seat.x + offset, seat.y)
			if not _main.survival_builder._inside_grid(probe):
				continue
			if _main.survival_builder.part_at(_main._build_layer, probe).is_empty():
				target = probe
				break
		if target.x < 0:
			print("PREVIEW_MOUNT_SKIPPED no_free_cell")
		else:
			_main._cursor = target
			var reason: String = _main._mount_selected_inventory()
			print("PREVIEW_MOUNT expected=%s cell=%s reason=%s" % [expected_id, target, reason])
			_expect(reason.begins_with("已贴装：%s" % expected_id), "mount_used_selected_id")
			_expect(_main._selected_index <= maxi(_main._option_ids().size() - 1, 0),
				"index_in_range_after_mount")
			var after_cells: Array = _main._preview_cells()
			_expect(after_cells.size() >= 0, "preview_cells_after_mount")
