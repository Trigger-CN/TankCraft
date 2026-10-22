# TankCraft Roadmap

> 权威范围：**里程碑、交付物、验收标准、风险、实时状态**。
> 机制细节以 `docs/design.md` 为准；工程约定与元规则以 `agent_note.md` 为准。
> **本文档必须实时维护**：任何里程碑状态变化，当次改动内就要更新 §1 状态表与本文件"变更记录"（`agent_note.md` M1）。

版本：**v3.20.1** · 2026-10-22

---

## 0. 当前状态速览

| 项 | 值 |
| --- | --- |
| 项目阶段 | **正式实现阶段（M2、M3、M4、M5、M6、M9 波次生存 已完成；M3.5 Android 导出尝试 ⛔ 阻塞于环境；移动端触屏仅完成设计）** |
| 当前里程碑 | **M9 — 波次生存单人玩法**（✅ 已完成）；**M6**（✅）；**M3.5 Android APK 导出**（⛔ 阻塞）；**M8 移动端触屏支持**（⬜ 未开始，设计已入 §11.6） |
| 下一个里程碑 | **M7 — 视觉打磨与内容补齐**（可与 M8 并行）；APK 导出仍待用户授权 |
| 生存页战斗 UI | **v3.9**：起始坦克布局收归 `SurvivalRun.STARTER_*` + `build_starter()`（唯一来源，测试与开局车同一份），武装由 20mm 改为 **76mm**（`ammo_factory_76` → `conveyor_straight` → `cannon_76`）——旧 20mm 对 armor 3 平台只有 5 伤/发，而招募级 Bot 总血量 1835，一波 45 s 内数学上不可能击毁。敌我坦克改为**逐部件按血量着色**（>60% 队伍色 / 25–60% 琥珀 / <25% 红）；新增命中闪光、命中/击毁动效与「总输出」读数；右 HUD 新增**坦克镜像面板**（`SURVIVAL_MIRROR_RECT`）：俯视镜像 + 平台/模块/行进计数 + 存活格均血条 + 逐部件状态行（按血量比升序）。`main.gd` 148460 → 160536 B |
| 架构模块化度 | **v3.12 实测**：**领域层已模块化**——preload 边为单向 DAG、无循环依赖、反向引用零命中，领域脚本（5–41 KB）每个都被独立 headless smoke 直接驱动，数据访问纪律良好（`block_*`/`global_*` 137 处，直接读 `registry.globals` 仅 8 处）。**页面层仍未模块化**——`main.gd` 现为 **143963 B**（v3.10 时 160536 B / 187 函数 / 69 const / 84 var；v3.11 后 142618 B / 170 函数；v3.12 因新增 `_capture_frozen` 及注释增至 143963 B），仍承载菜单 + 设置 + 建造编辑器 + 试驾页 + 对战页 + 生存页 5 子页 + 输入总路由 + 7 个截图钩子，页面间零语言级隔离。**`scripts/` 实测 18 个 `.gd`**（不是 v3.11 所写的 16——P3a 删的 5 个文件中只有 3 个在 `scripts/`，另 2 个在 `tests/`；再 +1 为 P2 新建的 `fx_layer.gd`），`tests/` 11 个 `.gd`。**v3.10–v3.12 已完成的模块化改进**：抽掉 FX 生命周期（`scripts/fx_layer.gd`）与坦克绘制（`_draw_hull_shared`）两类重复；删掉旧远征页（−401 行）、2 个死 preload、3 个零引用脚本（13907 B）与 2 个遗留测试；清掉 5 个孤儿 `.uid`。**仍未做**：按页面拆文件（需先定页面状态容器）、`MATCH_DIFFICULTY`/`DRIVE_ARENA_ID` 页面层硬编码 |
| 截图证据链 | **v3.12 修复了一个使历史证据失效的缺陷**：同一 `--capture` 命令连续两次产出不同字节（177682 B vs 177340 B，逐像素差 12993 个、最大通道和 546），因为预热跑完固定步后 `_capture_next_frame()` 还要 `await` 30 帧，期间 `_process()` 仍按真实 delta 推进模拟。**因此 v3.10/v3.11 反复引用的「四张截图 sha256 完全相同」只能算巧合，不能作为逐字节等价证明。** 修法：新增 `_capture_frozen`，`_process()` 早退，取图前设冻结并把 `_screen_opacity`/`_focus_rail_alpha` 置终值。修后连续两次截图逐字节相同（178280 B / `e56ce92f…`）。**旧 canonical `ui_surv4.png` 作废**，新基线为 `g5_surv.png` |
| 版本控制（v3.19） | **仓库已建立**：`git init` 完成，初始提交 **`fd3857f`**（`chore(repo): 初始化 TankCraft 仓库`，77 文件 / 22366 行），本地配置 `Trigger-CN` / `759025229@qq.com`。**本机 `core.autocrlf=true` 会在检出时改写行尾**，而本工程以文件字节做验证基线，因此已加 `.gitattributes` 的 `* text=auto eol=lf` 钉死；`git ls-files --eol` 全为 `i/lf w/lf`，四个代表文件的 blob hash 与工作区 hash 完全一致（未改任何字节）。`.godot/` 与 `.me/` 已忽略，`git status` 干净。**注意**：仓库建在 v3.18 之后，**v3.10/v3.11 旧代码仍找不回来**；但从今往后可以真正做 before/after 了 |
| 截图可复现基线（v3.13） | **7 个 `--capture` 钩子全部可复现，7/7 逐字节相同**：`drive` 213476 / `match` 135548 / `survival` 178280 / `survival_levelup` 203203 / `survival_shop` 236008 / `survival_summary` 196813 / `survival_modify` 253691。其中三个又在**不同进程**重跑一次，仍 `SAME`。**这是当前唯一有效的截图基线。** **不可逆限制**：工作区**没有 git 仓库**（实测 `NO_GIT_DIR`），v3.10/v3.11 旧代码已不存在，**无法重做真正的 before/after**。 |
| 差异归因（v3.13） | 把新基线与历史截图做**分区**比对，差异全部落在会随模拟变化的区域，**静态 UI 区零差异**：生存页右 HUD `0` / 状态栏 `0`；对战页右 HUD `0` / 状态栏 `0`。**决定性证据**：生存页两张图的 `SURVIVAL_MIRROR_RECT`（1560,436,312,400）裁切后**逐字节相同**（均 56256 B / `df09e63e…`）——镜像面板整套绘制逻辑一字未变。**结论**：全部差异可归因于**模拟多推进了若干步**，非渲染回归。 |
| 战场区验证能力（v3.14） | **新增 `--steps=N`，预热步数参数化**（`main.gd` 143963 → 146185 B）。三个对照全部成立：`--steps=420` 两次 **SAME**（178280 B / `e56ce92f…`）；`--steps=200` **DIFF**（173254 B / `0ac8f3d1…`，证明参数真生效）；**不传参数与改前基线逐字节相同**（v3.13 的 7 张基线仍有效）。**盲区已补齐**：战场区（320,168,1216,684）裁切后，`--steps=420` 两次均 **92207 B / `b16c7e15…` 逐字节相同**，`--steps=200` 为 91959 B（不同）——说明**战场区渲染本身是确定性的**，之前的「不可验证」只是缺了步数参数化。**今后渲染回归流程**：改动前后各跑同一 `--steps=N`，裁战场区比 sha256 |
| 坦克阵容（v3.15） | **按用户要求重做**：起始车 8×2 单履带 → **6×4 双履带**（两条 `track_heavy` 横跨 x=2..3，履带中心压在质心横坐标上；`ammo_factory_76 → conveyor_straight → cannon_76` 沿 y=1 逐格相邻；驾驶舱与引擎居中）。**13 张 Bot 蓝图全部重写**：招募级 30 格 → 14/20/12（十字/方块/楔形），老兵 24/32/20，精英 33/36/23，王牌 44/40/40；每档三张是三种不同轮廓（按平台格集合判重）。**敌人持续生成**：新增 `enemy_quota_for()`（同屏上限 × `enemy_quota_multiplier` 3.0）+ `_reinforce_enemies()`（`enemy_reinforce_delay_s` 5.0 间隔），`start_wave()` 只出同屏上限。**通过条件随之变更**：由「场上没敌人就立即通过」改为「计时归零」或「配额耗尽且场上无敌人」。新截图基线 `n_surv_a.png` 176395 B / `fdf2c020…`（`--steps=420` 两次逐字节相同） |
| 数字更正（v3.16） | **更正 v3.15 两个与实测不符的数字**（历史行不改，以此为准）：① 「带弹药库的版本 21.8 s 内被殉爆连锁 13 次炸死」→ **36.4 s**（唯一证据 `probe_roster2.txt` 的 `PROBE_DEATH_STEP 2185` ÷ 60 Hz；22.7 s 来自 `probe_roster5` 里驾驶舱放 (5,1) 的**另一套试验布局**）；② 「会瞄准时命中 12–22 次、击杀 1–2 台」→ **命中 8–22 次、击杀 0–2 台**（`probe_gain.txt` 六次扫描：11/0、8/0、22/1、18/1、13/1、10/2）。**只改注释与文档文字，代码 / 常量 / 测试零改动**，v3.15 的 `SURVIVAL_OK`、11 项全绿、`n_surv_a.png` = `n_surv_b.png` 176395 B / `fdf2c020…` 仍然有效 |
| 输入分发（v3.17） | **修掉一个自 v3.8 就存在的栈溢出崩溃**（用户报告 `SCRIPT ERROR: Stack overflow`）。`_handle_mouse()` 在 `SCREEN_SURVIVAL` 时调 `_handle_survival_mouse()`，而后者结尾又调回 `_handle_mouse()`——**双向互调、无终止条件**。生存页改装模式下任何一次非「完成改装」按钮的网格点击都会无限递归，最终炸在 `data_registry.get_module()`（因为每层都走 `_update_hover() → _build_option_index_at() → _option_ids()`）。**修法**：`_input()` 入口分流 + `_handle_mouse()` 删回跳分支，转发单向化（`_input()` → `_handle_survival_mouse()` → `_handle_mouse()`）。**顺带修好**：改装页的模块列表滚轮与「拖拽铺平台」的**落笔**因同一原因从未到达 `_handle_mouse()`——v3.8 文档声称的「改装页有矩形/直线铺平台、拖动铺」在鼠标路径上一直不成立。**新永久回归** `tests/mouse_input_smoke.gd`：实例化 `main.tscn` 并把真实 `InputEventMouseButton`/`Motion` 灌进 `_input()`，**反向对照已验证它真能抓到旧 bug**（加回旧代码即复现 Stack overflow）。`main.gd` 146185 → 147659 B；`tests/` 11 → **12** 个 `.gd` |
| 编辑器分层（v3.18） | **按用户要求把改装/建造编辑器的三层做成「看得见的分层」**：① 非选中层降到 `LAYER_DIM_ALPHA = 0.22`（`_draw_cell` / `_draw_aim_line` 新增 `alpha` 参数，`_draw_grid()` 按选中层分别传值；用 alpha 而非乘 RGB，因为霓虹靠 HDR glow，乘 RGB 会丢色相）；**操作隔离本来就成立**——每个编辑操作只作用于 `_build_layer`，本轮补的是可见性。② `_select_layer()` 把 `_selected_index` / `_rotation` / `_aim` 归零并回报「层：X · 光标件：Y」，修掉切层后光标拿着无关配件的问题。③ `GridBuilder.content_bounds()` + `center_content()`，在 `_activate_main_menu()` 建造分支与 `_survival_enter_modify()` 两处把整车居中（整块平移保持三层相对位置）；改装期平移安全因为结构延迟到下一次 `start_wave()` 才生效，**战斗期绝不能搬**。④ 两处重叠：`_build_layer_rect()` 230→258（步长 48→44，避开 `_draw_panel` 的分隔线 y=248）、`BUILD_TOOL_Y` 785→800（避开「工具」标签 baseline 793）。⑤ 连带修复 `_survival_capture_modify()` 写死的落点 `(6,0)`，改为按 `content_bounds()` 算。**验证**：`--check-only` 78 B / `6ca5b6ba`；12 项 smoke 全绿且 `l6_all.txt` 638 B / `7ae7106a` 与上轮基线逐字节相同；`build_smoke` 新增 5 条居中断言全过；分层透明像素探针 `module 452（选中）vs 191（未选中）`、比值 2.37 → `DIMMING_OK`；`--steps=420` 两次生存页截图 176395 B / `fdf2c020…` 与改前逐字节相同。`main.gd` 147659 → 151611 B，`grid_builder.gd` 30014 B。**探针错了三版**（比较不同格亮度不成立、平台格填充太淡看不出来），均记录为探针缺陷而非产品缺陷 |
| 碰撞箱与伤害数字（v3.20） | **按用户要求把碰撞箱从整车外接 AABB 改为逐配件格子**（用户原话：「优化坦克和其他物品的碰撞箱逻辑，坦克的整体碰撞箱和中弹判定都是由配件构成，受到伤害和造成伤害都要有悬浮数字提示」）。**先纠正前提**：中弹判定（弹道→坦克）**本来就是逐格 slab 求交**（`_clip_to_tank` 对 `target["cells"]` 每格求交取最小 `t`，自带 `cell`/`part_index`），本轮零改动；真正有缺陷的是**碰撞箱**。`TankBody` 新增 `cell_world_rects()` / `cell_overlap_rect()` / `cell_overlap_circle()` / `cells_overlap_tank()`，矩形与圆障碍改为逐格 + 迭代推出（`MAX_PUSH_ITERATIONS = 8`，伤害只结算一次），坦克互撞改为逐格 OBB SAT，撞房屋改为 `cell_overlap_rect()`；**`apply_boundary()` 仍用 `world_bounds()` 且这是正确的**（边界轴对齐，外接框 min/max 就是格角极值，与逐格数学等价）；圆心埋在车体内的退化情形保留外接框兜底 `_resolve_circle_inside_hull()`。**圆取「最深」而非「最浅」是实测结论**：按最浅格迭代会卡在 `depth=0` 死循环（`diag2.txt`），改最深后一次收敛（`diag3.txt`）。**悬浮数字**：`duel._resolve_impact()` 在 `apply_hit()` **返回之后**写回 `damage`/`shield`/`victim`（延迟爆炸分支的值已是过护甲值）；`FxLayer.push()` 增加可选 `text`；生存页与对局页各一套推入/绘制（坐标系统不同）；`dealt` → `+N`、`received`/`shield` → `-N`；同侧限流 6 条；零随机偏移。**验证**：`--check-only` 六个脚本均 78 B / `6ca5b6ba`；**12 项 smoke `s3.txt` 638 B / `7ae7106a` 与历史基线逐字节相同**；`PHYSICS_OK` 四个数值一字未变；`physics_smoke` 新增五条**区分性**断言（U 形凹口）。**截图**：`v20_surv_c.png` = `v20_surv_d.png` = 178927 B / `fa188823`（青色 `+52` + 红色 `-17`），对局页 `v20_match_s340.png` 132259 B / `62fee88c`（红色 `-52`）。**区域归因**：修复前后 left_hud / right_hud / mirror_panel / status_bar **全 0**，唯一差异战场区 704 px / 69×73 包围盒。**如实纠正**：镜像面板**不是静态区域**（实时 HP 条会随受伤变化），不能当「必须 0」的判据。`main.gd` → 159079 B，`tank_body.gd` → 33485 B |
| 改装页下标越界（v3.20.1） | **修用户报告的 `SCRIPT ERROR: Out of bounds get index '8' (on base: 'PackedStringArray') at: _preview_cells`**（栈形 `_preview_cells ← _draw_grid ← _draw_build ← _draw_survival ← _draw`）。**根因：同一个字段被当成两套下标**——`_selected_index` 是 `_option_ids()` 的下标，但改装期 `_option_ids()` 是「按层过滤 + 按 id 去重」后的结果，**与 `survival.inventory` 长度不等、顺序也不对应**。旧代码：`_ensure_option_visible()` 只钳制 `_option_scroll`、**根本不钳制 `_selected_index`**；`_preview_cells()` 直接 `options[_selected_index]`（**越界就在这一行**，绘制每帧一次所以报错刷屏）；`_mount_selected_inventory()` 拿 `_selected_index` 当库存下标（即使不越界也会**贴装另一件**）。**实测触发条件**：库存 6 件、当前层去重后 3 个 id → `_selected_index = 5` 对库存合法、对可选件非法。**修法**：收口点 `_ensure_option_visible()` 按可选件数量钳制；`_preview_cells()` 加防御式 `clampi`；`_mount_selected_inventory()` 改为 `options[idx]` → `module_id` → `inventory.find(module_id)`；两处 `visible_count` 包 `maxi(..., 0)`。**新永久回归 `tests/editor_bounds_smoke.gd`**：实例化 `main.tscn`、真实购买 6 格后构造越界状态，`inventory=6 > options=3` 前提成立，`PREVIEW_OK`。**反向对照**：把三处修复临时退回旧写法后**立刻复现用户报告的完全相同错误**（`pb_neg.txt`）。**验证**：`--check-only` 78 B / `6ca5b6ba`；**13 项 smoke 全绿**（`s4.txt` 720 B / `f1606d4c`，原 12 项数值逐字不变）；改装页截图 `v21_modify.png` 254891 B / `6db6db59` **与 v3.18 的 `l_mod2.png` 逐字节相同**；真实窗口无 `SCRIPT ERROR`。`main.gd` 159079 → 161231 B，`tests/` 12 → 13 个 `.gd` |
| 代码状态 | M1 数据层、M2 编辑器与运行期 `BUILD_MODE`、M3 物理/操控/弹道（转向手感缺陷已于 v3.1 修正）、M4 弹药网络、M5 战斗结算、M6 三层 AI 与完整对局、**M9 波次生存（`scripts/survival_run.gd` + 主场景 `SCREEN_SURVIVAL` 五张页面）**均已实现并通过 smoke；**v3.5 修复 R17 的 9 个碰撞/损坏缺陷（含 3 个额外发现）**、**v3.6 完成 R18（`duel` 多敌人同屏）**、**v3.7 补上改装 UI 入口**、**v3.8 修好用户报告的界面四项**、**v3.9 修好「炮弹打不动人」并重做生存页战斗 UI**、**v3.10 完成架构审查并修好对战页动效不衰减与三套重复实现**、**v3.11 完成 P3 清理（删旧远征页 + 3 个死脚本 + 2 个遗留测试 + 2 个死 preload）与 P2 第一段（抽 `FxLayer`）**、**v3.12 完成 P2/P3 收尾审计（修正文件计数为 `scripts/` 18 个 `.gd`、清掉 5 个孤儿 `.uid`、修复截图取图时刻不固定）**并均已并入永久回归；**代码中仍无任何触摸处理**。⚠️ `expedition_run.gd` 与 `runtime_builder.gd` **已无任何玩法调用方**（仅被各自 smoke 直接驱动），是否连脚本一起删属另一个决定 |
| 阻塞项 | **M3.5 阻塞**：本机缺 Godot 导出模板、缺 Android SDK、`java_sdk_path` 为空；三项均需工作区外安装，待用户授权（用户已指示“先不导出 apk”）。**R17 与 R18 均已关闭**。M9 已无代码阻塞，但**`boss_armor`、`safe_radius`、商店稀有度权重方向**三项待做（见 §2 M9）；**改装 UI 入口已于 v3.7 关闭** |

---

## 1. 里程碑状态表

图例：`⬜ 未开始` · `🟨 进行中` · `✅ 已完成` · `⛔ 阻塞` · `➖ 已取消`

