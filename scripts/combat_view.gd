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
## 数字错开只对「靠得够近」的数字生效：v3.49 之前这个 step 是全局累加的，
## 于是第 6 条数字被抬高 70 px，**哪怕它和第一条隔了半个战场**。
## 现在按位置分桶：只有与已画数字距离 < 本值的才往上错开。
## 取 1.6 倍 `DAMAGE_POPUP_STACK_STEP` 的两倍左右，正好能容下 3 条不重叠的数字。
const DAMAGE_POPUP_STACK_RADIUS := 48.0
## 炮口闪光 / 消散特效的时长与尺寸（v3.23）。
## 两者都比命中闪光（0.14 s）长，因为它们要表达「发生了什么」而不只是「打到了」。
const MUZZLE_FLASH_TIME := 0.18
const MUZZLE_FLASH_LEN := 26.0
const MUZZLE_FLASH_MIN_LEN := 10.0
const EXPIRE_FLASH_TIME := 0.26
const EXPIRE_FLASH_RADIUS := 16.0
## 部件被摧毁时的碎片抛洒（v3.50）。比命中闪光（0.14 s）长得多——它要表达「这一件彻底没了」。
const PART_DEBRIS_TIME := 0.55
## 碎片抛洒半径 = 本值 × cell_size（格）→ 世界像素由调用方乘好传入。
const PART_DEBRIS_RADIUS_PER_CELL := 1.35

## ===== 炮弹外观分档（v3.49） =====
## 拖尾的参考时长（秒）：拖尾长度 = 速度 × 本值。
## 不用「上一帧位移」是因为那样长度同时受帧率与速度影响，同一发弹在 30 fps 与 144 fps 下拖尾长短不同。
const SHOT_TRAIL_TIME := 0.045
const SHOT_TRAIL_MIN := 10.0
const SHOT_TRAIL_MAX := 46.0
## 拖尾长度直接取 `shot["speed"]`（`projectile_field` 生成炮弹时写入的 px/s）乘以本时长。
## v3.49 首次实现时用「上一帧位移 ÷ 1.0」反推速度，得到的是「每帧多少像素」而不是 px/s，
## 60 Hz 下一发 `cal_76` 每帧只走约 16.7 px，乘完被夹到 `SHOT_TRAIL_MIN`——**所有口径的拖尾都塌到最短**。
## 现在不反推，也不读引擎全局步频：步长来自 `data/globals.json` 的 `physics_hz`，组件不应去猜它。
## 弹头半径（屏幕像素）：最轻口径 → 最重口径。
const SHOT_RADIUS_MIN := 1.8
const SHOT_RADIUS_MAX := 5.4
## 拖尾宽度（屏幕像素）：同上。
const SHOT_TRAIL_WIDTH_MIN := 1.0
const SHOT_TRAIL_WIDTH_MAX := 3.2
## 拖尾分成几段做亮度渐变。3 段在 10–46 px 的长度上已经足够平滑，再多就只是增加绘制调用。
const SHOT_TRAIL_BANDS := 3
## 口径分档的对数分母：`cal_155` 的 `base_damage` = 240。
## 取对数而非线性，否则 8/20/55 三个轻口径会全挤在区间最左端，看上去还是一样细。
const SHOT_GAUGE_REFERENCE := 240.0

## 动效圆环的默认风格：生存页这一套（半径随剩余寿命线性收，带半透明填充）。
##
## v3.49：三套风格现在**全部开启** `special` 与 `centre_dot`。
## v3.33 抽取时刻意把另两页关着，理由是「抽取的目的是消除分叉，不是重做另两页的观感」——
## 那个约束在当轮是对的，但代价是 `detach` / `core` / `debris` / `shield_hit` 在
## 对局页与生存页一直长得和普通命中一模一样，玩家分不清「打中一格」与「整块被撕下」。
## 本轮就是美化的轮次，所以统一打开；**三页的历史像素基线因此全部失效**，必须重拍。
const FX_STYLE_SURVIVAL := {
	"radius_base": 0.6,
	"radius_grow": 0.4,
	"min_radius": 2.0,
	"arc_points": 20,
	"arc_width": 1.5,
	"fill_scale": 0.5,
	"alpha_scale": 0.75,
	"special": true,
	"centre_dot": 0.22,
	"centre_alpha": 0.55,
	"burst": true,
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
	"special": true,
	"centre_dot": 0.18,
	"centre_alpha": 0.5,
	"burst": true,
}

