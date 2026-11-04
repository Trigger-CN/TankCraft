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
## - **全部坐标系都是纯世界坐标（v3.42）**：不乘缩放、不做投影、**不做裁剪**。
##   调用方把这些函数画在 `BattleViewport` 里的世界节点上，由 `SubViewport` 的边界
##   天然剪掉溢出部分。缩放/平移由引擎 `Camera2D` 负责，线宽与最小尺寸由调用方传入
##   的 `pixel = pixel_of(缩放)` 换算成世界单位。
##   历史上这里曾有 `to_screen()` / `in_view()` / `_clipped_disc()` 一整套手写投影与
##   逐图元裁剪，它的固有缺陷是「每一处绘制都必须记得裁剪，漏一处就溢出」——
##   实测在 2.0× / 4.0× 下圆形障碍会画到状态栏、矩形障碍会压到右侧 HUD。
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
## 炮口闪光 / 消散特效的时长与尺寸（v3.23）。
## 两者都比命中闪光（0.14 s）长，因为它们要表达「发生了什么」而不只是「打到了」。
const MUZZLE_FLASH_TIME := 0.18
const MUZZLE_FLASH_LEN := 26.0
const MUZZLE_FLASH_MIN_LEN := 10.0
const EXPIRE_FLASH_TIME := 0.26
const EXPIRE_FLASH_RADIUS := 16.0

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

## 试驾页这一套：与 `FX_STYLE_MATCH` 同形（向外收缩 + 无填充），另加两个开关：
##   `special`        画出 `debris` / `shield_hit` / `detach` / `core` 四种专用形状
##                    （默认 `false`，这四种在另两页依旧画成通用圆环）
##   `centre_dot` / `centre_alpha`  通用圆环中心补一个亮点（试驾页从 M5 起就有的观感）
## 两个开关缺省关闭，所以另两页的像素不受影响。
const FX_STYLE_DRIVE := {
	"radius_base": 1.0,
	"radius_grow": -0.8,
	"min_radius": 0.0,
	"arc_points": 24,
	"arc_width": 2.0,
	"fill_scale": 0.0,
	"alpha_scale": 0.8,
	"special": true,
	"centre_dot": 0.18,
	"centre_alpha": 0.5,
}

## 世界坐标 → 屏幕坐标。
##
## v3.42：战场绘制已经搬进 `SubViewport` + `Camera2D`，缩放与平移交给引擎；
## 本函数只剩**鼠标/准星一侧**的用途——把一个世界点换算成主视口里的设计坐标。
##
## 它必须与引擎相机的映射**逐字一致**，否则玩家看到的炮管指向与真实弹道会分成
## 两套推导（v3.37 的教训）。`BattleViewport` 的相机正是用
## `position = camera.get_center()`、`zoom = view.size.x / camera.size.x` 设的，
## 所以下面的式子就是那条引擎变换的展开。
##
## 参数 `camera` 是「**相机当前看到的那一块世界矩形**」。相机拉近时它比竞技场小，且
## **永远不超出竞技场**（v3.40）；拉到最远时它就是 `arena` 本身 ——
## 于是本式退化成 `view.position + (world - arena.position) * scale`，与 v3.37 逐字相同。
static func to_screen(view: Rect2, camera: Rect2, world: Vector2, scale_factor: float) -> Vector2:
	return view.position + (world - camera.position) * scale_factor


## 屏幕坐标 → 世界坐标：`to_screen()` 的精确逆变换。
##
## **必须与 `to_screen()` 成对维护。**一个页面如果画用前者、瞄准用后者而两者不同源，
## 玩家看到的炮管指向与真实的弹道方向就会分成两套推导（v3.37 的教训）。
## `camera` 与正向变换用的那个必须是**同一个**。
static func to_world(view: Rect2, camera: Rect2, screen: Vector2, scale_factor: float) -> Vector2:
	if scale_factor <= 0.0001:
		return camera.position
	return camera.position + (screen - view.position) / scale_factor


