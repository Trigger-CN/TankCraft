# TankCraft 实现设计审核报告

> 审核对象：`D:\WS\tankcraft`（提交 `be376fc`，v3.44）
> 审核视角：**系统的（机制之间是否自洽）/ 可持续的（能否继续长）/ 通用的（能否被复用与替换）**
> 参照物：同类作品的通行做法 + Godot 社区通用工程实践
> 性质：**只审核，不改产品代码**。本报告是本轮唯一新增文件。

---

## 0. 结论先行

**整体判断：领域层是真工程，页面层是欠债，横切能力几乎为零。**

三句话说完：

1. **领域层（10 个模块、约 300 KB）质量高于同规模个人项目平均水平**：`res://` 依赖图是严格单向 DAG、零反向引用、每个模块都被独立 headless smoke 直接驱动、玩法数值基本走 `data/*.json`。这部分**不需要重做**。
2. **真正的风险在页面层与横切能力**：`main.gd` 一个文件 4591 行承载 6 个页面，**新增第 7 个页面要同时改 8 个入口函数**；输入用 95 处 `KEY_*` 硬编码、没有 InputMap；音频 0、本地化 0、run 存档 0。这些不是「代码不好看」，而是**直接决定还能不能继续加内容**。
3. **最该立刻修的是一件「玩家能感知的玩法缺陷」，而不是架构**：蓝图存档**不保存改进槽配置**，意味着玩家精心配的弹药流水线**存盘即丢**。对一款以「管线布局」为核心卖点的游戏，这等于核心玩法不可沉淀。

按优先级：**先修 1 个 P0（蓝图槽配置）→ 再补 2 个 P1 门禁（测试自检 + 数据自检）→ 再做 1 个 P1 横切（InputMap）→ 架构重构放最后且只在扩页面前做。**

---

## 1. 审核方法与证据边界

### 1.1 怎么审的

不依赖记忆与文档摘要，**全部从仓库文件直接取数**。本轮写了 5 个探针脚本（`.me/tmp/main/audit_*.py`），分别统计：

| 探针 | 产出 |
| --- | --- |
| `audit_check_calls.py` | 23 个测试里 `_check_*` 的定义数与调用数对比 |
| `audit_main_structure.py` | `main.gd` 规模、页面枚举、8 个入口函数的分支分布、最长函数、硬编码常量 |
| `audit_system.py` | 死代码引用方、持久化点、输入/音频/本地化配置、validator 覆盖面、事件发射-消费对照 |
| `audit_dataflow.py` | `block_*` / `global_*` / 直接读 registry 的分布、tier 字符串重复、数字字面量密度 |
| `audit_extensibility.py` | KEY 硬编码、InputMap、音频资源、`tr()`、存档调用、可扩展点 |

### 1.2 这份报告的证据边界（必须读）

- 本报告**没有**做真人试玩。所有结论来自**静态代码读数 + 既有 23 项 headless smoke 的语义**。凡涉及手感、平衡、观感的判断，本报告只指出「机制上缺什么」，不替玩家下结论。
- 「同类作品怎么做」是**品类常识层面的对照**，不是对某个具体版本的逆向分析。引用这些作品是为了说明「这条路有人走通过」，不是要求照抄。
- 报告中所有行号对应提交 `be376fc` 的 `File.Read` 口径（`main.gd` = 4591 行）。`(Get-Content).Count` 会给出 3931，两者对空行统计不同，**以 `File.Read` 为准**。
- 未在 Android 上验证，任何 APK 均不存在。本报告不涉及移动端结论。

---

## 2. 基线事实（全部实测）

### 2.1 规模分布

| 文件 | 字节 | 行数 | 函数 | 备注 |
| --- | --- | --- | --- | --- |
| `scripts/main.gd` | 238,787 | 4,591 | 213 | 6 个页面 + 输入总路由 + 7 个截图钩子 |
| `scripts/ammo_network.gd` | 56,054 | 1,277 | — | 管线图论 + 在途弹药 |
| `scripts/survival_run.gd` | 56,788 | 1,092 | — | 生存状态机 |
| `scripts/tank_body.gd` | 44,141 | 871 | — | 刚体 + 逐格碰撞 |
| `scripts/damage_system.gd` | 33,465 | 881 | — | 伤害/护盾/维修/连锁 |
| `scripts/combat_view.gd` | 32,776 | 585 | — | 纯绘制，全 static |
| `scripts/grid_builder.gd` | 32,535 | 812 | — | 建造模型 + 校验 |
| 其余 15 个 | ~170 KB | — | — | 单个 1.7–26.9 KB |

- `data/`：**26 个 JSON / 56,570 B**（模块 3 个目录文件、口径 1、升级 1、竞技场 3、蓝图 17、globals 1）
- `tests/`：**23 个 `.gd`**
- `main.gd` 占 `scripts/` 总量约 **38%**

### 2.2 依赖结构（这是本项目最大的资产）

`res://scripts/` 引用图实测：

```
palette / fx_layer / data_registry / battle_viewport     ← 叶子，无出边
       ↓
   module_defs ← data_registry
       ↓
   领域层 10 个模块（tank_body, grid_builder, cannon_bank, ammo_network,
                    damage_system, projectile_field, duel, bot_ai,
                    match_state, survival_run）
       ↓
    main.gd（唯一汇聚点，17 条出边）
```

**关键实测结论**：

- **零反向引用**：没有任何领域脚本 preload `main.gd`。这是本项目最重要的一条架构不变量，也是领域层能被独立 smoke 驱动的根本原因。
- **无循环依赖**：DAG 成立。
- **两个死节点**：`expedition_run.gd`（278 行）与 `runtime_builder.gd`（288 行）**零运行时调用方**，仅在 `match_state.gd:4` 与 `survival_run.gd:11` 的**注释**里被提到。但 `tests/expedition_smoke.gd` 与 `tests/runtime_build_smoke.gd` 仍在 23 项回归里。

### 2.3 页面分派形态（可持续性的核心证据）

`main.gd` 用 6 个 `SCREEN_*` 魔串、8 条独立的 if/elif 链做页面分派：

| 入口函数 | 行 | 行数 | 分支数 | 涉及页面 |
| --- | --- | --- | --- | --- |
| `_draw` | 1719 | 17 | 5 | DRIVE MAIN MATCH SETTINGS SURVIVAL |
| `_input` | 364 | 71 | 4 | BUILD DRIVE MATCH SURVIVAL |
| `_process` | 321 | 37 | 3 | DRIVE MATCH SURVIVAL |
| `_handle_key` | 435 | 30 | 3 | BUILD MAIN SETTINGS |
| `_handle_mouse` | 765 | 66 | 3 | BUILD MAIN SETTINGS |
| `_update_hover` | 715 | 50 | 3 | MAIN SETTINGS SURVIVAL |
| `_set_screen` | 465 | 23 | 3 | DRIVE MATCH SURVIVAL |
| `_draw_battle_world` | 2264 | 55 | 3 | DRIVE MATCH SURVIVAL |

`SCREEN_*` 常量被引用次数：SURVIVAL 20 / DRIVE 15 / MATCH 15 / MAIN 14 / SETTINGS 8 / BUILD 7。

**含义**：新增一个页面 = 改 8 个函数、记得在每处加分支、并保证不破坏原有 6 个页面的分支顺序。本项目已经为此付过代价：v3.23 的 `expire` 事件在三个页面层都**没有对应分支**，导致射出后未命中的炮弹消散特效一直静默丢弃——这不是疏忽，是**分派模式**的必然产物。

### 2.4 测试装置