## 试驾页这一套：与 `FX_STYLE_MATCH` 同形（向外收缩 + 无填充）。
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
	"burst": true,
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
	## v3.49 美化：**内发光**。四道由内向外递减的细线，给战场一个「光源在场地中心」的层次，
	## 而不是一块完全均匀的暗板。用 4 道而不是渐变纹理：`draw_*` 没有渐变图元，
	## 而引入 `Gradient` + `TextureRect` 会多一个节点与一条绘制路径（单场景架构下不值得）。
	for glow_index in range(4):
		var inset := (float(glow_index) + 0.5) * 3.0 * pixel
		var glow_rect := Rect2(arena.position + Vector2(inset, inset), arena.size - Vector2(inset, inset) * 2.0)
		if glow_rect.size.x <= 0.0 or glow_rect.size.y <= 0.0:
			break
		canvas.draw_rect(glow_rect, Color(border_colour, 0.055 - 0.012 * float(glow_index)), false, 2.0 * pixel)
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
	## v3.49 美化：**四角 L 形标记**。边框本身在 4.0× 下会被视窗剪到只剩一段直线，
	## 看不出「这里是地图边界」；角标是固定尺寸的，无论缩放到多少都认得出来。
	var corner := 26.0 * pixel
	for corner_index in range(4):
		var corner_x := arena.position.x if corner_index % 2 == 0 else arena.end.x
		var corner_y := arena.position.y if corner_index < 2 else arena.end.y
		var dir_x := 1.0 if corner_index % 2 == 0 else -1.0
		var dir_y := 1.0 if corner_index < 2 else -1.0
		var corner_at := Vector2(corner_x, corner_y)
		canvas.draw_line(corner_at, corner_at + Vector2(corner * dir_x, 0.0), border_colour, 3.0 * pixel)
		canvas.draw_line(corner_at, corner_at + Vector2(0.0, corner * dir_y), border_colour, 3.0 * pixel)
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
		## v3.49 美化：**房屋与障碍分家**。两者旧版都是「填充 + 单线边框 + 血条」，
		## 而固定障碍用的是红色（`draw_arena()` 里画），房屋用琥珀 —— 只靠颜色区分在混战里很难认。
		## 现在房屋多两道语义：**双线边框**（可拆）与**四角内向短刻线**（目标标记），
		## 障碍保持单线不变，于是「双线 = 能打掉拿钱」成为一个可学的视觉规则。
		canvas.draw_rect(house_rect, Palette.ACCENT_AMBER, false, 1.5 * pixel)
		var inner := house_rect.grow(-3.0 * pixel)
		if inner.size.x > 0.0 and inner.size.y > 0.0:
			canvas.draw_rect(inner, Color(Palette.ACCENT_AMBER, 0.55), false, 1.0 * pixel)
		var tick := minf(8.0 * pixel, minf(house_rect.size.x, house_rect.size.y) * 0.22)
		for corner_index in range(4):
			var corner_x := house_rect.position.x if corner_index % 2 == 0 else house_rect.end.x
			var corner_y := house_rect.position.y if corner_index < 2 else house_rect.end.y
			var dir_x := 1.0 if corner_index % 2 == 0 else -1.0
			var dir_y := 1.0 if corner_index < 2 else -1.0
			var corner_at := Vector2(corner_x, corner_y)
			canvas.draw_line(corner_at, corner_at + Vector2(tick * dir_x, 0.0), Palette.ACCENT_AMBER, 2.0 * pixel)
			canvas.draw_line(corner_at, corner_at + Vector2(0.0, tick * dir_y), Palette.ACCENT_AMBER, 2.0 * pixel)
		var ratio := clampf(float(house["hp"]) / maxf(float(house["hp_max"]), 0.001), 0.0, 1.0)
		## 血条同样用世界坐标：`draw_rect` 的粗细也是世界单位，所以高度要乘 `pixel`。
		## 两段式（底槽 + 前景）而不是单条：空槽给出了「还剩多少」的参照，
		## 否则 3 px 高的短条在混战里看不出是满的还是快没了。
		## 低于 30% 转红：这是「这一栋快倒了」的唯一预告。
		var bar := Rect2(house_rect.position + Vector2(0.0, -6.0 * pixel), Vector2(house_rect.size.x, 3.0 * pixel))
		canvas.draw_rect(bar, Color(Palette.WIRE, 0.4), true)
		var fill_colour := Palette.ACCENT_RED if ratio < 0.30 else Palette.ACCENT_AMBER
		canvas.draw_rect(Rect2(bar.position, Vector2(bar.size.x * ratio, bar.size.y)), fill_colour, true)
	for raw_debris in debris:
		var item: Dictionary = raw_debris
		if bool(item.get("taken", false)):
			continue
		var centre_world := (Vector2(Vector2i(item["cell"])) + Vector2(0.5, 0.5)) * cell_px
		var half := cell_px * 0.35
		var box := Rect2(centre_world - Vector2(half, half), Vector2(half, half) * 2.0)
		canvas.draw_rect(box, Color(Palette.ACCENT_LIME, 0.30), true)
		canvas.draw_rect(box, Palette.ACCENT_LIME, false, 1.0 * pixel)