## 铺满视图所需的缩放系数。
## **这是「相机拉到最远」时的比例**；拉近后相机变小，本函数自然返回更大的值，
## 于是 `camera.size` 自动把比例抬到 `fit_arena * mag`。
##
## v3.42：它同时是**引擎相机的 zoom** —— `BattleViewport.apply()` 直接拿它设相机，
## 所以「画出来的比例」与「鼠标反算的比例」从构造上就是同一个数。
static func fit_scale(view: Rect2, camera: Rect2) -> float:
	if camera.size.x <= 0.0:
		return 1.0
	return view.size.x / camera.size.x


## 缩放系数的倒数：**一个屏幕像素折合多少世界单位**。
##
## 世界坐标绘制里的线宽 / 最小尺寸都必须乘它：一条 `w` 世界单位的线在屏幕上只有
## `w × 缩放` 像素，不换算的话拉到最远时 2 px 的边框会瘦成 1.2 px。
## 单独成一个函数是为了让所有调用点用同一个来源，而不是各自写 `1.0 / scale`。
static func pixel_of(scale_factor: float) -> float:
	if scale_factor <= 0.0001:
		return 1.0
	return 1.0 / scale_factor

## 【v3.40 重做】相机 = 一台真实摄像机，状态是**距离**而不是「地图除以倍数」。
##
## `height` = 相机视野覆盖的世界高度（px）。它是相机的「远近」：数值越大相机越远、
## 看到越多但每样东西越小；数值越小相机越近、东西越大。
##
## 三条硬约束（v3.38 的旧模型违反了中间那条，这就是用户说的「很多问题」）：
##  1. **最远 = 整张地图**：`height >= arena.size.y` 时**原样返回 `arena`**（零乘除），
##     于是「相机拉到最远」与 v3.37 的默认画面**逐字节相同**，历史截图基线继续可比。
##  2. **相机永远不超出地图**：`height` 被夹到 `arena.size.y` 以内，Rect 再夹进竞技场。
##     旧模型允许 `zoom < 1`（相机比地图还大），于是在完全没有地形的地方画出一圈空白——
##     实测 0.5x 时相机 4096×2304、**视图 75% 是空的**。相机不该看得到世界之外。
##  3. **宽高比永不改变**：宽 = 高 × 竞技场宽高比。本项目视图与竞技场宽高比相同，
##     所以相机在任何距离下都恰好铺满视图，既没有 letterbox 也没有裁切。
static func camera_at_height(arena: Rect2, focus: Vector2, height: float) -> Rect2:
	if arena.size.x <= 0.0 or arena.size.y <= 0.0:
		return arena
	## 最远：整张地图。**先返回，不做任何乘除** —— 这是默认像素不变的构造性保证。
	if height >= arena.size.y:
		return arena
	var h := maxf(height, 0.0)
	var w := h * (arena.size.x / arena.size.y)
	var half := Vector2(w, h) * 0.5
	## 焦点只在**真正拉近之后**才有意义；夹取保证相机不跑出竞技场。
	var centre := Vector2(
		clampf(focus.x, arena.position.x + half.x, arena.end.x - half.x),
		clampf(focus.y, arena.position.y + half.y, arena.end.y - half.y))
	return Rect2(centre - half, half * 2.0)


## 距离 ↔ 读数（「相机 x.xx×」）的换算。
##
## `1.00×` 就是**最远 / 整图**，往近推数值变大。旧模型把 1.0 叫「标准」、0.5 叫「退远」，
## 于是「退远」比整图还远、什么也看不到 —— 镜头语言上自相矛盾，这是重做的直接动机。
static func camera_height_for_mag(arena: Rect2, mag: float) -> float:
	if arena.size.y <= 0.0:
		return 0.0
	## mag < 1 一律当成最远：**没有比「整张地图」更远的视角**。
	return arena.size.y / maxf(mag, 1.0)


static func camera_mag(arena: Rect2, height: float) -> float:
	if arena.size.y <= 0.0 or height <= 0.0:
		return 1.0
	return clampf(arena.size.y / height, 1.0, 999.0)

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