- 23 个 smoke，`_check_*` 定义总数 **128**。
- **实测漏调 2 处**：
  - `tests/camera_zoom_smoke.gd:278` `_check_negative_control()`（25 行，其注释原文是「断言它必须溢出竞技场。如果这条不成立，说明本测试对旧缺陷不敏感 —— 那它就是在替实现背书」）
  - `tests/physics_smoke.gd:496` `_check_performance(definitions)`（带参数，因此不是简单的 `name()` 形式遗漏）
- 全部 23 个测试都有 `quit()`，退出路径无遗漏（v3.43 踩过的坑已堵住）。
- 同一类「验收函数定义了却没被调用」的问题，v3.44 刚在 `survival_smoke.gd` 修过 **9 处**（`SURVIVAL_OK` 长期只覆盖 10/19）。

### 2.5 横切能力覆盖率

| 维度 | 实测 | 判断 |
| --- | --- | --- |
| 输入 | `KEY_*` 硬编码 **95 处**；`project.godot` **无 `[input]` 段**；`Input.is_action_*` **0 处** | 全部键位不可重绑定 |
| 音频 | `AudioStream`/`AudioServer`/`play_sound` **0 处**；仓库内 `.wav`/`.ogg` **0 个** | 完全静音 |
| 本地化 | `_draw_text()` **156 处**中文字面量；`tr()` **0 处**；无 locale/translation 配置 | 单语言硬编码 |
| 持久化 | `main.gd` 仅 **3 处** `FileAccess`：`USER_BLUEPRINT_PATH` 存/读 + `--blueprint` 读 | 只有蓝图，无 run 存档 |
| 场景 | 全仓仅 **1 个** `.tscn`；无 `[autoload]` | 单场景（用户设定的硬约束） |

### 2.6 数据驱动覆盖率

`block_*()` / `global_*()` / 直接读 `registry.globals` 的分布：

| 脚本 | block | global | 直接读 |
| --- | --- | --- | --- |
| `survival_run.gd` | **41** | 9 | 1 |
| `damage_system.gd` | 0 | **19** | 0 |
| `tank_body.gd` | 0 | 13 | 0 |
| `main.gd` | **0** | 10 | 1 |
| `grid_builder.gd` | 0 | 9 | 0 |
| `bot_ai.gd` | 8 | 1 | 0 |
| `module_defs.gd` | 2 | 2 | 3 |
| 其余 8 个 | 0–6 | 1–3 | 0 |

**观察**：`survival_run` 是最规范的（41 处 block 级读取，说明生存块的每个数值都真的从 data 拿）；**`main.gd` 的 block 级读取为 0** —— 页面层没有任何块级数据读取，只有 global 级。

### 2.7 数据查询成本

`data_registry.get_module / get_ammo / get_upgrade / get_arena / get_blueprint` **每次都 `duplicate(true)` 深拷贝**（`data_registry.gd:37-50`）。调用点约 **111 处**，其中 `main.gd` 31 处（多在绘制路径）、`grid_builder.gd` 18 处、`survival_run.gd` 13 处。

---

## 3. 系统一致性（机制之间是否自洽）

> 判定标准：同一件事在系统里是否只有一个定义、一个来源、一个真值。

### S1【P1】稀有度系统语义与命名脱节

### S1【P1】稀有度系统语义与命名脱节

> **✅ 已修复（v3.46）**。`_rarity_multiplier()` 已删除；拆成 `_rarity_tier(price)`（按两个阈值定档，与定价解耦）+ `_weighted_pick(by_tier)`（按累计权重抽档，再在档内抽件）。`shop_rarity_weight` **回归「抽取权重」**语义（实测 1200 样本占比 **0.602 / 0.301 / 0.098**），价格改由新增的 `shop_tier_price_multiplier`（默认 `[1.0, 1.0, 1.0]` ⇒ 成交价与 v3.44 相同）控制。每次抽取**固定 2 次 `_next_unit()`**，确定性纪律未破。补了 `_check_shop_rarity_weights()`（权重压成 `[1,0,0]` → 每格必须普通档、`[0,0,1]` → 每格必须史诗档）；负向对照 `negctl46d.py` 退回全池均匀抽 → 精确报 4 条。**玩家可感知的变化**：价格没变，变的是**哪些商品会出现**（低价普通件明显更常见）。下文保留为缺陷现场记录。

**事实**（`survival_run.gd:939-976`）：
**事实**（`survival_run.gd:939-976`）：

```gdscript
# 抽取：对所有 price>0 的模块做均匀随机（权重完全不参与）
var module_id := String(pool[int(_next_unit() * float(pool.size())) % pool.size()])
...
# 定价：权重被当成价格倍率
var price := float(def.get("price", 0.0)) * _rarity_multiplier(float(def.get("price", 0.0)))
func _rarity_multiplier(price: float) -> float:
    ...
    return 1.0 + weight / total     # 越「稀有」的档，价格越贵
```

**问题**：`shop_rarity_weight = [60, 30, 10]` 这个字段名与设计文档 §14.8 都暗示「稀有度决定出现概率」，但代码里它是**价格乘数**。于是：

- 玩家看到的「稀有商品」= 更贵的同一件东西，而不是「更难得的东西」；
- 全局 48 件模块**均匀抽取**，意味着最便宜的布局件（`conveyor_straight` 6 cr、`platform_cell` 4 cr）和最贵的 `modifier_mk3`（240 cr）**出现概率完全相同**；
- 这一条已被 `docs/roadmap.md` §481 记为「方向反了」，但记了十几个版本仍未修。

**同类作品怎么做**：TFT / 背包乱斗 / Slay the Spire 的商店都是**稀有度决定权重**（低稀有度高频出现），价格按稀有度**档位固定**。这样「攒钱等稀有」才有意义。

**建议**：把 `_rarity_multiplier()` 拆成两件事——`_rarity_tier(price)` 定档，`_weighted_pick(tier)` 按档加权抽；价格由 `price` 直接给（或用 `shop_price_multiplier_by_tier`）。数据层加 `shop_tier_price_multiplier: [1.0, 1.0, 1.0]` 以便随时调价。**改动量约 40 行，全在 `survival_run.gd` 一个函数族内，零架构风险。**

### S2【P1】难度曲线是魔数，与「数据驱动」纪律直接冲突

### S2【P1】难度曲线是魔数，与「数据驱动」纪律直接冲突

> **✅ 已修复（v3.46）**。`tier_for()` 不再写死 `4 / 9 / 14`，改为遍历 `BotAI.TIERS` 读 `_tier_thresholds`，来源是 `data/globals.json` 的 `survival.tier_wave_thresholds`（默认 `{"recruit":1,"veteran":5,"elite":10,"ace":15}` —— **与旧值完全等价**，所以搬进 data 没顺手改难度）。Boss 波「至少精英」的下限规则**独立保留**。`main.gd` 的 `MATCH_DIFFICULTY` 改用 `BotAI.TIERS`，消除字面量副本。补了 `_check_tier_thresholds_from_data()`（换表 `{1,2,3,4}` → w2/w3/w4 必须跟着变）；负向对照 `negctl46e.py` 退回写死 → 精确报 `tier_custom_w2/w3/w4`。下文保留为缺陷现场记录。

**事实**（`survival_run.gd:354-362`）：
**事实**（`survival_run.gd:354-362`）：

```gdscript
func tier_for(current_wave: int) -> String:
    var tier := BotAI.TIER_RECRUIT
    if current_wave > 4:   tier = BotAI.TIER_VETERAN
    if current_wave > 9:   tier = BotAI.TIER_ELITE
    if current_wave > 14:  tier = BotAI.TIER_ACE
    if current_wave % _boss_every == 0 and BotAI.TIERS.find(tier) < BotAI.TIERS.find(BotAI.TIER_ELITE):
        tier = BotAI.TIER_ELITE
    return tier
```