## 在途炮弹：拖尾 + 弹头（纯世界坐标，v3.42）。
##
## 颜色按射手分：玩家弹药琥珀、其余品红——这是「谁在打我」的唯一即时线索。
## `player_tag` 由调用方给出，因为多阵营模式下「玩家」不是一个全局常量。
##
## v3.49 美化两处：
##
## ① **拖尾长度不再用「上一帧位移」。** 旧版画 `prev → pos` 这一段，长度 = `速度 × dt`，
##    所以它随帧率与速度双变（60 Hz 下 `cal_20` 约 6 px、`cal_155` 约 15 px，都短得不像拖尾）。
##    现在按**速度 × `SHOT_TRAIL_TIME`** 算长度并夹在 `[SHOT_TRAIL_MIN, SHOT_TRAIL_MAX]`：
##    同样的速度在任何帧率下画出同样长的拖尾，而且慢弹也有可见的尾。
##
## ② **弹头按口径分档。** 旧版所有口径都画成同一个半径，玩家分不清飞过来的是 20 mm 还是 155 mm。
##    现在用 `ammo_lookup(ammo_id) -> Dictionary` 注入数据层的弹药定义，按 `base_damage` 在
##    `[SHOT_RADIUS_MIN, SHOT_RADIUS_MAX]` 之间插值；同时把拖尾宽度也按同一比例加粗。
##    **组件不直接依赖 `data_registry`**（与 `colour_fn` / `text_fn` 同一惯例），
##    `Callable()` 缺省时退回旧行为——这样任何未注入的调用点像素不变。
##
## `pixel` 只用于「弹头半径不小于 2 屏幕像素」这个下限。
static func draw_shots(canvas: CanvasItem, shots: Array, player_tag: String, pixel: float = 1.0, ammo_lookup: Callable = Callable()) -> void:
	for raw_shot in shots:
		var shot: Dictionary = raw_shot
		var head := Vector2(shot["pos"])
		var tail := Vector2(shot["prev"])
		var colour := Palette.ACCENT_AMBER if String(shot["shooter"]) == player_tag else Palette.ACCENT_MAGENTA
		## 口径分档：0 = 最轻口径，1 = 最重口径。查不到时用 0.5（中间档），不会因缺数据而消失。
		var gauge := 0.5
		if ammo_lookup.is_valid():
			var ammo: Dictionary = ammo_lookup.call(String(shot["ammo_id"]))
			if not ammo.is_empty():
				gauge = _shot_gauge(float(ammo.get("base_damage", 0.0)))
		var head_radius := shot_head_radius(gauge, pixel)
		var trail_width := shot_trail_width(gauge, pixel)
		## 拖尾：从 `head` 沿反向铺 `SHOT_TRAIL_TIME` 秒的行程，再夹到上下限。
		## 速度直接读 `shot["speed"]`（`projectile_field` 生成时写入的 px/s），**不反推**：
		## 反推需要知道一个固定步长是多少秒，而那个值来自 `data/globals.json` 的 `physics_hz`，
		## 组件不应去猜它。取不到时退回「上一帧位移」，即旧版行为。
		var forward := head - tail
		var speed := float(shot.get("speed", 0.0))
		var trail_length := shot_trail_length(speed, forward.length())
		if forward.length_squared() > 0.000001:
			forward = forward.normalized()
		else:
			forward = Vector2.RIGHT
		var trail_from := head - forward * trail_length
		## 三段拖尾：越靠头越亮越粗，给「运动方向」一个渐变的形状而不只是均匀线段。
		for band in range(SHOT_TRAIL_BANDS):
			var t0 := float(band) / float(SHOT_TRAIL_BANDS)
			var t1 := float(band + 1) / float(SHOT_TRAIL_BANDS)
			var band_from := trail_from + (head - trail_from) * t0
			var band_to := trail_from + (head - trail_from) * t1
			var band_alpha := 0.18 + 0.62 * t1
			var band_width := trail_width * (0.45 + 0.55 * t1)
			canvas.draw_line(band_from, band_to, Color(colour, band_alpha), band_width)
		## 弹头：外壳 + 亮芯，重口径多一圈描边，轻口径只有亮芯。
		canvas.draw_circle(head, maxf(head_radius, 2.0 * pixel), colour)
		canvas.draw_circle(head, maxf(head_radius * 0.45, 1.0 * pixel), Color(Palette.TEXT_HI, 0.9))
		if gauge > 0.6:
			canvas.draw_arc(head, maxf(head_radius * 1.7, 3.0 * pixel), 0.0, TAU, 14, Color(colour, 0.55), maxf(pixel, 1.0))