## 竞技场底板 + 网格线 + 边界 + 固定障碍（**纯世界坐标**，v3.42）。
##
## `obstacles` 统一为**已是世界像素**的条目（见 `scale_obstacles()`）：
##   `{shape: "rect", rect: Rect2}` 或 `{shape: "circle", center: Vector2, radius: float}`
##
## **本函数不做任何裁剪，也不接收 `view` / `camera` / 缩放。**
## 它画在 `SubViewport` 里的世界节点上，溢出视窗的部分由**视窗边界天然剪掉** ——
## 这正是用户要的「相机和视窗设置好就行」：裁剪不该是每一处绘制都记得调用的东西。
##
## v3.38 / v3.40 的写法是「手写投影 + 逐图元裁剪」：矩形用 `Rect2.intersection()`、
## 圆用 `_clipped_disc()`（48 段多边形 + `Geometry2D.clip_polygons` 近似）。
## 实测在 2.0× / 4.0× 下仍有圆形障碍画到状态栏、矩形障碍压到右侧 HUD ——
## 因为那条路线要求**每一处绘制都记得裁剪**，漏一处就溢出。
##
## `pixel` = `pixel_of(缩放)`，只用于线宽与最小尺寸的换算。
##
## `grid_step` 是网格**世界单位**间距（0 表示不画网格）：对局页与生存页传缺省值，
## 因此它们的像素不受网格分支影响；试驾页传「4 格宽」的间距，每第 4 根线加亮。
static func draw_arena(canvas: CanvasItem, arena: Rect2, obstacles: Array, border_colour: Color, pixel: float = 1.0, grid_step: float = 0.0) -> void:
	canvas.draw_rect(arena, Color(Palette.BG_BASE, 0.94), true)
	if grid_step > 0.0:
		var x := arena.position.x
		var column := 0
		while x <= arena.end.x:
			canvas.draw_line(Vector2(x, arena.position.y), Vector2(x, arena.end.y), Color(Palette.GRID_LINE, 0.55 if column % 4 == 0 else 0.26), pixel)
			x += grid_step
			column += 1
		var y := arena.position.y
		var row := 0
		while y <= arena.end.y:
			canvas.draw_line(Vector2(arena.position.x, y), Vector2(arena.end.x, y), Color(Palette.GRID_LINE, 0.55 if row % 4 == 0 else 0.26), pixel)
			y += grid_step
			row += 1
	canvas.draw_rect(arena, border_colour, false, 2.0 * pixel)
	for raw_obstacle in obstacles:
		var obstacle: Dictionary = raw_obstacle
		if String(obstacle.get("shape", "rect")) == "rect":
			var rect: Rect2 = obstacle["rect"]
			canvas.draw_rect(rect, Color(Palette.ACCENT_RED, 0.16), true)
			canvas.draw_rect(rect, Palette.ACCENT_RED, false, 1.5 * pixel)
		else:
			var centre := Vector2(obstacle["center"])
			var radius := float(obstacle["radius"])
			canvas.draw_circle(centre, radius, Color(Palette.ACCENT_RED, 0.16))
			canvas.draw_arc(centre, radius, 0.0, TAU, 48, Palette.ACCENT_RED, 1.5 * pixel)


## 地图中立物：可摧毁的房屋（琥珀方块 + 血条）与可碾过的残骸（青色小方块）。
##
## `houses` 每项 `{rect: Rect2, hp: float, hp_max: float, alive: bool}`；
## `debris` 每项 `{cell: Vector2i, taken: bool}`。
## 传空数组即完全不画——对局页没有这两种东西，直接传 `[]`，不需要额外的模式布尔量。
##
## v3.42：纯世界坐标、不裁剪（理由见 `draw_arena()`）。`pixel` 只用于线宽换算。
static func draw_neutrals(canvas: CanvasItem, houses: Array, debris: Array, cell_px: float, pixel: float = 1.0) -> void:
	for raw_house in houses:
		var house: Dictionary = raw_house
		if not bool(house.get("alive", true)):
			continue
		var house_rect: Rect2 = house["rect"]
		canvas.draw_rect(house_rect, Color(Palette.ACCENT_AMBER, 0.14), true)
		canvas.draw_rect(house_rect, Palette.ACCENT_AMBER, false, 1.5 * pixel)
		var ratio := clampf(float(house["hp"]) / maxf(float(house["hp_max"]), 0.001), 0.0, 1.0)
		## 血条同样用世界坐标：`draw_rect` 的粗细也是世界单位，所以高度要乘 `pixel`。
		var bar := Rect2(house_rect.position + Vector2(0.0, -6.0 * pixel), Vector2(house_rect.size.x, 3.0 * pixel))
		canvas.draw_rect(bar, Color(Palette.WIRE, 0.4), true)
		canvas.draw_rect(Rect2(bar.position, Vector2(bar.size.x * ratio, bar.size.y)), Palette.ACCENT_AMBER, true)
	for raw_debris in debris:
		var item: Dictionary = raw_debris
		if bool(item.get("taken", false)):
			continue
		var centre_world := (Vector2(Vector2i(item["cell"])) + Vector2(0.5, 0.5)) * cell_px
		var half := cell_px * 0.35
		var box := Rect2(centre_world - Vector2(half, half), Vector2(half, half) * 2.0)
		canvas.draw_rect(box, Color(Palette.ACCENT_LIME, 0.30), true)
		canvas.draw_rect(box, Palette.ACCENT_LIME, false, 1.0 * pixel)


