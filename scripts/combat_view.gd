extends RefCounted

## 战斗视图的唯一实现（v3.22 从 `main.gd` 抽出）。
##
## 抽出的理由：对局页与生存页原本各有一整套逐行同构的战斗绘制——竞技场底板、障碍、
## 房屋残骸、弹道、动效圆环、伤害数字——差异只有动效风格参数与坐标细节。两份副本各自
## 演化，结果对局页始终没拿到生存页早就有的命中闪光与血量分档上色。合成一个类之后，
## 「新增一种战斗表现」只需要改一处，所有战斗模式自动获得。
##
## 设计约束（与 design §2.3 / agent_note §8 一致）：
## - **全部 static 无状态**：可变状态（`FxLayer`、命中闪光剩余时间）留在页面层，组件只做
##   「把给定状态画出来」。这样生存页切换过来时一个字节的像素都不会变，也让组件本身可以
##   被任何页面以任意参数复用，不存在「哪个实例才持有真状态」的歧义。
## - 绘制函数一律接收 `canvas: CanvasItem` 并用 `canvas.draw_*`。Godot 允许在 `_draw()`
##   周期内从别处调用这些方法，因此不必新增 Node2D（单场景架构下新增节点还要额外管理
##   z 序与生命周期）。
## - `draw_string` 需要页面层的双字体，所以文本绘制以 `text_fn: Callable` 注入，
##   签名与 `main.gd` 的 `_draw_text(text, position, size, color, mono)` 一致。
## - 不使用 `randf` / `randi`；任何脉动相位由调用方用 `sin(_time * …)` 提供。
##
## 刻意**不**在这里的东西：
## - 车体本身的逐格绘制（`main.gd` 的 `_draw_hull_shared()`，带 `effects` 尾参，三页共用）。
##   这里只提供它的着色判据（`hull_damage_colour` / `hull_damage_alpha`）。
## - 坦克镜像面板：它与生存 run 的 inventory / wave / level 强耦合，抽出去只会把生存语义
##   灌进通用组件。镜像复用是独立的后续目标。

const Palette := preload("res://scripts/palette.gd")
const FxLayer := preload("res://scripts/fx_layer.gd")

## 命中闪光持续时间（秒，固定步长累减）。
const HIT_FLASH_TIME := 0.14
## 伤害悬浮数字：上升距离与存活时长。
const DAMAGE_POPUP_RISE := 46.0
const DAMAGE_POPUP_LIFE := 0.85
## 同一帧同一模式最多显示几条数字：多炮齐射或殉爆时避免数字糊成一团。
const DAMAGE_POPUP_PER_SIDE := 6
## 同帧多条数字的垂直错开步长（像素）。
const DAMAGE_POPUP_STACK_STEP := 14.0

## 动效圆环的默认风格：生存页这一套（半径随剩余寿命线性收，带半透明填充）。
const FX_STYLE_SURVIVAL := {
	"radius_base": 0.6,
	"radius_grow": 0.4,
	"min_radius": 2.0,
	"arc_points": 20,
	"arc_width": 1.5,
	"fill_scale": 0.5,
	"alpha_scale": 0.75,
}

## 对局页这一套：半径从满尺寸向外扩张（`1.0 - 0.8t`），不画填充，描边更粗。
const FX_STYLE_MATCH := {
	"radius_base": 1.0,
	"radius_grow": -0.8,
	"min_radius": 0.0,
	"arc_points": 24,
	"arc_width": 2.0,
	"fill_scale": 0.0,
	"alpha_scale": 0.8,
}

## 世界坐标 → 屏幕坐标。
##
## 三页原本各有一份逐字相同的副本（`_drive_to_screen` / `_match_to_screen` /
## `_survival_to_screen`），差别只在读哪个会话对象。每个页面**必须传自己的竞技场**，
## 复用别的页面的竞技场会静默算出错误比例（M6 已踩过一次）。
static func to_screen(view: Rect2, arena: Rect2, world: Vector2, scale_factor: float) -> Vector2:
	return view.position + (world - arena.position) * scale_factor


## 竞技场 → 视图的缩放系数：把整个竞技场宽度铺满视图宽度。
static func fit_scale(view: Rect2, arena: Rect2) -> float:
	if arena.size.x <= 0.0:
		return 1.0
	return view.size.x / arena.size.x