| 里程碑 | 名称 | 状态 | 目标周期 | 核心交付 |
| --- | --- | --- | --- | --- |
| **M0** | 文档与规范 | ✅ 已完成 | 第 1 阶段 | `agent_note.md`、`docs/design.md`、`docs/roadmap.md` |
| **M0.5** | 视觉验证原型 | ✅ 已完成（旧版已废弃） | 第 1.5 阶段 | 旧版霓虹调色板、静态线框坦克与网格视觉验证 |
| **M0.6** | 菜单与建造交互原型 | ✅ 已完成 | 第 1.6 阶段 | `MAIN_MENU` / `SETTINGS` / `BUILD_PHASE`，三层网格放置、旋转、拆除、预算/质量/连通性反馈 |
| **M1** | 项目骨架与核心数据层 | ✅ 已完成 | 第 2 阶段 | `data/` JSON、加载器与校验器、启动错误报告、`tests/` smoke tests |
| **M2** | 建造编辑器与运行期建造 | ✅ 已完成 | 第 3 阶段 | 正式数据驱动三层网格编辑器、矩形/直线工具、校验、蓝图存读；运行期 `BUILD_MODE`（scrap 支付、施工计时、受击中断、拆解返还） |
| **M3** | 坦克物理与操控 | ✅ 已完成 | 第 4 阶段 | 自建刚体（逐格 `M/C/I`）、差速驱动与 `turn_assist` 递减收益、硬碰撞与撞击伤害、炮管装填与弹道、试驾沙盒页 |
| **M3.5** | Android APK 导出尝试 | ⛔ 阻塞（环境缺失） | 第 4.5 阶段 | `export_presets.cfg`、导出命令与失败诊断；**APK 未产出**（缺导出模板 + Android SDK + Java SDK 路径） |
| **M4** | 弹药输送网络 | ✅ 已完成 | 第 5 阶段 | 管路图与端口自动连接、BFS 层级与可达性、20 Hz 四步定序调度、装填与拒绝、弹药库槽位、改进装置处理、拥塞与断链可视化；**显式路由面板未实装**（推迟到 M6） |
| **M5** | 战斗结算与可拆解摧毁 | ✅ 已完成 | 第 6 阶段 | 实体弹道与扫掠命中、命中层序与伤害公式、护盾状态机与穿透分账、9 种弹药升级、逐格摧毁与连通块脱落、驾驶舱判负、维修与状态效果、殉爆与引擎爆炸；详见 §2 M5 的 8 条验收结果、6 条有意简化与自击缺陷 |
| **M6** | 机器人 AI 与完整对局 | ✅ 已完成 | 第 7 阶段 | 对局状态机（`BUILD/DEPLOY/BATTLE/RESULT`）、双坦克 `duel`、三层 AI 与四档难度、12 张 Bot 蓝图、`EXPEDITION` 5 层×3 波循环、`scrap` 经济、升级三选一入库存、对战页与菜单项；详见 §2 M6 的验收结果与 6 条遗留项 |
| **M7** | 视觉打磨与内容补齐 | ⬜ 未开始 | 第 8 阶段 | 霓虹主题定稿、动效、HUD、菜单动效与无障碍、竞技场、蓝图池 |
| **M8** | 移动端触屏支持 | ⬜ 未开始（设计已完成） | 待定 | 输入抽象层与 `InputFrame`、虚拟摇杆与虚拟按键、建造页手势、HUD 双布局与安全区、`touch` 常量入 JSON、真机验证 |
| **M9** | 波次生存单人玩法 | ✅ 已完成（v3.6） | 第 7.5 阶段 | 波次限时生存、房屋与残骸、经验升级菜单（三选一）、波间商店（6 格/刷新/出售）、每 5 波 Boss、`survival` 常量块、禁用战斗期改装；**R18 多敌人同屏同期完成**；详见 §2 M9 |

**里程碑依赖**：M0 → M0.5 → M0.6 → M1 → M2 → M3 → M4 → M5 → M6 → **M9** → M7。M0.5 只确立视觉语言；M0.6 用轻量交互验证菜单与建造操作闭环，不等同于正式 M2 建造编辑器；M2 与 M3 之间可并行。**M9 紧跟 M6**：它改写 M6 交付的单人玩法，且依赖 M6 的 `duel` / `bot_ai` / 12 张 Bot 蓝图作为地基，因此不能排在 M6 之前；M9 与 M7 可交错（视觉打磨不阻塞玩法）。**M8 是横切里程碑**：其设计（`design.md` §11.6）已定稿，实现建议排在 M9 之后、与 M7 并行；但它依赖 M3 的驾驶页与 M2 的建造页作为接入点，因此不能排在 M3 之前。

---

## 2. 里程碑详情

### M0 — 文档与规范 ✅

**目标**：让任何 AI 或开发者读完文档就能无歧义开工。

交付物：
- [x] `agent_note.md`：元规则 M1–M8、文档地图、技术栈、工程约定、三层坐标模型、术语表、上手流程、共识 A1–A25、已知陷阱
- [x] `docs/design.md`：视觉规范、对局流程、三层建造、物理模型、9 类功能模块 + 驾驶舱、弹药网络、战斗结算、竞技场、AI、UI、架构、数值基线、建造经济与价格表、ADR、开放问题
- [x] `docs/roadmap.md`：本文件
- [x] 文档交叉一致性检查完成，已修正 4 项实质缺陷（均用脚本数值回归验证）：① 质量基准矛盾（0.6 u → **1.0 u/格**）；② 转向物理不可用（原公式对称双履带扭矩抵消、坦克无法转向）→ 重建为**差速驱动**（ADR-009）；③ 推力量纲失真 → 统一为 `u·px/s²` 并重标定四种行进机构；④ 惯量算法未定 → 定为**逐格精确公式**（禁用矩形近似，实测偏大 40%）。详见 design §17（v1.1→v1.3）与 agent_note §9（v1.1）。
- [x] 用户确认 `design.md` §16 的开放问题 **Q1–Q5** 与 **Q12–Q14**（2026-10-17）：Q1 引擎供能包含给其他模块供能、Q2 引入信用点经济与可购买质量上限、Q3 分离模块立即摧毁、Q4 炮管安装时可调向安装后固定、Q5 驾驶舱为核心部件；Q12 驾驶舱双方默认可视、Q13 维修装置能修驾驶舱、Q14 质量上限不跨局保留。**Q6–Q11、Q15–Q17 未确认**，实现期按文档内标注的假设处理（其中 Q17 为模型自拟、用户未提出）。

验收标准：
1. 三份文档均存在，章节完整，无 "TODO/待补" 除开放问题外。
2. 术语表覆盖设计文档中出现的所有专有名词（抽查 20 个，命中率 100%）。
3. 数值只出现在 `design.md` §14（抽查 10 个数值，文档内无第二处定义）。
4. 元规则 M1 的同步对照表覆盖"改机制/改数值/做决策/推进度"四类事件。

**完成定义（DoD）**：用户确认开放问题中至少 Q1/Q2/Q3/Q4，且其余问题被明确标记为"实现期按当前假设处理"。

---

### M0.5 — 视觉验证原型 ✅（旧版已废弃）

**目标**：记录已完成的旧版静态视觉验证。该 demo 已按用户新指示从主场景移除，不再作为当前运行入口。

旧版交付物与像素证据保留在历史变更记录和 `.me/tmp/main/` 临时工件中；当前主场景不再引用旧版 `GridField`、`TankA`、`TankB`、`HUD` 节点。

---

### M0.6 — 菜单与建造交互原型 ✅

**目标**：在正式 M1/M2 之前，用可运行 demo 验证菜单导航与三层网格建造的操作闭环。

**范围**：提供 `MAIN_MENU`、`SETTINGS`、`BUILD_PHASE`；支持模块目录、层切换、格子吸附、放置、旋转、拆除、信用点/质量校验、平台覆盖与驾驶舱 4-连通性反馈。仍不实现物理、弹药网络、投射物、AI、战斗结算或蓝图持久化。

交付物：
- [x] 单一主场景与菜单树，旧版静态 demo 引用移除
- [x] 主菜单进入建造与设置；设置开关反馈可见
- [x] 三层网格建造：平台 / 行进机构 / 功能模块
- [x] 模块选择、1/2 格占位、旋转、拆除、鼠标与键盘操作
- [x] 驾驶舱、平台覆盖、质量与信用点状态面板
- [x] `--capture=<png>` 截图契约与可重复检查

验收结果：
1. 主菜单、设置、建造三个界面已用键盘走通并可返回。
2. 平台与两格行进机构已完成定位、放置、旋转、拆除验证。
3. 合法/非法放置状态与实时校验面板已验证。
4. 驾驶舱数量、平台覆盖、平台 4-连通、信用点与质量状态均可见。
5. 旧版静态坦克/HUD 节点已从主场景引用树移除。
6. Godot 截图命令输出 `CAPTURE_OK`，生成 1920×1080 RGB PNG。

风险：交互原型若过早扩大成正式建造编辑器，会把 M1 数据层与 M2 校验范围混在一起；正式 M2 仍按原路线推进。


---

### M1 — 项目骨架与核心数据层 ✅

**目标**：工程能跑起来，数据能加载，非法数据会明确报错。

交付物：
- [x] Godot 4.7 工程与主场景启动接入数据注册表
- [x] `data/` 目录与全部 schema：`modules/*.json`、`ammo/*.json`、`upgrades/*.json`、`arenas/*.json`、`blueprints/*.json`、`globals.json`
- [x] `design.md` §14 数值基线落成 JSON（正式系统通过注册表读取）
- [x] `scripts/data_registry.gd` 与 `scripts/data_validator.gd`
- [x] `tests/data_smoke.gd` 与 `tests/data_error_smoke.gd`

验收结果：
1. `DATA_OK files=10 modules=45 ammo=5 upgrades=9 arenas=3 blueprints=1`。
2. 主场景数据校验失败时输出 `M1_DATA_ERROR`，成功时继续启动；截图契约输出 `CAPTURE_OK`。
3. 异常数据回归输出 `DATA_ERROR_OK errors=17`，覆盖错误类型与 JSON 路径报告。
4. 跨文件模块/口径/蓝图引用及蓝图造价重算已校验；发现并修正示例蓝图记录值 782 → 629 cr。

风险：schema 过早复杂化。对策：M2 已扩展编辑器所需的质量升级与历史深度字段，后续继续保持新增数据先更新 schema。

---

### M2 — 建造编辑器与运行期建造 ✅

**目标**：玩家能在三层网格上自由搭出一台坦克，并被正确校验。

已完成的核心交付：
- [x] `module_defs.gd` 封装正式 `DataRegistry` 数据；`grid_builder.gd` 承载纯建造逻辑
- [x] 三层网格与 I1–I10 核心校验：同层重叠、平台覆盖、驾驶舱唯一、行进机构、连通性、边界、预算与质量
- [x] 矩形工具、Bresenham 直线工具、Shift 擦除
- [x] 6 种形状平台块（`plat_1x1/1x2/2x2/l3/t4/wedge`）
- [x] 模块放置、旋转、移动、删除、撤销/重做（深度由 `globals.json` 的 `undo_history_depth` 提供）
- [x] 校验面板：信用点余额、质量上限等级、体积、驾驶舱和错误列表
- [x] 蓝图存读与稳定性检查，读取时拒绝层归属、边界和同层重叠错误
- [x] 质量上限逐级购买/退款、驾驶舱保护、炮管 `aim` 45° 步进
- [x] 主场景改用正式 JSON 模块目录，M2 数据与 schema 已接入
- [x] 菜单淡入、焦点轨道、菜单/设置/建造条目 hover 与统一绘制/命中几何
- [x] 配件目录面板内布局、鼠标滚轮浏览、鼠标网格定位、左键放置/拖动、右键拆除与矩形/直线拖拽
- [x] `scripts/runtime_builder.gd`：`BUILD_MODE` 子状态、`movement_locked()`、`scrap` 支付与原子拒绝、按格施工计时、受击中断不返还、拆解返还 `scrap_refund`、运行期质量升级
- [x] `grid_builder.gd` 的 `budget_enabled` 开关，让编辑器 credit 与运行期 scrap 共享规则但分离货币语义
- [x] 主菜单第四项「远征」与 `EXPEDITION_BATTLE` 施工页（层/配件/状态面板、lime 虚线轮廓 + 进度弧、鼠标 hover 与滚轮）
- [x] `tests/runtime_build_smoke.gd`：13 个运行期建造场景

验收结果：
1. `tests/build_smoke.gd` 已覆盖合法构建、移动、旋转、撤销/重做、直线工具、蓝图存读稳定性和非法重叠蓝图拒绝，输出 `BUILD_OK cells=43 modules=6 mobility=1 spent=698 mass=62.9`。
2. `tests/runtime_build_smoke.gd` 覆盖 VERSUS 拒绝、建造模式限制、scrap 原子拒绝、1 格/2 格计时、受击中断不返还、无关受击不中断、退出中断、驾驶舱/最后行进机构拒拆、返还比例、质量升级价、并发与施工中拆解拒绝，输出 `RUNTIME_OK scrap=751.0 level=1 cells=41 modules=7 mobility=1`。
3. `data_smoke.gd` 输出 `DATA_OK files=10 modules=45 ammo=5 upgrades=9 arenas=3 blueprints=1`；`data_error_smoke.gd` 输出 `DATA_ERROR_OK errors=17`。
4. 主场景截图契约输出 `CAPTURE_OK`：`menu_capture.png`（主菜单）与 `expedition_capture.png`（远征页施工中）；像素对比确认两者为独立渲染结果（panel 2862→3128、grid 1678→2582、diff 102199）。

风险：`EXPEDITION_BATTLE` 目前只是运行期施工的接入证据，敌人 AI、投射物、弹药网络与波次推进均未实现；M3–M5 落地时需把 `notify_hit()` 接到真实伤害事件，并由 `expedition_run.gd` 驱动 `scrap` 结算与等级清零。

---

### M3 — 坦克物理与操控 ✅

**目标**：坦克开着像坦克——有质量、会甩尾、被打掉一半会变重/变偏。

已完成的交付物：
- [x] 自建刚体解算（`scripts/tank_body.gd`，`design.md` §5）：`M / C / I` 实时重算、推力/扭矩/阻尼积分、固定 60 Hz 步长
- [x] 4 种行进机构（`track_light/heavy`、`armored_wheel`、`speed_wheel`），带 `thrust` / `grip` / 安装朝向
- [x] **差速驱动转向**（`design.md` §5.2、ADR-009）：`throttle`/`steer` 两轴输入 → 每侧目标推力 → `T` 与 `τ`
- [x] 引擎 `turn_assist` 与多引擎收益递减（`design.md` §6.1）：按 `turn_assist` 降序 × 权重 `[1.0, 0.7, 0.5, 0.35]`
- [x] 碰撞与撞击伤害：**用旋转后世界 AABB**（非贪心合并轮廓，已作为沙盒阶段简化假设记录在 `design.md` §5.6）；0.001 px 接触容差 + `4 + 0.05·|v|` 伤害 + `wall_impact_min_speed` 门槛
- [x] 角速度硬上限 `OMEGA_MAX` 与惯量下限 `I_MIN` 的稳定性保护
- [x] 视觉：履带滚动相位、加速滞后 0.5 px、转向倾斜 ≤ 2°（纯视觉）
- [x] **炮管与弹道**（`scripts/cannon_bank.gd` / `scripts/projectile_field.gd`）：单发容量、`reload_s` 冷却、口径强匹配、`aim` 战斗锁定、后坐冲量、线段扫掠与四种终止条件
- [x] **试驾沙盒**（`DRIVE_LAB`）：无对手场景，可测速度、加速度、原地转向角速度，并可直接开火验证弹道
- [x] `tests/physics_smoke.gd`（8 项验收）与 `tests/cannon_smoke.gd`（装填/口径/后坐/弹道）

验收结果：
1. ✅ 对称 6×7 构建（42 格板 + 2 轻履 + 中引擎 + 76 炮 + 轻驾驶舱）实测 `M=61.0 u`、`I=104 064 u·px²`、`T=9000`、闭式 `v_max=192.1 px/s`，1500 步实测终端速度偏差 ≤ 8%；原地 180° 实测 **1.35 s**（v3.1 手感修正后重测，此前为 1.32 s；设计意图量级 1.42 s）。基准已写入 `design.md` §5.3；v1.3 的旧参考表（突击型 ≈179 px/s）已降级为设计意图参考，不再作验收值。
2. ✅ `throttle=0, steer=1` 时 `|T|` 微小而 `|τ|` 最大，坦克原地打转；`angular_velocity > 0` 与 `heading > 0` 同向，即与 Godot `rotation` 正方向（顺时针）一致。
3. ✅ `throttle=1, steer=0.5` 且两侧履带对称时 `ω ≥ 0.05` 且速度 ≥ 5 px/s，证明扭矩相加而非抵消。
4. ✅ 移除一侧 `track_light` 后，`steer=0` 下 `|ω|` 仍 ≥ `0.05 rad/s`，持续偏转可感知。
5. ✅ 摧毁一格平台后 `M` 立即下降 1.0 u，`I` 与质心同帧变化。
6. ✅ 以 400 px/s 撞墙：法向速度归零、位置夹回场内，伤害精确等于 `4 + 0.05×400 = 24.0`。
7. ✅ 120 模块坦克的 `step + apply_boundary` 在 `Time.get_ticks_usec()` 采样下断言通过（≤ 6 ms/帧预算）；汇总行未打印具体毫秒数，仅断言通过。
8. ✅ **松手后自旋衰减**（v3.1 新增验收项）：按住 `steer=1` 到稳态 `ω=3.0 rad/s` 后松手，`|ω|` 降到 `0.1 rad/s` 用时 **0.62 s**（断言上限 1.5 s）。该项对应 v3.0 及更早的验收缺口 —— 旧验收集只有「原地 180° 用时」，完全不覆盖松手后的衰减，实测松手后跑满 6000 步（100 s）`ω` 仍为 2.9970，即用户报告的「转一下会原地旋转很久」。

接入证据：主场景新增 `DRIVE_LAB` 页（主菜单第二行「试驾」），`W/S` 油门、`A/D` 转向、`Space` 开火、`R` 重开、`Esc` 返回；`--screen=drive` 截图契约输出 `CAPTURE_OK`，页面级脚本在真实 `main.tscn` 中得 `parts=46 mass=55.9 cannons=1 speed=92.2 shots=1 wall=23.5`。**桌面交互式试驾未进行**，验证依据为六份 headless smoke、像素统计与页面级脚本。

风险：偏心质心 + 高惯量导致抖动/爆炸式自转。对策已落地：`I_MIN` 下限、`OMEGA_MAX` 钳制、固定步长；`physics_smoke.gd` 额外断言 `centroid_cell.y ≈ 7.5` 与 `drive_metrics(0,0)["torque"] ≈ 0`，把“终端速度验收需质量对称”这个隐含前提钉死在测试里（`design.md` §5.6）。

---

### M3.5 — Android APK 导出尝试 ⛔

**目标**：把当前 M3 试驾 demo 通过 Godot 的 Android 导出流水线编成可安装的 APK。用户原话：“测试demo尝试编译一个Android平台apk”——“尝试”即允许失败，但必须报告卡在哪里。

本轮范围：**只做导出链路**。不包含触屏操控、移动端 UI 重排、Google Play 签名/AAB、真机测试与性能分析。

已完成的交付物：
- [x] `export_presets.cfg`（工程根目录，1548 字节）：单一预设 `name="Android"`、`platform="Android"`、`architectures/arm64-v8a=true`（其余关闭）、`gradle_build/use_gradle_build=false`（走预构建模板路径，不需 Gradle/NDK）、`package/unique_name="com.tankcraft.prototype"`、`version/name="0.3.0-m3"`、`screen/immersive_mode=true`、`export_filter="all_resources"`（`data/` 随 PCK 打包）、输出 `.me/tmp/main/tankcraft-debug.apk`
- [x] 真实导出尝试与完整失败诊断（见下）

执行命令：

```powershell
godot --headless --path . --export-debug "Android" .me/tmp/main/tankcraft-debug.apk
```

结果：**失败**。`EXITCODE=1`，`Test-Path .me/tmp/main/tankcraft-debug.apk` → `False`，**未产出任何 APK**。Godot 原始报错：

```text
Unable to open Android 'build-tools' directory.
ERROR: Cannot export project with preset "Android" due to configuration errors:
未在预期路径处找到导出模板：C:/Users/TRIGGER/AppData/Roaming/Godot/export_templates/4.7.2.stable/android_debug.apk
未在预期路径处找到导出模板：C:/Users/TRIGGER/AppData/Roaming/Godot/export_templates/4.7.2.stable/android_release.apk
编辑器设置中需要有效的 Java SDK 路径。
编辑器设置中的 Android SDK 路径无效：缺少 "platform-tools" 目录！（找不到 adb）
编辑器设置中的 Android SDK 路径无效：缺少 "build-tools" 目录！（找不到 apksigner）
ERROR: Project export for preset "Android" failed.
```