同一个 `survival` 块里，`wave_time_s`、`enemy_count_per_wave`、`enemy_quota_multiplier`、`boss_every`、`wave_clear_credit_base` **全部**从 data 读，**唯独**把「第几波升档」的 4/9/14 写死在代码里。

**问题**：这是 AGENTS 级纪律（`agent_note.md` 的「单场景 + 数据驱动」）的**唯一一处系统性违背**，而且它是最需要反复调参的那一处——难度曲线几乎必然要按玩家反馈改。

**同类作品怎么做**：VS/Brotato 的 stage→怪物池/强度是**表驱动**，改表即改难度。

**建议**：`data/globals.json` 的 `survival` 块加：

```json
"tier_wave_thresholds": {"recruit": 1, "veteran": 5, "elite": 10, "ace": 15}
```

`tier_for()` 改为遍历该表。约 15 行改动。

### S3【P2】等级字符串三处独立定义

| 位置 | 形态 |
| --- | --- |
| `bot_ai.gd:11-15` | `TIER_RECRUIT/VETERAN/ELITE/ACE` + `TIERS` 数组 |
| `main.gd:71` | `const MATCH_DIFFICULTY := ["recruit", "veteran", "elite", "ace"]`（字面量副本） |
| `main.gd:72` | `const MATCH_DIFFICULTY_LABEL := ["新兵", "老兵", "精英", "王牌"]` |

**建议**：`main.gd` 直接 `var tier: String = BotAI.TIERS[min(...)]`，删掉字面量副本。~5 行。

### S4【P2】事件契约字段名与另一套常量重名

`survival_run.gd:30` 有 `const CHOICE_MODULE := "module"`；同时 `house_destroyed` / `enemy_defeated` 事件里也有 `"module": module_id` 字段（掉落模块 id）。

**为什么是问题**：探针按 `kind == "module"` 去扫「未被消费的事件」，会**假命中**一条其实不存在的事件（本轮就中了，见 §6 的方法教训）。对后续写静态检查的人是陷阱。

**建议**：事件字段改名 `"dropped_module"`，或在事件里加 `"kind"` 之外的命名空间前缀。~2 行。

### S5【P2】数据查询的深拷贝成本

`get_module()` 等 5 个函数全部 `duplicate(true)`。约 111 个调用点；其中 `main.gd` 有 31 处，很多在**每帧绘制路径**上（如 `_draw_grid` / `_draw_build_sidebar` / `_draw_survival_mirror`）。

**影响面**：README 已记录「wave12 有约 4% 的单步超过 16.67 ms，`spawn_enemy_us` 尖峰 2.6–10.7 ms」。**不能断言深拷贝就是那个尖峰的成因**（未做 profile），但它是**同一类结构性问题**：绘制层每帧重复分配字典。

**同类做法**：原型数据（`data/*.json` 冻结后不变）用**只读共享引用**，只在需要写时拷贝（COW）；调用方若怕被改，就在 `data_registry` 上加一条注释约定 + 一个 debug 断言。

**建议**：新增 `peek_module(id)` / `peek_ammo(id)` 返回**不拷贝**的引用，供只读路径（绘制、HUD、校验）使用；`get_*` 保留给确实要改的场景。**改动小、收益明确，且能直接拿 `perf_smoke` 量化。**

### S6【P2】死模块仍在回归里

`expedition_run.gd`（278 行）+ `runtime_builder.gd`（288 行）零运行时调用方，但 `tests/expedition_smoke.gd`、`tests/runtime_build_smoke.gd` 每轮都跑。

**判断**：这不是「该删的功能」，而是**回归预算被占用**。23 项 smoke 里 2 项（9%）在验证不可达代码。

**建议**：二选一——(a) 明确标记为「实验模块」，从默认 runner 移出，用 `run_smoke --experimental` 单独跑；(b) 若确认永久不做，直接删脚本 + 删测试（需先确认 `docs/roadmap.md` 里的远征计划是否已废弃）。

---

## 4. 可持续性（能否继续长）

> 判定标准：加一个新页面 / 新玩法 / 新平台，要付多大代价。

### B1【P2，架构级但不应现在做】单文件 6 页面的分派结构

> **审核后更正**：本节原本把 B2（下面那条「测试自检」）写在「测试装置 128 个 `_check_*` 中 2 个未调用」上。**实测复核后改为一处**：只有 `physics_smoke._check_performance(definitions)` 确实未调用；`camera_zoom_smoke._check_negative_control()` **其实已被调用**（出现 2 次），之前是我自己的判定脚本误判（详见 §6）。**结论方向不变**（128 个函数里仍有 1 个是死的，且 v3.44 刚修过 9 个），但**数量必须写对**。

见 §2.3 的实测表格。核心矛盾：

- 用户明确要求**单场景架构**（禁止 `change_scene()`），这是**产品级硬约束**，不应推翻；
- 但「单场景」不等于「单文件」。Godot 里完全可以「一个 `main.tscn` + N 个 `Node` 子节点各管一屏」，或「一个 `Main` + N 个 `RefCounted` 页面控制器」。

**同类/通用做法**：Godot 官方推荐每屏一 Scene；若必须单场景，社区通行做法是 **State/Scene 管理器 + 每个状态一个脚本**（`screens/main_menu.gd`、`screens/build.gd`…），`Main` 只负责：切换、转发 `_input`、持有共享服务（`definitions`、`palette` 字体）。

**为什么建议现在不做**：v3.11 曾评估过「按页面拆文件」并明确搁置，理由是「需页面状态容器、74 个 var 重新归属、`_editor_model()` 跨页分流重设计、`_draw`/`_input`/`_process` 必须留在 `Node2D`、7 个预热钩子需重新定位」。这个评估是**对的**。全量重构会一次性触碰 4,591 行，风险远高于收益。

**建议（折中，成本可控）**：只在**下一次要加新页面前**做「**入口函数字典化**」这一小步：

```gdscript
# 现在
func _draw() -> void:
    if _screen == SCREEN_MAIN: _draw_main_menu()
    elif _screen == SCREEN_SETTINGS: _draw_settings()
    ...

# 改成
var _screen_draw := {
    SCREEN_MAIN: _draw_main_menu,
    SCREEN_SETTINGS: _draw_settings,
    ...
}
func _draw() -> void:
    var fn: Callable = _screen_draw.get(_screen, Callable())
    if fn.is_valid(): fn.call()
```

- 收益：**8 个入口函数的 if/elif 全部消失**，「漏加分支」在结构上不再可能（v3.23 的 `expire` 类事故从根上消失）。
- 成本：8 个字典 + 8 个两行函数，**不改任何页面代码，不改任何状态归属**。
- 风险：像素不变（调用序列完全相同），可用现有截图基线逐字节验证。

这是本报告**最推荐的架构类改动**：用最小代价买下最大的一类结构性风险。

### B2【P1】测试装置没有自检

> **✅ 已修复（v3.46）**。新增 `tests/selfcheck_smoke.gd`：扫 `tests/*.gd` 的 `func _check_xxx(` 定义并逐行统计**调用点**（跳过空行 / `#` 注释行 / 定义行），调用点为 0 即报 `SELFCHECK_UNCALLED` 并计失败；反向要求 `defs >= 120`。当前 `SELFCHECK_OK defs=128 called=128`。`physics_smoke._check_performance(definitions)` 已接入 `_init()`（先用探针确认它在当前代码下是绿的，**只接调用、不改阈值**）。**下文 §292 那段「审核后更正」本身是错的，已在下方就地更正。**