## 弹药 `base_damage` → 口径档位 `[0, 1]`。
##
## 用对数刻度而不是线性：`cal_20`=8 与 `cal_40`=20 差 12，而 `cal_120`=130 与 `cal_155`=240
## 差 110——线性会把前三个口径全挤到最左端，看上去还是「一样细」。
## 分母用 `SHOT_GAUGE_REFERENCE`（= `cal_155` 的 240），口径再大也不会越界。
static func _shot_gauge(base_damage: float) -> float:
	if base_damage <= 0.0:
		return 0.0
	var normalized := log(maxf(base_damage, 1.0)) / log(SHOT_GAUGE_REFERENCE)
	return clampf(normalized, 0.0, 1.0)


## 口径档位 `[0,1]` → 弹头半径（世界单位）。
##
## 抽成公开静态函数是为了**可测**：`draw_*` 不能在 `_draw()` 之外调用（v3.49 实测），
## 但「重口径必须比轻口径粗」这条要求本身是纯数值关系，不需要真实画布。
static func shot_head_radius(gauge: float, pixel: float = 1.0) -> float:
	return lerpf(SHOT_RADIUS_MIN, SHOT_RADIUS_MAX, clampf(gauge, 0.0, 1.0)) * pixel


## 口径档位 `[0,1]` → 拖尾宽度（世界单位）。
static func shot_trail_width(gauge: float, pixel: float = 1.0) -> float:
	return lerpf(SHOT_TRAIL_WIDTH_MIN, SHOT_TRAIL_WIDTH_MAX, clampf(gauge, 0.0, 1.0)) * pixel