## 在途炮弹：拖尾线段 + 弹头圆点（纯世界坐标，v3.42）。
##
## 颜色按射手分：玩家弹药琥珀、其余品红——这是「谁在打我」的唯一即时线索。
## `player_tag` 由调用方给出，因为多阵营模式下「玩家」不是一个全局常量。
## `pixel` 只用于「弹头半径不小于 2 屏幕像素」这一个下限。
static func draw_shots(canvas: CanvasItem, shots: Array, player_tag: String, pixel: float = 1.0) -> void:
	for raw_shot in shots:
		var shot: Dictionary = raw_shot
		var head := Vector2(shot["pos"])
		var tail := Vector2(shot["prev"])
		var colour := Palette.ACCENT_AMBER if String(shot["shooter"]) == player_tag else Palette.ACCENT_MAGENTA
		canvas.draw_line(tail, head, Color(colour, 0.7), 1.5 * pixel)
		canvas.draw_circle(head, maxf(float(shot["radius"]), 2.0 * pixel), colour)


## 瞬时动效圆环。
##
## `style` 用来消掉各模式的**观感差**，而不是让每个模式各写一份绘制：
##   `radius_base` / `radius_grow`  半径系数 = base + grow × t（t 是剩余寿命比例）
##   `min_radius`                   屏幕上的最小半径（像素）
##   `arc_points` / `arc_width`     描边段数与线宽
##   `fill_scale`                   圆内填充的 alpha 倍率；0 表示不画填充
##   `alpha_scale`                  描边 alpha 倍率
##   `special`                      是否画 `debris` / `shield_hit` / `detach` / `core` 专用形状
##   `centre_dot` / `centre_alpha`  通用圆环中心的亮点半径系数与 alpha（0 = 不画）
##   `centre_dot` / `centre_alpha`  通用圆环中心的亮点半径系数与 alpha（0 = 不画）
## 缺省用 `FX_STYLE_SURVIVAL`，对局页传 `FX_STYLE_MATCH`，试驾页传 `FX_STYLE_DRIVE`。
##
## v3.42：纯世界坐标、不裁剪。半径与线宽都是**世界单位**，`pixel` 只用来把
## 「屏幕上至少几 px」的下限换算成世界单位（`style` 里的 `min_radius` / 线宽）。
static func draw_fx(canvas: CanvasItem, entries: Array, style: Dictionary = FX_STYLE_SURVIVAL, pixel: float = 1.0) -> void:
	var radius_base := float(style.get("radius_base", 0.6))
	var radius_grow := float(style.get("radius_grow", 0.4))
	var min_radius := float(style.get("min_radius", 2.0)) * pixel
	var arc_points := int(style.get("arc_points", 20))
	var arc_width := float(style.get("arc_width", 1.5)) * pixel
	var fill_scale := float(style.get("fill_scale", 0.5))
	var alpha_scale := float(style.get("alpha_scale", 0.75))
	var special := bool(style.get("special", false))
	var centre_dot := float(style.get("centre_dot", 0.0))
	var centre_alpha := float(style.get("centre_alpha", 0.0))
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
		var at := Vector2(entry["pos"])
		## 全尺寸半径（未乘收缩系数）：中心亮点与专用形状用它，通用圆环再乘 `base + grow·t`。
		var full_radius := float(entry["radius"])
		if special and _draw_impact_shape(canvas, at, full_radius, colour, kind, t, pixel):
			continue
		var radius := maxf(full_radius * (radius_base + radius_grow * t), min_radius)
		var alpha := alpha_scale * t
		if fill_scale > 0.0:
			canvas.draw_circle(at, radius, Color(colour, alpha * fill_scale))
		canvas.draw_arc(at, radius, 0.0, TAU, arc_points, Color(colour, alpha), arc_width)
		if centre_dot > 0.0:
			canvas.draw_circle(at, maxf(full_radius * centre_dot * t, pixel), Color(colour, centre_alpha * t))