见 §2.4。**128 个 `_check_*` 中 1 个确定从未被调用**：`physics_smoke._check_performance(definitions)`（`physics_smoke.gd` 全文仅出现 1 次）。

> **⚠️ 就地更正（v3.46，第三次事实更正）**：下面这段「审核后更正」**本身是错的**。
>
> 它写「`camera_zoom_smoke._check_negative_control` 出现 **2 次**（定义 + 调用），**它是被调用的**」。**实测不是。** `Select-String` 逐行列出全文只有两处：
>
> ```
> 19  | ## 内部的夹取写法无关。配套的 `_check_negative_control` 把旧 0.5× 公式**独立重算**
> 278 | func _check_negative_control() -> void:
> ```
>
> 即 **一行注释 + 一行定义**。`_init()` 第 56–67 行调用的 12 个 `_check_*` 里**没有它**。
>
> **错在哪里**：我用「同名出现 2 次 ⇒ 有一次调用」这个**原始判据**去复核另一个原始判据，把**注释里的一次提及**当成了调用点，于是把一个**正确的发现推翻了**。
>
> **正确的结论**：**128 个 `_check_*` 里确有 2 个从未被调用** —— `physics_smoke._check_performance` **与** `camera_zoom_smoke._check_negative_control`。两者均已在 v3.46 接入 `_init()`（后者使 `CAMERA_OK checks=594 → 600`，+6 条断言）。
>
> **教训**：判「是否被调用」必须看**那一行是什么**（定义 / 注释 / 调用），不能只数次数。这条已写进 `agent_note.md` §8。

**同类/通用做法**：测试清单的「定义 - 调用」一致性应由**测试框架自身**保证，而不是靠人肉 review。GDScript 没有反射枚举函数，但可以用**极简源码扫描**实现。

**建议**（可立即落地，约 30 行）：

在 `run_smoke` 里加一步 `tests_selfcheck`（或独立 `tests/_selfcheck.gd`）：

```gdscript
# 对每个 tests/*.gd：正则收集 ^func (_check_\w+)\(，再统计同名出现次数；
# < 2 次 ⇒ 报 XXX_UNCALLED，runner 记为失败。
# 注意：有参数的验收（如 _check_performance(definitions)）也要能被这条规则覆盖——
# 它们同样只会出现 1 次。
```

同时把 `physics_smoke._check_performance(definitions)` 补上调用（**它有参数，补的时候要传 `definitions`**），先确认它在当前代码下到底是绿还是红。

**这条的价值**：v3.44 刚花了一整轮发现并修 9 处同类问题；一个 30 行的门禁可以让它**永不复发**。

### B3【P2】数据文件不是合法标准 JSON

> **✅ 已修复（v3.46）**。唯一一处真尾逗号已从 `git show HEAD:` 的原始字节用正则 `,(\s*[}\]])` 精确删除（断言「严格 JSON 能解析」+「**语义完全相同**」+「字节增量 −1」）。另新增 `tests/data_strict_smoke.gd`（28 条 / 26 个 JSON）作为**门禁**：查尾逗号 / `//` 行注释 / `NaN` / `Infinity` / 单引号；**刻意不用 `JSON.parse_string()` 做严格性检查** —— 它恰恰容忍尾逗号，用它复检等于自证。下文保留为缺陷现场记录。

`data/globals.json` 第 53 行 `"tank_collision_coefficient": 0.04,` 后面紧跟 `},` —— **尾逗号**。

- Godot 的 `JSON.parse_string()` 容忍它（所以 `data_smoke` 报 `DATA_OK`，玩家侧无影响）；
- **Python `json`、`jq`、CI、任何编辑器插件都不容忍**。本轮写文档核验脚本时就直接崩在这行，只能先写正则剥尾逗号绕过去。

**建议**：删掉这个逗号（一行）。并在 `data_smoke` 里加一条「用严格解析器复检」（Godot 无严格模式，可用 `JSON.stringify(JSON.parse_string(s))` 长度对比，或由外部脚本在 CI 跑）。**这是极低成本、消除一整类工具摩擦的修复。**

### B4【P1】输入完全硬编码

95 处 `KEY_*`，0 个 InputMap action，0 处 `Input.is_action_*`。

**为什么这是可持续性问题**（不只是通用性问题）：

- 想做**键位重绑定**（设置页已有 `SCREEN_SETTINGS`）→ 要改 95 处；
- 想支持**手柄**（`docs/roadmap.md` 记为「暂不支持」，但那是裁定不是永久的）→ 无从下手；
- 想做**触屏**（M8 已设计、代码零实现）→ 虚拟按键必须映射到 action 才有落点；
- 现在 `_handle_key` 里是一个巨大的 `match key` 分支，加键就要改它。

**建议（渐进，不要求一次改完）**：新增 `project.godot` 的 `[input]` 段，定义 **12 个核心 action**（`move_up/down/left/right`、`fire`、`zoom_in/out`、`pause`、`editor_cancel`、`editor_rotate`、`editor_layer_prev/next`），先把 `_input`/`_handle_key` 里**战斗相关**的键走 action，编辑器类键可暂留。**收益立竿见影：重绑定与触屏都有了落点，且不影响现有键位（action 的默认绑定就是当前键）。**

### B5【P2】`main.gd` 绘制层数字字面量密度过高

按函数统计「应当提取为具名常量」的裸数字：

| 函数 | 裸数字个数 |
| --- | --- |
| `_draw_build_inspector()` | 89 |
| `_draw_drive_hud()` | 67 |
| `_draw_match_hud()` | 57 |
| `_draw_survival_hud()` | 56 |
| `_draw_survival_mirror()` | 55 |
| `_draw_preview_tank()` | 48 |
| `_draw_build_sidebar()` | 46 |

**共 31 个函数的裸数字 ≥ 12 个。**

**判断**：这些多数是 HUD 布局坐标（`+32.0`、`+74.0` 这类），**放进 `data/*.json` 是错的**（它们不是玩法数值，且改 data 就改 UI 是危险的）。但**留成裸数字也有代价**：v3.18 的「层级选择和标题重叠」、v3.8 的「难度按钮压住菜单」都是这么来的——两个布局块各自算坐标，谁也不知道对方占了哪。

**建议（不是重构）**：只对**已经出过重叠事故**的那几处抽具名常量（`BUILD_LAYER_Y0`、`BUILD_TOOL_Y`、`MENU_DIFFICULTY_Y`…），并在 `tests/editor_bounds_smoke.gd` 里加「矩形不相交」断言。**用测试而不是注释来防重叠**。

### B6【P3】无 run 存档（有意，但要有边界文档）

实测只有蓝图读写 3 处 `FileAccess`，**没有** run 存档。用户已确认「质量上限目前不是跨局保存，每次对局都是从零开始」——这是**产品决策，不是缺陷**。

**但要注意**：`docs/roadmap.md` 里「肉鸽」这个词通常隐含「局外成长（meta progression）」。当前实现是**纯局内**肉鸽。如果未来要做局外成长，`GridBuilder` 的 `mass_cap_level` 与 `credits` 是最自然的沉淀点，但它们是实例状态、无序列化。**建议在 design 文档里显式写一条「本作不含局外成长」或「局外成长预留点」，避免后续对『肉鸽』的理解漂移。**

---

## 5. 通用性（能否被复用与替换）

> 判定标准：换掉一个子系统（渲染/输入/数据/音效）要不要改别处。