## 炮弹速度（px/s）→ 拖尾长度（世界单位）。
##
## `fallback_length` 是「取不到速度」时的退路（= 上一帧位移，即旧版行为）。
## 用**速度 × 时长**而不是直接拿上一帧位移：后者同时受帧率与速度影响，
## 同一发弹在 30 fps 与 144 fps 下会画出不同长度的尾。
static func shot_trail_length(speed: float, fallback_length: float) -> float:
	if speed <= 0.0:
		return fallback_length
	return clampf(speed * SHOT_TRAIL_TIME, SHOT_TRAIL_MIN, SHOT_TRAIL_MAX)


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
##   `burst`                        是否画 `explosion_burst` 多层爆炸（v3.49）
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
	var burst := bool(style.get("burst", true))
	for raw_entry in entries:
		var entry: Dictionary = raw_entry
		var kind := String(entry.get("kind", ""))
		## `damage` 由 `draw_damage_popups()` 单独画文字，这里跳过以免多画一个零半径小圆。
		##
		## **v3.49 修掉一个真实缺陷**：旧版这里还跳过 `kind == "shield"`，而生存页唯一会推的护盾事件
		## 正是 `kind = "shield"`（且位置与半径都是 0）。两处叠加的结果是——**护盾挡下伤害时
		## 屏幕上什么都不发生**，玩家只能从「血量没掉」反推护盾在工作。现在护盾受击统一用
		## `shield_hit`（带位置与半径），本函数照常画它；旧的无坐标 `shield` 条目仍然跳过，
		## 因为零半径的东西画了也看不见。
		if kind == "damage" or kind == "shield":
			continue
		var life := float(entry["life"])
		if life <= 0.0:
			continue
		var t := clampf(float(entry["left"]) / life, 0.0, 1.0)
		var colour: Color = entry["colour"]
		var at := Vector2(entry["pos"])
		## 全尺寸半径（未乘收缩系数）：中心亮点与专用形状用它，通用圆环再乘 `base + grow·t`。
		var full_radius := float(entry["radius"])
		## v3.49：多层爆炸优先于 `special` 分支——它是「一整个效果」而不是「圆环的一种形状」。
		if burst and kind == "explosion_burst":
			draw_explosion_burst(canvas, at, full_radius, float(entry["left"]), life, colour, pixel)
			continue
		## v3.50：部件被摧毁时的碎片抛洒。比通用圆环更具体地表达「这一件碎了」。
		if kind == "part_debris":
			draw_part_debris(canvas, at, full_radius, float(entry["left"]), life, colour, pixel)
			continue
		if special and _draw_impact_shape(canvas, at, full_radius, colour, kind, t, pixel):
			continue
		var radius := maxf(full_radius * (radius_base + radius_grow * t), min_radius)
		var alpha := alpha_scale * t
		if fill_scale > 0.0:
			canvas.draw_circle(at, radius, Color(colour, alpha * fill_scale))
		canvas.draw_arc(at, radius, 0.0, TAU, arc_points, Color(colour, alpha), arc_width)
		if centre_dot > 0.0:
			canvas.draw_circle(at, maxf(full_radius * centre_dot * t, pixel), Color(colour, centre_alpha * t))


## `special` 打开时才走的专用形状（v3.33 从试驾页 `_draw_drive_fx()` 搬进来）。
##
## **v3.49：三套风格全部打开了 `special`**。v3.33 刚抽取时刻意只给试驾页开，理由是「抽取的
## 目的是消除分叉，不是重做另两页的观感」——那个约束在当时是对的，但它留下了一个真实的
## 可读性问题：`detach`（整块脱落）与 `core`（驾驶舱被毁）在另两页与「打中一格」长得一模一样。
## 本轮就是美化轮次，所以统一打开。
##
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
			## 护盾受击：六边形硬边闪光，**不收缩**——护盾不会「散掉」，只会闪一下。
			##
			## v3.49 从「一圈圆环」改成「六边形 + 六道径向刻线」：圆环与普通命中闪光的形状太接近，
			## 玩家在混战里分不出「打穿装甲」与「被护盾挡住了」。六边形是能量屏的语言，一眼可辨。
			var shield_radius := maxf(radius, 3.0 * pixel)
			var hex := PackedVector2Array()
			for corner in range(6):
				var angle := TAU * float(corner) / 6.0 + PI / 6.0
				hex.append(at + Vector2(cos(angle), sin(angle)) * shield_radius)
			canvas.draw_polyline(hex + PackedVector2Array([hex[0]]), Color(colour, 0.95 * t), 2.0 * pixel)
			for spike in range(6):
				var spike_angle := TAU * float(spike) / 6.0 + PI / 6.0
				var spike_dir := Vector2(cos(spike_angle), sin(spike_angle))
				canvas.draw_line(at + spike_dir * shield_radius, at + spike_dir * shield_radius * 1.45, Color(colour, 0.65 * t), 1.5 * pixel)
			canvas.draw_circle(at, maxf(shield_radius * 0.25, pixel), Color(colour, 0.35 * t))
			return true
		"detach", "core":
			## 整块脱落 / 驾驶舱被毁：双同心圆向外扩散，比通用圆环更「重」。
			canvas.draw_arc(at, radius * (0.35 + 0.65 * grow), 0.0, TAU, 32, Color(colour, 0.85 * t), 3.0 * pixel)
			canvas.draw_arc(at, radius * (0.15 + 0.4 * grow), 0.0, TAU, 24, Color(colour, 0.55 * t), 2.0 * pixel)
			return true
	return false