## `special` 打开时才走的四种专用形状（v3.33 从试驾页 `_draw_drive_fx()` 搬进来）。
##
## **为什么不是默认行为**：对局页也会推 `detach` 动效，若把它改成专用形状，对局页的像素
## 就会变——而抽取的目的是「消除分叉」而不是「重做另两页」。所以这四种形状必须由风格开关
## 显式启用，缺省时它们与抽取前一样走通用圆环分支。
## 返回是否已画出，`false` 表示调用方继续走通用分支。
## `pixel` 只用于「屏幕上的最小尺寸」换算（v3.42 改为世界坐标）。
static func _draw_impact_shape(canvas: CanvasItem, at: Vector2, radius: float, colour: Color, kind: String, t: float, pixel: float = 1.0) -> bool:
	var grow := 1.0 - t
	match kind:
		"debris":
			## 残骸碎片：实心小点，随寿命缩小。
			canvas.draw_circle(at, maxf(radius * t, pixel), Color(colour, 0.7 * t))
			return true
		"shield_hit":
			## 护盾受击：固定半径的短促圆环，不收缩——护盾不会「散掉」，只会闪一下。
			canvas.draw_arc(at, maxf(radius, 2.0 * pixel), 0.0, TAU, 12, Color(colour, t), 2.0 * pixel)
			return true
		"detach", "core":
			## 整块脱落 / 驾驶舱被毁：双同心圆向外扩散，比通用圆环更「重」。
			canvas.draw_arc(at, radius * (0.35 + 0.65 * grow), 0.0, TAU, 32, Color(colour, 0.85 * t), 3.0 * pixel)
			canvas.draw_arc(at, radius * (0.15 + 0.4 * grow), 0.0, TAU, 24, Color(colour, 0.55 * t), 2.0 * pixel)
			return true
	return false

## 状态（命中点与剩余时间）留在页面层——组件只负责按当前剩余时间画出来，因此两个战斗
## 模式各自持有自己的闪光，不会互相覆盖。
##
## v3.42：纯世界坐标、不裁剪。半径与线宽乘 `pixel` 保持屏幕上的观感恒定。
static func draw_hit_flash(canvas: CanvasItem, at_world: Vector2, left: float, life: float = HIT_FLASH_TIME, pixel: float = 1.0) -> void:
	if left <= 0.0:
		return
	var t := clampf(left / maxf(life, 0.001), 0.0, 1.0)
	var radius := (6.0 + 10.0 * (1.0 - t)) * pixel
	canvas.draw_circle(at_world, radius, Color(Palette.ACCENT_AMBER, 0.30 * t))
	canvas.draw_arc(at_world, radius, 0.0, TAU, 24, Color(Palette.TEXT_HI, 0.9 * t), 2.0 * pixel)