### C1【P3 - 反而是优点】渲染层已经是可替换的

`combat_view.gd`（32.8 KB）全 `static`、无状态、只 preload `palette` + `fx_layer`；`battle_viewport.gd` 把相机与裁剪完全交给引擎；`pipe_view` / `cannon_view` 也是纯几何。**四层绘制组件都不持有状态、不反向依赖 `main.gd`。**

**这是本项目做得最好的一块**：v3.42 把「手写投影 + 手写裁剪」换成 `SubViewport + Camera2D` 时，`main.gd` 只需改 `_paint_battle_world()` 一处；组件本身一行没动。**同类项目在这一步通常要重写全部绘制代码。**

**建议：保持这条纪律不许破坏** —— 新增任何绘制代码都必须「传 `canvas` + 纯函数 + 无状态」。这条已写在 `agent_note.md`，但应提升为**架构不变量**级别的显式条目。

### C2【P2】蓝图不保存改进槽配置（**本报告唯一的 P0 级玩法缺陷**）

### C2【P2】蓝图不保存改进槽配置（**本报告唯一的 P0 级玩法缺陷**）

> **✅ 已修复（v3.46）**。`_serialize_parts()` 现在对带 `upgrade_slots` 的模块写出 `upgrades`（空数组也写），`_parse_part()` 读回，新增 `_parse_upgrades()` 走与 `set_modifier_upgrades()` 同源的校验（未知 id 丢弃 / 超槽截断 / 按 `stack_limit` 去重，**非法项不整条失败**）；`data_validator.validate_blueprint()` 新增第 5 参 `upgrade_ids`、`data_registry` 传参。新增回归 `tests/blueprint_roundtrip_smoke.gd`（20 条）；负向对照 `negctl46.py` 撤掉序列化后精确报 3 条。**尚未经过用户实机确认**（存盘 → 重启 → 读回的端到端链路只有 headless 证据）。下文保留为缺陷现场记录。

**事实**（`grid_builder.gd`）：
**事实**（`grid_builder.gd`）：

- `set_modifier_upgrades(cell, upgrades)` 把升级写进 `part["upgrades"]`；
- `modifier_upgrades_at(cell)` 读回来；
- **但 `_serialize_parts()` 与 `_parse_part()` 都不处理 `upgrades`**（也不处理 `intrinsic`）。

`docs/design.md` §17 的 v3.41 行与 README「已知限制」都已记录这一条，定位为「蓝图不保存槽配置」。

**为什么升级为 P0**：

1. **这是本作最核心的玩法**。玩家买/捡到 `modifier_mk2`、在改装页用 `Q/E`+`T` 把 `up_damage` + `up_burn` 配进两个槽，整条流水线的价值全在这两个槽上。**存档不存它 = 存下来的是一台空壳车。**
2. **它的表现形式是「静默丢失」**：`Ctrl+S` 会报「蓝图已保存到用户存档」，`Ctrl+O` 会报读回成功，**但槽位是空的**。玩家不会收到任何警告。
3. 修复成本**极低**（见下），而延后的代价是每多一个玩家用蓝图，就多一份「我配了但没了」的困惑。

**同类作品怎么做**：背包乱斗 / 自走棋的构筑存档必然包含所有配装细节——**构筑就是存档的全部意义**。

**建议**（约 20 行）：

- `_serialize_parts()` 每件 part 增加 `"upgrades": [...]`（空数组也写，保持 round-trip 稳定）；
- `_parse_part()` 读回时 `if part.has("upgrades"): part["upgrades"] = ...`，**并校验每个 id 存在于 `definitions.registry.upgrades`**，非法则丢弃该项并记一条 status（不整条失败，避免旧存档打不开）；
- **不写 `intrinsic`**（它是模块类型属性，运行期从定义读，写盘会造成第二真源——v3.41 已就此定过结论，保持）；
- 加一条 smoke：构造带 2 个槽配置的车 → 序列化 → 反序列化 → 断言 `modifier_upgrades_at()` 逐项相等。

### C3【P2】无音频层

> **⏸ 未修复（v3.46 刻意不做）**：报告 §7.3 给它的触发条件是「素材到位」。仓库内仍 0 个 `.wav` / `.ogg`，建事件层也没有东西可放。下文保留。

`AudioStream` / `.wav` / `.ogg` 全为 0。

**判断**：这不是「代码质量问题」，但对**射击建造类**游戏它是**可玩性主项**——开火的炮口闪光再漂亮，没有声音就没有打击感；命中、被击中、模块损毁、护盾破碎、波次通过，每一个都是一次反馈机会，现在**全部靠文字与颜色**。

**通用做法**：一个 `AudioDirector`（autoload 或 `main` 子节点）+ 一组 `[input]` 无关的「事件→音效」映射，由 `Duel.drain_events()` 已经在产出的同一套事件驱动。**本项目的架构其实**已经**为这一步准备好了：事件流是现成的（`impact` / `destroyed` / `muzzle` / `expire` / `shield_hit` / `wave_cleared` …），只缺一个消费者。

**建议**：不要求一次做完。先接 **3 个**（`muzzle` / `impact` / `destroyed`），验证「事件→音效」这条链，其余按素材到位逐步加。**这是本项目投入产出比最高的一项体验改进**，比任何架构重构都更能让玩家感到「变好了」。

### C4【P2】无本地化

156 处 `_draw_text()` 中文字面量，0 处 `tr()`。

**判断**：如果目标只有中文玩家，这**不是问题**——强行引入 `tr()` 会让 156 处调用变长，收益为零。**但要把这件事写清楚**：`docs/design.md` 应显式声明「单语言：简体中文，不支持切换」，而不是留白让人以为「迟早要做」。

**若未来要出海**：Godot 的 `tr()` + CSV 导入是最低成本路径，且 `tr()` 对未翻译字符串**原样返回**，所以可以**渐进替换**（先替换菜单，后替换 HUD）。这一点值得写进文档，作为「如果要做，怎么做」的锚点。

### C5【P3】`main.gd` 的硬编码页面常量

`DRIVE_ARENA_ID := "arena_standard"`、`MATCH_DIFFICULTY` 数组都在页面层硬编码。

**影响**：小。试驾页固定用标准竞技场是合理产品决策（试驾就该在标准场）。**但 `data/arenas/` 里有 3 个竞技场（`arena_standard` / `arena_pit` / `arena_corridor`），而 `scripts/` 与 `tests/` 里除 `arena_standard` 外零命中**（实测检索结果），即 `arena_pit` 与 `arena_corridor` **从未被任何代码加载过** —— 它们是纯数据、零验证，不合格也发现不了。建议二选一：要么做成可见的「选图」入口（`data/globals.json` 加 `pages: {drive: {arena: ...}, match: {arena: ...}}`），要么明确标为素材草稿并降级出回归验证。

### C6【P3】扩展点确实是数据驱动的（优点）

- 模块：`data/modules/{mobility,platforms,systems}.json`
- 口径：`data/ammo/calibers.json`
- 升级：`data/upgrades/upgrades.json`
- 竞技场：`data/arenas/*.json`（3 个）
- 蓝图：`data/blueprints/*.json`（17 个）
- `data_validator.gd` 覆盖 6 类：globals / module_catalog / ammo_catalog / upgrade_catalog / arena / blueprint

**加一件模块 / 一个口径 / 一张蓝图，确实只需加 JSON**。这是本项目「通用性」的正面证据，也是它能快速迭代 44 个版本的原因。

**唯一缺口**：`data_validator` 不校验 `blueprints` 内部的 `upgrades`（因为本来就不存），修 C2 时要同步补校验。

---