## 多层爆炸（v3.49）：殉爆 / 引擎爆炸 / 溅射共用的「大事件」表现。
##
## **为什么不直接用通用圆环**：一个圆环无法表达「多大范围」与「多重」，而殉爆是玩家最需要
## 一眼看出严重程度的时刻。本函数用四层叠加：
##   ① 三层同心环，扩张速率递增（0.30 / 0.55 / 0.85）——外环跑得最快，形成冲击波先后感；
##   ② 中心实心核，随进度快速缩小并转白（高温）；
##   ③ 八根固定角度射线（每 45°），长度随进度先伸后收；
##   ④ 一圈缓慢外溢的淡色充能底。
##
## **全程无随机**：角度是常量表 `TAU / 8` 的倍数，扩张曲线是 `sin(π·progress)`，
## 所以同一模拟两次跑出同一像素（截图逐字节比对仍然成立）。
##
## `radius` 是世界单位的「爆炸名义半径」，由调用方按 `radius_cells × cell_size` 算好传入。
static func draw_explosion_burst(canvas: CanvasItem, at: Vector2, radius: float, left: float, life: float, colour: Color, pixel: float = 1.0) -> void:
	if left <= 0.0 or radius <= 0.0:
		return
	var t := clampf(left / maxf(life, 0.001), 0.0, 1.0)
	var progress := 1.0 - t
	## 冲击波：`sin(π·progress)` 在 progress=0.5 达到峰值，两端为 0——先胀后收，不是一直变大。
	var wave := sin(PI * progress)
	## ① 三层同心环。外环先跑出去并先淡，内环滞后——这是「冲击波」与「持续燃烧」的区别。
	for ring_index in range(3):
		var ring_t := clampf(progress * (1.6 - 0.3 * float(ring_index)), 0.0, 1.0)
		var ring_radius := radius * (0.30 + 0.85 * float(ring_index)) * (0.35 + 0.65 * ring_t)
		var ring_alpha := (1.0 - ring_t) * (0.85 - 0.18 * float(ring_index))
		if ring_alpha <= 0.0:
			continue
		canvas.draw_arc(at, ring_radius, 0.0, TAU, 28, Color(colour, ring_alpha), (3.0 - float(ring_index) * 0.6) * pixel)
	## ② 中心核：快速缩小、转白。`lerp` 到 TEXT_HI 让最中心看上去比外环更「热」。
	var core_radius := maxf(radius * 0.55 * (1.0 - progress * 1.3), 1.0 * pixel)
	canvas.draw_circle(at, core_radius, Color(colour.lerp(Palette.TEXT_HI, 0.55), 0.9 * t))
	## ③ 八根固定角度射线。`wave` 让它们先伸后收，与环形成两种不同节奏。
	var spoke_length := radius * (0.55 + 0.75 * wave)
	for spoke in range(8):
		var angle := TAU * float(spoke) / 8.0
		var dir := Vector2(cos(angle), sin(angle))
		canvas.draw_line(at + dir * radius * 0.28, at + dir * spoke_length, Color(colour, 0.55 * t), 1.5 * pixel)
	## ④ 淡色外溢底：给出「范围」的直观大小，而不是只有几条线。
	canvas.draw_circle(at, radius * (0.30 + 0.70 * progress), Color(colour, 0.10 * t))

## 部件被摧毁时的碎片抛洒（v3.50）。
##
## **为什么不用通用圆环**：圆环表达的是「发生了一个事件」，而这里要表达的是
## 「这一件东西碎了、碎片飞出去了」——它们是**离散的**、**带重力的**、**不回到原处**的。
## 所以画成八片沿径向抛洒并下落的小块，而不是一圈对称的环。
##
## `radius` 是抛洒半径（调用方按 `PART_DEBRIS_RADIUS_PER_CELL × cell_size` 算好）。
##
## **零随机但也不均匀**：角度、抛洒距离系数、尺寸系数全部取自下面四张**常量表**。
## 均匀的 8 片 `TAU × i / 8` 在 4× 放大后看起来是一颗**辐射星芒**，不像碎块（v3.50
## 自己看截图发现的）；打散成不等距、不等大、不等远，才读得出「碎块向四周飞出去」。
## 全部是常量表 + `progress` 多项式，同一模拟两次跑出同一像素（design §10.4）。
const PART_DEBRIS_ANGLE := [0.00, 0.85, 1.70, 2.55, 3.35, 4.20, 5.05, 5.75]
## 抛洒距离系数：近的落在 `0.75 × reach`，远的到 `1.15 × reach`。
const PART_DEBRIS_REACH := [1.12, 0.78, 1.06, 0.88, 1.15, 0.75, 1.02, 0.94]
## 碎片尺寸系数（相对基础尺寸）。
const PART_DEBRIS_SIZE := [1.00, 0.62, 0.86, 1.22, 0.70, 1.08, 0.78, 0.94]
## 竖直下落系数：重的碎块落得快（与尺寸正相关）。
const PART_DEBRIS_FALL := [1.35, 0.70, 1.05, 1.30, 0.75, 1.20, 0.80, 1.00]