## 炮口闪光（v3.23）：发射瞬间从炮口沿炮管方向射出的一道锥形光 + 一圈冲击环。
##
## **为什么画成锥形而不是一个圆**：圆无法表达「朝哪边打的」。玩家在混战里最需要确认的
## 就是「我这发到底向哪个方向出去了」——炮管朝向与车体朝向可以不同（`aim` 偏移），
## 只有沿 `dir` 拉长的形状才能一眼看出。
##
## 长度随寿命收缩、亮度随寿命淡出；全程无随机，同一模拟两次跑出同一像素。
## `life` 由调用方传入剩余时间，页面层负责在固定步长里递减。
##
## v3.42：纯世界坐标、不裁剪。所有长度乘 `pixel`（世界单位 / 屏幕像素），
## 保持任何缩放下屏幕观感恒定。
static func draw_muzzle_flash(canvas: CanvasItem, at_world: Vector2, dir: Vector2, left: float, colour: Color, life: float = MUZZLE_FLASH_TIME, pixel: float = 1.0) -> void:
	if left <= 0.0:
		return
	var t := clampf(left / maxf(life, 0.001), 0.0, 1.0)
	var forward := dir.normalized() if dir.length_squared() > 0.000001 else Vector2.RIGHT
	var side := forward.orthogonal()
	## 长度随剩余寿命从满收缩到零；最小屏幕长度保证极小缩放下仍可见。
	var length := maxf(MUZZLE_FLASH_LEN * t, MUZZLE_FLASH_MIN_LEN) * pixel
	var half := length * 0.32
	## ① 锥形光：炮口 → 两侧张开的宽口，用两个三角形拼出一个尖头向外的光锥。
	var tip := at_world + forward * length
	canvas.draw_colored_polygon(PackedVector2Array([
		at_world,
		tip + side * half,
		tip - side * half,
	]), Color(colour, 0.55 * t))
	## ② 中心亮芯：一条细长亮线，保证光锥在小尺寸下也有可读的「指向」。
	canvas.draw_line(at_world, tip, Color(Palette.TEXT_HI, 0.85 * t), 1.5 * pixel)
	## ③ 炮口冲击环：以炮口为中心的短促圆环，让「刚刚开火」这件事在静止画面里也成立。
	var ring := (4.0 + 8.0 * (1.0 - t)) * pixel
	canvas.draw_arc(at_world, ring, 0.0, TAU, 20, Color(colour, 0.75 * t), 1.5 * pixel)


## 射程耗尽消散（v3.23）：炮弹未命中、飞满射程后原地消失的特效。
##
## **必须与命中闪光明显不同**，否则玩家分不清「打中了」与「打空了」：
## - 命中闪光：实心琥珀圆 + 白亮描边，向外**扩张**（半径 6 → 16），0.14 s；
## - 消散特效：三圈同心描边 + 向外的短刻线，半径**收缩**并向上漂，0.26 s，颜色按敌我。
## 二者形状、时长、运动方向全不同，不看颜色也能分辨。
##
## `rise` 让消散点向上漂几像素：射程尽头通常在空旷处，纯原地消失容易被弹道残影混淆。
##
## v3.42：纯世界坐标、不裁剪，尺寸乘 `pixel` 保持屏幕观感恒定。
static func draw_expire_flash(canvas: CanvasItem, at_world: Vector2, left: float, colour: Color, life: float = EXPIRE_FLASH_TIME, pixel: float = 1.0) -> void:
	if left <= 0.0:
		return
	var t := clampf(left / maxf(life, 0.001), 0.0, 1.0)
	## 进度 0 → 1（与 t 相反）：半径从大收到小、透明度从有到无。
	var progress := 1.0 - t
	var at := at_world + Vector2(0.0, -6.0 * progress * pixel)
	var radius := maxf(EXPIRE_FLASH_RADIUS * (1.0 - 0.55 * progress), 2.0 * pixel) * pixel
	## ① 三圈同心描边：由外向内收缩，形成「散掉」而不是「炸开」的感觉。
	var ring_alpha := 0.85 * t
	for ring_index in range(3):
		var ring := radius * (1.0 - 0.22 * float(ring_index))
		canvas.draw_arc(at, ring, 0.0, TAU, 18, Color(colour, ring_alpha / (1.0 + float(ring_index))), 1.5 * pixel)
	## ② 四根向外短刻线：固定角度（45° 起点、90° 步进），无随机。
	var spoke := radius * 1.25
	for spoke_index in range(4):
		var angle := PI * 0.25 + PI * 0.5 * float(spoke_index)
		var outer := at + Vector2(cos(angle), sin(angle)) * spoke
		var inner := at + Vector2(cos(angle), sin(angle)) * radius
		canvas.draw_line(inner, outer, Color(colour, 0.6 * t), 1.5 * pixel)
	## ③ 中心一点微光：只在最初 40% 寿命里存在，避免结束时留下一个亮点。
	if t > 0.6:
		canvas.draw_circle(at, maxf(2.0 * pixel, 1.5 * pixel), Color(colour, 0.35 * t))