## 把 `data/arenas/*.json` 的**格单位**障碍换算成世界像素。
##
## 换算只在调用方做一次：生存页读原始数据文件，而对局页的 `duel.obstacles` 已经由
## `Duel.load_arena()` 换算过。两者形态不同，所以统一在进入绘制前正规化。
static func scale_obstacles(raw_obstacles: Array, cell_px: float) -> Array:
	var result: Array = []
	for raw_obstacle in raw_obstacles:
		var obstacle: Dictionary = raw_obstacle
		if obstacle.has("rect"):
			var r: Array = obstacle["rect"]
			result.append({
				"shape": "rect",
				"rect": Rect2(Vector2(float(r[0]), float(r[1])) * cell_px, Vector2(float(r[2]), float(r[3])) * cell_px),
			})
		elif obstacle.has("circle"):
			var c: Array = obstacle["circle"]
			result.append({
				"shape": "circle",
				"center": Vector2(float(c[0]), float(c[1])) * cell_px,
				"radius": float(c[2]) * cell_px,
			})
	return result


## 竞技场底板 + 边界 + 固定障碍。
##
## `obstacles` 统一为**已是世界像素**的条目（见 `scale_obstacles()`）：
##   `{shape: "rect", rect: Rect2}` 或 `{shape: "circle", center: Vector2, radius: float}`
static func draw_arena(canvas: CanvasItem, view: Rect2, arena: Rect2, scale_factor: float, obstacles: Array, border_colour: Color) -> void:
	canvas.draw_rect(view, Color(Palette.BG_BASE, 0.94), true)
	canvas.draw_rect(Rect2(view.position, arena.size * scale_factor), border_colour, false, 2.0)
	for raw_obstacle in obstacles:
		var obstacle: Dictionary = raw_obstacle
		if String(obstacle.get("shape", "rect")) == "rect":
			var rect: Rect2 = obstacle["rect"]
			var screen_rect := Rect2(view.position + (rect.position - arena.position) * scale_factor, rect.size * scale_factor)
			canvas.draw_rect(screen_rect, Color(Palette.ACCENT_RED, 0.16), true)
			canvas.draw_rect(screen_rect, Palette.ACCENT_RED, false, 1.5)
		else:
			var centre := to_screen(view, arena, Vector2(obstacle["center"]), scale_factor)
			var radius := float(obstacle["radius"]) * scale_factor
			canvas.draw_circle(centre, radius, Color(Palette.ACCENT_RED, 0.16))
			canvas.draw_arc(centre, radius, 0.0, TAU, 48, Palette.ACCENT_RED, 1.5)


## 地图中立物：可摧毁的房屋（琥珀方块 + 血条）与可碾过的残骸（青色小方块）。
##
## `houses` 每项 `{rect: Rect2, hp: float, hp_max: float, alive: bool}`；
## `debris` 每项 `{cell: Vector2i, taken: bool}`。
## 传空数组即完全不画——对局页没有这两种东西，直接传 `[]`，不需要额外的模式布尔量。
static func draw_neutrals(canvas: CanvasItem, view: Rect2, arena: Rect2, scale_factor: float, houses: Array, debris: Array, cell_px: float) -> void:
	for raw_house in houses:
		var house: Dictionary = raw_house
		if not bool(house.get("alive", true)):
			continue
		var house_rect: Rect2 = house["rect"]
		var screen_house := Rect2(view.position + (house_rect.position - arena.position) * scale_factor, house_rect.size * scale_factor)
		canvas.draw_rect(screen_house, Color(Palette.ACCENT_AMBER, 0.14), true)
		canvas.draw_rect(screen_house, Palette.ACCENT_AMBER, false, 1.5)
		var ratio := clampf(float(house["hp"]) / maxf(float(house["hp_max"]), 0.001), 0.0, 1.0)
		canvas.draw_rect(Rect2(screen_house.position + Vector2(0.0, -6.0), Vector2(screen_house.size.x, 3.0)), Color(Palette.WIRE, 0.4), true)
		canvas.draw_rect(Rect2(screen_house.position + Vector2(0.0, -6.0), Vector2(screen_house.size.x * ratio, 3.0)), Palette.ACCENT_AMBER, true)
	for raw_debris in debris:
		var item: Dictionary = raw_debris
		if bool(item.get("taken", false)):
			continue
		var centre_world := (Vector2(Vector2i(item["cell"])) + Vector2(0.5, 0.5)) * cell_px
		var at := to_screen(view, arena, centre_world, scale_factor)
		var half := cell_px * 0.35 * scale_factor
		var box := Rect2(at - Vector2(half, half), Vector2(half, half) * 2.0)
		canvas.draw_rect(box, Color(Palette.ACCENT_LIME, 0.30), true)
		canvas.draw_rect(box, Palette.ACCENT_LIME, false, 1.0)


