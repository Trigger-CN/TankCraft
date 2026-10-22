extends RefCounted

## 视觉规范唯一来源：docs/design.md §2。
## 这里的 HEX 值不得凭感觉调整；改色必须先改 §2.1 并同步本文件（M1/M4）。
##
## 刻意不使用 class_name：全局类依赖编辑器导入生成的 class 缓存，
## headless 首次运行时装不上，消费方一律用 preload 引用。

# §2.1 色彩规范
const BG_BASE := Color("#05070A")
const GRID_LINE := Color("#0E1A24")
const ACCENT_CYAN := Color("#00F0FF")     # 我方
const ACCENT_MAGENTA := Color("#FF2BD6")  # 敌方
const ACCENT_LIME := Color("#B6FF00")     # 能量 / 充能
const ACCENT_AMBER := Color("#FFC400")    # 弹药 / 物流
const ACCENT_RED := Color("#FF3B30")      # 警示 / 失效
const WIRE := Color("#8FA6B2")            # 结构线条
const TEXT_HI := Color("#EAF6FF")
const TEXT_LO := Color("#6D8494")

# §2 基准：16 px / 格，1920×1080
const CELL_SIZE := 16
const BASE_WIDTH := 1920
const BASE_HEIGHT := 1080

# §2.3 辉光：发光色亮度必须超过 glow_hdr_threshold 才会溢出
const GLOW_INTENSITY := 1.2
const GLOW_BLOOM := 0.15
const GLOW_HDR_THRESHOLD := 0.8


## 归属色：我方 cyan / 敌方 magenta（§2.1）。
static func team_color(is_ally: bool) -> Color:
	return ACCENT_CYAN if is_ally else ACCENT_MAGENTA


## 仅改透明度，保持色相与饱和度完全等于 §2.1 的 HEX 值。
##
## 不要用「乘系数提亮」来触发辉光：所有强调色的最大通道本就是 1.0，
## 已高于 glow_hdr_threshold=0.8，辉光会自然产生；再乘系数只会让通道溢出
## 被钳制，把色相推离规范值（实测 #FF2BD6 提亮后变 #FE30DB、#FFC400 变 #FECB00）。
static func faded(color: Color, alpha: float) -> Color:
	return Color(color.r, color.g, color.b, alpha)
