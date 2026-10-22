extends SceneTree

## M2 运行期 BUILD_MODE 回归：scrap 支付、施工计时、受击中断、拆解返还与远征限制。

const ModuleDefs := preload("res://scripts/module_defs.gd")
const RuntimeBuilder := preload("res://scripts/runtime_builder.gd")

var _runtime: RuntimeBuilder

func _init() -> void:
	var definitions := ModuleDefs.new()
	if not definitions.load_all():
		_fail("RUNTIME_DATA_FAILED")
		return
	_runtime = RuntimeBuilder.new()
	if not _runtime.setup(definitions):
		_fail("RUNTIME_SETUP_FAILED")
		return
	_runtime.reset_demo()

	# 1. 非 EXPEDITION 一律拒绝进入建造模式。
	_runtime.set_mode("VERSUS")
	if _runtime.enter_build_mode().is_empty():
		_fail("RUNTIME_VERSUS_ACCEPTED")
		return
	_runtime.set_mode("EXPEDITION")
	# 2. 未进入建造模式时不允许施工。
	if _runtime.request_build("module", "conveyor_straight", Vector2i(6, 6)).is_empty():
		_fail("RUNTIME_BUILD_OUTSIDE_MODE")
		return
	if not _runtime.enter_build_mode().is_empty():
		_fail("RUNTIME_ENTER_FAILED")
		return
	if not _runtime.movement_locked():
		_fail("RUNTIME_MOVEMENT_NOT_LOCKED")
		return
	# 3. scrap 不足必须原子拒绝。
	_runtime.set_scrap(0.0)
	if _runtime.request_build("module", "conveyor_straight", Vector2i(6, 6)).is_empty():
		_fail("RUNTIME_FREE_BUILD_ACCEPTED")
		return
	if not is_equal_approx(_runtime.scrap, 0.0) or _runtime.is_building():
		_fail("RUNTIME_FREE_BUILD_SIDE_EFFECT")
		return
	_runtime.set_scrap(1000.0)
	# 4. 一格部件：扣 6 scrap，需 0.6 s。
	if not _runtime.request_build("module", "conveyor_straight", Vector2i(6, 6)).is_empty():
		_fail("RUNTIME_CONVEYOR_REJECTED")
		return
	if not is_equal_approx(_runtime.scrap, 994.0):
		_fail("RUNTIME_CONVEYOR_COST %s" % _runtime.scrap)
		return
	if not _runtime.is_building():
		_fail("RUNTIME_CONVEYOR_NOT_PENDING")
		return
	if not _runtime.part_at_module(Vector2i(6, 6)).is_empty():
		_fail("RUNTIME_CONVEYOR_INSTANT")
		return
	_runtime.tick(0.5)
	if not _runtime.is_building():
		_fail("RUNTIME_CONVEYOR_TOO_FAST")
		return
	_runtime.tick(0.2)
	if _runtime.is_building():
		_fail("RUNTIME_CONVEYOR_NOT_FINISHED")
		return
	if _runtime.part_at_module(Vector2i(6, 6)).is_empty():
		_fail("RUNTIME_CONVEYOR_MISSING")
		return
	# 5. 平台格：与新平台 4-连通才允许。
	if not _runtime.request_build("platform", "platform_cell", Vector2i(14, 8)).is_empty():
		_fail("RUNTIME_PLATFORM_REJECTED")
		return
	_runtime.tick(0.7)
	if not _runtime.builder.platform_cells.has(Vector2i(14, 8)):
		_fail("RUNTIME_PLATFORM_MISSING")
		return
	# 6. 两格模块：1.2 s 施工时间。
	if not _runtime.request_build("module", "engine_medium", Vector2i(12, 7)).is_empty():
		_fail("RUNTIME_ENGINE_REJECTED")
		return
	if not is_equal_approx(_runtime.scrap, 870.0):
		_fail("RUNTIME_ENGINE_COST %s" % _runtime.scrap)
		return
	_runtime.tick(1.0)
	if not _runtime.is_building():
		_fail("RUNTIME_ENGINE_TOO_FAST")
		return
	_runtime.tick(0.25)
	if _runtime.is_building() or _runtime.part_at_module(Vector2i(12, 7)).is_empty():
		_fail("RUNTIME_ENGINE_TIMING")
		return
	# 7. 受击中断：已付 scrap 不返还，部件不落地。
	if not _runtime.request_build("module", "ammo_depot_small", Vector2i(6, 7)).is_empty():
		_fail("RUNTIME_DEPOT_REJECTED")
		return
	var before_hit := _runtime.scrap
	if _runtime.notify_hit(Vector2i(6, 7)).is_empty():
		_fail("RUNTIME_HIT_IGNORED")
		return
	if _runtime.is_building() or not is_equal_approx(_runtime.scrap, before_hit):
		_fail("RUNTIME_HIT_REFUNDED %s" % _runtime.scrap)
		return
	_runtime.tick(1.0)
	if not _runtime.part_at_module(Vector2i(6, 7)).is_empty():
		_fail("RUNTIME_HIT_STILL_BUILT")
		return
	# 8. 无关格受击不影响施工。
	if not _runtime.request_build("module", "conveyor_straight", Vector2i(6, 7)).is_empty():
		_fail("RUNTIME_SECOND_CONVEYOR_REJECTED")
		return
	if not _runtime.notify_hit(Vector2i(0, 0)).is_empty() or not _runtime.is_building():
		_fail("RUNTIME_UNRELATED_HIT_ABORTED")
		return
	if _runtime.exit_build_mode().is_empty() or _runtime.is_building():
		_fail("RUNTIME_EXIT_PENDING_SILENT")
		return
	if _runtime.movement_locked():
		_fail("RUNTIME_MOVEMENT_STILL_LOCKED")
		return
	# 退出后未完成施工不落地、不返还。
	if not _runtime.part_at_module(Vector2i(6, 7)).is_empty():
		_fail("RUNTIME_EXIT_BUILT_ANYWAY")
		return
	if not _runtime.enter_build_mode().is_empty():
		_fail("RUNTIME_REENTER_FAILED")
		return
	# 9. 拆解驾驶舱被禁止。
	if _runtime.request_dismantle("module", Vector2i(9, 8)).is_empty():
		_fail("RUNTIME_COCKPIT_DISMANTLED")
		return
	# 10. 拆掉最后一个行进机构被禁止。
	if _runtime.request_dismantle("mobility", Vector2i(7, 9)).is_empty():
		_fail("RUNTIME_LAST_MOBILITY_DISMANTLED")
		return
	# 11. 正常拆解返还 price × 0.5。
	var before_dismantle := _runtime.scrap
	if not _runtime.request_dismantle("module", Vector2i(8, 7)).is_empty():
		_fail("RUNTIME_DISMANTLE_REJECTED")
		return
	if not is_equal_approx(_runtime.scrap, before_dismantle + 3.0):
		_fail("RUNTIME_DISMANTLE_REFUND %s" % _runtime.scrap)
		return
	if not _runtime.part_at_module(Vector2i(8, 7)).is_empty():
		_fail("RUNTIME_DISMANTLE_LEFT_PART")
		return
	# 12. 运行期质量上限用 scrap 购买。
	var before_upgrade := _runtime.scrap
	var level_before := _runtime.builder.mass_cap_level
	if not _runtime.purchase_mass_upgrade().is_empty():
		_fail("RUNTIME_MASS_UPGRADE_REJECTED")
		return
	if _runtime.builder.mass_cap_level != level_before + 1:
		_fail("RUNTIME_MASS_UPGRADE_LEVEL")
		return
	if not is_equal_approx(_runtime.scrap, before_upgrade - 60.0):
		_fail("RUNTIME_MASS_UPGRADE_COST %s" % _runtime.scrap)
		return
	# 13. 已有施工时禁止并发与拆解。
	if not _runtime.request_build("module", "conveyor_straight", Vector2i(8, 7)).is_empty():
		_fail("RUNTIME_REBUILD_REJECTED")
		return
	if _runtime.request_build("module", "conveyor_straight", Vector2i(7, 8)).is_empty():
		_fail("RUNTIME_CONCURRENT_BUILD")
		return
	if _runtime.request_dismantle("module", Vector2i(10, 7)).is_empty():
		_fail("RUNTIME_DISMANTLE_DURING_BUILD")
		return
	_runtime.tick(0.7)

	print("RUNTIME_OK scrap=%.1f level=%d cells=%d modules=%d mobility=%d" % [
		_runtime.scrap,
		_runtime.builder.mass_cap_level,
		_runtime.builder.platform_occupancy().size(),
		_runtime.builder.module_parts.size(),
		_runtime.builder.mobility_parts.size(),
	])
	quit(0)

func _fail(code: String) -> void:
	printerr(code)
	quit(1)