## 6. 我自己这次的装置缺陷（必须记，不算产品问题）

写报告时踩到**三个**坑。前两个是探针缺陷，**第三个是我自己写在报告里的错误结论，已更正**：

1. **事件扫描假命中**：用正则 `"kind": "(\w+)"` 扫 `survival_run.gd` 的发射事件，把 `const CHOICE_MODULE := "module"`（升级候选类型）和**商店商品格** `{"kind": "module", "id": …, "price": …}`（`_roll_shop` 写入 `shop_slots` 的槽结构）都当成了「事件 kind」，于是报出「`module` 事件被发射但页面层未消费」。**核实后：没有任何 run 事件叫 `module`** —— 那个字面量属于**商店槽结构**，不是 `frame_events`。教训同 v3.39：**探针的期望值必须来自独立推导，不能靠正则抓实现里的字面量**。
2. **JSON 解析失败**：核验脚本用 Python 标准库读 `data/globals.json`，崩在第 53 行尾逗号。**这不是文档写错，是数据文件不合法**（见 B3）。当时选择「在脚本里剥尾逗号」而不是改仓库文件——**因为审核任务不应顺手改产品代码**。这条修法留给 B3。
3. **我自己写错的两条结论（已更正，留此存证）**：
   - 曾写「`_check_negative_control()` 定义了但未调用」。**错**：它在 `camera_zoom_smoke.gd` 里出现 **2 次**（定义 + 调用），是**已被调用的**。我当时用了一个错误的判定脚本（把「同名出现次数 < 2」当作未调用，但对只有一个定义且无调用的函数同样得 1，无法区分）；改用「文件内出现次数」后仍误判，最终靠 `File_Search` 逐条看结果才确认：**只有 `physics_smoke._check_performance(definitions)` 出现 1 次，是真未调用**。**这是一次「我用工具做了检查但没看结果细节」的典型失手。**
   - 曾写「`data/arenas/` 里 3 个竞技场只用了 2 个」。**错**：`arena_pit` 与 `arena_corridor` 在 `scripts/` 与 `tests/` 里**零命中**，实际**只用了 1 个**（`arena_standard`）。已在 C5 更正。

**这三条合起来说明一件事**：审核报告里的每一个数字都应有「直接读到」作为依据；凡是由我**推断**出来的（比如「几次出现 = 是否被调用」），必须回到原始输出逐条验证。本轮为此额外写了一个 `audit_verify_claims.py` 做二次校对。

---

## 7. 优先级与执行建议

> **执行状态（v3.46，用户指令「按照建议开始修复」）**：§7.1 的 3 项 + §7.2 的 3 项，**共 6 项已全部落地并验证**；§7.3（触发条件未到）与 §7.4（明确不建议）**刻意未做**。
>
> | # | 项 | 状态 |
> | --- | --- | --- |
> | 1 | 蓝图保存改进槽配置（C2 / P0） | ✅ 已修（`BPROUND_OK checks=20`；负向 `NEGCTL46_PASS`） |
> | 2 | 删 `globals.json` 尾逗号（B3） | ✅ 已修（`SEMANTIC_IDENTICAL True` / `DELTA -1` 字节；`STRICT_OK`） |
> | 3 | 补未调用的验收（B2） | ✅ 已修（`physics_smoke` 接入 `_check_performance`，数值与基线逐字相同） |
> | 4 | 测试自检门禁（B2） | ✅ 已修（`SELFCHECK_OK defs=128 called=128`） |
> | 5 | 稀有度按档加权抽取（S1） | ✅ 已修（实测占比 0.602/0.301/0.098；负向 `NEGCTL46D_PASS`） |
> | 6 | 难度曲线进 data（S2） | ✅ 已修（默认值与旧 4/9/14 完全等价；负向 `NEGCTL46E_PASS`） |
>
> 全量回归 `s46_all.txt` **26 项全绿**，`PHYSICS_OK` / `CANNON_OK` / `BUILD_OK` / `RUNTIME_OK` / `DATA_OK` / `DATA_ERROR_OK` / `CANNONVIEW_OK` / `PERF_OK` 与 v3.45 基线**逐字相同**；唯一数值变化是 **`CAMERA_OK checks=594 → 600`**（接入 `camera_zoom_smoke._check_negative_control`，+6 条断言）。
>
> **本次改动尚未经过用户实机确认**；全部证据为 headless smoke + 负向对照 + 探针断言，**没有做 profile**。

### 7.1 立即做（1–2 小时内可完成，风险极低）

| # | 项 | 位置 | 成本 | 收益 |
| --- | --- | --- | --- | --- |
| 1 | **蓝图保存改进槽配置**（C2 / P0） | `grid_builder.gd` `_serialize_parts` / `_parse_part` | ~20 行 + 1 smoke | 核心玩法可沉淀；消除静默丢失 |
| 2 | 删 `globals.json:53` 尾逗号（B3） | `data/globals.json` | 1 字符 | 消除全部标准 JSON 工具摩擦 |
| 3 | 补 1 处未调用的验收（B2） | `physics_smoke._check_performance(definitions)` | ~5 行 | 让 `PHYSICS_OK` 名副其实 |

### 7.2 下一轮做（各半天以内）

| # | 项 | 成本 | 收益 |
| --- | --- | --- | --- |
| 4 | **测试自检门禁**（B2） | ~30 行 | 「定义了没调用」永不复发 |
| 5 | **稀有度改成按档加权抽取**（S1） | ~40 行 | 修掉从 v3.6 记到现在的语义错误 |
| 6 | **难度曲线进 data**（S2） | ~15 行 + JSON | 补上唯一的纪律破口 |

### 7.3 有明确触发条件时再做

| # | 项 | 触发条件 |
| --- | --- | --- |
| 7 | **入口函数字典化**（B1 折中） | **下一次要加新页面之前**。若永远不加第 7 页，可不做 |
| 8 | **InputMap 化**（B4） | 要做「键位重绑定」或 M8 触屏之前 |
| 9 | **音频事件层**（C3） | 素材到位即可开始；建议先 3 个音效验证链路 |
| 10 | `peek_*()` 只读接口（S5） | 若 `perf_smoke` 实测「绘制期深拷贝」占比 >5% 再动 |

### 7.4 明确不建议做

- **不要在现在做「按页面拆分 `main.gd`」的全量重构。** v3.11 的风险评估是对的（状态归属、`_editor_model` 跨页分流、预热钩子重定位）。B1 的字典化折中能拿到 80% 的收益、1% 的风险。
- **不要把 HUD 布局数字搬进 `data/*.json`。** 它们不是玩法数值，data 驱动它们会让「改数值」意外改布局。
- **不要强行引入 `tr()`。** 单语言是当前正确选择，把「不支持多语言」写进文档即可（C4）。
- **不要为了「架构整洁」去动领域层。** 那 10 个模块是本项目最好的资产，DAG 单向、独立 smoke 覆盖，动它风险远大于收益。

---

## 8. 结论

**做得好、且应当保持的**（不是客套，是有实测支撑的）：

1. `res://` 依赖图是**严格单向 DAG**，零反向引用——这是 22 个脚本能用 23 项独立 smoke 驱动的前提。
2. **绘制层四件套**（`combat_view` / `pipe_view` / `cannon_view` / `battle_viewport`）全静态、无状态、不反向依赖页面层，v3.42 换渲染方案时零改动。
3. **数据驱动覆盖率**在领域层是真实的（`survival_run` 41 处 block 级读取），加模块 / 口径 / 蓝图确实只需加 JSON。
4. **测试纪律**：全部 23 个测试都有 `quit()`，负向验证已成惯例（`negctl4x.py` 系列），这是同规模项目里罕见的自觉。