static func draw_part_debris(canvas: CanvasItem, at: Vector2, radius: float, left: float, life: float, colour: Color, pixel: float = 1.0) -> void:
	if left <= 0.0 or radius <= 0.0:
		return
	var t := clampf(left / maxf(life, 0.001), 0.0, 1.0)
	var progress := 1.0 - t
	## ① 淡色外溢底：给出抛洒范围的直观大小，随进度扩散并淡出。
	canvas.draw_circle(at, radius * (0.25 + 0.85 * progress), Color(colour, 0.10 * t))
	## ② 八片碎片：径向外抛 + 竖直下落（`progress²` 让下落感在尾段才明显）。
	## 下落基准从 0.55 提到 0.85：旧值在 4× 放大图里几乎看不出“掉”，只像“涨”。
	var reach_base := radius * (0.35 + 1.15 * progress)
	var fall_base := 0.85 * radius * progress * progress
	var chunk_base := radius * 0.18 * t
	for index in range(PART_DEBRIS_ANGLE.size()):
		var angle: float = PART_DEBRIS_ANGLE[index]
		var dir := Vector2(cos(angle), sin(angle))
		var reach := reach_base * float(PART_DEBRIS_REACH[index])
		var fall := fall_base * float(PART_DEBRIS_FALL[index])
		## 尺寸与寿命同为 `t` 的函数：碎片在消失前会缩小，而不是突然断掉。
		var chunk := chunk_base * float(PART_DEBRIS_SIZE[index])
		var centre := at + dir * reach + Vector2(0.0, fall)
		## 沿径向外指的小线段，长度 = 尺寸 × 1.6：线比点更像「碎块」。
		var tail := centre - dir * chunk * 1.6
		canvas.draw_line(tail, centre, Color(colour, 0.85 * t), maxf(chunk * 0.45, pixel))
## 命中闪光：实心亮圆 + 描边，半径向外扩张。
##
## v3.49 新增**方向性溅射**：传入 `normal` 时，沿该方向额外画出三道长短不一的短刻线
## 与一段半圆冲击弧。旧版是对称圆，玩家看不出「从哪个方向打过来的」——
## 而炮口闪光已经用锥形表达了「往哪打」，命中侧没有对应信息是不对称的。
## `normal` 缺省 `Vector2.ZERO` 时不画溅射，与旧版逐字节相同。
##
## v3.42：纯世界坐标、不裁剪。半径与线宽乘 `pixel` 保持屏幕上的观感恒定。
static func draw_hit_flash(canvas: CanvasItem, at_world: Vector2, left: float, life: float = HIT_FLASH_TIME, pixel: float = 1.0, normal: Vector2 = Vector2.ZERO) -> void:
	if left <= 0.0:
		return
	var t := clampf(left / maxf(life, 0.001), 0.0, 1.0)
	var radius := (6.0 + 10.0 * (1.0 - t)) * pixel
	canvas.draw_circle(at_world, radius, Color(Palette.ACCENT_AMBER, 0.30 * t))
	canvas.draw_arc(at_world, radius, 0.0, TAU, 24, Color(Palette.TEXT_HI, 0.9 * t), 2.0 * pixel)
	if normal.length_squared() <= 0.000001:
		return
	## 溅射方向取**法线反向**：`normal` 是命中面的法线（指向外侧），而火花应该向「来向」飞。
	var away := -normal.normalized()
	var side := away.orthogonal()
	## 三道长短不一的刻线，偏移量是常量表（-0.5 / 0 / +0.5），无随机。
	for index in range(3):
		var spread := (float(index) - 1.0) * 0.5
		var dir := (away + side * spread).normalized()
		var length := radius * (1.5 + 0.35 * (1.0 - absf(spread) * 2.0)) * (0.4 + 0.6 * t)
		canvas.draw_line(at_world + dir * radius * 0.7, at_world + dir * length, Color(Palette.TEXT_HI, 0.75 * t), 1.5 * pixel)
	## 半圆冲击弧：朝向命中面，让「打在哪一面」在静态图里也能读出来。
	var facing := away.angle()
	canvas.draw_arc(at_world, radius * 1.35, facing - PI * 0.4, facing + PI * 0.4, 14, Color(Palette.ACCENT_AMBER, 0.6 * t), 1.5 * pixel)


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
	## v3.49：`maxf(2.0 * pixel, 1.5 * pixel)` 是死逻辑（前者恒大于后者），已简化为 `2.0 * pixel`。
	if t > 0.6:
		canvas.draw_circle(at, 2.0 * pixel, Color(colour, 0.35 * t))


