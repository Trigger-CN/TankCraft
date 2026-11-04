extends Node

## 战斗场地渲染容器（v3.42）：`SubViewport` + `Camera2D` + 一个纯世界坐标的绘制节点。
##
## ## 为什么必须有这个类
##
## v3.38 与 v3.40 两轮都在用**手写世界→屏幕投影 + 手写逐图元裁剪**：
## `CombatView.to_screen()` 求屏幕点，`in_view()` 当剔除闸，矩形障碍用
## `Rect2.intersection()`、圆形障碍用 48 段多边形近似裁剪。两次都被实机否决。
##
## 那条路线的固有缺陷不是参数调不好的问题，而是**结构性的**：
##  1. 裁剪是「每一处绘制都要记得调用」的约定 —— 漏一处就溢出；
##  2. 圆的裁剪是多边形近似，切口边线必然出现偏差；
##  3. 每新增一种图元都要重新想一遍「它会不会溢出、怎么裁」。
##
## 实测症状（`.me/tmp/main/b42_2.0.png` / `b42_4.0.png`）：2.0× 与 4.0× 下
## **圆形障碍画到了状态栏上、矩形障碍越过战场右边框压到右侧 HUD**。
##
## 本类就是用户说的「相机和视窗设置好就行」：
## 战场画在一个 `SubViewport` 里，缩放与平移交给引擎 `Camera2D`，
## **裁剪由视窗边界天然保证** —— 任何图元画到视窗之外都会被自动剪掉，
## 不需要任何一处代码记得调用裁剪。
##
## ## 为什么用「blit 纹理」而不是 `SubViewportContainer`
##
## `SubViewportContainer` 是一个 `Control` 子节点，而 Godot 里**子节点画在父节点之后**。
## 于是战场会盖住 `Main._draw()` 里画的一切 —— 升级三选一卡片、商店、准星、
## 切页淡入遮罩全都会沉到战场下面。实测确认过这一点，所以改用显式 blit：
##
##   把 `SubViewport` 挂成一个**普通 `Node`**（不产生任何视觉输出），
##   由 `Main._draw()` 在原来画竞技场的位置调用 `blit()` 把纹理贴上去。
##
## 这样战场就成了 `Main` 画布的一部分，后面画的 HUD / 卡片 / 准星 / 遮罩
## 自然按原有的顺序盖在上面 —— **绘制顺序一个字节都不用改**。
##
## ## 坐标约定
##
## 绘制节点 `world` 收到的坐标是**纯世界像素**（与 `arena` 同一坐标系）。
## 它不乘缩放、不做投影、不做裁剪。线宽与「屏幕上至少几像素」的下限
## 由调用方用 `pixel()` 换算成世界单位。
##
## ## 为什么鼠标逆变换仍走 `CombatView.to_world()`
##
## 实测（`.me/tmp/main/probe42_cam.gd` → `p42cam.txt`）`SubViewport.get_canvas_transform()`
## 在 `set_position` / `set_zoom` 的**同一帧**仍返回旧值（探针输出 `STALE True`），
## 拿它反算鼠标会慢一帧 —— 缩放插值期间就是一次可感知的偏移。
## 因此鼠标侧继续用「相机矩形 + 缩放系数」的解析逆变换；它与引擎相机的映射
## **逐字等价**（`apply()` 正是用同一组数设相机），不存在两套推导的问题。

## `SubViewport` 内的绘制节点。
##
## 它只做一件事：把 `_draw()` 转交给注入的 `painter`。这样世界坐标绘制仍然写在
## `main.gd`（那里有字体、特效层、会话状态），不必把页面语义灌进渲染容器。
class BattleWorld extends Node2D:
	var painter: Callable = Callable()

	func _draw() -> void:
		if painter.is_valid():
			painter.call(self)

## 视窗矩形（设计坐标）。与 `main.gd` 的 `DRIVE_VIEW` 同值。
var rect := Rect2()
var viewport: SubViewport
var camera: Camera2D
var world: BattleWorld

## 本帧的缩放系数（`rect.size.x / 相机宽`）。`apply()` 每帧写它。
var _scale := 1.0