## 在途炮弹：拖尾线段 + 弹头圆点。
##
## 颜色按射手分：玩家弹药琥珀、其余品红——这是「谁在打我」的唯一即时线索。
## `player_tag` 由调用方给出，因为多阵营模式下「玩家」不是一个全局常量。
static func draw_shots(canvas: CanvasItem, view: Rect2, arena: Rect2, scale_factor: float, shots: Array, player_tag: String) -> void:
	for raw_shot in shots:
		var shot: Dictionary = raw_shot
		var head := to_screen(view, arena, Vector2(shot["pos"]), scale_factor)
		var tail := to_screen(view, arena, Vector2(shot["prev"]), scale_factor)
		var colour := Palette.ACCENT_AMBER if String(shot["shooter"]) == player_tag else Palette.ACCENT_MAGENTA
		canvas.draw_line(tail, head, Color(colour, 0.7), 1.5)
		canvas.draw_circle(head, maxf(float(shot["radius"]) * scale_factor, 2.0), colour)


## 瞬时动效圆环。
##
## `style` 用来消掉两个战斗模式的**观感差**，而不是让每个模式各写一份绘制：
##   `radius_base` / `radius_grow`  半径系数 = base + grow × t（t 是剩余寿命比例）
##   `min_radius`                   屏幕上的最小半径（像素）
##   `arc_points` / `arc_width`     描边段数与线宽
##   `fill_scale`                   圆内填充的 alpha 倍率；0 表示不画填充
##   `alpha_scale`                  描边 alpha 倍率
## 缺省用 `FX_STYLE_SURVIVAL`，对局页传 `FX_STYLE_MATCH`。
static func draw_fx(canvas: CanvasItem, view: Rect2, arena: Rect2, scale_factor: float, entries: Array, style: Dictionary = FX_STYLE_SURVIVAL) -> void:
	var radius_base := float(style.get("radius_base", 0.6))
	var radius_grow := float(style.get("radius_grow", 0.4))
	var min_radius := float(style.get("min_radius", 2.0))
	var arc_points := int(style.get("arc_points", 20))
	var arc_width := float(style.get("arc_width", 1.5))
	var fill_scale := float(style.get("fill_scale", 0.5))
	var alpha_scale := float(style.get("alpha_scale", 0.75))
	for raw_entry in entries:
		var entry: Dictionary = raw_entry
		var kind := String(entry.get("kind", ""))
		## `shield` 是纯状态事件、`damage` 由 `draw_damage_popups()` 单独画文字。
		## 若在这里画，会为每一个伤害数字多画一个零半径小圆。
		if kind == "shield" or kind == "damage":
			continue
		var life := float(entry["life"])
		if life <= 0.0:
			continue
		var t := clampf(float(entry["left"]) / life, 0.0, 1.0)
		var colour: Color = entry["colour"]
		var at := to_screen(view, arena, Vector2(entry["pos"]), scale_factor)
		var radius := maxf(float(entry["radius"]) * scale_factor * (radius_base + radius_grow * t), min_radius)
		var alpha := alpha_scale * t
		if fill_scale > 0.0:
			canvas.draw_circle(at, radius, Color(colour, alpha * fill_scale))
		canvas.draw_arc(at, radius, 0.0, TAU, arc_points, Color(colour, alpha), arc_width)


## 最近一次命中点的高亮圈：即便命中发生在缩放后只有几像素的敌车上也能看见。
##
## 状态（命中点与剩余时间）留在页面层——组件只负责按当前剩余时间画出来，因此两个战斗
## 模式各自持有自己的闪光，不会互相覆盖。
static func draw_hit_flash(canvas: CanvasItem, view: Rect2, arena: Rect2, scale_factor: float, at_world: Vector2, left: float, life: float = HIT_FLASH_TIME) -> void:
	if left <= 0.0:
		return
	var t := clampf(left / maxf(life, 0.001), 0.0, 1.0)
	var at := to_screen(view, arena, at_world, scale_factor)
	var radius := 6.0 + 10.0 * (1.0 - t)
	canvas.draw_circle(at, radius, Color(Palette.ACCENT_AMBER, 0.30 * t))
	canvas.draw_arc(at, radius, 0.0, TAU, 24, Color(Palette.TEXT_HI, 0.9 * t), 2.0)