## **不用随机偏移**：否则同一模拟两次跑出不同像素，截图逐字节比对就失效了。
##
## v3.42：纯世界坐标、不裁剪 —— 溢出视窗的数字由**视窗边界天然剪掉**。
## `pixel` 把上升距离、错开步长、字号换算成世界单位，观感与缩放无关。
##
## 字号本身就是「世界单位」：引擎相机缩放会把它按比例放大，所以这里**不**再乘 `pixel`
## 之外的额外缩放——`pixel` 只是把 `20 px` 字号还原成它在屏幕上应有的视觉大小。
static func draw_damage_popups(canvas: CanvasItem, entries: Array, text_fn: Callable, pixel: float = 1.0) -> void:
	var placed: Array = []
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
		var origin := Vector2(entry["pos"])
		var stack := _popup_stack_at(placed, origin)
		var progress := clampf(1.0 - float(entry["left"]) / life, 0.0, 1.0)
		var rise := DAMAGE_POPUP_RISE * sqrt(progress) * pixel
		var offset := Vector2(0.0, -rise - float(stack) * DAMAGE_POPUP_STACK_STEP * pixel)
		var at := origin + offset
		var size := int(roundf((20.0 - 4.0 * progress) * pixel))
		var colour: Color = entry["colour"]
		## 前 70% 保持不透明，后 30% 才淡出：数字要看得清，不能一出来就开始糊。
		var alpha := 1.0 if progress < 0.7 else clampf((1.0 - progress) / 0.3, 0.0, 1.0)
		## 先画一层暗色底再画本体：霓虹背景下纯色小字容易被地形线淹掉。
		text_fn.call(text, at + Vector2(1.0, 1.0) * pixel, size, Color(0.0, 0.0, 0.0, 0.55 * alpha), true)
		text_fn.call(text, at, size, Color(colour, alpha), true)


## 在「已占用的数字簇」里为 `origin` 找下一个可用的层号，并把结果记回 `placed`。
##
## **v3.49 修掉一个真实缺陷**：旧版 `stack` 是**全局累加**的——循环外一个计数器，每画一条就 +1，
## 于是第 6 条数字被抬高 `5 × 14 = 70 px`，**哪怕它和第一条隔了半个战场**。
## 生存页一次击毁 12 格部件会推 12 条 `break`、金钱数字又共用同一 kind，触发概率很高。
##
## 现在按**位置分桶**：只与「距离 < `DAMAGE_POPUP_STACK_RADIUS`」的已画数字比较，
## 取它们用过的最大层号 +1。近的才错开，远的不互相干扰。
##
## 单独抽成函数（而不是留在 `draw_damage_popups()` 循环里）是为了**可测**：
## `draw_*` 不能在 `_draw()` 之外调用（v3.49 实测：headless 下会报
## "Drawing is only allowed inside this node's `_draw()`"），所以绘制函数本身无法被
## 单元测试驱动；而这段错开逻辑是纯数据变换，可以。
static func _popup_stack_at(placed: Array, origin: Vector2) -> int:
	var stack := 0
	for raw_placed in placed:
		var record: Dictionary = raw_placed
		if origin.distance_to(Vector2(record["pos"])) >= DAMAGE_POPUP_STACK_RADIUS:
			continue
		stack = maxi(stack, int(record["stack"]) + 1)
	placed.append({"pos": origin, "stack": stack})
	return stack


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