## **不用随机偏移**：否则同一模拟两次跑出不同像素，截图逐字节比对就失效了。
##
## v3.42：纯世界坐标、不裁剪 —— 溢出视窗的数字由**视窗边界天然剪掉**。
## `pixel` 把上升距离、错开步长、字号换算成世界单位，观感与缩放无关。
##
## 字号本身就是「世界单位」：引擎相机缩放会把它按比例放大，所以这里**不**再乘 `pixel`
## 之外的额外缩放——`pixel` 只是把 `20 px` 字号还原成它在屏幕上应有的视觉大小。
static func draw_damage_popups(canvas: CanvasItem, entries: Array, text_fn: Callable, pixel: float = 1.0) -> void:
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
		var rise := DAMAGE_POPUP_RISE * sqrt(progress) * pixel
		var offset := Vector2(0.0, -rise - float(stack) * DAMAGE_POPUP_STACK_STEP * pixel)
		var at := Vector2(entry["pos"]) + offset
		var size := int(roundf((20.0 - 4.0 * progress) * pixel))
		var colour: Color = entry["colour"]
		## 前 70% 保持不透明，后 30% 才淡出：数字要看得清，不能一出来就开始糊。
		var alpha := 1.0 if progress < 0.7 else clampf((1.0 - progress) / 0.3, 0.0, 1.0)
		## 先画一层暗色底再画本体：霓虹背景下纯色小字容易被地形线淹掉。
		text_fn.call(text, at + Vector2(1.0, 1.0) * pixel, size, Color(0.0, 0.0, 0.0, 0.55 * alpha), true)
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


## ===== 车体上两个「纯视觉」附加层（v3.33 从试驾页私有改共享） =====
##
## 两者原本只存在于试驾页（`_drive_part_offset()` / `_draw_drive_track_marks()`）。
## 它们的观感很好（加速时车体有惯性感、履带在转），但另两页完全没有——
## 这不是模式差异，而是「谁先写完谁就有」的历史遗留。
##
## 现在改成**共享的可选项**：任何战斗页把这两个函数当作 `_draw_hull_shared()` 的
## `offset_fn` / `cell_hook` 传进去就能用，不传就是原来的行为。
## 默认不启用而不是默认启用，因为启用会改变另两页的像素——
## 而本次改动的目标是「消除分叉」，不是「重做另两页的观感」。

## 履带纹的步长与相位周期（局部像素）：相位取自行进距离，所以轮子「走多少转多少」。
const TRACK_MARK_X_STEP := 6.0
const TRACK_MARK_Y_STEP := 5.0
const TRACK_MARK_LEN := 3.0
const TRACK_PHASE_PERIOD := 6.0

## 加速时行进机构整体向后拖一点（局部格）。`throttle` 是 -1..1 的油门量。
## 返回 `Vector2.ZERO` 时 `_draw_hull_shared()` 的行为与不传 offset_fn 完全一致。
static func track_offset(part: Dictionary, throttle: float, enabled: bool) -> Vector2:
	if not enabled or is_zero_approx(throttle):
		return Vector2.ZERO
	if String(part.get("kind", "")) != "mobility":
		## 字面量 "mobility" 与 `TankBody.KIND_MOBILITY` 同值。这里不引用 `TankBody`：
		## 组件目前只依赖 `palette` / `fx_layer`，引入车身脚本会多一条无谓的耦合边。
		return Vector2.ZERO
	return Vector2(-0.5 * signf(throttle), 0.0)

## 只在行进机构格上叠履带纹。`phase` 由调用方用「行进距离」累加，不用 randf。
static func track_marks(canvas: CanvasItem, box: Rect2, colour: Color, phase: float) -> void:
	var start := fposmod(phase, TRACK_PHASE_PERIOD)
	var mark := Color(colour, 0.8)
	var y := box.position.y + 3.0
	while y < box.end.y:
		var x := box.position.x + start
		while x < box.end.x:
			canvas.draw_line(Vector2(x, y), Vector2(minf(x + TRACK_MARK_LEN, box.end.x), y), mark, 1.0)
			x += TRACK_MARK_X_STEP
		y += TRACK_MARK_Y_STEP