**最该改的三件事，按顺序**：

1. **蓝图不保存改进槽配置** —— 唯一的 P0。它让「配好管线再存蓝图」这个动作**静默失去意义**，而修它只要 20 行。
2. **测试与数据的自检门禁**（未调用验收 + 非法 JSON）—— 都是几十行的成本，消除的是**反复复发**的同类问题（v3.44 一轮修 9 处、本轮又查出 2 处）。
3. **入口函数字典化** —— 在加第 7 个页面之前做，用 ~50 行买下「漏加分支」这一整类结构性风险。

**最后一句实话**：

这个项目的**领域层设计水平明显高于它的规模给人留下的印象**，问题几乎全部集中在「页面层的组织方式」和「横切能力的缺失」上。这两块都不需要推倒重来——需要的是**几个几十行的止损点**，以及**在做下一次扩展之前先花半天把入口函数和门禁补上**。

---

> 报告生成于提交 `be376fc`（v3.44）。审核过程未修改任何产品代码。
> 所有行号/计数均可用 `.me/tmp/main/audit_*.py` 五个探针脚本重新复现。
>
> **v3.46 执行轮更新**：报告正文（§0–§6）**保留为快照，未重写**；只就地加注「已修复 / 未修复」并补上第三次事实更正（见 §4 B2）。报告里的行号仍对应 `be376fc` 的 `File.Read` 口径。执行后的代码状态见 `docs/design.md` §11.4.2.25 与 `docs/roadmap.md` §0/§5 的 v3.46 行。
>
> **本报告里我自己写错、并在执行轮发现的三处，已全部就地更正且不得隐去**：
>
> 1. §4 B2 的「审核后更正」**本身是错的** —— `camera_zoom_smoke._check_negative_control` 确实**从未被调用**（第 19 行是注释、第 278 行是定义），「真未调用」应为 **2 个**而非 1 个。
> 2. 原文把「尾逗号」的位置指向 `tank_collision_coefficient` 那一行 —— 那个逗号是**正常的成员分隔符**，真正的尾逗号是**下一行闭合 `global` 块的那个 `},`**。
> 3. 本报告「唯一 P0」的修法估计（约 20 行）**偏低**：实际改动 4 个脚本 + 1 个新测试（含数据层校验参数透传）。
>
> **v3.47 排查轮补充（只排查、不改码）**：用户提问「检查那些地方还需要完善」，本轮做了 **8 个独立扫描脚本**的静态排查，结论写入 `docs/roadmap.md` §4.5（清单本体）与 `docs/design.md` §11.4.2.26（技术背景）。**本报告 §7.3 / §7.4 的结论全部仍然有效，本次不重复也不推翻**；§4.5 列的是那两份清单**没有覆盖到**的项（P0 ×4 / P1 ×6 / P2 ×6）。
>
> 两处与**本报告自身**相关的复查结论，必须记在这里：
>
> 1. **§2.7 的「深拷贝调用点约 111 处」** —— 本轮把 `tests/` 也计入后实测为 **155 处**（`get_module` 104 / `get_ammo` 15 / `get_upgrade` 15 / `get_arena` 13 / `get_blueprint` 8）。**仍未做 profile**，所以报告里「只说结构性成本、不断言是 wave12 超预算的成因」这个边界**保持不变**。
> 2. **§2.5 / §4 B1 的「8 条 if/elif 链」** —— 本轮在设置页找到了它的一个**具体受害者**：`_settings_index` 的上下界**硬编码在两处**（`main.gd:457` 的 `mini(_settings_index + 1, 2)` 与 `main.gd:498` 的 `range(3)`），加第 4 行设置项必须同时改这两处，否则**键盘与鼠标行为不一致**。这给 B1 字典化的收益提供了一个可复现的实例。
>
> **另外，本轮排查也检验了本报告 §1 的「证据边界」纪律**：8 个扫描器里有 **2 个第一版是错的**（「零引用函数」28 个中 13 个误报、「零读取数据键」13 个中 8 个误报），已全部核实排除后才写进文档。**扫描器本身的误报也是证据链的一部分，不能省。**

> **v3.48 执行轮补充**：用户说「按计划开始」，指 `docs/roadmap.md` §4.5.5 的建议执行顺序。本轮执行了**待完善清单的全部 P0 四项**（P0-1 设置持久化 / P0-2 生存模式暂停 / P0-3 设置页扩行 / P0-4 退出二次确认）与 **P1 三项**（P1-3 `processing_multiplier` 定性为实现 / P1-4 删 13 个零引用函数 / P1-5 删 4 个零读取数据键），**P1-6 的 `arena_pit` / `arena_corridor` 保留不删**（改为标注「纯数据、零加载」）。**P2 六项本轮未动**，留给用户定优先级。实现记录见 `docs/design.md` §11.4.2.27，变更行见三份文档的变更表。
>
> **与本报告直接相关的三条**：
>
> 1. **§4 B1「8 条 if/elif 链」得到了第二个可复现实例** —— 设置页的行数上下界硬编码在**两处**（键盘 `mini(_settings_index + 1, 2)` 与鼠标 `range(3)`），加一行必须同时改两处。本轮已用 `SETTINGS_ROW_COUNT` / `SETTINGS_ROW_Y` 两个单一来源常量消除。**但 §7.3 的「入口函数字典化」本身仍未做** —— 触发条件「下一次要加新页面之前」仍未到（仍是 6 个页面）。
> 2. **§2.7「深拷贝调用点」的边界不变** —— 本轮**仍未做 profile**。P1-3 的实现只在加工时间上乘一个因子，不涉及任何查询热路径，因此**不构成对深拷贝成本的任何证据**。
> 3. **§7.3 其余项（InputMap 化 / 音频事件层 / `peek_*()` 只读接口）与 §7.4（明确不建议）全部未动，结论仍有效。**
>
> **本轮发现的两个测试装置弱点，应记入后续审核**：
>
> 1. **运行时 `SCRIPT ERROR` 不等于断言失败，而且会让 `extends SceneTree` 进程永久挂起。** 测试脚本的 `_init()` 被 `SCRIPT ERROR` 中断后，`quit(0)` / `quit(1)` 一个都执行不到，进程停在事件循环里；从外部看只表现为「输出静默」，与「命令还在跑」无法区分。本轮 `runtime_build_smoke` 因此挂起过一次。**规则：跑 smoke 一律带 `--quit-after` 兜底，判断完成只看工件文件与提示符。**
> 2. **反向用例对「默认值为 `false` 的布尔字段」没有区分力。** 「把默认值写回去、读回也必须是默认值」这条断言，对 `debug_readout`（默认 `false`）在「压根没写这个键」的缺陷下**恰好恒成立**。**反向用例的期望值必须与「缺键时的默认值」不同。** 已知覆盖缺口，本轮不修。
>
> **另外必须记一笔的是我自己的操作失误**：本轮我造成 **3 处真实产品回归**（`runtime_builder.part_at_module()` 被误删 → 测试进程永久挂起；`_battle_viewport.configure(...)` 被误删 → **整个战场完全不渲染**；`build_cost()` 被连带删除 → `Parse Error`），全部被 `--check-only` / 全量 smoke 抓到并修好，**无一流入提交**。根因是同一个：**`File.Edit` 的 `replace` 选中行数与 `new_lines` 覆盖的完整行数不匹配**（本轮共 5 次同类），以及**删除核实脚本只扫 `scripts/` 没扫 `tests/`**。**这印证了本报告 §1 的纪律：验证手段本身的缺陷也是证据链的一部分。**
>
> **边界（不得弱化）**：本轮全部证据为 **headless smoke（27 项）+ 负向对照（3 组）+ 源码直读**。**本次改动尚未经过用户实机确认**；**UI 改动（设置页 5 行 / 退出确认文案 / 暂停遮罩 / 调试叠加层）没有任何自动化测试覆盖**（`_draw` 在 headless 下不执行，`tests/` 对 UI 层零覆盖）；`main.gd::_survival_simulate()` 的累加器清零分支在 headless 下测不到；**没有做 profile**；**未在 Android 上验证，任何 APK 均不存在**。