阻塞原因（三项，均需工作区**外**安装）：
1. **导出模板缺失** —— `%APPDATA%\Godot\export_templates\` 为空目录，连 `4.7.2.stable\` 子目录都没有。需在编辑器里 *Editor → Manage Export Templates → Download and Install*（或在能联网的机器上下载官方模板包后解压到该路径）。
2. **Android SDK 缺失** —— 本机无 `ANDROID_HOME` / `ANDROID_SDK_ROOT`，`%LOCALAPPDATA%\Android\Sdk` 不存在，`adb` / `sdkmanager` 均不在 PATH，也没有 Android Studio。仅需 `cmdline-tools` + `platform-tools` + `build-tools` + 一个 platform，**不需要 NDK**（因为不走 Gradle 构建）。
3. **`java_sdk_path` 未配置** —— JDK 17 已装（`openjdk 17.0.11`），但编辑器设置 `export/android/java_sdk_path` 为空，需指向 JDK 根目录。

附带发现：`javac -version` 报 `无法将主类 com.sun.tools.javac.Main 加载到模块 jdk.compiler 中`，但导出错误清单**没有任何 javac 项** —— 预构建模板路径不调 javac，只靠 `apksigner` + `keytool`，所以 javac 损坏暂不构成阻塞。另外编辑器里的 `debug_keystore` 指向 `…/Godot/keystores/debug.keystore`（复数目录）而该目录不存在，补齐 SDK 后首次导出需让 Godot 自动生成或用 `keytool` 手动生成。

**验收标准**：`godot --headless --path . --export-debug "Android" <路径>` 返回 `EXITCODE=0`，APK 文件真实存在、大小合理、包内含 `AndroidManifest.xml`、`lib/arm64-v8a/libgodot_android.so` 与 `assets/` 中的 PCK。**当前未达成。**

**能力边界（无论 APK 是否产出都成立）**：全部输入路径都是键盘/鼠标（`W/S` 油门、`A/D` 转向、`Space` 开火、`R` 重开、`Esc` 返回），代码中**没有任何触摸处理**。所以即使 APK 能装能启动，**仅靠触屏也无法游玩**。触屏操控方案已于 v2.8 写入 `design.md` §11.6，但**实现属 M8**，不在 M3.5 范围。用户已指示“先不导出 apk”，因此本里程碑暂停推进，不再重试导出或安装环境。

风险：Godot 4 的 Android 导出对模板版本与编辑器版本强绑定，装错版本会被直接拒绝；SDK 版本也需与模板要求的 build-tools 匹配。建议按编辑器里的版本号原样安装，不要自行升级模板。

---

### M4 — 弹药输送网络 ✅

**目标**：炮弹真的"在管路里跑"，并且堵住时看得见。

交付物：
- 6 种管路件（直管、1/4 弧、1/2 弧、一分二、二合一、四通），带单向端口
- 端口自动连接（`design.md` §7.2）——**已实装**；手动路由面板（`from → to`）——**本轮未实装**：`grid_builder.routes` 仍是 M2 留下的死代码，由“端口自动连接 + 可达性 BFS”顶替，推迟到 M6 菜单体系（见 `design.md` §7.8）
- 拓扑变化时批量算路（BFS，按节点 id 字典序确定性）
- 20 Hz 独立调度（§7.7 四步定序），在途容量 1 发/段，速度 4 格/s
- 装填与拒绝：口径不匹配 → 逆向退回；目标满 → 上游等待
- 弹药库 slot 容量（`20/40=1, 76=2, 120=3, 155=4`）
- 改进装置处理（槽数 × 口径系数）
- 拥塞可视化：管路变红闪烁 + HUD 断链图标定位到具体炮管

验收标准与结果（全部通过，`tests/ammo_net_smoke.gd` 打印 `AMMO_OK`）：
1. 制造装置 → 直管 → 炮管：连续产出 10 发，全部到达，无丢失无重复。✅
2. 一分二轮流交替；一侧被堵时，另一侧连续接收而不卡死。✅
3. 二合一按 `in0` 优先，无对撞、无丢失。✅
4. 把 76mm 送进 155mm 炮管：被拒收并沿原路返回弹药库。✅
5. 移除管路中段后：该路由标 `UNREACHABLE`，在途炮弹 1 s 后消失并播放警告。✅
6. 帧率被拖到 20 fps 时，吞吐不变（证明与物理帧解耦）。✅
7. 同蓝图的两次运行产生完全一致的事件序列（确定性）。✅

**主场景接入结果**：驾驶页已删除两处 `bank.load_all()`，改由 `network.step()` + `network.fill_cannons()` 供弹；`grid_builder.reset_demo()` 把 `cannon_20` 从 (11,8) 移到 (9,7)，使演示构建的供弹链连通（`BUILD_OK` 与 `parts=46 mass=55.9` 均不变）。页面级脚本（临时文件，已删除）在真实 `main.tscn` 上打印 `M4_PAGE_STATE parts=46 mass=55.9 cannons=1 loaded_s=0.75 emitted=2 delivered=1 reachable=1 flights=1` 与 `M4_PAGE_RELOAD s=0.40 shots=1`：先断言进入驾驶页时炮管空膛（旧 `load_all()` 行为会立即装满而失败），再验证 0.75 s 首发送达、开火后 0.40 s 二次装填。截图 `.me/tmp/main/drive_m4_capture.png` 确认管路底槽、在途炮弹与拥塞红色闪烁均真实绘制，HUD 显示 `M4 管路 · 在途 1 · 拥塞 1 · 断链 0`。七条既有 smoke 同会话重跑与基线逐字一致（`PHYSICS_OK` / `CANNON_OK` / `BUILD_OK` / `RUNTIME_OK` / `DATA_OK` / `DATA_ERROR_OK errors=17`）。

**能力边界（必须如实声明）**：① **显式路由面板未实装**（见交付物第 2 条）；② 页面证据是**脚本驱动 + 截图像素检查**，不是人工桌面交互验证；③ 远征页（`SCREEN_EXPEDITION`）本轮**未**接入弹药网络；④ 从未在 Android 设备上验证，APK 仍不存在；⑤ `blocked[ammo_id]` 粒度过粗——同源同口径的后续正常炮弹也会被挡住，直到拓扑重建（`design.md` §7.8）。

风险：算路与在途物品的时序耦合 bug（一 tick 走两次）。对策：严格遵守 §7.7 的四步顺序，单测覆盖"同 tick 双推"场景。

---

### M5 — 战斗结算与可拆解摧毁 ✅

**状态**：✅ 已完成（v3.2）。下一站 M6。

**目标**：打掉对手通往驾驶舱的甲板，让他的半个坦克飞出去；或直接击毁驾驶舱。

交付物（全部落地）：
- 实体投射物 + 线段扫掠命中（不穿模），`max_range 1400 px`、寿命 3.5 s —— `scripts/projectile_field.gd`（255 行 / 11153 字节 / `b4d231ba`）
- 命中层序 `module → platform → mobility`（§8.2）—— `damage_system._resolve_target()`
- 伤害公式：护甲减免 + 15% 保底 + `pierce` —— `_final_damage()` = `floorf(maxf(dmg·0.15, dmg − armor·(1−pierce))·10)/10`
- 3 种护盾（`cell/plate/dome`）状态机 `ACTIVE → BROKEN → 充能 → ACTIVE`；覆盖几何在代码内推导，不改 `systems.json`
- 护盾穿透按比例分账（§8.4）：`to_shield = dmg·(1−p)`、`to_body = dmg·p`；`p = 0` 时直接 return，即「整发被吃」
- 9 种弹药升级全部生效 + 合并规则（§8.6）—— **整台聚合**（有意简化 1）
- 逐格/逐块摧毁：模块死亡效果、残骸 3 s、质量重算
- **连通块脱落**：以驾驶舱所在格为锚点 4-连通重算，主块外一切**立即摧毁** —— 新增 `grid_builder.force_remove()`（`remove_at()` 的两项建造期约束正好是 `detach` 必须违反的）
- **驾驶舱判负**：同帧置 `defeated` 并短路后续殉爆/脱落/质量重算（只产 1 条 `core_destroyed` 事件）
- 维修装置 `repair_small` / `repair_field`（含对驾驶舱修复量减半，待 Q15 裁定）
- 状态效果：灼烧、减速（HUD 图标 + 剩余秒数）
- 弹药库殉爆 `6 × slot`、引擎死亡爆炸 25 @1.5 格
- 装填完成**边沿**脉冲（`loaded` false→true，非电平）：`_drive_cannon_pulse` + `_drive_cannon_loaded`

验收结果（8 条，全部由 `tests/combat_smoke.gd` 的 11 个阶段断言，输出 `COMBAT_OK`）：
1. ✅ 打断 1 格宽脖颈后远端整块脱落 —— `_check_detach()`：`detach` 事件恰好 1 条、`cells==4`、`parts==1`；脖颈与远端 4 格从 `platform_occupancy()` 及 `tank.parts` 消失，`parts` 11 → 5；驾驶舱块完好、`not defeated`。**「动效可见」只有截图/像素层面支撑；`detach` 的「整块撕裂」动效本身从未被观察**（`reset_demo()` 无可断脖颈，预热流程不触发 `detach`）
2. ✅ 整发被吃 —— 240 打 `shield_cell` 得 `damage==0.0`、`shield==240`、本体 hp 不变、`state==BROKEN`、`charge==recharge_s`(6.0)；`step(6.0)` 后 `state==ACTIVE`、`hp==shield_hp`、1 条 `shield_restored`
3. ✅ `shield_pierce = 0.5`（2 层 `up_shield_pierce`）—— 护盾吃 `27.5`、本体吃 `26.5`（= `_expected_final(55, 0.5, armor 1, pierce 0)`），护盾仍 `ACTIVE`
4. ✅ 冷却拒绝装填 + 边沿脉冲 —— `fire` 后 `loaded==false`、`reload_remaining==reload_s`，`load_round` 失败；`step(reload_s*0.5)` 仍失败；再半程后成功。断言 `before_fire and not after_ready and now_loaded`，证明是 false→true **边沿**而非电平
5. ✅ 殉爆 `6 × slot` —— `ammo_depot_small`(8 槽) → `48`、`ammo_depot_large`(22 槽) → `132`（目标取 armor 0 的 `conveyor_straight`，否则 AOE 会再过一次护甲）
6. ✅ 灼烧/减速到期移除 —— `statuses()` 报 `duration == remaining == burn_duration_s`(3.0) 与 `slow_duration_s`(2.5)；`thrust_scale()` 1 层 `0.7` / 2 层 `0.4` / 到期回 `1.0`；各产生 1 条 `burn_expired` / `slow_expired`。**HUD 图标与秒数的渲染只有截图像素证据（当前为空态「状态 无」），非人工交互验证**
7. ✅ 200 发同屏 —— `field.spawn` ×200 + 30 帧 `field.step`，测得 `per_frame_ms=1.65` < `1000/55 = 18.18`。**只能表述为「逻辑步进的帧预算内断言通过」：该测量为纯逻辑步进、无渲染，不是实测帧率**
8. ✅ 维修 —— 普通模块 `amount==12`、`core==false`；驾驶舱 `amount==6`、`core==true`；`cal_155` 摧毁驾驶舱后 1 条 `core_destroyed` + `defeated==true`，此后 `step(period*3)` **无任何 `repaired` 事件**

**已知偏差（6 条有意简化，详见 `design.md` §8.9.6）**：
1. 升级**整台聚合**而非逐发携带（与 §7.1 有差距；`modifier_mk1/2/3` 无 `upgrades` 字段，`cannon_upgrades()` 现恒返回空数组，测试靠 `inject_upgrades()` 或直接给 `apply_hit()` 传 upgrades）
2. 残骸 3 s 只在 `damage_system.debris` 内维护，未接入 `grid_builder` 的放置校验（属 M6 建造期）
3. `_drive_load_arena()` 仍丢弃障碍 `hp` / `armor` —— M5 障碍不可摧毁
4. 撞墙伤害不触发殉爆 / detach / 判负（`apply_part_damage()` 接线口已备，但 `_drive_step()` 未调用）
5. 护盾覆盖几何与维修范围在代码推导，`data/modules/systems.json` 未改（仍 41 行 / 7109 字节 / `36f1cd68`）
6. 维修对驾驶舱减半是实现假设，待 `design.md` §16.2 Q15 裁定

**M6 前必须解决的已知缺陷 —— 自击**：`cannon_bank.muzzle_origin()` = 格中心 + `dir × (cell_size × 0.5)`，正好落在相邻格**边界**；`projectile_field._clip_to_aabb()` 对「起点在格内/边界」返回 `t = 0`，于是弹丸出生第一帧就命中射手自己占用的格，`_sweep()` 按最小 `t` 裁决得到 `target = "tank"` 并交给 `damage_system.apply_hit()`。**已实证发生**：`--screen=drive` 固定预热（90 步油门 + 开火 + 6 步）后，截图 `drive_m5_capture3.png` 的 `最近事件` 显示 `命中本体装甲`。`cal_20`（base 8）对 armor 3 只有 `8 − 3 = 5.0` 伤害，故未摧毁任何部件、既有验收数值不受影响；但实弹武器（`cal_155` base 240）会直接自伤。候选修法（尚未选定）：按 `shooter` 过滤自身、把 `muzzle_origin` 沿方向外推到船体之外、或忽略 `t == 0` 且 `tag == shooter` 的命中。

**验证边界（必须如实看待）**：`COMBAT_OK` 的 11 个阶段全部**直接调用 `damage_system`**，因此 `main.gd` 的战斗事件分发（`_drive_resolve_impact` / `_drive_consume_damage_events` / `_drive_spawn_split`）**只被执行过「无事件」空态路径**；页面证据为**脚本预热 + 截图像素检查，非人工桌面交互验证**；七条既有回归已逐字重跑通过（含 `DATA_ERROR_OK errors=17`，证明 21 个新 `global` 键未破坏校验器）。

风险：`detach` 过于惩罚（一次走火掉半个车）。对策：锚点已定为**驾驶舱**且分离**立即摧毁**（用户 2026-10-17 确认，无宽限期）；缓解手段改为建造期提示（高亮驾驶舱的脆弱连接）与 HUD 预警，不再提供宽限开关。**M5 未实现该建造期提示，属 M6/M7 待补。**

---

### M6 — 机器人 AI 与完整对局 ✅

**状态**：✅ 已完成（v3.3）。下一站原为 M7，**v3.4 起改为 M9**（波次生存单人玩法）。

> ⚠️ **v3.4 覆盖声明**：本里程碑交付的 `EXPEDITION` 单人循环（5 层 × 3 波、`INTERMISSION`、`scrap` 双货币、原地建造）**已被 v3.4 推翻**（`design.md` ADR-017、§16.1 Q8 修订）。本段保留为**历史实现记录**：它准确描述了当时交付的代码与验收结果，且这些代码**现在仍存在且仍能通过 `EXPEDITION_OK`**，但它们验证的是**旧玩法**，**不能**作为新玩法的证据。新玩法见 §2 M9。

**目标**：能完整打一局 vs Bot，从建造到结算闭环。

交付物（均已完成，括号为落地文件）：
- 对局状态机 `MATCH_SETUP → BUILD → DEPLOY → BATTLE → RESULT`（`scripts/match_state.gd`；`DEPLOY_COUNTDOWN_S = 3.0`）
- 双坦克对局：两侧各自持有 builder / tank / cannon_bank / ammo_network / damage_system，共用一张弹道场（`scripts/duel.gd`）
- 胜负判定：驾驶舱被毁同帧转 `RESULT`；同帧双毁与超时均比已造成伤害；已造成伤害按 `shooter` 归因
- AI 三层决策（战略 2 Hz / 战术 10 Hz / 执行 60 Hz，`scripts/bot_ai.gd`）
- 4 档难度（新兵/老兵/精英/王牌），反应延迟 500/220/80/40 ms、瞄准误差 8°/3°/1°/0.4°，**全部读 `globals.ai` 块**
- Bot 预置蓝图池 `data/blueprints/bot_*.json`：**已交付 12 张（四档各 3 张）**，均经 `load_blueprint` + `validation_report` 通过
- 结算面板数据：`result_panel()` 输出双方造成伤害、剩余部件数、剩余平台格、剩余质量、对局剩余时间
- AI 只使用可观察信息：不读玩家弹药量；驾驶舱位置对所有档位公开，难度差异体现在**用不用**（新兵/老兵不用，精英与王牌用割点分析）
- **`EXPEDITION` 远征循环**（`scripts/expedition_run.gd`）：5 层 × 3 波推进、坦克跨层连续（复用同一个 `GridBuilder`，破口不回滚）、`INTERMISSION` 层间整备（发放 600 cr + 升级三选一）、`RUN_SUMMARY` 结算
- **`scrap` 经济**（同文件内 `_accumulate_scrap()`）：摧毁掉落 `price × 0.35`、击毁整机额外 +60、远征结束清零。**未另建 `scrap_economy.gd`** —— 该逻辑只服务于远征，单独拆文件会多一层无收益的间接
- **升级赠送**：候选 3 选 1，赠品入 `inventory` 而非直接贴装；`inventory` 不计入 `M` / `mass_cap`
- **远征出生点**：竞技场 `expedition_spawns` 按波次取用（`expedition_run._player_spawn()` / `_wave_spawns()`）
- **对战页与菜单项**：`main.gd` 新增 `SCREEN_MATCH`、主菜单第 3 项「对人机对战」（菜单项由 5 增至 6）、难度用 A/D 切换、对局输入/推进/绘制与 `--screen=match` 截图钩子

验收结果：

1. **完整跑一局**：`tests/match_smoke.gd` 的 `_check_full_match()` 让 AI 驱动敌方、玩家侧给出伤害，跑到 `is_over()` 为真——`MATCH_RUN steps=18000 outcome=timeout_player player_dmg=500.0 enemy_dmg=313.0 player_parts=13 enemy_parts=18`。**注意：本局是超时结束而不是驾驶舱被毁**——`steps=18000` 正好等于 `match_time_limit_s 300 × physics_hz 60`，即对局压满时限后按已造成伤害判定胜者（500.0 > 313.0）；循环上限 20000 步从未被触及。两种结束方式分开验证：超时由本用例覆盖，驾驶舱被毁由 `_check_defeat_ends_match()` 覆盖（转 `RESULT` 后再 `step(1.0)` 仍为 `RESULT`、outcome 不变）。
2. **难度有效**：只断言了**参数层**——`_check_ai_tiers()` 验证四档的 `_reaction_s` 与 `_aim_error_deg` 与 JSON 逐字一致且严格递降，并验证 `uses_structure_analysis` 仅精英/王牌为真。**没有测“王牌命中率高于老兵”** —— 那需要一个固定对局样本与命中率统计，本阶段未做。
3. **新兵更易被击败**：**未测**。同上，需要多局蒙特卡罗统计胜率差，本阶段未做。
4. **可复现**：`_check_ai_determinism()` 断言同种子两次运行的决策序列字符串逐字相同、换种子则不同（`ai_determinism` / `ai_seed_matters`）。
5. **不读对手弹药量**：`bot_ai.gd` 全程只访问 `duel.tank_of()` / `duel.builder_of()` / `duel.can_fire()` / `duel.bank_of(...)["cannons"][0]["aim"]`，**没有任何访问 `network` 状态的代码**；此为代码审查结论，**未加运行时断言**。
6. **质量上限不跨局**：本阶段**未实现跨局持久化**，`GridBuilder.mass_cap_level` 天然每局重建为 0（`setup()` 不读任何存档），因此该条以“无持久化即满足”形式成立，**未加专门断言**。
7. **5 层远征**：`tests/expedition_smoke.gd` 的 `_check_full_run()` 跑到 `STAGE_SUMMARY`，断言 `end_reason == "cleared"`、`sector == 5`、`waves == 15`、`kills == 15`、`inventory.size() == 4`（第 1 波后 1 次 + 每层结束 1 次 × 4 = 5 次节点，其中首次在第 1 波结束时触发，故 4 次 INTERMISSION）；`EXPEDITION_RUN waves=15 sectors=5 kills=15 scrap=1971.0 credit=4800.0 rewards=4`。
8. **驾驶舱被毁立即结束**：`_check_core_destroyed_ends_run()` 断言 `stage == SUMMARY`、`end_reason == "core_destroyed"`。
9. **跨层连续**：`_check_carry_over()` 打掉一块玩家平台格使 `cells_before > cells_after`，进 `INTERMISSION` 后 `advance_sector()` → 第 2 层，再 `start_wave()` 时 `platform_cells.size()` 仍等于 `cells_after`（破口保留）。
10. **`scrap` 掉落**：`_check_scrap_economy()` 断言单部件掉落 ≥ `price × scrap_yield`、击毁整机后 `kills == 1` 且本次增量 ≥ `scrap_kill_bonus`；结束清零由 `_check_full_run()` 末尾的 `close_run()` 断言。
11. **赠品进库存不贴装**：`_check_reward_inventory()` 断言 `inventory` 增加 1 项、`stage` 转 `INTERMISSION`，且**坦克的质量与部件数完全不变**。
12. **全链路无 `change_scene()`**：仍为零调用（单一场景架构未变）；但**“从主菜单到结算用键盘与手柄走通”未做人工验证** —— 手柄在本项目里从未支持（Q25 已裁定暂不支持），因此本条的“手柄”部分不适用。
13. **暂停冻结计时器**：`_check_pause_freezes_timer()` 断言 `toggle_pause()` 后 `step(0.5)` 使 `battle_time_left` 不变、`paused_time` 增加 0.5，再 `toggle_pause()` 后恢复倒计时。**按键是 `P` 而不是 `Esc`** —— `Esc` 在 M6 用作“返回主菜单”，与设计 §11.4.8 的“`Esc` 逐层返回”有偏差，见下方遗留项。
14. **无“重开本层 / 继续游戏 / 读取存档”入口**：满足（根本没有这些 UI）。
15. **卡面文案与库存只读**：**未实现** —— 三选一只有数据层（`reward_choices` / `choose_reward()`），没有卡面 UI。

**六条遗留项（不构成阻塞，已登记在 `design.md` §10.5.6）**：
1. 王牌档的“诱骗”行为未实现 —— 王牌只比精英更准更快。
2. 王牌档的“预判弹药耗尽时机”未实现 —— 且与 §10.4「不读弹药量」需先裁定边界。
3. 远征每波仍只生成 **1 台**敌方坦克（设计允许 1–3 台）；多敌方需要 `duel` 支持同 tag 多 side。
4. **对战页没有独立的 `BUILD_PHASE → DEPLOY_PHASE` 页面**：`_enter_match()` 直接用建造页当前蓝图开局，3 s 部署倒计时在代码里跑完，玩家看不到倒计时画面。
5. 竞技场障碍仍不可摧毁（继承自 M5 §8.9.6 第 3 条）。
6. 升级赠品未接战斗期原地建造：`inventory` 可累积、可 `take_from_inventory()`，但没有 UI 把它贴到坦克上。

**在本阶段修掉的 M5 遗留缺陷**：
- **自击**：`projectile_field._sweep()` 新增 `shooter_tag` 参数跳过射手自身；`combat_smoke` 新增 `_check_no_self_hit()` 双向断言；`drive` 页截图的 `最近事件` 由 `命中本体装甲` 变为 `—`。
- **撞墙不连锁**：`tank_body` 新增 `damage_router: Callable`，`main._enter_drive()` 与 `duel.add_side()` 都接 `apply_part_damage`；`physics_smoke` 不设路由，行为逐字不变。

**验证边界（必须如实看待）**：截图 `m6_match2.png` 是**脚本预热 + 像素检查**，非人工交互验证；`MATCH_RUN` 的 18000 步是压测上限而非真实对局时长；验收 2/3 的“难度有效性”只有参数层证据、没有胜率统计。

风险：AI 在“拆结构”上过强或过弱。对策：难度差异只体现在操作质量，不改蓝图数值（`design.md` §10.2）。**M6 实际实现中，精英与王牌会主动找割点断岛，因此“拆结构过强”的风险升高** —— 缓解手段仍是建造期提示（高亮驾驶舱的脆弱连接），**该提示与 M5 一样仍未实现，属 M7 待补**。

---

### M9 — 波次生存单人玩法 ✅

**状态**：✅ 已完成（v3.6 主体 + v3.7 补上改装入口 + v3.8 改装页改为复用建造编辑器）。设计在 `docs/design.md` §3.4（含 §3.4.6 实现记录与 v3.8 改写的 §3.4.7 改装页）；代码在 `scripts/survival_run.gd` + `scripts/main.gd` 的 `SCREEN_SURVIVAL` 五张页面。**R18（多敌人同屏）在本里程碑内同期完成**（design §10.6）。

**已交付**：`survival` 块 36 键、竞技场 `props`、`boss_warlord.json`、`survival_run.gd`（`STAGE_BATTLE / LEVEL_UP / SHOP / MODIFY / SUMMARY`）、战斗页/升级三选一页/商店页/改装页/结算页、主菜单「生存」入口、`tests/survival_smoke.gd`（13 阶段）、`match_smoke` 的 3 个多侧阶段。

**验收结果（实测，日志 `.me/tmp/main/f_*.log`）**：

| # | 标准 | 结果 |
| --- | --- | --- |
| 1 | 至少 6 波含第 5 波 Boss，无报错 | 🟨 **逻辑级已验证**（`survival_smoke` 覆盖 wave 1 与 wave 5），**未做人工跑 6 波的会话** |
| 2 | 计时归零且驾驶舱存活即通过 | ✅ `_check_wave_passes_on_timer` |
| 3 | 战斗期不可改装 | ✅ `_check_no_combat_modification`（`take_level_choice` / `buy_shop_slot` / `reroll_shop` / `sell_inventory` / `start_next_wave` 全部拒绝，且无 `build_mode` 开关）；**但“代码搜索”一半未做**，且改装 UI 入口本来就不存在 |
| 3 | 战斗期不可改装 | ✅ `_check_no_combat_modification`（`take_level_choice` / `buy_shop_slot` / `reroll_shop` / `sell_inventory` / `start_next_wave` 全部拒绝，且无 `build_mode` 开关）+ **v3.7 新增 `_check_modification` 的 `mod_rejected_in_battle` / `mod_mount_rejected_in_battle`**（`enter_modification()` 与 `mount_from_inventory()` 在 `STAGE_BATTLE` 均被拒）；**但“代码搜索”一半仍未做** |
| 5 | 升级菜单三选一不可跳 | ✅ `_check_level_choices` + `_check_xp_and_levels` 新增的可达性断言（波次通过必先进 `LEVEL_UP`，领完才进 `SHOP`） |
| 6 | 房屋撞击/炮击两路 + 残骸收益 | 🟨 `_check_props` 覆盖了炮击摧毁、残骸碾过与只拾取一次；**「撞击摧毁」路径未单独断言**（依赖 R17 修好的撞墙/障碍伤害链，但无专项用例） |
| 7 | 敌人分级按波次 | ✅ `tier_for()` + `tier_w1/w4/w6/w5_boss_floor/w10/w15` |
| 8 | Boss 波部件数显著更高 + 固定奖励 | ✅ `boss_bigger_128_vs_60` / `boss_credit_reward` / `boss_xp_reward` / `boss_drop_count_3` |
| 9 | 同一波 ≥ 2 台敌人、独立 AI 与伤害归属 | ✅ `_check_start_wave` + `match_smoke` 的三个多侧阶段 |
| 10 | 同种子可完全复现 | ✅ `determinism_same_seed` / `determinism_rng_same_seed` / `determinism_rng_diff_seed` |
| 11 | 全部回归保持通过 | ✅ 11 项逐字通过（含 `SURVIVAL_OK`） |

**已知缺口（待办，不得当作已完成）**：

1. ~~改装 UI 入口不存在~~ → **v3.7 已交付**：升级页与商店页各一个「M 改装坦克」按钮，`STAGE_MODIFY` 子阶段 + 改装页（design §3.4.7）。**v3.8 已改为复用建造页整套编辑器**（`_editor_model()` / `_in_modify_mode()`），v3.7 曾记录的两项「手感简化」（无矩形/直线铺平台工具、无撤销/重做按钮）**已随复用一并消失，不再成立**：矩形/直线铺平台、拖动铺、`Ctrl+Z`/`Ctrl+Y` 撤销重做、模块目录排版与 I1–I10 错误列表格式现在改装页全有；独立改装页的 `SURVIVAL_MODIFY_*` 常量与 15 个 `_survival_modify_*` 函数已删除。
2. **商店稀有度权重方向反了**：实现把 `shop_rarity_weight` 当作价格倍率（`1 + w/Σw`），导致普通件 ×1.6、史诗件 ×1.1，低价件反而更贵。
3. **`safe_radius` 未被读取**：房屋/残骸位置是固定表，不经 LCG 抽取，也不避开出生点。
4. **`boss_armor` 未实现**：不可摧毁装甲块不存在。
5. **房屋撞击摧毁无专项断言**。
6. **无开局建造页**：起始坦克由代码现场摆放，玩家不能自定义起始车（与 §3.4 的 `EXPEDITION_SETUP → BUILD_PHASE` 不一致）。
7. **无人工交互验证、无 Android 验证、无 APK**。
8. ~~「炮弹似乎不能对敌人造成伤害」~~ → **v3.9 已修**：根因是数值与反馈两层——旧起始车用 20mm（`cal_20` 对 armor 3 平台只有 5 伤/发，而招募级 Bot 总血量 1835，一波 45 s 内不可能击毁）；且敌车整台只画一种颜色、命中坦克时事件行不更新、HUD 无累计伤害读数。现已改为 76mm 起始车（实测一波内 `hits=25 destroyed=21 kills=1`）+ 逐部件血量着色 + 命中闪光/动效 + 总输出读数，并新增永久回归 `_check_player_fire_damage()`（含 `fire_kill_within_wave`）。**仍缺**：敌人没有自己的镜像面板（敌人血量只体现为车体格子颜色）。
9. ~~对战页动效不衰减~~ → **v3.10 已修**：`_match_step()` 结尾误调 `_drive_tick_fx()`（它只递减 `_drive_fx`），`_match_fx` 的 `left` 从无递减点，`_draw_match_fx()` 用 `left/life` 算 alpha 故恒为 1，脱落环永久常驻。已新增 `_match_tick_fx()`。**仍缺**：动效「随时间真的淡出」只有代码层证据，未做连续帧观察。
10. **`main.gd` 仍是上帝类（v3.10 审查确认；v3.11 已减 11.2% 但未拆）**：现为 **142618 B / 170 函数 / 64 const / 74 var**（v3.10 时为 160536 B / 187 / 69 / 84），仍承载菜单 + 设置 + 建造编辑器 + 试驾页 + 对战页 + 生存页 5 子页 + 输入总路由 + 7 个截图钩子，**页面间零语言级隔离**。**v3.11 已抽掉 FX 生命周期（`scripts/fx_layer.gd`）与坦克绘制（`_draw_hull_shared`）两类可安全外移的部分；按页面拆文件未做**，因它需先定页面状态容器（74 个 `var` 重新归属、`_editor_model()` 跨页分流重设计、`_draw`/`_input`/`_process` 必须留在 `Node2D`、7 个预热钩子需重新定位），属架构级改造而非清理。
11. ~~旧远征页绘制副本~~ → **v3.11 已关闭**：整个 `SCREEN_EXPEDITION` 页面连同 `_draw_expedition_grid` / `_draw_expedition_sidebar` 等 7 个绘制函数与 16 个控制函数一并删除（−401 行），该页不再可达。
12. ~~`expedition` 死块读取 + 硬编码数值~~ → **v3.11 已关闭**：两处 `globals.get("expedition", {}).get("scrap_kill_bonus", 60)) * 4.0` 随远征页一并删除；那句「价格来自 data/globals.json 的 expedition 段」假文案也已移除。
13. ~~死依赖与死代码~~ → **v3.11 已关闭**：`main.gd` 不再 preload `runtime_builder.gd` / `expedition_run.gd`；`tank_visual.gd` / `hud.gd` / `grid_field.gd`（13907 B / 310 行）与两个遗留 `_tmp_*.gd` 已删除。注意：`expedition_run.gd` / `runtime_builder.gd` **脚本本体仍存在**且各自 smoke 仍通过（`EXPEDITION_OK` / `RUNTIME_OK`），但已无任何玩法调用方——是否连脚本一起删属另一个决定。
14. **页面层硬编码数据概念（v3.10 审查确认，未修）**：`MATCH_DIFFICULTY` / `MATCH_DIFFICULTY_LABEL` 把难度档名单写死在页面层；`DRIVE_ARENA_ID := "arena_standard"` 把试驾页绑死到单一竞技场 id。
**旧交付物说明**：`scripts/expedition_run.gd` 与 `scripts/runtime_builder.gd` 已从主菜单断连，且因 `expedition` 块被删而回退到代码内默认值；`EXPEDITION_OK` 与 `RUNTIME_OK` 仍通过，但**不再验证真实数值来源**。

**目标**：单人模式变成"活过一波、花掉奖励、再活过下一波"的闭循环，且有可感知的成长压力与随机性。

**来源**：用户 2026-10-17 描述（逐条对应到交付物）："主要肉鸽生存向，需要在每个波次的时间内生存下来" / "地图散落房屋、坦克残骸，碾过残骸得金钱或经验、概率掉配件" / "房屋需撞击或炮击摧毁才能得奖励" / "机器人敌人分级别，级别越低坦克越简单，高级结构更复杂" / "击败敌人得经验金钱，一定概率掉落自身已有的某个配件" / "升级弹三选一赠送配件 + 改装按钮" / "正常战斗时不允许改装" / "波次成功进商店：六件商品、花钱刷新、卖已有配件、进改装" / "每 5 波一个 Boss，庞大复杂火力防御较强，奖励较多"。

交付物（括号为落地文件，均**尚未创建**）：
- 波次生存状态机：`BATTLE → (计时归零或敌人清空) → LEVEL_UP → SHOP → 下一波`，驾驶舱被毁直接 `RUN_SUMMARY`（`scripts/survival_run.gd`，替代 `expedition_run.gd`）
- 经验/等级系统：经验曲线 `XP(n) = 60 + 45(n−1)`，满级弹出升级菜单，溢出逐级结算
- 升级菜单：三选一（新配件进库存 / 已装升级即刻生效 / 免费质量上限 +1）+ 改装按钮（UI + 逻辑）
- 波间商店：6 个商品位、恒定 60 cr 刷新、出售库存（回收 50%）、改装入口
- 地图道具：房屋（HP 260 / 护甲 5，撞击或炮击摧毁）与坦克残骸（碾过即得），每波按 `props` 重生成
- 敌人分级：按波次切换新兵/老兵/精英/王牌蓝图池（复用 M6 的 12 张 `bot_*.json`）
- **多敌人同屏**：`duel` 扩展到同 tag 多 side（当前只支持双方各一台，这是最大技术缺口）
- Boss 波：每 5 波换 `data/blueprints/boss_*.json`（≥ 1 张），更高火力/防御/结构，奖励 320 cr + 200 xp + 必掉 3 件
- 战斗期禁用改装：`BUILD_MODE` 在本模式彻底移除入口（§4.7 停用）
- `data/globals.json` 新增 `survival` 块（§14.8 六组常量），读取走 `block_number("survival", …)`
- 竞技场 `props` 字段入 JSON（§9.2）
- 货币统一：`scrap` 废弃，`expedition` 块的旧键删除；`credit` + `experience` 两资源

验收标准：
1. 能完整跑一场：至少 6 波，其中第 5 波为 Boss，全程无报错、无卡死。
2. **限时生存生效**：波次计时归零且驾驶舱存活时，本波判为通过并进入 `SHOP`（而不是判平/判负）。
3. **战斗期不可改装**：`BATTLE_PHASE` 内不存在任何建造/更换配件入口（代码搜索 + 运行时断言双向验证）。
4. **商店可操作**：买商品、刷新（扣 60 cr）、卖出库存（回收 50%）三项各自有断言；已装部件不可直接卖。
5. **升级菜单**：经验满级触发；三选一必选其一；新配件进 `inventory` 且**坦克质量与部件数不变**；升级与质量上限**即刻生效**。
6. **房屋与残骸**：碾过残骸得钱/经验（概率掉落有断言）；房屋被撞与被炮击两种路径都能摧毁并给奖励。
7. **敌人分级**：低波只出新兵蓝图（部件数最少），高波出精英/王牌（部件数更多），且各自能加载并通过校验。
8. **Boss 波**：第 5 波出现 Boss 且其部件数显著高于同波普通敌人；击毁给固定奖励 + 必掉 3 件。
9. **多敌人同屏**：同一波内 ≥ 2 台敌人同时存在、各自独立 AI 与伤害归属（当前实现会直接做不到）。
10. **确定性**：同种子 + 同输入序列可完全复现（波次敌人、商店商品、掉落均走显式 LCG）。
11. **回归**：`physics_smoke` / `cannon_smoke` / `ammo_net_smoke` / `build_smoke` / `runtime_build_smoke` / `data_smoke` / `data_error_smoke` / `combat_smoke` / `match_smoke` 全部保持通过。

风险：
- **R12（升级）**：新玩法的平衡面远比旧版大（波次时限、经验曲线、商店价格、掉率四个旋钮互相耦合）。缓解：全部走 `design.md` §14.8，禁止内联；先以"能跑通"为准再标定数值。
- **R17（✅ 已解决 v3.5）**：碰撞与损坏链路的 9 个缺陷已全部修复，并额外修掉 3 个实现级 bug（矩形障碍穿墙、圆形障碍少推 1 px、互撞接近判定符号反）。房屋撞击所依赖的撞墙/障碍伤害路径现在是可信的。
- **R18（✅ 已解决 v3.6）**：多敌人同屏已落地——`duel` 的 `sides` 改为按 tag 遍历，新增 `TEAM_PLAYER` / `TEAM_ENEMY`、`add_side(…, team)`（拒绝空/重复 tag）、`team_defeated` / `team_damage` / `hostiles_of`；`projectile_field._sweep()` 跳过同队目标；`bot_ai._refresh_target()` 确定性重选目标。回归：`match_smoke` 新增 3 个多侧阶段。
- **R12（仍开放）**：新玩法数值未标定。另剩三个已知缺口：商店稀有度权重被当作价格倍率且方向反了、`safe_radius` 未被读取、`boss_armor` 未实现。（原第四个缺口「改装 UI 入口不存在」已于 v3.7 关闭。）

依赖：M6 的 `duel` / `bot_ai` / 12 张 Bot 蓝图；`damage_system` 与 `projectile_field`；`grid_builder` 的建造校验（供改装页复用）。**不依赖** M7 的视觉打磨。

---

### M7 — 视觉打磨与内容补齐 ⬜

**目标**：达到"极简 · 霓虹 · 荧光"的定稿观感，内容量够玩。

交付物：
- 霓虹主题定稿：调色板（`design.md` §2.1）落地为主题资源，`WorldEnvironment` Glow 调参达标
- 全程序化绘制（无位图）：模块线框、45° 切角语言、1px/2px 线宽规范
- 6 类关键动效（击毁碎裂、护盾涟漪/破裂、开火火花+抖屏、弹药拖尾、装填脉冲）
- 建造 UI + 战斗 HUD 完整实现（含结构小地图、弹药链状态、护盾充能环）
- 3 张竞技场：`arena_standard` / `arena_corridor` / `arena_pit`
- 音效：开火、命中、护盾、摧毁、装填完成、UI 反馈（程序化合成或免费素材）
- 无障碍：关闭辉光、关闭动效、UI 缩放 80%–150%、色盲形状差异
- 蓝图库：≥ 8 张可玩蓝图为玩家提供起点
- 菜单视觉与无障碍打磨（`design.md` §11.4.7 / §11.4.8）：焦点竖条与淡入淡出动效、禁用项的虚线表达、UI 缩放 150% 下主菜单与三选一卡片改为单列 / 纵向堆叠

验收标准：
1. 截图与 `design.md` §2 的调色板逐色比对，无越界色（高饱和发光色 ≤ 3 种同屏）。
2. 发光元素确有光晕（非仅高亮度），关辉光后信息仍可读。
3. 所有状态除颜色外有形状/图标差异（色盲模拟下可区分）。
4. 无障碍三项开关全部生效。
5. 8 张蓝图均可加载、通过校验、可进战斗。
6. 菜单界面同屏高饱和色不超过 3 种（实际仅用 `accent_cyan` 一种）；无全屏闪白、无背景发光、无转圈 loading。
7. UI 缩放 80% 与 150% 下主菜单、设置页、三选一卡片均无重叠与截断；1280×720 下全部界面可用。

风险：辉光过曝导致信息模糊。对策：先定"信息优先"，辉光强度作为最后调参项。

---

### M8 — 移动端触屏支持 ⬜（设计已完成，实现未开始）

**目标**：让触屏设备能完整游玩——不只是“能启动”，而是能从菜单进建造、造出坦克、开出去、开火。

**当前状态**：**仅设计，零代码。** 完整方案已写入 `docs/design.md` §11.6（含 §11.6.1–§11.6.9），触屏常量表在 §14.10。三个开放问题**已由用户裁定**（§16.1）：Q24 **不需要**右侧瞄准摇杆、Q25 **暂不支持**外接手柄、Q26 **仅横屏**（因此只需一套上下分区布局，不做竖屏变体）。`data/globals.json` 中**尚无 `touch` 块**，`scripts/*.gd` 中**无任何触摸事件处理**。

交付物（按 `design.md` §11.6.9 的五个阶段）：
- [ ] 抽 `input_source` 契约与 `InputFrame`，把 `main.gd` 现有键盘分支搬进去（行为与当前完全一致）
- [ ] `TouchSource` + 左虚拟摇杆（半径 96、接管热区 2R、死区 0.18、圆形归一化、松手归零）
- [ ] 右侧虚拟按键组（开火按住连发、重开与返回二次确认、忽略 hover）
- [ ] 建造页与远征施工页手势（单击放置 / 按住拖动 / 长按拆除 / 双击旋转 / 工具按钮组 / 矩形与直线改按下-拖动-抬起）
- [ ] HUD 双布局（桌面 = 横向三段，移动 = 上下分区）与安全区适配
- [ ] `data/globals.json` 新增 `touch` 块（十个常量，§14.10），读取走 `registry.globals["touch"]` 而非 `global_number()`
- [ ] 真机验证记录（**目前为零**）

验收标准：
1. 在真实 Android 设备上，仅用触屏完成“进建造 → 放平台 + 行进机构 + 驾驶舱 → 进试驾 → 摇杆行驶 → 开火”全链路，全程不需键盘鼠标。
2. 摇杆斜推至边界时，实测稳态速度与 §5.3 的 `v_max 192.1 px/s` 误差 ≤ 8%，与单轴满推结果一致（证明圆形归一化生效）。
3. 摇杆松手后 100 ms 内 `throttle` 与 `steer` 回到 0，且坦克无残余滑行输入。
4. 全部可点控件在目标设备上物理尺寸 ≥ 7 mm；摇杆与按键均不被安全区（刘海/手势条）遮挡。
5. 键鼠与触屏同时输入时 `|vector| ≤ 1`，且不出现抖动（§11.6.4 合成规则）。
6. 无触摸代码的回归：`physics_smoke` / `cannon_smoke` / `build_smoke` / `runtime_build_smoke` / `data_smoke` / `data_error_smoke` 全部保持通过。

风险：
- **R14（新增）**：热区手感只能真机验证，桌面模拟触摸无法暴露遮挡与误触问题；若等到全部功能写完再上机，可能需返工布局。对策：第 2 阶段（摇杆 + 开火）一完成就上机，不等全部完成。
- **R15（新增）**：`InputEventScreenDrag` 被 Godot 同时合成为鼠标移动，若复用现有 hover 分支，手指划过会误触发高亮甚至误点击。对策：触屏提供者完全绕过 hover 路径（§11.6.3）。

依赖：需先有可用 APK 才能真机验证，因此本里程碑的验收部分**受 M3.5 阻塞项约束**（导出模板 + Android SDK + `java_sdk_path`，均需工作区外安装且需用户授权）。前置的 1–4 阶段实际上可以在桌面用鼠标模拟触摸开发，但**验收第 1、4 条无法在桌面完成**。

---

## 3. 横切工作（贯穿所有里程碑）

这些不单独立项，但每个里程碑都必须遵守：

| 项 | 要求 | 检查方式 |
| --- | --- | --- |
| 文档同步 | 每次改动同步更新受影响文档（`agent_note.md` M1） | 提交前自检清单 |
| 数值集中 | 不内联魔法数字（M4） | 代码搜索 |
| 确定性 | 排序遍历、固定步长、单 RNG（`design.md` §9 与 §12.1） | 确定性回归测试 |
| 性能 | 逻辑帧 ≤ 6 ms，弹药网络 step ≤ 1 ms | 性能采样 |
| 测试 | 纯逻辑可脱离场景单测 | `tests/` 覆盖 |
| 数据驱动 | 新增模块不改核心逻辑 | 代码审查 |

---

## 4. 风险登记册

| # | 风险 | 概率 | 影响 | 缓解措施 |
| --- | --- | --- | --- | --- |
| R1 | 弹药网络时序 bug 导致炮弹丢失/复制/瞬移 | 高 | 高 | 严格 §7.7 定序；单测覆盖同 tick 双推；确定性回归 |
| R2 | `detach`（连通块脱落）惩罚过重，玩家挫败 | 中 | 高 | 锚点已定为驾驶舱且**立即摧毁**（Q3 已确认，不提供宽限）；靠建造期脆弱连接高亮 + HUD 预警降低意外 |
| R3 | 建造编辑器 2 格模块旋转/端口对齐难写 | 高 | 中 | M2 先做 1 格打通，再加 2 格；端口可视化调试 |
| R4 | 偏心质心 + 高惯量导致物理抖动/自旋爆炸 | 中 | 中 | `I_MIN`、角速度钳制、固定步长、`K_ANGDRAG` 可调 |
| R5 | 120 模块 × 三层全画节点导致掉帧 | 高 | 中 | 每层单 Node + 批量 `_draw()`，仅动效件升级为独立节点 |
| R6 | 数值平衡（尤其升级叠加）失控 | 中 | 中 | 全部走 §14 + JSON；叠加上限封顶；试驾沙盒快速迭代 |
| R7 | 引擎"供能 PU"设定（Q1）与用户预期不符，导致返工 | **已消解** | — | 用户已于 2026-10-17 明确确认 Q1；仍保留 PU 为数据字段，便于后续调整 |
| R8 | 炮弹"逆向退回"逻辑复杂引入死锁 | 中 | 中 | 退回只允许回退到最近存弹点；设超时 1 s 兜底销毁 |
| R9 | 建造学习曲线过陡，新手 5 分钟造不出能打的坦克 | 中 | 高 | 蓝图库 + 分步引导 + 断链可视化；"一键试驾"降低试错成本 |
| R10 | 价格表绝对数值未经实战验证，满配 2194/2400 cr 仅剩 8% 余量，可能导致"只有一种最优解" | 中 | 中 | 先按 `design.md` §14.7 上线（Q11）；M6 用实战数据回调，偏离超 10% 则查价格表是否被意外改动 |
| R11 | 满配质量 191 u 对 Lv.1 上限 192 u **余量仅 1 u**，实现后若质量略高就得多买一级升级 | 中 | 中 | 已核实：`design.md` §5.3 的 174 u 是聚合估计值（不含武器/驾驶舱），§14.7 的 191 u 才是逐模块求和，两者差 17 u（`.me/tmp/main/mass_reconcile.py` 验证 ALL_OK）；M1 用真实 JSON 重算后若超 192 u，需上调 Lv.1 上限或下调模块质量 |
| R12 | roguelike 双货币与波次强度平衡失当：前期打不过、后期无挑战，或 `scrap` 通胀导致战斗中无限扩建 | 高 | 高 | 全部系数走 `design.md` §14.8（`SCRAP_YIELD` / `SCRAP_KILL_BONUS` / `SCRAP_BUILD_RATE` / `SCRAP_REFUND` / `BUILD_TIME_PER_CELL`），禁止内联；M6 用实战数据回调；`scrap` 不跨远征保留（无元进度）已封住长期通胀 |
| R13 | 菜单作为同场景界面树，状态管理（焦点栈 / 暂停停表 / 与 `BUILD_MODE` 同级）易退化成散落的布尔开关，出现"暂停中还能开建造""`Esc` 连按直接退出" | 中 | 中 | 界面树与暂停语义集中到 `menu_router.gd`（`design.md` §13.2、ADR-014）；M6 验收第 12–14 条覆盖全链路与倒带禁令；`PAUSE_PANEL` 明定为 `BATTLE_PHASE` 子状态，不进 §3.1 阶段表 |
| R16 | M4 的 `blocked[ammo_id]` 粒度过粗：源模块一旦因拒收写入该标记，同源同口径的后续**正常**炮弹也会被挡住，直到拓扑重建 | 中 | 中 | 已在 `design.md` §7.8 与 M4 段如实登记；M5/M6 接入真实战斗后若发现供弹异常停止，优先检查该标记而非算路；彻底修复需把标记细化到“目标 + 口径”并加超时 |
| R17 | ~~**碰撞与损坏链路已确认 9 个实质缺陷**~~ → **✅ 已修复（v3.5）**。原缺陷：撞墙伤害打到车身**对侧**、矩形障碍可嵌入、圆形障碍修正量不足、墙角伤害翻倍、**坦克互撞完全未实现**、护盾本体被毁后仍会“复活”并吸收伤害、AOE 后旧索引扣血打到无关部件、延迟爆炸上报伤害未过护甲、AOE 重复发 `destroyed` 事件 | ~~高~~ **已消除** | — | **修复过程中又发现 3 个额外的实现级 bug**：$\textcircled{a}$ 矩形障碍用 `overlap_x < overlap_y` 选轴，长条墙体完全包含车身时会选错轴导致直接穿墙（实测旧 `final_x=800.00` 穿墙 → 新 `final_x=186.86 still_overlapping=false`）；$\textcircled{b}$ 圆形障碍圆心落在 AABB 内时少推 1 px（旧 53.00 → 新 54.00）；$\textcircled{c}$ `apply_tank_collision` 接近判定符号反了，任何对撞都被判「正在远离」返回 0，互撞伤害永不结算。`ram_damage_base` 矛盾按设计裁定：`30+0.06×Δv` 归 `thruster`（键更名为 `thruster_ram_*`），坦克对撞无基数项。**永久回归已并入** `tests/physics_smoke.gd`（+5 项）与 `tests/combat_smoke.gd`（+4 项），十项 smoke 逐字通过，`PHYSICS_OK` 与基线完全一致 |
| R18 | ~~M9 的多敌人同屏会将 `duel` 从"固定两侧"变成"N 侧"~~ → **✅ 已解决（v3.6）**。原风险：多处代码假设 `TAG_PLAYER` / `TAG_ENEMY` 二选一（`damage_dealt` 归因、`_sweep` 的 `shooter_tag` 过滤、`match_state._resolve_outcome`） | ~~高~~ **已消除** | — | `duel` 的 `sides` 改为按 tag 遍历并引入 `TEAM_PLAYER` / `TEAM_ENEMY`；新增 `add_side(…, team := "")`（**拒绝空 tag 与重复 tag**，否则会静默覆盖一侧）、`remove_side` / `team_of` / `team_damage` / `team_defeated` / `alive_in_team` / `hostiles_of`；`projectile_field._sweep()` 新增 `shooter_team` 参数使同队目标不参与求交；`match_state` 判负与伤害比较改按 team；`bot_ai` 新增 `_refresh_target()` 按「距离最小 → tag 字典序」确定性重选。回归：`tests/match_smoke.gd` 新增 `_check_multi_side` / `_check_multi_side_friendly_fire` / `_check_multi_side_team_damage` 三个阶段（344→426 行） |

---

## 5. 变更记录

| 日期 | 版本 | 摘要 | 影响章节 |
| --- | --- | --- | --- |
| 2026-10-17 | v1.0 | 初始创建：M0–M7 八阶段里程碑、状态表、验收标准、横切要求、风险登记册 R1–R9 | 全文 |
| 2026-10-17 | v1.1 | 同步 design v1.1：M3 交付物与验收标准改为差速驱动模型（新增转向回归项）；M0 一致性检查标为已完成；M6 质量上限 260 u → 150 u；R6 修正笔误 | §0 §2 M0 §2 M3 §2 M6 §4 §5 |
| 2026-10-17 | v1.2 | 离线脚本数值验证后重标定：M3 验收标准改为引用 design §5.3 参考构建表（实测目标 189 px/s 而非旧值 122）；M6 质量上限 150 u → 200 u（容纳满配 173 u） | §2 M3 §2 M6 |
| 2026-10-17 | v1.3 | 同步 design v1.3：M0 一致性检查描述改为完整版4 项实质缺陷；M3 验收基准改以“突击型” 7×6 布局、M≈70 u、目标 179 px/s、原地 180° ≈ 1.42 s | §2 M0 §3 M6 |
| 2026-10-17 | v1.4 | 同步 design v1.4：M0 标为完成、M2 补信用点/驾驶舱/aim 交付物、M5 补 detach 与驾驶舱判负、M6 改为信用点口径并新增 R10/R11 | §0 §1 §2 §4 §5 |
| 2026-10-17 | v1.4.1 | 一致性收尾：R11 补写两处质量口径差异；M2 验收格式与文件头修正 | §2 §4 §5 |
| 2026-10-17 | v1.5 | 同步 design v1.5：驾驶舱可视、维修可修驾驶舱、质量上限不跨局保留 | §0 §5 |
| 2026-10-17 | v1.5.1 | 交叉一致性校验补齐：M0/M5/M6 交付物与验收同步、文件头对齐 | §0 §2 M0 §2 M5 §2 M6 §5 |
| 2026-10-17 | v1.6 | 新增并完成 M0.5 视觉验证原型，记录 Glow 偏差与像素验收 | §0 §1 §2 M0.5 §5 |
| 2026-10-17 | v1.7 | 同步 design v1.7：单人 roguelike、双货币、升级赠送与原地建造；M2/M6 补运行期建造与远征交付物 | §0 §1 §2 M2 §2 M6 §4 §5 |
| 2026-10-17 | v1.8 | 同步 design v1.8：菜单体系、焦点与返回、ADR-014、M6/M7 菜单交付物与 R13 | §0 §1 §2 M6 §2 M7 §4 §5 |
| 2026-10-17 | v1.9 | **新增 M0.6 菜单与建造交互原型**：旧版静态视觉 demo 废弃；新 demo 提供菜单、设置、三层网格放置/旋转/拆除、预算/质量/驾驶舱连通性反馈，完整玩法仍未实现 | §0 §1 §2 M0.5 M0.6 §5 |
| 2026-10-17 | v2.0 | **完成 M0.6 交互原型**：Godot 实际启动与桌面操作验证通过；M0.6 标记完成，下一步恢复为 M1；同步记录新入口、建造交互与截图验证结果 | §0 §1 §2 M0.6 §5 |
| 2026-10-17 | v2.1 | **开始 M1 正式实现**：用户指示“按照 roadmap 开始正式实现游戏”；M1 标记进行中，正式数值改由 `data/*.json` 提供，新增加载/校验器与测试框架交付物 | §0 §1 §2 M1 §5 |
| 2026-10-17 | v2.2 | **完成 M1 核心数据层**：落地 10 个数据文件/目录，注册表与 schema 校验器接入主场景；正常 smoke、异常 smoke、截图启动均通过；M1 标记完成，下一步进入 M2 | §0 §1 §2 M1 §5 |
| 2026-10-17 | v2.3 | **M2 建造编辑器核心进入进行中**：接入 `module_defs.gd` / `grid_builder.gd`，完成正式 JSON 三层编辑、工具、校验、经济、蓝图和回归验证；运行期 `BUILD_MODE` 留待后续补齐 | §0 §1 §2 M1 M2 §5 |
| 2026-10-17 | v2.4 | **完善菜单动画与建造页鼠标交互**：M2 编辑器新增菜单淡入/焦点/hover、统一目录与按钮几何、配件滚轮、鼠标定位与编辑操作；最新 Godot 主场景截图及 `BUILD_OK` / `DATA_OK` / `DATA_ERROR_OK` 回归均通过；运行期 `BUILD_MODE` 继续保持待补 | §0 §2 M2 §5 |
| 2026-10-17 | v2.5 | **完成 M2 运行期 `BUILD_MODE` 并关闭 M2**：新增 `runtime_builder.gd`（scrap 支付、按格施工计时、受击中断不返还、拆解返还、运行期质量升级、单施工任务）与 `runtime_build_smoke.gd`（13 场景）；`grid_builder.gd` 加 `budget_enabled` 分离编辑器 credit 与运行期 scrap；主场景新增「远征」入口与 `EXPEDITION_BATTLE` 施工页；`RUNTIME_OK` / `BUILD_OK` / `DATA_OK` / `DATA_ERROR_OK` 与两张 `CAPTURE_OK` 截图均通过；下一站 M3 | §0 §1 §2 M2 §5 |
| 2026-10-17 | v2.6 | **完成 M3 坦克物理与操控**：新增 `tank_body.gd`（§5 自建刚体：逐格 `M/C/I`、差速驱动、固定步长积分、AABB 硬碰撞与 `4+0.05·\|v\|` 撞墙伤害、后坐冲量、部件摧毁后同帧重算）、`cannon_bank.gd`（§6.5 单发容量、`reload_s` 冷却、口径强匹配）、`projectile_field.gd`（§8.1 线段扫掠弹道）；主场景新增 `DRIVE_LAB` 试驾沙盒页（主菜单五项）；新增 `physics_smoke.gd` / `cannon_smoke.gd`。验收基准改为真实 JSON 重算（`M 61.0 u` / `I 104 064 u·px²` / `v_max 192.1 px/s` / 原地 180° `1.32 s`），M3 验收第 1 条随之更新；新增 §0/§1 状态与 §2 M3 验收结果；下一站 M4 | §0 §1 §2 M3 §4 §5 |
| 2026-10-17 | v2.7 | **新增 M3.5 Android APK 导出尝试（⛔ 阻塞）**：新增 `export_presets.cfg`（预设 `Android`、`arm64-v8a`、`use_gradle_build=false`、debug 签名、输出到 `.me/tmp/main/tankcraft-debug.apk`）；实测 `--export-debug` 返回 `EXITCODE=1` 且 APK 未生成，阻塞于导出模板缺失 + Android SDK 缺失 + `java_sdk_path` 为空（三项均需工作区外安装）；§0 状态改为含 M3.5，§1 新增 M3.5 行，§2 新增 M3.5 完整记录（命令、原始报错、阻塞清单、能力边界）；记录 `javac` 在预构建模板路径下不构成阻塞 | §0 §1 §2 M3.5 §5 |
| 2026-10-17 | v2.8 | **新增 M8 移动端触屏支持（⬜ 未开始，仅设计）**：同步 `design.md` v2.8 新增的 §11.6（输入抽象层、虚拟摇杆、虚拟按键、共存规则、建造页手势、HUD 重排与安全区、UI 缩放、常量落点、五步实现顺序）与 §14.10（十个 `touch` 常量）；§1 新增 M8 行并补里程碑依赖（M8 为横切里程碑，不得排在 M3 之前），§0 状态改为含 M3.5 阻塞与 M8 未开始，M3.5 能力边界段改为指向 §11.6 并注明实现属 M8；新增 R14/R15 两条风险与 6 条真机验收标准；本里程碑不含任何代码实现 | §0 §1 §2 M3.5 §2 M8 §4 §5 |
| 2026-10-17 | v2.9 | **落实用户对 Q24–Q26 的裁定**：Q24 不需要右侧瞄准摇杆（炮管 `aim` 安装后锁定，靠车身转向）；Q25 暂不支持外接手柄；Q26 仅横屏、不做竖屏布局。M8 当前状态段随之改写为“三个开放问题已裁定”并写明只需一套上下分区布局；**M8 仍为 ⬜ 未开始，本轮无任何代码改动** | §0 §2 M8 §5 |
| 2026-10-17 | v3.0 | **完成 M4 弹药输送网络**：新增 `scripts/ammo_network.gd`（端口几何由代码推导、4 邻接 + 反向 side 自动连接、BFS 层级与可达性、20 Hz 四步定序、每段容量 1 发、tee 轮询 / merge in0 优先 / cross 直通优先、口径不匹配逆向退回、弹药库 slot 与改进装置槽位、拥塞与断链查询、确定性事件流）、`tests/ammo_net_smoke.gd`（九阶段覆盖端口几何 + 七条验收，打印 `AMMO_OK`）；`data/globals.json` 新增 `conveyor_strand_grace_s`；`scripts/main.gd` 删除两处 `bank.load_all()` 改由网络供弹并新增管路/在途/拥塞/断链绘制与真实供弹 HUD；`grid_builder.gd` 的 `reset_demo()` 把 `cannon_20` 移到 (9,7) 打通演示供弹链；§0/§1 状态改为 M4 已完成、下一站 M5；M4 段写入七条验收结果与**显式路由面板未实装**（`grid_builder.routes` 仍为死代码，推迟到 M6）、页面证据为脚本驱动 + 截图非人工交互、远征页未接入等边界；新增 R16（`blocked[ammo_id]` 粒度过粗）待办风险 | §0 §1 §2 M4 §4 §5 |
| 2026-10-17 | v3.1 | **修正 M3 转向手感缺陷（角阻尼量纲错误）**：`scripts/tank_body.gd` 的角速度积分原为 `α = (τ - k_ang_drag·ω·|ω|)/max(I,I_MIN)`，把二次阻尼项当作扭矩从 `τ` 里减，而实测 `τ=583200`、`I=104064` 时该项在 `ω=3` 仅 `3.15`，相差 10⁵ 量级 ⇒ 角阻尼事实上为零（松手后 100 s `ω` 仍为 2.9970）。修正为角减速度量纲 `α = τ/max(I,I_MIN) - k_ang_drag·ω·|ω|`，并在 `steer == 0` 时叠加线性松手制动 `- k_ang_brake·ω`；`data/globals.json` 新增 `k_ang_brake: 5.0`（走 `global_number()`，未内联）。`tests/physics_smoke.gd` 新增 `_check_spin_stop()` / `_measure_spin_stop()`，汇总行扩展 `spin_stop_s`。实测 `spin_stop_s` 由「6000 步内从未收敛」变为 **0.62 s**，`turn180_s` 由 1.32 → **1.35 s**（+2.5%，转向敏捷度基本未受影响），单侧履带的战损偏转行为保留（0.5608 rad/s）；M3 验收第 1 条基线与新增第 8 项随之更新；七条 smoke 全部通过、`DATA_ERROR_OK errors=17` 未变；页面证据为脚本预热 + 截图像素检查（驾驶页角速度 −2.95 → −0.25 rad/s），**非人工桌面交互验证** | §0 §1 §2 M3 §5 |
| 2026-10-17 | v3.2 | **完成 M5 战斗结算与可拆解摧毁**：新建 `scripts/damage_system.gd`（881 行 / 30165 字节 / `a9f93935`：命中层序 `module → platform → mobility`、`floorf(maxf(dmg·0.15, dmg − armor·(1−pierce))·10)/10`、三种护盾状态机与 `to_shield/to_body` 分账、AOE / 灼烧 / 减速 / 延迟爆炸 / 分裂、殉爆 `6×slot` 与引擎爆炸 25、残骸 3 s、维修、以驾驶舱为锚点的 4-连通 `detach`、驾驶舱判负短路）；`projectile_field.gd` 增加 `targets` 坦克格集合求交与 `upgrades`/`damage_scale` 随弹；`tank_body.gd` 的 `parts` 补 `armor`/`key` 且 `damage_part()` 返回 `Dictionary` 并回写 `GridBuilder`；`grid_builder.gd` 新增 `force_remove()`；`data/globals.json` 新增 21 个常量；`main.gd` 完成驾驶页接线与 M5 HUD（护盾行、状态行、装填**边沿**脉冲、动效层）；新增 `tests/combat_smoke.gd`（626 行 / 28342 字节 / `0909e0a7`，11 阶段，输出 `COMBAT_OK`，`per_frame_ms=1.65`）。§0/§1 改为 M5 已完成、下一站 M6；M5 段写入 8 条验收的实测结果、6 条有意简化、**自击缺陷（已实证发生、M5 未修、列为 M6 前必修）**与验证边界。七条既有回归逐字未变。如实声明：第 1 条「动效可见」只有截图/像素支撑、`detach` 动效从未被观察；第 7 条仅为「逻辑步进的帧预算内断言通过」；无人工交互验证、无 Android 验证、无 APK | §0 §1 §2 M5 §5 |
| 2026-10-17 | v3.3 | **完成 M6 机器人 AI 与完整对局**：新建 `scripts/duel.gd`（10066 字节 / `7ed7fcaa`，双坦克各持 builder/tank/bank/network/damage、共用弹道场、伤害按 `shooter` 归因）、`scripts/match_state.gd`（5224 / `4fc8785a`，`BUILD/DEPLOY/BATTLE/RESULT`、3 s 部署倒计时、驾驶舱被毁同帧转 `RESULT`）、`scripts/bot_ai.gd`（11154 / `fcca7e75`，三层 2/10/60 Hz、四档难度全读 `globals.ai`、精英与王牌用**割点**分析找断岛点、显式 LCG 不用 `randf`）、`scripts/expedition_run.gd`（10924 / `a8628539`，5 层×3 波、坦克跨层不回滚、`INTERMISSION` +600 cr、升级三选一入 `inventory`、`scrap = price × 0.35` + 击毁 60、驾驶舱被毁立即 `RUN_SUMMARY`、结束清零）；`data/globals.json` 新增 `ai` 块 15 键（4698e68c）；`data/blueprints/` 新增 **12 张 Bot 蓝图**（`DATA_OK` 由 `files=10 blueprints=1` 变为 `files=22 blueprints=13`）；`module_defs.gd` 新增 `block_number` / `block_int`；**修掉 M5 两项遗留**：`projectile_field` 加 `shooter_tag` 过滤治自击、`tank_body` 加 `damage_router` 治“撞墙不连锁”；`main.gd` 新增 `SCREEN_MATCH`、菜单第 3 项「对人机对战」（5→6 项）、对局输入/推进/绘制与 `--screen=match`。新增 `tests/match_smoke.gd`（`MATCH_OK`）与 `tests/expedition_smoke.gd`（`EXPEDITION_OK`），`combat_smoke.gd` 增 `_check_no_self_hit()`。§0/§1 改为 M6 已完成、下一站 M7；M6 段逐条写明 15 条验收的**实测结果与未做到的部分**（验收 2/3 只有参数层证据、无胜率统计；验收 6 以“无持久化即满足”形式成立；验收 12 的手柄部分不适用；验收 13 的按键是 `P` 而非 `Esc`；验收 15 无卡面 UI）与 6 条遗留项。九条回归逐字通过（`DATA_ERROR_OK errors=17` 不变）。截图 `m6_match2.png` 为脚本预热 + 像素检查，非人工交互 | §0 §1 §2 M6 §5 |
| 2026-10-17 | v3.4 | **根据用户新描述把单人模式重写为「肉鸽波次生存」，并新增 M9 承接实现；本轮只改文档不改代码**。用户描述：每波限时生存；地图散落房屋（撞击/炮击摧毁）与坦克残骸（碾过得钱/经验/概率掉配件）；机器人敌人分级，低级坦克简单、高级结构复杂；击败敌人得经验金钱、概率掉自身已有配件；升级弹三选一赠配件 + 改装按钮；**战斗时不允许改装**；波次成功进商店（6 商品、重刷、卖配件、改装）；每 5 波一个 Boss。落地：① 同步 `design.md` v3.4（§1.1/§1.3/§3.1/§3.3/§3.4 全节重写、§4.7 停用、§9.2 `props`、§11.4.4 重写 + §11.4.4.1、§14.8 整节重写为 `survival` 块、ADR-017、Q8 改写、Q27–Q33）；② §0 状态改为下一站 **M9** 并显式声明"新玩法尚无一行代码、`EXPEDITION_OK` 验证的是旧玩法"；③ §1 新增 M9 行（⬜ 未开始，设计已完成零代码）与里程碑依赖改为 `…→ M6 → M9 → M7`；④ **新增 §2 M9 全节**（目标/交付物 12 项/验收 11 条/风险 R12·R17·R18/依赖），并逐条对应到用户原话；⑤ M6 段加 **v3.4 覆盖声明**（旧远征已被推翻，本段降为历史实现记录）；⑥ 风险登记册新增 **R17**（已实测确认的 9 个碰撞/损坏缺陷，列为 M9 前置必修）与 **R18**（多敌人同屏会把 `duel` 从两侧变 N 侧）。M7 段暂未改，仍为「视觉打磨与内容补齐」 | §0 §1 §2 M6 §2 M9 §4 §5 |
| 2026-10-17 | v3.5 | **修复 R17 的 9 个碰撞/损坏缺陷（M9 前置）**。改动三个脚本：`tank_body.gd`（`apply_boundary` 重写为「先收集所有贴墙法向 + 最深穿透 → `_resolve_contact()` 统一结算」治墙角双扣；`_apply_impact_damage` 参数由 `inward` 改为 `outward` 并用 `dot(outward)` 选件治撞墙打错件；`_resolve_obstacle_rect` 改为四面最小穿透沿体推出治穿墙与嵌入；`_resolve_obstacle_circle` 分两分支（圆心在外用 `radius − distance`，圆心在内按 AABB 膨胀取最小面）治少推 1 px；新增 `apply_tank_collision()` 治坦克互撞缺失）、`damage_system.gd`（`_strike` 末尾改用 `_index_of_key` 重定位治 AOE 后索引漂移；`up_delay` 分支上报 `_final_damage` 治伤害高估；`_area_damage` 删除重复 `destroyed` append；新增 `_prune_shields()` 并在 `_on_destroyed` / `_prune_by_parts` 调用治护盾幽灵复活）、`duel.gd`（`step()` 新增 `_resolve_tank_collisions()`）。**修复过程中又发现并修掉 3 个实现级 bug**：矩形障碍选轴仍错（长条墙包含车身时选错轴直接穿墙，实测旧 `final_x=800.00` → 新 `final_x=186.86`）、圆形障碍圆心在 AABB 内时少推 1 px（旧 53.00 → 新 54.00）、互撞接近判定符号反了（旧 `-relative.dot(axis)` 使任何对撞都返回 0）。**`ram_damage_base` 矛盾裁定**：`30+0.06×Δv` 是 §6.8 **喷射冲撞**专属，§8.7 坦克对撞无基数项；`data/globals.json` 中两个键更名为 `thruster_ram_damage_base` / `thruster_ram_damage_per_speed`，`tank_body.gd` 删除 `_ram_base`。**永久回归**：`tests/physics_smoke.gd` 新增 5 项（363→570 行）、`tests/combat_smoke.gd` 新增 4 项（667→794 行）。十项 smoke 逐字通过：`PHYSICS_OK mass=61.0 inertia=104064 v_max=192.1 turn180_s=1.35 spin_stop_s=0.62` / `CANNON_OK shots=3 reload76=1.10 range=1400` / `AMMO_OK` / `BUILD_OK cells=43 modules=6 mobility=1 spent=698 mass=62.9` / `DATA_OK files=22 modules=45 ammo=5 upgrades=9 arenas=3 blueprints=13` / `DATA_ERROR_OK errors=17` / `COMBAT_OK` / `MATCH_OK` / `EXPEDITION_OK` / `RUNTIME_OK scrap=751.0 level=1 cells=41 modules=7 mobility=1`。同步 `design.md` v3.5（§6.8 明确两套公式归属、§8.7 改写含四条修正说明与修订记录表、§17 追加行）与 `agent_note.md`。如实声明：全部验证为**无头 smoke + 临时探针实测**，探针跑完已删除；**无人工交互验证、无 Android 验证、无 APK** | §0 §4 §5 |
| 2026-10-17 | v3.6 | **完成 M9 波次生存并同步 R18**。① §0 状态改为 M9 ✅、下一站 M7；② §1 M9 行改为 ✅ 已完成（v3.6）并写入 R18 同期完成；③ **§2 M9 全节重写**为已完成状态：状态行 / 已交付清单 / **11 条验收标准的逐条实测结果表**（其中第 1 条「跑 6 波」与第 6 条「房屋撞击摧毁」如实标为 🟨 部分验证）/ **7 条已知缺口**（改装 UI 入口不存在、商店稀有度权重方向反、`safe_radius` 未被读取、`boss_armor` 未实现、房屋撞击无专项断言、无开局建造页、无人工/Android 验证）/ 旧交付物说明；④ §4 风险登记册 **R18 改为 ✅ 已解决（v3.6）**并写入具体改造与回归项，R12 保持开放并补四个新缺口。**回归**：11 项逐字通过（`PHYSICS_OK` / `CANNON_OK` / `AMMO_OK` / `BUILD_OK` / `RUNTIME_OK` / `DATA_OK files=23 … blueprints=14` / `DATA_ERROR_OK errors=30` / `COMBAT_OK` / `MATCH_OK` / `EXPEDITION_OK` / **`SURVIVAL_OK`**）。**如实声明**：四张页面截图（`m9_battle.png` / `m9_levelup.png` / `m9_shop.png` / `m9_summary.png`，均 1920×1080）为**脚本预热 + 像素检查，非人工交互验证**；**未在 Android 上验证，无 APK**；`DATA_ERROR_OK errors=17→30` 是 fixture 从 `expedition` 改为 `survival` 块的预期后果（必需键从 5 个变 36 个） | §0 §1 §2 M9 §4 §5 |
| 2026-10-17 | v3.7 | **补上改装 UI 入口（M9 唯一遗留的明确未交付需求）**。① **逻辑层**：`scripts/survival_run.gd` 33633 → 38167 B（941 行）——新增 `STAGE_MODIFY` 子阶段与 `modify_return_stage` / `modify_credit_baseline` / `modify_spent_total`；`enter_modification()` 只接受 `LEVEL_UP` / `SHOP`；`modification_cost()` 按**净增建造支出**（`credits_spent() − 基线`）；`leave_modification()` 回到**进入时的阶段**；`mount_from_inventory()` 按模块 `layer` 分发 + 阶段门槛 + 余额不足 `undo()` 回滚；新增 `place_platform_at()` / `dismantle_at()`（后者用 `validation_report()` 兜底 I5/I7/I8）；`commit_modification()` 从空壳变真实扣款。② **表现层**：`scripts/main.gd` 131844 → 150063 B（3296 行）——升级页卡片下方与商店页标题行右侧各一个「M 改装坦克」按钮（`M` 键或左键）；新增改装页（库存列表 / 24×24 网格 / 金钱·支出·质量·校验信息栏）与 `_handle_survival_mouse()` 接入 `_handle_mouse`；`--screen=survival_modify` 截图钩子；几何与坐标换算自带（`SURVIVAL_MODIFY_*`），**不复用** `_draw_grid()` / `_grid_rect()` / `_mouse_to_cell()`。③ **明确不做的两样**：不暴露 `GridBuilder.buy_mass_upgrade()`（`budget_enabled = false` 时它免费升上限）；不提供矩形/直线铺平台与撤销重做按钮（已写入 design §3.4.7「已知简化」）。④ **回归**：`tests/survival_smoke.gd` 25107 → 30724 B（645 行），新增 `_check_modification()`（85 行 / 26 条断言）；**11 项逐字通过**：`PHYSICS_OK mass=61.0 inertia=104064 v_max=192.1 turn180_s=1.35 spin_stop_s=0.62` / `CANNON_OK shots=3 reload76=1.10 range=1400` / `AMMO_OK` / `BUILD_OK cells=43 modules=6 mobility=1 spent=698 mass=62.9` / `DATA_OK files=23 modules=45 ammo=5 upgrades=9 arenas=3 blueprints=14` / `DATA_ERROR_OK errors=30` / `COMBAT_OK` / `MATCH_OK` / `EXPEDITION_OK` / `RUNTIME_OK scrap=751.0 level=1 cells=41 modules=7 mobility=1` / `SURVIVAL_OK`。⑤ 文档：§0 代码状态与阻塞项、§1 M9 行、§2 M9 状态/已交付/验收表第 3 条/缺口表第 1 条、§4 R12 缺口列表同步。**如实声明**：三张截图（`m9_modify.png` / `m9_levelup_btn.png` / `m9_shop_btn.png`，均 1920×1080）为**脚本驱动 + 像素检查，非人工交互验证**——鼠标点按钮与键盘贴装只有 headless 断言覆盖，**从未人工点过**；**未在 Android 上验证，无 APK**；`boss_armor` 仍未实现、`safe_radius` 仍未被读取、商店稀有度权重方向仍反 | §0 §1 §2 M9 §4 §5 |
| 2026-10-17 | v3.8 | **修用户报告的界面四项（不新增玩法）**。用户原话：「游戏打开时默认最大窗口，各种菜单交互非常难用，鼠标都没有良好适配，而且菜单中很多元素位置错误产生重叠，生存模式中的建筑模式为什么没有复用主菜单的建造系统」，并澄清「我的意思是游戏打开时应该默认最大窗口」。① **窗口**：`project.godot` 新增 `window/size/mode=2`（`WINDOW_MODE_MAXIMIZED`）+ `window/size/resizable=true`，1280×720 override 仅作还原尺寸；`main.gd` 的 `_ready()` 再显式确认并打印实测值。实测 **`WINDOW_MODE mode=2 size=(1842, 1057)`**（mode 2 即 MAXIMIZED，尺寸随屏幕变化而非跟随 override）。`stretch/mode="viewport"` + `aspect="keep"` 保证设计坐标恒为 1920×1080，最大化不动任何页面坐标。② **鼠标**：新增 `_hover_survival_button` / `_hover_modify_button` / `_hover_menu_difficulty` 与 `_handle_survival_mouse()`——升级页三张卡点击 → `take_level_choice(index)`、商店页六个商品格点击 → `buy_shop_slot(index)`、两页的「M 改装坦克」与改装页「完成改装」按钮均可点；滚轮/拖拽门槛由 `_screen == SCREEN_BUILD` 改为 `_in_build_editor()`。**v3.8 之前升级页 / 商店页 / 改装页没有任何鼠标路径**。③ **重叠**：主菜单「难度：…」（y=654）与提示（y=700）都压在六行菜单最后一行「退出」（616–688）上；现难度改为菜单**下方**独立可点按钮（`MENU_ROW_Y + 6×56 + 16 = 712`，460×44），提示下移到 y=800；并补上 `A`/`D`/`←`/`→` 切难度（**旧提示行写了「A / D 切换难度档」，但 `_handle_key()` 的 `SCREEN_MAIN` 分支里根本没有这个键**）。改装页「完成改装」按钮由 y=96 上移到 y=80 以避开网格 `cursor NN:NN` 读数。④ **改装页复用建造系统**：抽出 `_editor_model()` / `_in_modify_mode()` / `_in_build_editor()`，将 16 个编辑器函数里的 48 处 `builder.` 改为 `_editor_model().`；`_draw_survival()` 在 `STAGE_MODIFY` 时调 `_draw_build()` + `_draw_modify_overlay()`，键盘走 `_handle_build_key()`（仅拦 `Ctrl+S`/`Ctrl+O`），鼠标转发给 `_handle_mouse()`；新增改装期支付分支 `_option_ids()`（只列库存本层件）/ `_mount_selected_inventory()` → `survival.mount_from_inventory()` / `_place_platform_cell_at()` → `survival.place_platform_at()` / `_remove_current()` → `survival.dismantle_at()`；**删掉整套独立改装页**（15 个 `_survival_modify_*` 函数 + 六个 `SURVIVAL_MODIFY_*` 常量，约 183 行），`main.gd` 150063 B / 3296 行 → **148460 B / 3261 行**（在新增窗口断言、鼠标支持与难度按钮的同时净减少）。⑤ **撤回 v3.7 的两项「手感简化」**：改装页现在随建造页一起拥有矩形/直线铺平台、拖动铺、`Ctrl+Z`/`Ctrl+Y` 撤销重做与 I1–I10 错误列表格式，原文「无矩形/直线工具、无撤销重做」**不再成立**。⑥ **回归**：全套 11 项逐字通过（`AMMO_OK` / `BUILD_OK cells=43 modules=6 mobility=1 spent=698 mass=62.9` / `CANNON_OK shots=3 reload76=1.10 range=1400` / `COMBAT_OK` / `DATA_ERROR_OK errors=30` / `DATA_OK files=23 modules=45 ammo=5 upgrades=9 arenas=3 blueprints=14` / `EXPEDITION_OK` / `MATCH_OK` / `PHYSICS_OK mass=61.0 inertia=104064 v_max=192.1 turn180_s=1.35 spin_stop_s=0.62` / `RUNTIME_OK scrap=751.0 level=1 cells=41 modules=7 mobility=1` / `SURVIVAL_OK`），与 v3.7 基线一致；`tests/survival_smoke.gd` 未改（26 条改装断言仍全过）。同步 `design.md` v3.8（新增 §11.4.2.1、改写 §3.4.7、§2.3 补窗口配置、§17 追加行）与 `agent_note.md`。**如实声明**：三张截图（`ui_menu2.png` 161034 B / `ui_modify3.png` 251706 B / `ui_levelup2.png` 159991 B，均 1920×1080）为**脚本驱动 + 像素检查，非人工交互验证**——本轮新增的鼠标点击与键盘贴装路径只有 headless 断言与代码检查覆盖，**从未人工点过任何控件**；**未在 Android 上验证，无 APK**；`boss_armor` 仍未实现、`safe_radius` 仍未被读取、商店稀有度权重方向仍反 | §0 §2 M9 §5 |
| 2026-10-17 | v3.9 | **修用户报告的「发射炮弹似乎不能对敌人造成伤害」并重做生存页战斗 UI**（用户原话：「优化战斗系统，发射炮弹似乎不能对敌人造成伤害，生存模式的 UI 也需要优化，要有一个小窗口显示一个坦克的镜像，展示坦克每个模块的状态」）。① **定位（先拿数字再改）**：三个临时探针实测——命中链路本身**正常**（`PROBE impact_tank tag=enemy_1 part_index=28`，单发 `damage_dealt_player=5.00`）；但整波 45 s 连续开火只有 `fired=89 hit_tank=78 player_damage_total=435.50 kills=0`。根因两层：**数值**（`PROBE3 recruit1 platform_cells=30 total_platform=1350 modules=485 grand_total=1835`；`cal_20 per_hit_vs_platform=5.0 hits_to_kill_all=367`；`cal_20_ttk_s=128.4` > 波次上限 45 s ⇒ 数学上不可能击毁）+ **反馈**（敌车整台只画一种颜色不看 HP、命中坦克时「最近事件」不更新、HUD 无累计伤害读数）。② **数值修复**：`scripts/survival_run.gd` 38167 → 40812 B，新增 `STARTER_SIZE` / `STARTER_MOBILITY` / `STARTER_MODULES` + `static func build_starter(model)`，起始车 8×2 平台 + `track_light` + `engine_small` + `cockpit_light` + `ammo_factory_76` + `conveyor_straight` + `cannon_76`；`main.gd` 的 `_build_survival_starter()` 与 `tests/survival_smoke.gd` 的 `_make_rig()` **都转调它**（唯一布局来源）。探针实测同一波内 `hits=25 destroyed=21 parts 37->14 damage=1397.5 kills=1 enemy_alive=false`。③ **表现层**：`scripts/main.gd` 148460 → 160536 B——`_draw_survival_hull()` 改为逐部件按血量着色（`_survival_hull_colour()`，>60% 队伍色 / 25–60% 琥珀 / <25% 红，填充透明度 `0.14+0.20×ratio`）；`_survival_step()` 新增 `impact` / `destroyed` / `core_destroyed` / `shield_hit` 分支（文案区分「命中 enemy_N」/「本体被命中」/「击毁敌 X」/「自损 X」）；新增 `_survival_fx` 瞬时动效 + `_hit_flash_at` 命中闪光（`HIT_FLASH_TIME=0.14 s`，倒计时只在固定步长里推进，不用 `randf`）；新增 `_survival_cell_world()` 把事件的建造格坐标经该侧刚体转世界坐标；HUD 左列新增「总输出 N」。④ **坦克镜像面板**：`SURVIVAL_MIRROR_RECT = Rect2(1560, 436, 312, 400)`（右 HUD 下半部；键位提示到 y=410、`DRIVE_HUD_RIGHT` 到 y=852，不重叠）+ `_draw_survival_mirror()`：俯视镜像（正北朝上、等比缩放居中、逐格按血量填充、质心十字 + 朝头线）+「平台 N 格 · 模块 N · 行进 N」+「存活格均血 N%」进度条 + 逐部件状态行（按血量比升序、最残的排前面、★ 标驾驶舱、条形 + 百分比，`MIRROR_ROW_VISIBLE=6`）。⑤ **截图钩子**：`_survival_capture_warmup()` 从「第 60 步开一炮」改为「原地持续开火 420 帧」——旧截图里根本看不到损伤，用户看到的「没伤害」有一部分就是这种截图造成的。⑥ **回归**：`tests/survival_smoke.gd` 30724 → 32423 B，新增 `_check_player_fire_damage()`（`fire_hits_landed` / `fire_damage_dealt` / `fire_destroys_parts` / `fire_kill_within_wave`）；**11 项逐字通过**：`AMMO_OK` / `BUILD_OK cells=43 modules=6 mobility=1 spent=698 mass=62.9` / `CANNON_OK shots=3 reload76=1.10 range=1400` / `COMBAT_OK` / `DATA_ERROR_OK errors=30` / `DATA_OK files=23 modules=45 ammo=5 upgrades=9 arenas=3 blueprints=14` / `EXPEDITION_OK` / `MATCH_OK` / `PHYSICS_OK mass=61.0 inertia=104064 v_max=192.1 turn180_s=1.35 spin_stop_s=0.62` / `RUNTIME_OK scrap=751.0 level=1 cells=41 modules=7 mobility=1` / `SURVIVAL_OK`。同步 `design.md` v3.9（新增 §3.4.8 起始坦克与 §11.4.4.2 镜像面板与命中反馈、§17 追加行）与 `agent_note.md` v3.7。**如实声明**：截图 `ui_surv4.png`（1920×1080，`CAPTURE_OK` 见 c4.log）为**脚本驱动 + 像素检查，非人工交互验证**——本轮新增的命中反馈与镜像面板从未人工点过/看过；镜像面板只展示玩家自己，**敌人没有镜像**；四个临时探针跑完已删除；**未在 Android 上验证，无 APK**；`boss_armor` 仍未实现、`safe_radius` 仍未被读取、商店稀有度权重方向仍反 | §0 §2 M9 §5 |
| 2026-10-21 | v3.10 | **架构模块化审查（只审查不改码）+ 修复审查查出的两处真实缺陷**。用户原话：「检查整体代码架构是否是模块化实现」，随后「继续」。① **审查结论（实测）**：领域层是真模块化——`scripts/` 20 文件约 260 KB，**54 条 preload 边构成单向 DAG**（`data_validator ← data_registry ← module_defs` → 领域层 9 脚本 → `main.gd`），**无循环依赖**，**反向引用（任何脚本 preload `main.gd`）零命中**；领域层 9 脚本 5–41 KB 且**每个都被独立 headless smoke 直接驱动**（`physics`→`tank_body`、`cannon`→`cannon_bank`+`projectile_field`、`ammo_net`→`ammo_network`、`build`→`grid_builder`、`combat`→`damage_system`、`match`→`duel`+`match_state`+`bot_ai`、`survival`→`survival_run`、`data`/`data_error`→`data_registry`+`data_validator`）；数据访问纪律良好（`block_*`/`global_*` 共 137 处，直接 `registry.globals` 仅 8 处、6 处合规）。**但页面层不是**：`main.gd` 160536 B / 187 函数 / 69 const / 约 84 var = `scripts/` 的 **61.7%**，一个类承载菜单、设置、建造编辑器、旧远征页、试驾页、对战页、生存页 5 子页、输入总路由与 7 个截图钩子，**页面间零语言级隔离**。② **P0 修真实 bug**：`_match_step()` 结尾误调 `_drive_tick_fx()`（只递减 `_drive_fx`）；`_match_fx` 的所有出现位置（141/1026/1127/1146/1997/2022）**无一递减 `left`**，`_draw_match_fx()` 用 `left/life` 算 alpha 故恒为 1，对战页脱落环**永久常驻满亮度**。新增 `_match_tick_fx()` 并改调。③ **P1 消除重复**：三份逐行相同的 FX 衰减合并为 `static func _fx_decay(list, step_time)`；三段同构坦克绘制合并为 `_draw_hull_shared(hull, origin, heading, scale_factor, colour_fn, alpha_fn, offset_fn, cell_hook)`（`_draw_match_hull` 20→7、`_draw_drive_hull` 26→9、`_draw_survival_hull` 18→7 行）。`main.gd` 160536 → 162148 B。**顺带消除了「v3.9 的逐格 HP 上色没回灌到对战页」的架构原因**。④ **像素级等价证据**：`ui_surv5.png`（177553 B）sha256 `bfa0382d4181ada5396da6574bae50ae5ce0f3be01a73a4b3e0cc4cffc52a77c`，与重构前 canonical `ui_surv4.png` **逐字节完全相同**。⑤ **回归**：11 项全绿且数值与基线一致。⑥ **审查查出但本轮未修（新增到 §2 M9 缺口）**：`main.gd` 上帝类；旧远征页约 183 行绘制副本（`_draw_expedition_grid` / `_draw_expedition_sidebar`）；`main.gd:195/403` 读**已删除的 `expedition` 块**并硬编码 `* 4.0`；`main.gd:1872` 文案仍宣称「价格来自 data/globals.json 的 expedition 段」（**当前为假**）；`MATCH_DIFFICULTY` / `DRIVE_ARENA_ID` 硬编码在页面层；死依赖 `runtime_builder`（:5）/ `expedition_run`（:15）；死代码 `tank_visual` 9284 B / `hud` 3171 B / `grid_field` 1452 B（共 13907 B / 310 行、零引用）；遗留测试 `_tmp_capture_check.gd` / `_tmp_drive_page.gd`。**如实声明**：对战页动效「随时间真的淡出」仍只有**代码层证据**（单帧截图无法证明时间维度），**未做连续帧观察、未做人工桌面交互验证**；**未在 Android 上验证，无 APK**；`boss_armor` / `safe_radius` / 商店稀有度权重方向三项旧缺口未动 | §0 §2 M9 §5 |
| 2026-10-21 | v3.11 | **P3 清理死代码与死依赖 + P2 抽取 FX 层**（用户指示：「继续P2P3」）。① **P3a**：删 5 个零引用文件——`tank_visual.gd` 9284 B / `hud.gd` 3171 B / `grid_field.gd` 1452 B（共 13907 B / 310 行）+ `tests/_tmp_capture_check.gd` 2208 B + `tests/_tmp_drive_page.gd` 4094 B，合计 20209 B；删前经 `Get-ChildItem scripts,tests,scenes,docs -Recurse | Select-String` 确认代码零命中、`project.godot` 无 autoload 引用。② **P3b**：`main.gd` 162148 → 143127 B（−19 KB / −401 行）——移除 `RuntimeBuilder` / `Expedition` 两个死 preload、`SCREEN_EXPEDITION` / `EXP_PANEL` / `EXP_STATUS` 常量、`var runtime` + 5 个 `_exp_*` 变量、**16 个远征控制函数 + 7 个远征绘制函数**（含只被远征页用的 `_draw_dashed_rect`）与全部 `SCREEN_EXPEDITION` 分支（`_ready`/`_process`/`_input`/`_handle_key`/`_set_screen`/`_update_hover`/`_handle_mouse`/`_draw`/`_handle_capture_request`）；**顺带消除读已删除 `expedition` 块 + 硬编码 `* 4.0` 的两处死代码与那句「价格来自 data/globals.json 的 expedition 段」假文案**。`expedition_run.gd` / `runtime_builder.gd` 脚本本体与两个 smoke 保留。③ **P2**：新建 `scripts/fx_layer.gd`（2291 B / 68 行，零依赖）把三页各持一份的 FX 生命周期合并为 `push()`/`step()`/`clear()`/`ratio()`；`main.gd` 三处改为 `var _*_fx := FxLayer.new()`、push 与 tick 各缩为一行、删掉 `static _fx_decay()`（21 行）。④ **顺带修两个真实缺陷**：`_update_hover()` 一整段重复代码（两次初始化 + 两次 `SCREEN_MAIN` 分支）已合并；删远征分支时误吞 `_process()` 里 `if` 的块体已补回。⑤ **像素级等价**：`p2_surv.png` sha256 `bfa0382d4181ada5396da6574bae50ae5ce0f3be01a73a4b3e0cc4cffc52a77c` 与 canonical `ui_surv4.png` 逐字节相同（P3b、P2 两阶段各验一次）。⑥ **回归**：三轮各 11 项全绿且数值与基线逐字一致（`a_*.log`/`b_*.log`/`c_*.log`）。⑦ **规模**：`main.gd` 160536 → **142618 B（−11.2%）**，函数 187 → 170，`scripts/` 20 → 16 文件；§2 M9 缺口第 11–14 条（远征页副本、`expedition` 死块、死依赖/死代码、遗留测试）**均已关闭**。⑧ **未做**：按页面拆文件经评估属架构级改造（需页面状态容器、74 个 `var` 重新归属、`_editor_model()` 跨页分流重设计、`_draw`/`_input`/`_process` 必须留在 `Node2D`、7 个预热钩子需重新定位），风险高于本轮清理项且无像素级等价证据可依，故未执行。**如实声明**：对战页动效「随时间真的淡出」仍只有**代码层证据**（单帧截图无法证明时间维度），**未做连续帧观察、未做人工桌面交互验证**；**未在 Android 上验证，无 APK**；`boss_armor` / `safe_radius` / 商店稀有度权重方向反三项旧缺口未动 | §0 §2 M9 §5 |

| 2026-10-21 | v3.12 | **P2/P3 收尾审计：修正文件计数 + 清理孤儿 `.uid` + 修复截图证据链的真实缺陷**。① **纠正 v3.11 的算术错误**：v3.11 写「`scripts/` 20 → 16 文件」是错的——P3a 删的 5 个文件中只有 **3 个在 `scripts/`**（`tank_visual.gd` / `hud.gd` / `grid_field.gd`），另 **2 个在 `tests/`**（`_tmp_capture_check.gd` / `_tmp_drive_page.gd`）；再算上 P2 新建的 `fx_layer.gd`，正确算式为 `20 − 3 + 1 = 18`。**实测确认：`scripts/` 18 个 `.gd`、`tests/` 11 个 `.gd`**。历史行按 append-only 不改，以本行为准。② **清理 5 个孤儿 `.uid`**：P3a 只删了 `.gd`、`.uid` 残留——`scripts/grid_field.gd.uid`（`f977200b`）/ `scripts/hud.gd.uid`（`d25e9d17`）/ `scripts/tank_visual.gd.uid`（`dc971614`）/ `tests/_tmp_capture_check.gd.uid`（`831d6747`）/ `tests/_tmp_drive_page.gd.uid`（`a80ac7da`），均已删除，删后 `.uid` 与现存 `.gd` 一一对应、无孤儿。③ **发现并修复证据链本身的真实缺陷（本轮最重要）**：同一条 `--capture` 命令连续两次产出**不同字节**——`g1_surv.png` 177682 B vs `g2_surv.png` 177340 B，逐像素差 **12993 个**、最大通道和 **546**、bbox 349,448–622,628。根因：`_survival_capture_warmup()` 跑完固定 420 步后返回，而 `_capture_next_frame()` 还要 `await` **30 帧**才取图，这 30 帧里 `_process()` 仍按**真实 delta** 推进 `_*_simulate()` 并累加 `_time`——**预热步数固定、取图时刻不固定**。**这意味着 v3.10/v3.11 反复引用的「四张截图 sha256 完全相同 = 重构无可见变化」在原理上不成立，那些 hash 相同只是碰巧。** ④ **修复**（`main.gd` 142618 → 143963 B）：新增 `var _capture_frozen := false`；`_process()` 开头 `if _capture_frozen: return`；`_handle_capture_request()` 在预热后、取图前设 `_capture_frozen = true`，并**必须同时把 `_screen_opacity` / `_focus_rail_alpha` 显式置终值**（否则冻结在淡入起点，实测截图只有 8587 B、几乎全黑）。⑤ **修复后验证**：`g5_surv.png` 与 `g6_surv.png` 连续两次**逐字节相同**（178280 B，sha256 `e56ce92faa5911e5da72d26d8aa98935597a5cd373ecac487431ce00073de6ad`）——**可复现性成立**。⑥ **代价（如实声明）**：新截图与旧 canonical `ui_surv4.png`（177553 B）**不再相同**——剩余时间显示 38.0 s 而旧图 37.3 s，因为冻结时机比旧版晚若干帧。**旧 canonical 作废**，新基线为 `g5_surv.png`。⑦ **回归**：`--check-only` 四次均 78 B / `6ca5b6ba`；11 项 smoke 全绿且数值与历史基线**逐字一致**（`g5sum.txt`）；对战页 `g7_match.png`（135548 B）、试驾页 `g7_drive.png`（213476 B）、升级页 `g7_levelup.png`（203203 B）均 `CAPTURE_OK`、无 `SCRIPT ERROR`，且经 `Image_View` **目视确认画面完整**。⑧ **本轮自伤 1 次已修**：改 `_process()` 时 `replace` 的 `end_line` 多算把整个函数体删掉（142509 B），重新 `File_Read` 定位后按原文完整补回，再验证 27 行结构完整。**如实声明**：截图仍为**脚本驱动 + 像素检查，非人工交互验证**；对战页动效「随时间真的淡出」仍只有**代码层证据**；**未在 Android 上验证，无 APK**；按页面拆文件（P2 后半）仍未做 | §0 §5 |
| 2026-10-21 | v3.13 | **截图证据链重验：7 个钩子的可复现基线 + 与历史截图的差异归因**（用户对上一轮建议回复「按你说的做」）。① **先确认不可逆限制**：工作区**没有 git 仓库**（`NO_GIT_DIR`、`git rev-parse` 报 `fatal: not a git repository`），v3.10/v3.11 旧代码已不存在，**无法重做真正的 before/after**。本轮只做两件能做的事。② **可复现基线**：7 个 `--capture` 钩子各连拍两次，**7/7 逐字节相同**——`drive` 213476 / `match` 135548 / `survival` 178280 / `survival_levelup` 203203 / `survival_shop` 236008 / `survival_summary` 196813 / `survival_modify` 253691。其中 `survival_shop` / `survival_summary` / `survival_modify` 又在**不同进程**重跑，仍 `SAME`。③ **差异归因（关键）**：新基线 vs 历史截图做**分区**比对，静态 UI 区**零差异**——生存页右 HUD `0` / 状态栏 `0`；对战页右 HUD `0` / 状态栏 `0`；非零部分为左 HUD（3068 / 2698，含计时/速度/总输出等随模拟变化的数字）与战场区（30598 / 37053）。④ **决定性证据**：生存页两张图的 `SURVIVAL_MIRROR_RECT`（1560,436,312,400）裁切后**逐字节相同**（均 56256 B，sha256 `df09e63e6f56025a…`）——镜像面板的逐格血量填充、质心十字、朝头线、部件行、条形图这一整套绘制逻辑**一字未变**。⑤ **试驾页右 HUD 的 16379 像素差异已目视核对**：布局与文字完全一致，差异仅在于装填状态「装填 0.25s」vs「待发」及进度条长度，以及左 HUD 的 `126.7` vs `145.8 px/s`、`339°` vs `330°`——**模拟状态差，非渲染逻辑差**。⑥ **结论**：冻结修复只改了「取图时刻」，未动任何绘制代码；历史与当前截图的全部差异可归因于**模拟多推进了若干步**，而非渲染回归。这比原先「sha256 相同」的论证更强：原先是碰巧，现在是已知差异来源、且静态区逐字节相同。⑦ **新增局限声明**：以上只证明「静态 UI 区渲染未变」，**不是**「所有像素都未变」；战场区的坦克位置、弹道、残骸状态本就会随模拟推进变化，无法用整图 hash 验渲染回归。要验那部分，需先把预热步数参数化，而当前 `_capture_frozen` 只冻结「取图前」，**未冻结「预热步数可参数化」，后者仍未做**。新增 `docs/design.md` §11.4.9.1 记录完整重验。**如实声明**：所有截图仍为**脚本驱动 + 像素检查，非人工交互验证**；对战页动效「随时间真的淡出」仍只有**代码层证据**；**未在 Android 上验证，无 APK** | §0 §5 |
| 2026-10-21 | v3.14 | **`--steps=N`：预热步数参数化，补齐战场区渲染验证盲区**（用户「继续」）。① **动机**：v3.13 声明「战场区无法用整图 hash 验渲染回归」——因为预热步数写死在各页 `for ... in range(N)` 里，没法在同一模拟状态下截两次。② **实现**（`main.gd` 143963 → 146185 B）：新增 `var _capture_steps := -1`、`_requested_capture_steps()`（解析 `--steps=N`，非法值打 `CAPTURE_BAD_STEPS` 回退）、`_warmup_steps(default_steps)`；三个预热函数改为调它，默认值仍写在调用处（试驾 90 / 对局 150 / 生存 420）；对局页开火时机由写死的第 60 步改为 `maxi(total_steps * 2 / 5, 1)`。③ **三个对照全部成立**：`--steps=420` 两次 **SAME**（178280 B / `e56ce92f…`）；`--steps=200` **DIFF**（173254 B / `0ac8f3d1…`）；**不传参数与改前基线逐字节相同**（v3.13 的 7 张基线仍有效）。④ **盲区补齐的关键证据**：战场区（320,168,1216,684）裁切后，`--steps=420` 两次均 **92207 B / `b16c7e15aaebbd6a` 逐字节相同**，`--steps=200` 为 91959 B（不同）——**战场区渲染本身是确定性的**，之前的「不可验证」只是缺了步数参数化。⑤ **今后渲染回归流程**：改动前后各跑同一 `--steps=N`，裁战场区比 sha256。⑥ **回归**：`--check-only` 78 B / `6ca5b6ba`；11 项 smoke 全绿且数值与基线逐字一致。**如实声明**：本轮交付的是**能力**，**未做具体的「改动前后」对比**（旧代码不存在、无 git）；`--steps` 只影响 `drive` / `match` / `survival` 三个跑预热的钩子，另四个页面钩子直接构造状态、不受影响；截图仍为**脚本驱动 + 像素检查，非人工交互验证**；对战页动效「随时间真的淡出」仍只有**代码层证据**；**未在 Android 上验证，无 APK** | §0 §5 |

| 2026-10-21 | v3.15 | **生存模式坦克阵容重做**（用户：「修改生存模式初始玩家坦克和敌人的坦克，让坦克的配件、摆放更合理，初始敌人的坦克过于大应该再缩小，而且敌人不断地生成，不同等级的敌人的坦克不同，要设计多种坦克」）。① **起始车**：`STARTER_SIZE` 8×2 → **6×4**（24 格）；两条 `track_heavy` @ (2,0)/(2,3) 横跨 x=2..3，履带中心压在质心横坐标上（旧车只有一条 `track_light` 贴在车身最左端，`drive_metrics()` 的 `side = signf(forward.cross(offset))` 会让净推力与扭矩同时畸变）；`ammo_factory_76(0,1) → conveyor_straight(2,1) → cannon_76(3,1)` 沿 y=1 逐格相邻，`cockpit_light(2,2)` + `engine_small(3,2)` 居中。**不放弹药库**：实测殉爆 `6×8 = 48` 伤害、半径 2.5 格，带库版本 21.8 s 内被连锁炸死（`probe_roster2`）。② **13 张 Bot 蓝图全部重写**：招募级 30 格 → **14/20/12**（十字/方块/楔形）、老兵 24/32/20（长车身/方车/四履带）、精英 33/36/23、王牌 44/40/40；**每档三张是三种不同轮廓**（按平台格集合判重），`credits_spent` 由生成脚本按 `_blueprint_price()` 口径重算（脚本内置端口连通性 / 平台覆盖 / 4-连通自检，`GEN_DONE` 无告警）。③ **敌人持续生成**：`survival` 块新增 `enemy_quota_multiplier 3.0` / `enemy_reinforce_delay_s 5.0`；新增 `enemy_quota_for()` / `_enemies_spawned` / `_enemy_reinforce_timer` / `_reinforce_enemies()`；`start_wave()` 只出同屏上限，之后按间隔补兵。**通过条件变更**：由「场上没敌人就立即通过」改为「计时归零」**或**「配额耗尽且场上无敌人」——旧规则与持续补兵互斥。④ **测试**：`survival_smoke` 修 3 处因布局变化失真的断言（驾驶舱格不再写死 (2,1)；`_check_wave_passes_on_timer` 改 `enemy_ai.clear()`；`_check_player_fire_damage` 改为真实打法——静止开火实测命中 4 次 / 击杀 0，会瞄准时 12–22 次 / 击杀 1–2 台），新增 `_check_reinforcement` 与 `_check_roster_shape`。⑤ **回归**：`--check-only` 78 B / `6ca5b6ba`；11 项 smoke 全绿且数值与基线逐字一致。⑥ **截图**：`n_surv_a.png` / `n_surv_b.png` 均 **176395 B / `fdf2c020753758cf…`**（`--steps=420` 两次逐字节相同）；目视确认玩家青色 6×4 双履带车、两台缩小且轮廓不同的品红敌车、镜像面板「平台 24 格 · 模块 5 · 行进 2」。**如实声明**：截图仍为**脚本驱动 + 像素检查，非人工交互验证**；持续补兵只有 headless 断言，**没有人工玩一整波观察补兵**；**未在 Android 上验证，无 APK**；`boss_armor` / `safe_radius` / 商店稀有度权重方向三项旧缺口未动 | §0 §2 M9 §5 |
| 2026-10-21 | v3.16 | **更正 v3.15 的两个数字（append-only：历史行不改，以本行为准）**。① 「带弹药库的版本 21.8 s 内被殉爆连锁 13 次炸死」→ **36.4 s**：唯一支撑证据 `probe_roster2.txt` 记录 `PROBE_DEATH_STEP 2185`，60 Hz 下 = 36.4 s；21.8 s 无任何工件支持，22.7 s 是 `probe_roster5` 里**驾驶舱放在 (5,1) 的试验布局**的死亡时间，被误挪用到弹药库殉爆这条上。② 「会瞄准时命中 12–22 次、击杀 1–2 台」→ **命中 8–22 次、击杀 0–2 台**：`probe_gain.txt` 的增益扫描为 `GAIN 0.6` 11 命中 / 0 击杀、`GAIN 1.0` 8 / 0、`GAIN 1.5` 22 / 1、`GAIN 2.5` 18 / 1、`GAIN 1.0 thr 0.4` 13 / 1、`GAIN 2.5 thr 0.4` 10 / 2——下界是 8 与 0，不是 12 与 1。③ **改动范围**：`scripts/survival_run.gd` 的 `STARTER_MODULES` 注释块、`docs/design.md` §3.4.8 两段（普通散文直接改），以及本文件 §0/§5 与 `agent_note.md` §5/§9 的追加文字。**代码、常量、测试零改动**，故未重跑 smoke、未重拍截图——v3.15 的验证结果继续有效。 | §0 §5 |
| 2026-10-21 | v3.17 | **修用户报告的栈溢出崩溃：生存页鼠标处理无限递归**（用户原话：`SCRIPT ERROR: Stack overflow`，栈形 `_handle_mouse(main.gd:587) ↔ _handle_survival_mouse(main.gd:3107)` 交替，最终炸在 `data_registry.get_module()`）。① **根因**：v3.8「改装页复用建造系统」时把转发做成了**双向**——`_handle_mouse()` 在 `SCREEN_SURVIVAL` 时调 `_handle_survival_mouse()`，后者结尾又调回 `_handle_mouse()`。改装页里任何一次**非「完成改装」按钮**的左/右键点击都会无限互调；每层都走 `_update_hover() → _build_option_index_at() → _option_ids()`，所以栈溢出炸在 `data_registry.get_module()`，**而不是炸在这两个函数本身**。② **修法（单向化，不改交互语义）**：`_input()` 的 `InputEventMouseButton` 分支按 `_screen == SCREEN_SURVIVAL` 分流；`_handle_mouse()` 删掉回跳分支；`_handle_survival_mouse()` 保留升级卡/商品格/两个改装按钮的专属热区，其余一律单向 `_handle_mouse()`。**方向只有一条：`_input()` → `_handle_survival_mouse()` → `_handle_mouse()`。** ③ **顺带修好一个一直哑着的缺陷**：旧版把滚轮与 `pressed=false` 在 `_handle_survival_mouse` 开头就 `return`，所以改装页的模块列表滚动与「拖拽铺平台」的落笔从未到达 `_handle_mouse()`——**v3.8 声称的「改装页拥有矩形/直线铺平台、拖动铺」在鼠标路径上一直不成立**（键盘路径正常）。④ **新增永久回归** `tests/mouse_input_smoke.gd`（4763 B / `548952e4`）：实例化 `main.tscn` 并把**真实 `InputEventMouseButton` / `InputEventMouseMotion` 灌进 `_input()`**，覆盖 motion/左键按下/松开/右键/滚轮/「完成改装」/战斗期点击七点。**为什么必须走真实场景**：`main.gd` 是 `extends Node2D`，`--script` 加载不了；纯函数级测试也抓不到「函数互调」这类只在调用链上成立的缺陷。⑤ **反向对照（关键）**：把旧回跳临时加回后跑同一测试，**立刻复现** `Stack overflow` 与完全相同的交替栈形（`mp3_negctl.txt` 693260 B）；撤回后输出 `MOUSE_OK`。⑥ **回归**：`--check-only` 78 B / `6ca5b6ba`；**12 项 smoke 全绿**（`m_sum.txt` 638 B / `7ae7106a`，原 11 项数值与历史基线逐字一致，新增 `MOUSE_OK`）；`--steps=420` 两次截图 `m_surv_a.png` = `m_surv_b.png` = **176395 B / `fdf2c020…`**，与修复前基线逐字节相同；`m_modify.png` 257622 B / `76b2449b…` 与历史一致——**修复对渲染零影响**。**如实声明**：修复后用脚本灌入的合成事件验证，**仍非人工桌面交互验证**（从未有人真的用鼠标点过改装页）；截图仍为脚本驱动 + 像素检查；**未在 Android 上验证，无 APK**；`boss_armor` / `safe_radius` / 商店稀有度权重方向三项旧缺口未动。 | §0 §11.4.2.2 §5 |
| 2026-10-21 | v3.18 | **编辑器分层隔离 + 光标件跟随 + 坦克默认居中 + 两处布局重叠**（用户原话：「坦克改装页面中，要明确坦克三个层级独立搭建，选中一个层时，其他两层要变得透明且无法操作，只能操作选中层，并且光标所持的配件也要根据选中层试试切换。坦克要默认在建造区域居中，再次检查菜单UI，层级选择和标题重叠了」）。① **先澄清边界**：**操作隔离本来就已经成立**——每个编辑操作（`place_*` / `remove_at` / `move_part` / `rotate_part` / `adjust_aim`）都只作用于 `_build_layer`，另外两层从未被改动。缺的是**看得见**的那一半：三层此前同亮度绘制，玩家无法从画面判断在编哪一层。本轮补的是可见性，不是可操作性。② **非选中层 22% alpha**：新增 `LAYER_DIM_ALPHA = 0.22`；`_draw_grid()` 为三层各算局部 alpha，`_draw_cell(..., alpha := 1.0)` 与 `_draw_aim_line(part, alpha := 1.0)` 新增参数把填充 / 边框 / 核心环 / 文字 / 瞄准线一起缩放；绘制顺序仍 平台 → 行进 → 模块。**用 alpha 不用 RGB 乘算**：霓虹靠 HDR glow（阈值 0.8），乘 RGB 会撞到 1.0 丢色相。③ **光标件随层切换**：`_select_layer()` 除设 `_build_layer` 外，把 `_selected_index` / `_rotation` / `_aim` 归零再 `_ensure_option_visible()`，并用 `_set_status("层：%s · 光标件：%s")` 回报；旧实现只 clamp `_selected_index`，切层后光标手里是「碰巧同下标」的无关件。新增 `_layer_label()` 统一三处层名。④ **默认居中**：`GridBuilder` 新增 `content_bounds() -> Rect2i` 与 `center_content() -> bool`，`volume_size()` 改为复用 `content_bounds().size`；调用点两处——`_activate_main_menu()` 建造分支与 `_survival_enter_modify()`，随后 `_cursor` 落到 `cockpit_cells()[0]`。**整块搬而不是逐件摆**：三层必须保持相对位置。**改装期平移安全**来自 `commit_modification()` 注释的「结构由下一次 `start_wave()` 重建 Duel 时才生效」；**战斗期绝不能搬**，因为 `TankBody.rebuild(source)` 直接从 builder 读格坐标。⑤ **两处布局重叠**：`_build_layer_rect()` 230→258（步长 48→44；`_draw_panel` 标题 baseline 227、分隔线 248，旧首行 230–268 正压在分隔线上）；`BUILD_TOOL_Y` 785→800（「工具」标签 baseline 793 落在旧按钮 785–823 内）。⑥ **连带修复**：`_survival_capture_modify()` 写死的 `(6,0)` 落点改为按 `content_bounds()` 算，否则居中后预览变红非法。⑦ **回归**：`--check-only` main.gd / grid_builder.gd 均 78 B / `6ca5b6ba`；**12 项 smoke 全绿且 `l6_all.txt` 638 B / `7ae7106a` 与上轮基线逐字节相同**；`build_smoke` 新增 5 条居中断言（非空 / 尺寸不变 / 花费与质量不变 / 边距差 ≤1 / 幂等）全过，`BUILD_OK` 数值不变；像素探针 `MODULE_SELECTED module=452` vs `PLATFORM_SELECTED module=191`、比值 2.37 → `DIMMING_OK`（`dim8.txt` 174 B / `8b4bb0d6`）；`--steps=420` 两次 `m_surv_a.png` = `m_surv_b.png` = 176395 B / `fdf2c020…` 与改前逐字节相同（生存页零影响）；改装页 `l_mod2.png` 254891 B、`l_plat.png` 230518 B。⑧ **探针自身错了三版**（比较不同格亮度不成立——模块格压在平台格正上方；「平台格应变亮」不成立——填充仅 0.12 alpha 几乎不可见；最终改用「本身够亮的一层被选中时必须显著更亮」才可判定），**记录为探针缺陷、不是产品缺陷**。**如实声明**：分层透明只有像素探针 + 脚本驱动截图证据，**从未有人真的用鼠标点过改装页的层按钮**；居中只在 `survival_modify` 与建造页入口验证，**未逐页回归**；截图仍为脚本驱动 + 像素检查；**未在 Android 上验证，无 APK**；`boss_armor` / `safe_radius` / 商店稀有度权重方向三项旧缺口未动。 | §0 §11.4.2.3 §5 |
| 2026-10-21 | v3.19 | **建立版本控制：`git init` + 初始提交**（用户原话：「初始化git，并做初始提交，用户信息为Trigger-CN 759025229@qq.com」）。① **执行**：`git init` → 本地配置 `user.name 'Trigger-CN'` / `user.email '759025229@qq.com'`（**仅本仓库，未动全局配置**）→ 写 `.gitignore` → `git add -A` → 提交。**初始提交 `fd3857f90ff813dd4a6fe5a81884013b5d5a9818`**（`master` 分支 root-commit），**77 files changed, 22366 insertions(+)**，作者与提交者均为 `Trigger-CN <759025229@qq.com>`，**全库仅 1 个提交**。② **关键判断：必须加 `.gitattributes`**。首次 `git add -A` 吐出 **77 条 `LF will be replaced by CRLF` 警告**——本机 `core.autocrlf=true`（Git for Windows 默认）。而本工程整套验证方法建立在**文件字节**上：`--check-only` 的 78 B / `6ca5b6ba` 判据、截图逐字节比对、`File.Stat` 的 hash 门控。若不管，将来任何一次 clone/checkout 都会把全部基线默默作废。补 `.gitattributes`（`* text=auto eol=lf` + `*.uid text eol=lf` + `*.png binary` + `*.apk binary`）后 `git rm -r --cached .` 重加，**警告归零**。③ **归一化未改任何字节**：`git ls-files --eol` 全为 `i/lf w/lf`、无例外、无 `i/-text`；`git check-attr eol` 对 `scripts/main.gd` / `docs/design.md` 均为 `eol: lf`；四个代表文件 blob hash 与 `git hash-object` 完全一致（`82449b585c46` / `064b81cc50e4` / `4353177a3eb0` / `012d190ee50d`，全 `same=True`）。④ **提交对象编码必须单独验（新教训）**：PowerShell 捕获原生命令 stdout 时按控制台代码页解码，`git log` 显示成 mojibake（`鍒濆鍖?TankCraft 浠撳簱`），看起来像提交信息被写坏。用 `subprocess` 取原始 bytes 再显式 utf-8 解码才确认真相：`utf8_decode=OK`、标题原文 `chore(repo): 初始化 TankCraft 仓库`、`has_replacement_char=False`、`mojibake_marks_present=False`——**乱码纯属 PowerShell 渲染，提交内容无损**。⑤ **入库决策**：`export_presets.cfg` 入库（手写 Android 预设，非生成物）；全部 `.uid` 入库（Godot 4 资源引用稳定性）；`.godot/` 与 `.me/` 排除；`.gitignore` 含 `.godot/`、`.me/`、`__pycache__/`、`*.pyc`、`*.apk`。⑥ **忽略规则验证**：`git status --porcelain` **0 行**；`tracked=77`；`me_tracked=0`、`godot_tracked=0`；`git check-ignore -v` 确认两条规则各自命中。⑦ **修正历史陈述**：本文档 §0 的「截图可复现基线（v3.13）」行与 §5 的 v3.13/v3.14 行曾以「无 git 仓库」为前提，现已就地追加更正——**结论不变但原因变了**：v3.10/v3.11 旧代码仍找不回来（仓库在 v3.18 之后才建），今后则可以真正做 before/after。**如实声明**：本轮只建立版本控制，**未改任何代码**，因此未重跑 smoke、未重拍截图；上一轮的 `--check-only` 与 12 项 smoke 结果仍有效。**未在 Android 上验证，无 APK**。 | §0 §5 |
| 2026-10-22 | v3.20 | **逐配件碰撞箱 + 伤害悬浮数字**（用户原话：「优化坦克和其他物品的碰撞箱逻辑，坦克的整体碰撞箱和中弹判定都是由配件构成，受到伤害和造成伤害都要有悬浮数字提示」）。① **先纠正前提**：**中弹判定（弹道→坦克）本来就是逐配件的**，本轮零改动——`projectile_field._clip_to_tank()` 把弹道线段变换进坦克局部空间后，对 `target["cells"]` 每格做 `_clip_to_aabb` slab 求交并取最小 `t`，结果自带 `cell`/`part_index`；`target_payload()` 逐格导出；`_resolve_target()` 按 模块>平台>行进 映射。真正有缺陷的是**碰撞箱**。② **缺陷面**：`TankBody.world_bounds()` 取所有格四角旋转后的 min/max 得到**整车旋转 AABB**，被当作碰撞形状用于矩形障碍推出、圆形障碍推出、坦克互撞、撞房屋（四处错误）；**`apply_boundary()` 是唯一正确的用法**——竞技场边界轴对齐，外接框 min/max 就是格角极值，与逐格数学等价。曾一度把它改成逐格并编造「外接框会提前撞墙」的差异，**已撤回，不计入产品修复**。③ **新增四个逐格查询**：`cell_world_rects()`（碰撞箱唯一真相来源）、`cell_overlap_rect()`（SAT 四轴，取最浅）、`cell_overlap_circle()`（局部最近点，**取最深**）、`cells_overlap_tank()`（逐格 OBB SAT）。`world_bounds()` 降级为粗筛。④ **取最深的实测依据**：按最浅格迭代时两相邻格互相拉扯，`diag2.txt` 记录 `DIAG_STALLED depth_zero` / `DIAG_FINAL_OVERLAP true`；改最深后 `diag3.txt` 一次收敛（`depth=22.000` → `DIAG_CONVERGED at step 1`）。⑤ **迭代推出 + 单次结算**：`MAX_PUSH_ITERATIONS = 8`，循环内只改位置，结束后 `_resolve_contact([last_normal], 0.0)` 传穿透 0，只扣一次血。⑥ **圆心埋在车内**的退化情形转交 `_resolve_circle_inside_hull()`，那里外接框才是正确模型。⑦ **撞房屋**改用 `cell_overlap_rect()`；残骸仍不是碰撞体。⑧ **悬浮数字**：`duel._resolve_impact()` 在 `apply_hit()` **返回之后**写回 `damage`/`shield`/`victim`；`FxLayer.push()` 增加可选 `text`；生存页与对局页各一套推入/绘制；`dealt`→`+N`、`received`/`shield`→`-N`；同侧限流 6 条；`sqrt(progress)` 上浮 + 后 30% 淡出 + 暗色描边；**零随机偏移**；两个 FX 绘制函数都 `continue` 掉 `damage` 条目。⑨ **修掉一个真实缺陷**：第一版 `"%+d"` 使本体被命中显示 `+17`（像加血），改为 `mode` 参数分流。⑩ **回归**：`--check-only` 六个脚本均 78 B / `6ca5b6ba`；**12 项 smoke `s3.txt` 638 B / `7ae7106a` 与历史基线逐字节相同**；`PHYSICS_OK mass=61.0 inertia=104064 v_max=192.1 turn180_s=1.35 spin_stop_s=0.62` 一字未变；`physics_smoke` 重写圆形断言为「圆心在车内 / 车外」两情形并新增 `_check_cell_hull_differs_from_aabb()` 五条**区分性**断言。⑪ **截图**：`v20_surv_c.png` = `v20_surv_d.png` = 178927 B / `fa188823`（青色 `+52` + 红色 `-17`）；对局页 `v20_match_s340.png` 132259 B / `62fee88c`（红色 `-52`）；对局页 150/420 步预热都已超过 0.85 s 数字寿命，是靠 `--steps=340` 才截到。⑫ **区域归因**：`region_diff.py`（新增 `diff_bbox()`）比对修复前后（`rdiff4.txt`）left_hud / right_hud / right_hud_above_mirror / mirror_panel / status_bar **全 0**，唯一差异战场区 704 px / 69×73 包围盒；比历史基线（`rdiff2.txt`）状态栏 0、右 HUD 上半 0。**如实纠正**：镜像面板**不是静态区域**（逐格实时 HP 与部件血条会随受伤变化），不能当「必须 0」的判据。⑬ **过程自伤 4 次（均已修复并复验）**：`world_bounds()` 函数体被误替换 + 孤儿 `world_bounds_impl()`；`survival_run.gd` replace 范围少算一行导致循环体被吞（`c_sr1` 721 B）；第二次 replace 插入重复 `_resolve_rammed_houses`（`c_sr2` 755 B）；`apply_boundary` 等价重写已撤回。另有一次**测试缺陷**：`PHYSICS_FAIL_CIRCLE_SHORT moved=18.69 expected=54.00` 是断言在验旧的外接框语义，已重写断言而非改回实现。**如实声明**：截图仍为**脚本驱动 + 像素检查，非人工交互验证**——**从未有人真的玩一局观察伤害数字**；**未在 Android 上验证，无 APK**；`boss_armor` / `safe_radius` / 商店稀有度权重方向三项旧缺口未动；房屋撞击仍无专项断言。 | §0 §11.4.2.4 §5 |
| 2026-10-22 | v3.20.1 | **修用户报告的 `_preview_cells()` 下标越界崩溃**（用户原话：`SCRIPT ERROR: Out of bounds get index '8' (on base: 'PackedStringArray') at: _preview_cells (res://scripts/main.gd:1559)`，栈形 `_preview_cells ← _draw_grid ← _draw_build ← _draw_survival ← _draw`）。① **根因：同一个字段被当成两套下标**。`_selected_index` 的真实语义是 **`_option_ids()` 的下标**；而改装期 `_option_ids()` 是「按 `_build_layer` 过滤 + 按 id 去重」的结果，**与 `survival.inventory` 长度不等、顺序也不对应**。旧代码三处错用：`_ensure_option_visible()` **只钳制 `_option_scroll`、根本不钳制 `_selected_index`**（收口点没在收口）；`_preview_cells()` 直接 `options[_selected_index]`（**越界就在这里**，绘制路径每帧一次所以报错刷屏）；`_mount_selected_inventory()` 用 `clampi(_selected_index, 0, inventory.size() - 1)` 再取 `inventory[index]`（即使不越界也会**贴装另一件**）。② **实测触发条件**：`inventory` 6 件（商店买满）、当前模块层去重后只剩 3 个可选 id，则 `_selected_index = 5` 对库存合法、对可选件非法；用户报的 `'8'` 是同一机理下数量更多的情形。③ **修法**：`_ensure_option_visible()` 第一件事按**可选件数量**钳制；`_preview_cells()` 加防御式 `clampi`；`_mount_selected_inventory()` 改为 `options[idx]` → `module_id` → `inventory.find(module_id)`；两处 `visible_count` 包 `maxi(..., 0)`。④ **新永久回归 `tests/editor_bounds_smoke.gd`**（6148 B）：实例化 `main.tscn`，走真实入口 `_enter_survival() → _open_shop() → 真实购买 6 格 → _survival_enter_modify()`，构造 `_selected_index = inventory_count - 1`（比可选件多、但比库存小）后调 `_preview_cells()`；实测 `inventory=6 > options=3`（**前提成立**）→ `PREVIEW_OK`。⑤ **反向对照（关键证据）**：用 `.me/tmp/main/negctl_apply.py` 把三处修复临时退回旧写法，**立刻复现用户报告的完全相同错误**（`pb_neg.txt`：`SCRIPT ERROR: Out of bounds get index '5' (on base: 'PackedStringArray') at: _preview_cells`、`PREVIEW_FAIL index_clamped_to_options`）；恢复后回到 161231 B / `0c0c3580`，与备份三方同 hash。⑥ **回归**：`--check-only` 78 B / `6ca5b6ba`；**13 项 smoke 全绿**（`s4.txt` 720 B / `f1606d4c`，原 12 项数值逐字一致，新增 `PREVIEW_OK`）；改装页截图 `v21_modify.png` **254891 B / `6db6db59` 与 v3.18 的 `l_mod2.png` 逐字节相同**（对渲染零影响）；真实窗口日志 `WINDOW_MODE mode=2 size=(1842, 1057)`、**无 `SCRIPT ERROR`**。⑦ **为什么一直没被发现**：库存每件同层且无重复 id 时两个长度恰好相等，错误被掩盖；而商店卖的正是**各层混合**的模块，必然暴露。⑧ **测试装置缺陷（已修，不是产品缺陷）**：首版直接调 `_draw_build()`——在 `_draw()` 之外调绘制函数会刷屏 `ERROR: Drawing is only allowed inside this node's _draw()`，且首版没买东西使 `inventory=0`；改为真实购买 + 只调 `_preview_cells()`。第二版贴装断言失败因为光标停在已占用的驾驶舱格，改为先找本层空格。`main.gd` 159079 → 161231 B，`tests/` 12 → 13 个 `.gd`。**如实声明**：截图与测试均为**脚本驱动，非人工桌面交互验证**——仍没有人真的在游戏里玩到崩溃复现；**未在 Android 上验证，无 APK**；`boss_armor` / `safe_radius` / 商店稀有度权重方向三项旧缺口未动。 | §0 §11.4.2.5 §5 |