## 伤害悬浮数字：从命中点向上飘升并淡出。
##
## `progress = 1 - left/life` 从 0 走到 1；上升距离先快后慢（`sqrt`），像真的被击飞。
## 同一帧多条数字按 `stack * DAMAGE_POPUP_STACK_STEP` 垂直错开，避免完全重叠。
## **不用随机偏移**：否则同一模拟两次跑出不同像素，截图逐字节比对就失效了。
static func draw_damage_popups(canvas: CanvasItem, view: Rect2, arena: Rect2, scale_factor: float, entries: Array, text_fn: Callable) -> void:
	var stack := 0
	for raw_entry in entries:
		var entry: Dictionary = raw_entry
		if String(entry.get("kind", "")) != "damage":
			continue
		var text := String(entry.get("text", ""))
		if text.is_empty():
			continue
		var life := float(entry["life"])
		if life <= 0.0:
			continue
		var progress := clampf(1.0 - float(entry["left"]) / life, 0.0, 1.0)
		var rise := DAMAGE_POPUP_RISE * sqrt(progress) * scale_factor
		var offset := Vector2(0.0, -rise - float(stack) * DAMAGE_POPUP_STACK_STEP)
		var at := to_screen(view, arena, Vector2(entry["pos"]), scale_factor) + offset
		var colour: Color = entry["colour"]
		## 前 70% 保持不透明，后 30% 才淡出：数字要看得清，不能一出来就开始糊。
		var alpha := 1.0 if progress < 0.7 else clampf((1.0 - progress) / 0.3, 0.0, 1.0)
		var size := int(roundf(20.0 - 4.0 * progress))
		## 先画一层暗色底再画本体：霓虹背景下纯色小字容易被地形线淹掉。
		text_fn.call(text, at + Vector2(1.0, 1.0), size, Color(0.0, 0.0, 0.0, 0.55 * alpha), true)
		text_fn.call(text, at, size, Color(colour, alpha), true)
		stack += 1


## 把一次真实结算的数值推入动效层（`kind = "damage"`，带 `text`）。
##
## 符号语义：`dealt` → `+N`；`received` / `shield` → `-N`。承受伤害显示成正数会让它
## 看起来像治疗——这是 v3.20 修掉的实际缺陷，这里保留正确语义。
## 同一模式同帧最多 `DAMAGE_POPUP_PER_SIDE` 条，超出就丢弃最新的一条：保先保稳，不保全。
## 返回是否真的推入了一条，方便调用方断言。
static func push_damage(fx: FxLayer, at: Vector2, amount: float, colour: Color, mode: String) -> bool:
	if fx == null or amount <= 0.0:
		return false
	var shown := int(roundf(amount))
	if shown <= 0:
		return false
	var counting := 0
	for raw_entry in fx.entries:
		var entry: Dictionary = raw_entry
		if String(entry.get("kind", "")) == "damage" and String(entry.get("mode", "")) == mode:
			counting += 1
	if counting >= DAMAGE_POPUP_PER_SIDE:
		return false
	var label := "+%d" % shown if mode == "dealt" else "-%d" % shown
	fx.push("damage", at, 0.0, colour, DAMAGE_POPUP_LIFE, label)
	## `mode` 在 push 之后补写：`push()` 的签名保持向后兼容（旧调用点不动），
	## 而模式信息只有绘制/限流需要，不进入通用字段。
	(fx.entries[fx.entries.size() - 1] as Dictionary)["mode"] = mode
	return true


## 逐部件按**血量比例**分档上色：完好 = `base`，中度损伤转琥珀，濒危转红。
##
## `base` 由调用方给出（队伍色；驾驶舱可另给琥珀），因为「是不是驾驶舱」需要查模块表，
## 那是页面层与数据层的职责，不该让视图组件依赖数据注册表。
##
## 旧版对局页整台只有一种颜色、不看 HP，玩家看不见自己到底打掉了什么——这正是
## 「炮弹似乎不能对敌人造成伤害」的直接感知来源（即使伤害真的算对了）。
static func hull_damage_colour(part: Dictionary, base: Color) -> Color:
	var ratio := clampf(float(part["hp"]) / maxf(float(part["hp_max"]), 0.001), 0.0, 1.0)
	if ratio > 0.6:
		return base
	if ratio > 0.25:
		return base.lerp(Palette.ACCENT_AMBER, 0.55)
	return Palette.ACCENT_RED


## 填充透明度随血量下降：一眼能看出哪块被打残了。与 `hull_damage_colour()` 配套使用。
static func hull_damage_alpha(part: Dictionary) -> float:
	var ratio := clampf(float(part["hp"]) / maxf(float(part["hp_max"]), 0.001), 0.0, 1.0)
	return 0.14 + 0.20 * ratio