> **v3.49 特效渲染审核轮补充**：用户原话「再次检查审核特效渲染方面，美化效果」。本轮是**实现轮**（先审计再改码），审的是**特效 / 粒子渲染子系统**，与 §7.3 / §7.4 的结论不重复也不推翻。
>
> **① 本轮找到的四个真实缺陷**（全部已修并做负向对照）：**A** 生存页护盾受击**零视觉反馈**（数据层发 `shield_hit` 带 `cell` / 页面层推 `kind="shield"` 位置零半径零 / 绘制层对 `shield` 直接 `continue`，三重错误互相掩盖）；**B** 殉爆与引擎爆炸在对局页只有一行文字、在生存页**完全没有分支**，而 `_area_damage()` 逐受波及部件发事件导致页面层拿不到爆炸中心；**C** `draw_damage_popups()` 的 `stack` 在循环外累加，第 6 条数字被抬高 70 px，**哪怕隔了半个战场**；**D** 命中闪光三页各是单变量，齐射只闪最后一发。
>
> **② 与本报告 §3「系统一致性」相关的一条结构判断**：缺陷 A 与 B 与 v3.43 的 `enemy_defeated` 是**同一类**——「机制存在 ≠ 可被感知」，事件在数据层产生了但页面层没有消费者。本轮把三页对 `*_burst` 的消费补上，并在 `fx_render_smoke` 里加了**源码扫描**型断言（「三页都必须真的消费 `*_burst`」），把这一类从「靠人读代码」变成「有断言盯着」。**但扫描断言只证明分支存在，不证明分支正确执行**，这一层仍只有截图 + 用户实机。
>
> **③ 必须如实记录的覆盖边界（不得弱化）**：本轮**没有**为绘制层建立任何自动化像素覆盖，而且**实测确认那条路走不通** —— `CanvasItem.draw_*` 只能在 `_draw()` 内调用，四种图元全部报 `Drawing is only allowed inside this node's \`_draw()\`…`，且脚本不中止。所以 `fx_render_smoke` 的 51 项断言只覆盖**纯数值关系、`DamageSystem` 事件、源文本**三层；**像素结论全部来自 `--capture` 截图 + 我自己的眼睛**。护盾受击与爆炸爆发两个特效的**像素表现未在任何截图里出现**；多实例命中闪光**未观察到同时闪光**（截图是单帧，无法证明时间维度）。
>
> **④ 三页历史截图基线全部作废并已重拍**：`v23c_surv.png` 183,957 B / `v23c_match.png` 133,180 B / `v23c_drive.png` 213,730 B → `v49_surv.png` 193,693 B / `v49_match.png` 145,011 B / `v49_drive.png` 200,829 B。作废原因**不是改坏了**，而是本轮**有意**改变了三页共用的绘制内容（`special` 形状启用 + 竞技场内发光与角标 + 房屋双线 + 伤害数字分桶），像素必然变化。
>
> **⑤ 我自己的失误（与产品缺陷严格分开记）**：`SHOT_STEP_REFERENCE` 单位错误（「上一帧位移 ÷ 1.0」得到 px/帧不是 px/s，所有口径拖尾塌到 clamp 下限；**修法是改数据来源 `shot["speed"]` 而不是调常数**）；`drive_feedback_smoke` 漏改导致**假绿**（`SCRIPT ERROR` 让 `_expect()` 根本不执行、测试照样打印 `*_OK` —— 这是本报告 §1 纪律的又一次现实版）；两次 `File.Edit` 吞掉整行导致 `Parse Error`；`fx_render_smoke` 自身 5 个夹具缺陷（模块 id 猜错 / `place_module()` 签名猜错 / 断言期望值写错 / 绕过 `DamageSystem` 导致殉爆事件为 0 / 源码扫描命中注释）。
>
> **边界（不得弱化）**：本轮全部证据为 **headless `--check-only` + `fx_render_smoke` 51 项 + 5 组负向对照 + 28 项全量 smoke + 三张真实窗口截图（逐张 `Image_View` 亲自看过）**。**本次改动尚未经过用户实机确认**；**没有做 profile**；**未在 Android 上验证，任何 APK 均不存在**。

> **v3.50 部件摧毁功能失效轮补充**：用户实机报告的「炮管打掉之后还能发射」已定位到确切根因 ——
> `CannonBank.cannons` 与 `AmmoNetwork.parts` 是 `tank.parts` / `builder` 之外的**两份独立功能索引副本**，
> 只在 `Duel.add_side()` / `Main._enter_drive()` 里构建一次；`DamageSystem.apply_part_damage()` 与 `_detach()`
> 只更新 `tank` / `builder` / 护盾表，**从不重建这两份索引**，于是被打掉的炮管仍留在 `bank.cannons` 里，
> 连 `loaded` / `reload_remaining` 状态都在。同根因使弹药制造装置 / 改进器 / 弹药库被打掉后功能同样不失效。
>
> **架构上这是一个「同一事实存了多份」的问题**，与本报告 §R17 系列记录的「机制存在 ≠ 生效」同类但形态不同：
> 那里是漏调 tick 或丢弃事件，这里是**漏重建索引**。修法选择「结算层只发回调、由编排层重建」而不是让
> `DamageSystem` 直接持有 `CannonBank` / `AmmoNetwork` —— 后者会给结算层引入 preload 环
> （`ammo_network` 已 preload `cannon_bank`），而且会让一个纯结算组件开始依赖功能索引层。
> 回调与既有的 `tank.damage_router = Callable(damage, "apply_part_damage")` 是同一惯例。
>
> **重建而非局部删除**是刻意的：`AmmoNetwork` 有八个互相引用的索引（`nodes` / `_nodes_by_cell` /
> `_links_out` / `_links_in` / `_levels` / `_rounds` / `_owner` / `_tee_counters`），局部删除必须同时维护全部；
> 而 `rebuild()` 已通过 23 条组合矩阵。重建不丢状态的前提是 `reload_from_body()` 按 `module_id` + 首格保留
> 装填态、`rebuild()` 按同一键重挂在途弹药 —— 这两条都由新增断言的 `keep_reload_preserved` /
> `keep_shots_preserved` 直接守住。
>
> **同轮补上碎片掉落效果**（用户同句提出的新需求）：新增独立 kind `part_debris` 与
> `CombatView.draw_part_debris()`，8 片固定角短线段 + 径向抛洒 + `progress²` 竖直下落，**全程零随机**。
> 三页原先只有生存页有一个 `break` 小圆环，对局与试驾的 `destroyed` 分支只写一行文字、零动效。
>
> **证据边界**：headless smoke（`PART_DESTROY_OK`）+ 6 组负向对照（全部精确变红并还原）+ 全量 smoke 29 项 +
> 源码扫描。**像素表现只有 `--capture` 截图 + 人眼，没有自动化覆盖**（`_draw` 在 headless 下不执行）。
> **本次改动尚未经过用户实机确认**；**没有做 profile**；**未在 Android 上验证，任何 APK 均不存在**。