## 建好视窗、相机与绘制节点。**必须在使用前调用一次。**
##
## `painter` 收到 `BattleWorld` 作为画布，签名与 `CombatView.draw_*()` 的
## `canvas: CanvasItem` 一致。
func configure(target: Rect2, painter: Callable) -> void:
	rect = target
	viewport = SubViewport.new()
	## 设计尺寸就是渲染尺寸：`rect` 恒为整数像素，所以贴回去是 1:1，没有重采样。
	viewport.size = Vector2i(int(roundf(target.size.x)), int(roundf(target.size.y)))
	## 不透明背景：相机永不超出竞技场，战场铺满整个视窗，没有需要透出的地方。
	## 设成 true 会让半透明图元与主视口内容混合，颜色偏离设计值。
	viewport.transparent_bg = false
	## 待机时完全停渲染：菜单 / 建造页 / 改装页都不需要这块离屏纹理。
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	viewport.handle_input_locally = false
	add_child(viewport)
	camera = Camera2D.new()
	## `DRAG_CENTER`：`position` 是**视窗中心对应的世界点**，
	## 即 `screen = (world - position) * zoom + size * 0.5`。
	## 这与 `CombatView.camera_at_height()` 返回的「相机矩形」正好差半个尺寸，
	## 所以 `apply()` 里传的是 `camera_rect.get_center()`。
	## `FIXED_TOP_LEFT` 会引入半像素偏移，1.00× 的像素基线随之失效。
	camera.anchor_mode = Camera2D.ANCHOR_MODE_DRAG_CENTER
	camera.enabled = true
	viewport.add_child(camera)
	camera.make_current()
	world = BattleWorld.new()
	world.painter = painter
	viewport.add_child(world)


## 每帧把「相机看到的那块世界矩形」喂给引擎相机。
##
## `camera_rect` 来自 `CombatView.camera_at_height()` —— **那套距离模型的数学一行没改**，
## 它仍然负责算出相机该看到哪一块世界；本函数只做两行换算交给引擎。
##
## 尺寸退化（未进入战斗页、arena 为空）时**保持上一次的相机不动**：
## 设成零尺寸会让引擎除零并输出满屏错误。
func apply(camera_rect: Rect2) -> void:
	if camera_rect.size.x <= 0.0001 or camera_rect.size.y <= 0.0001:
		return
	if rect.size.x <= 0.0001:
		return
	camera.position = camera_rect.get_center()
	_scale = rect.size.x / camera_rect.size.x
	camera.zoom = Vector2(_scale, _scale)


## 战斗页开始时打开实时渲染，离开时关掉。
func set_active(active: bool) -> void:
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if active else SubViewport.UPDATE_DISABLED


## 每帧更新绘制回调（绘制内容由页面层现算）。
##
## `configure()` 只在启动时设一次；这里重复设置是为了让 `painter` 永远指向
## 当前页面的闭包 —— 页面层改自己的绘制逻辑时不需要重新 `configure`。
func set_painter(painter: Callable) -> void:
	if world != null:
		world.painter = painter


## 把离屏纹理贴到 `canvas` 的 `rect` 位置上。
##
## **必须由 `Main._draw()` 在「原来画竞技场」的同一个位置调用**，这样它之后的
## HUD / 卡片 / 准星 / 淡入遮罩都按原有顺序盖在上面。
func blit(canvas: CanvasItem) -> void:
	var texture := viewport.get_texture()
	if texture == null:
		return
	canvas.draw_texture_rect(texture, rect, false)


## 当前缩放系数：一个世界单位在视窗里占多少像素。
func scale_factor() -> float:
	return _scale


## 一个**屏幕像素**折合多少世界单位（线宽 / 最小尺寸的换算系数，见 `CombatView.pixel_of()`）。
func pixel() -> float:
	if _scale <= 0.0001:
		return 1.0
	return 1.0 / _scale


## 标记世界节点需要重画。绘制内容由 `painter` 现算，所以每帧调用即可。
func refresh() -> void:
	if world != null:
		world.queue_redraw()
