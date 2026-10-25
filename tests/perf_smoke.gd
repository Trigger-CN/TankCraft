extends SceneTree

## v3.30 永久性能回归：生存模式逻辑步进的**长尾**预算。
##
## 为什么存在这个测试（design §11.4.2.14）：
##   用户报告「生存模式有卡顿，甚至长时间卡顿」。实测 root cause 是 `TankBody` 的碰撞层：
##   `cells_overlap_tank()` 无条件跑逐格两两 SAT（O(n×m)），而 `apply_obstacles()` 与
##   `world_bounds()` 每次调用都从零重建几万个 Vector2。wave12 单步 135 ms、p99 219 ms，
##   **是同屏坦克数平方级的成本，且与「是否真的碰上」无关**。
##
## **本测试刻意只断言长尾（p99 / max），不断言平均。** 平均值会把卡顿藏起来：
##   修前 wave12 mean=135.2 而 p99=219.3；若只看平均，很容易把「偶发 200 ms 冻结」
##   当成「整体慢一点」而放过。
##
## 阈值给的是**回归护栏**，不是性能目标：
##   - 修后实测 wave1 2.25 / wave5 4.16 / wave8 4.61 / wave12 8.73（mean）；
##     对应 p99 = 4.63 / 8.87 / 9.49 / 19.00，max = 5.45 / 10.26 / 12.80 / 21.70。
##   - 阈值取实测的 2–4 倍，既容得下 CI 抖动，又能在「退回旧算法」时立刻炸掉
##     （旧算法 wave12 是 p99 219 / max 236，差一个数量级）。
##
## 纯 headless、无渲染；只驱动 `SurvivalRun`（不实例化主场景）。

const ModuleDefs := preload("res://scripts/module_defs.gd")
const GridBuilder := preload("res://scripts/grid_builder.gd")
const SurvivalRun := preload("res://scripts/survival_run.gd")
const Duel := preload("res://scripts/duel.gd")

## 每波采样步数。900 步 = 15 s 的模拟时间，足以跨过一次补兵与多次开火。
const STEPS_PER_WAVE := 900
## 固定种子：分数必须可复现（本测试只比时长，不与内容签名挂钩，但共用同一条轨迹更稳）。
const SEED := 7

var definitions: ModuleDefs
var failures := 0

## 波次 → (p99 上限 ms, max 上限 ms)。键必须与 `_check_wave` 的调用一致。
##
## **阈值怎么定的**（很重要，别随便放宽）：
##  修后实测 p99 = 3.85 / 6.56 / 6.29 / 16.32（wave 1/5/8/12）。
##  接着做了一次**反向对照**：只把两份缓存关掉（分桶与剔除仍在），
##  p99 立刻变成 8.23 / 12.54 / 16.82 / 31.09 —— 每一项都翻倍。
##  所以 `p99` 阈值取「修后实测 × ~1.6~1.7」，既容得下本机抖动，又能让「退回无缓存」当场失败。
##  **先收紧再验证过反向对照**，不是拍脑袋定的。
##
## `max` 阈值必须比 p99 宽得多 —— **这是已知且本轮未修的事实**：
##  `spawn_enemy_us` 实测 2.6–10.7 ms（补兵时一次性建 144 部件坦克），
##  是**单独一帧的尖峰**，与碰撞层无关。一次运行里只要有 1 次补兵，max 就会含它。
##  实测 max 在 wave8 一次跑了 33.09 ms（仅 1/900 步）。所以 max 阈取 ~2x p99 阈值。
const BUDGETS := {
	1: [8.0, 30.0],
	5: [11.0, 30.0],
	8: [11.0, 40.0],
	12: [26.0, 60.0],
}

func _init() -> void:
	definitions = ModuleDefs.new()
	if not definitions.load_all():
		printerr("PERF_DATA_FAILED")
		quit(1)
		return
	for raw_wave in [1, 5, 8, 12]:
		_check_wave(int(raw_wave))
	if failures > 0:
		printerr("PERF_FAIL count=%d" % failures)
		quit(1)
		return
	print("PERF_OK")
	quit(0)

func _make_run(wave: int) -> SurvivalRun:
	var builder := GridBuilder.new()
	if not builder.setup(definitions):
		return null
	if not SurvivalRun.build_starter(builder).is_empty():
		return null
	var run_state := SurvivalRun.new()
	if not run_state.setup(definitions, "arena_standard", SEED):
		return null
	run_state.wave = wave
	run_state.bind_player(builder)
	if not run_state.start_wave():
		return null
	return run_state

func _check_wave(wave: int) -> void:
	var run_state := _make_run(wave)
	if run_state == null:
		failures += 1
		printerr("PERF_FAIL setup_wave_%d" % wave)
		return
	var dt := 1.0 / 60.0
	var samples: Array[float] = []
	for index in range(STEPS_PER_WAVE):
		if run_state.stage != SurvivalRun.STAGE_BATTLE:
			## 玩家被打死就重开同一波继续采样：单步成本不因重开而改变。
			run_state.wave = wave
			if not run_state.start_wave():
				break
		var started := Time.get_ticks_usec()
		run_state.step_battle(dt)
		samples.append(float(Time.get_ticks_usec() - started) / 1000.0)
	if samples.size() < STEPS_PER_WAVE / 2:
		failures += 1
		printerr("PERF_FAIL too_few_samples_wave_%d_%d" % [wave, samples.size()])
		return
	var ordered: Array[float] = []
	for value in samples:
		ordered.append(float(value))
	ordered.sort()
	var p99: float = ordered[mini(int(floorf(float(ordered.size()) * 0.99)), ordered.size() - 1)]
	var worst: float = ordered[ordered.size() - 1]
	var budget: Array = BUDGETS[wave]
	print("PERF wave=%d samples=%d p99=%.2fms max=%.2fms budget_p99=%.0f budget_max=%.0f" % [
		wave, ordered.size(), p99, worst, float(budget[0]), float(budget[1]),
	])
	if p99 > float(budget[0]):
		failures += 1
		printerr("PERF_FAIL p99_wave_%d %.2f > %.2f" % [wave, p99, float(budget[0])])
	if worst > float(budget[1]):
		failures += 1
		printerr("PERF_FAIL max_wave_%d %.2f > %.2f" % [wave, worst, float(budget[1])])
