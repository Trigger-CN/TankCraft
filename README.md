# TankCraft

一个用 **Godot 4.7.2** 写的 2D 坦克建造对战游戏。俯视视角，极简霓虹风格。

玩家在网格上从零搭一台坦克：先铺**平台**，再挂**行进机构**，最后堆**功能模块**。炮弹不是凭空出现的——它要被**制造、被输送、被装填**，所以「内部物流布局」和「外形武器」同样重要。打掉对手一段甲板，可能让他的整条弹药管路失效。

> **当前状态：可运行的实现原型，尚未发布。** 核心玩法（建造 / 物理 / 弹药网络 / 战斗结算 / AI / 波次生存）均已实现并有 21 项自动化 smoke 测试覆盖；**Windows release exe 已能一键构建并已 headless 实跑通过**（见「构建 release exe」）。**真人试玩由用户持续进行**（本项目几乎所有缺陷与需求都来自用户实机试玩）；**AI 侧的验证手段是 headless 测试 + 脚本驱动截图 + 像素比对**，不是人工试玩。**没有产出过任何 APK**。

---

## 玩法概览

### 单人：波次生存（`survival_battle`）

肉鸽式波次生存。每波有时限，活到计时归零即通过。

- 地图上散布**可摧毁的房屋**（撞击或炮击）与**可碾过的坦克残骸**，是战斗期的金钱与经验来源。
- 敌人**分级别**：招募 / 老兵 / 精英 / 王牌，级别越高结构越复杂。
- 每次升级弹**三选一送配件**的菜单，可顺带进**改装**。
- 波间进**商店**：6 件商品、花钱刷新、出售库存、改装。
- 每 5 波一个 **Boss**。
- **战斗期不允许改装**。驾驶舱被毁即本局结束。

### 对战：1v1 对机器人（`match_battle`）

固定竞技场内的 1v1 对战，双方各一台坦克，击毁对方驾驶舱获胜。

---

## 建造系统

坦克分**三层**，逐层搭建，选中一层时其余两层变暗且不可操作：

| 层 | 内容 | 说明 |
| --- | --- | --- |
| **行进机构层** | 履带、防弹轮组、机动轮组 | 决定速度与转向 |
| **平台层** | 不同形状的平台模块 | 相当于甲板/地基，模块必须装在平台上 |
| **功能模块层** | 引擎、弹药工厂、弹药库、改进器、炮管、护盾、维修装置、弹药管路、喷射系统 | 决定怎么打 |

两个全局约束：**信用点预算**与**质量上限**。

**驾驶舱是结构锚点**：甲板被打断后，只有仍与驾驶舱连通的部分存活，其余立即解体。

### 模块与管路

模块的端口方向随 `rot` 旋转，改装页会画出**输入/输出箭头**（青色 `in` 指内、琥珀 `out` 指外），方便规划流水线。

弹药管路共六种：

| 管路 | 行为 |
| --- | --- |
| 直管 | 唯一通路 |
| 四分之一弧 | 唯一通路，转 90° |
| 二分之一弧 | 唯一通路，跨 2 格 |
| 一分二（Tee） | 轮询交替喂两侧 |
| 二合一（Merge） | 两路合流，`in0` 优先但不会饿死 `in1` |
| 四通（Cross） | 两条车道交叉互不干扰，`in0`→`out0` / `in1`→`out1` 直通优先 |

> **注意**：四通不是分流器，它的语义是「两条线交叉」。**想让一路弹药喂两门炮，请用一分二。**

### 弹药与升级

- 弹药按口径分五档：**20 / 40 / 76 / 120 / 155 mm**。口径越小制造越快、基础伤害越低，占用弹药库槽位越少。
- **改进器**让流经的弹药携带升级（伤害、弹速、爆炸、灼烧、减速、延迟爆炸、护盾穿透、穿透、分裂），升级**逐发携带**，不是整台坦克共享。
- **炮管只接受精确口径**，口径不符会被拒收并原路退回——HUD 上会显示「拒收」计数。

**有效射速 = `max(craft_time_s, reload_s)`**：炮管拿不到弹就无法装填。

---

## 操作

### 战斗（试驾 / 对战 / 生存）

| 按键 | 作用 |
| --- | --- |
| `W` `A` `S` `D` / 方向键 | 油门与转向 |
| 鼠标移动 | 瞄准（炮口跟随光标） |
| **鼠标左键** | 开火（`空格` 为备选） |
| `P` | 暂停 / 继续（仅对战页） |
| `R` | 重开 |
| `Esc` | 逐层返回 |

### 建造 / 改装

| 按键 | 作用 |
| --- | --- |
| 方向键 / `WASD` | 移动光标 |
| `1` `2` `3` | 切换层的选择 |
| `A` / `D` | 切换当前层可选配件 |
| `R` | 旋转 |
| `Q` / `E` | 调整炮管朝向 |
| `X` | 拆解 |
| `C` | 定位驾驶舱 |
| `Ctrl+Z` / `Ctrl+Y` | 撤销 / 重做 |
| 鼠标 | 悬浮与左键点击均有支持 |

---

## 运行

### 环境要求

- **Godot 4.7.2 stable**（`4.7.2.stable.official.ed1daf0bf`）——用 4.x 特性，**不兼容 3.x**。
- Windows 桌面为主要目标；架构上保留 Linux / macOS。**移动端触屏只有设计、代码零实现。**

### 启动

```bash
godot --path .
```

窗口启动即最大化（`WINDOW_MODE_MAXIMIZED`），设计分辨率 1920×1080，等比缩放并保留黑边。

### 截图钩子（用于回归比对）

```bash
godot --path . -- --capture=out.png --screen=survival --steps=420 --cursor=960,540
```

`--screen` 可取：`drive` / `match` / `survival` / `survival_levelup` / `survival_shop` / `survival_summary` / `survival_modify`。

`--steps=N` 预热固定步数（让画面可复现），`--cursor=x,y` 把鼠标钉到指定设计坐标（`--capture` 路径本身不产生鼠标事件）。

### 构建 release exe

```bat
build_release.bat
```

产物为 **`build/windows/TankCraft.exe`**（单文件，pck 已内嵌），可直接分发。

| 参数 | 作用 |
| --- | --- |
| （无） | 构建 release 版 |
| `--debug` | 构建 debug 版（含控制台包装） |
| `--out <路径>` | 指定输出路径（支持含空格的路径） |
| `--godot <路径>` | 指定 Godot，建议指向 `*_console.exe` |
| `--install-templates` | 下载并安装匹配版本的导出模板（**只取 Windows 条目，约 69 MB**，不下载 1.28 GB 整包） |
| `--help` | 显示帮助 |

退出码：`0` 成功 / `1` 用法错误 / `2` 找不到 Godot / `3` 缺导出模板 / `4` 导出失败 / `5` 产物缺失 / `6` 模板安装失败。

> **前置条件**：必须先装 Godot **导出模板**，且版本与引擎严格一致。脚本默认**不会**自动安装（模板装在 `%APPDATA%`，属工程目录之外），缺失时以退出码 `3` 结束并打印精确路径与三种解决办法。
>
> **当前状态：已实测可产出。** `build\windows\TankCraft.exe` **109,825,632 B（104.74 MB）**，SHA256 `0528eb874a7f8a0a5ec5942530179d9a03b0b9ff78217be6eae749c4af338de7`；`--debug` 版 **103,733,856 B**。同一命令连跑两次**逐字节一致**。PE 为 `PE32+` / `x86_64` / `SUBSYSTEM=2 (WINDOWS_GUI)`，尾部带 `GDPC`（pck 524,372 B **内嵌**）⇒ 单文件。
>
> `--install-templates` 会把模板装到 `%APPDATA%\Godot\export_templates\<版本>\`（**工程目录之外**），因此脚本默认**不**自动安装，必须显式传该开关。它走 ZIP central directory + HTTP Range，**只取 4 个 Windows 条目（压缩后 69 MB）**，不会下载 1.28 GB 整包。
>
> **未在真实桌面（带窗口）运行过。** 全部验证都是 `--headless`；`build/` 已被 `.gitignore` 忽略，**exe 不在仓库里**。


---

## 测试

21 项 smoke，全部 headless、无外部依赖：

```bash
godot --headless --path . --script res://tests/ammo_combo_smoke.gd
```

| 测试 | 输出 |
| --- | --- |
| `physics_smoke.gd` | `PHYSICS_OK` |
| `cannon_smoke.gd` | `CANNON_OK` |
| `ammo_net_smoke.gd` | `AMMO_OK` |
| `ammo_combo_smoke.gd` | `AMMO_COMBO_OK` |
| `upgrade_flow_smoke.gd` | `UPGRADE_OK` |
| `aim_smoke.gd` | `AIM_OK` |
| `pointer_sync_smoke.gd` | `POINTER_OK` |
| `build_smoke.gd` | `BUILD_OK` |
| `runtime_build_smoke.gd` | `RUNTIME_OK` |
| `data_smoke.gd` | `DATA_OK` |
| `data_error_smoke.gd` | `DATA_ERROR_OK` |
| `combat_smoke.gd` | `COMBAT_OK` |
| `match_smoke.gd` | `MATCH_OK` |
| `expedition_smoke.gd` | `EXPEDITION_OK` |
| `survival_smoke.gd` | `SURVIVAL_OK` |
| `mouse_input_smoke.gd` | `MOUSE_OK` |
| `editor_bounds_smoke.gd` | `PREVIEW_OK` |
| `perf_smoke.gd` | `PERF_OK` |
| `drive_feedback_smoke.gd` | `DRIVE_FEEDBACK_OK` |
| `pipe_geometry_smoke.gd` | `PIPE_GEOMETRY_OK` |
| `conveyor_showcase_smoke.gd` | `SHOWCASE_OK` |

> `perf_smoke` 只断言 **p99 / max**，**刻意不断言平均**——平均会掩盖长尾卡顿。阈值由反向对照校准（关掉加速后 `PERF_FAIL count=3`），详见 `docs/design.md` §11.4.2.14。
>
> `drive_feedback_smoke` 实例化真实 `main.tscn` 进试驾页，把坦克摆到贴边并给一个朝墙的速度，逐固定步长断言「撞墙产生伤害 / 命中闪光被置位 / 动效层出现 `-N` 承受语义的伤害数字」。**它存在的理由**：试驾页的弹丸永远打不到发射者自己，所以「命中反馈」这类改动若写错分支，静态截图完全看不出来。该测试已用**变异测试**证明非空转（删掉产品代码里的推入调用后立即失败），详见 `docs/design.md` §11.4.2.15。
>
> `pipe_geometry_smoke` 对**六种管道 × 四个朝向**做 139 条几何断言：端口必须落在**格边中点**、相邻模块的端口点必须**精确重合**（不给容差）、弧端点切线必须垂直于所在格边、弧上采样点必须落在圆上、汇流臂端点必须两两分开。它**另有一条反向对照**：用旧实现那种「首格中心 → 末格中心」直线插值在四分弧上取点，最大偏离 `2.3431 px`（正好是弦高 `r(1−cos45°)`）——用来证明「弹头会飘出管子」这件事真实存在，而不是我把正确实现改掉了。**两条探针纪律都记在 `docs/design.md` §11.4.2.16**：容差必须从离散化阶数推（弧是 16 段折线，首尾弦偏差 `sin(90°/16/2)=0.0491`）；探针**不得复用被测实现的内部推导**，否则两边同错也会通过。
>
> `conveyor_showcase_smoke` 读入 `data/blueprints/conveyor_showcase.json`（专门为看管道做的展示车），断言六种管道齐备、每个管道件都有非空中心线、`connected_sides()` 同时产出「接上」与「没接上」两种端口，然后驱动 600 个 tick，断言「汇流类里 forward 弹药的 `exit_port` 永远非空」「段内 / 段末 / 阻塞三态都观察到」「至少投递成功一次」。**它守的是一个曾经会撒谎的字段**：`exit_port` 早期把「下游现在能不能收」也当判据，管道一满就变空串，画面上弹头立刻失去方向。详见 `docs/design.md` §11.4.2.16。

另有语法检查（不会执行脚本）：

```bash
godot --headless --path . --check-only --script res://scripts/ammo_network.gd
```

`--check-only` 只看「有没有 Parse Error」，输出里没有 `Parse Error` / `SCRIPT ERROR` 即为干净。

**脚本类测试的特点**：部分测试（`ammo_combo_smoke`、`ammo_net_smoke`、`aim_smoke`）是**纯领域层**的——直接用 `GridBuilder` 搭 `AmmoNetwork`，不经过主场景、`Duel` 或 `CannonBank`。它们证明「网络调度正确」，**不证明「游戏里真的能打出去」**。

---

## 项目结构

```
TankCraft/
├── project.godot            # 引擎配置（Godot 4.7.2 / GL Compatibility / 启动最大化）
├── scenes/main.tscn         # 唯一场景（单场景架构，禁止 change_scene）
├── scripts/                 # 20 个 .gd
│   ├── main.gd              # 单场景外壳：所有页面、输入分发、绘制（上帝类，4105 行 / 203 KB）
│   ├── grid_builder.gd      # 三层网格建造与校验
│   ├── tank_body.gd         # 坦克运动解算与逐格碰撞
│   ├── ammo_network.gd      # 弹药网络调度（20 Hz 独立步进）
│   ├── cannon_bank.gd       # 炮管组：装填、瞄准、开火
│   ├── projectile_field.gd  # 弹道、命中、射程耗尽消散
│   ├── damage_system.gd     # 伤害结算、护盾、维修、升级效果
│   ├── duel.gd              # 对局装配与事件分发
│   ├── bot_ai.gd            # 机器人 AI
│   ├── survival_run.gd      # 波次生存状态机
│   ├── combat_view.gd       # 可复用战斗视图（三页共用）
│   ├── pipe_view.gd         # 管道几何与绘制（建造/改装页 + 三个战斗页共用，全静态）
│   ├── module_defs.gd / data_registry.gd / data_validator.gd
│   ├── palette.gd / fx_layer.gd / match_state.gd
│   ├── expedition_run.gd / runtime_builder.gd   # 遗留，无玩法调用方
├── data/                    # 24 个 JSON —— 所有运行时数值的权威来源
│   ├── modules/             # systems / mobility / platforms
│   ├── ammo/calibers.json   # 五口径伤害、初速、射程
│   ├── upgrades/upgrades.json
│   ├── arenas/              # 3 张竞技场
│   ├── blueprints/          # 15 个：12 张 Bot 蓝图 + Boss + 1 张无效示例 + 1 张管道展示车
│   └── globals.json
├── tests/                   # 21 个 smoke
└── docs/
    ├── design.md            # 设计文档（机制、数值、架构、ADR）
    └── roadmap.md           # 里程碑与实时状态
```

---

## 架构要点

- **单场景架构**：所有页面都在 `scenes/main.tscn` + `scripts/main.gd` 里，`change_scene()` 被禁止。
- **数据驱动**：模块定义、价格、质量、建造时长、装填时长、后坐力、AI 参数、射程全部来自 `data/*.json`。代码里不写魔法数字。
- **确定性**：60 Hz 固定步长；只有固定步长累加器驱动逻辑，**绝不对 `dt` 做缩放**；绘制与逻辑中**不用 `randf` / `randi`**（闪烁用 `sin(_time * …)`，随机用显式种子的 LCG）。同一 `--steps=N` 连拍应逐字节相同。
- **弹药网络独立步进**：`ammo_net_hz = 20`，每段管路容量 1 发，与物理帧解耦。
- **两段式炮管装填**：`_accept()` 只登记「待装填」，真正入膛由 `fill_cannons()` 调 `CannonBank.load_round()` 完成。

---

## 文档

本仓库的文档是**权威源**，代码实现必须与之一致：

| 文档 | 内容 |
| --- | --- |
| [`agent_note.md`](agent_note.md) | **新接手先读这个**。元规则、技术栈、工程约定、术语表、AI 上手流程、已知陷阱 |
| [`docs/design.md`](docs/design.md) | 玩法机制、系统规格、数值基线、架构草案、ADR、开放问题 |
| [`docs/roadmap.md`](docs/roadmap.md) | 里程碑、交付物、验收标准、实时状态 |

**元规则 M1（最高优先级）**：任何改动、决定或共识，必须在**同一次改动中**同步更新所有受影响的文档。**文档没更新 = 改动未完成。**

**变更记录只追加**：三份文档各有一张变更表，历史行**永不修改或删除**。

---

## 已知限制

以下都如实记录，不是待办清单的包装：

- **真人试玩一直在进行，由用户执行。** 本项目的工作方式是「用户试玩发现 → AI 定位修复」，几乎所有缺陷与需求变更都来自用户实机试玩（UI 分叉、生存模式卡顿、准星错位、标题重叠、炮弹无伤害、转向难控……）。**AI 侧的验证手段是** headless 测试 + 脚本驱动截图 + 像素比对，**不包含人工试玩**——这两件事不能混为一谈。具体到某一项改动，可以说「尚未经过用户实机确认」，但不能说「没有人玩过」。
- **从未在 Android 设备上验证过任何内容，且不存在任何 APK。** 导出预设已写入工程，但本机缺导出模板与 Android SDK。
- **移动端触屏只有设计、代码零实现。**
- **`main.gd` 是上帝类**（3924 行 / 194 KB），按页面拆分被明确搁置。
- **四通单源接两出口只喂一侧**——这是设计语义（直通优先），不是缺陷，但**没有 UI 说明**。
- **改进器容量是设计值**：mk1 最多同时容纳 2 发（1 加工 + 1 排队），其余在上游管道排队，不是阻塞。
- **生存模式高波次仍偶发超预算**：wave12 有约 **36/900 步（4%）**单步超过 16.67 ms（p99 19.0 / max 21.7 ms）。碰撞层已从 O(n²) 改为空间分桶（`docs/design.md` §11.4.2.14），但补兵时 `spawn_enemy_us` 仍有 2.6–10.7 ms 的单帧尖峰；而且**只测了逻辑层，绘制层未测**。
- **release exe 已能构建，但从未在真实桌面（带窗口）运行过。** `build\windows\TankCraft.exe` **109,825,632 B（104.74 MB）** / SHA256 `0528eb87…338de7`，`--debug` 版 103,733,856 B，连跑两次逐字节一致，PE 为 `PE32+` / `x86_64` / `SUBSYSTEM=2` 且尾部带 `GDPC`（单文件内嵌 pck）。实跑证据：`TankCraft.exe --headless --quit-after 600 -- --screen=survival --steps=200` → 5.5 s 正常退出、stderr 仅 `SURVIVAL_ENTERED wave=1 enemies=2 houses=4 debris=6`、**无 `SCRIPT ERROR`**。但**全部验证都是 `--headless`**（`WINDOW_MODE mode=1 size=(0, 0)` 就是 headless display server 的表现），**没有人双击运行过它、没有人看过它的画面**。另外 `build/` 被 `.gitignore` 忽略，**exe 不在仓库里**；`--install-templates` 的 **`-All` 整包分支从未跑通**（只验证了默认的「只取 Windows 条目」分支）。
- **桌面 exe 没有任何人工启动验证**：它只在 `--headless` 下被跑过（且只跑到主菜单/生存模式初始化），Android 也没有 APK。**注意：这一条讲的是「exe 从未被双击启动」，不是「游戏没人玩」——游戏本身一直由用户实机试玩。**
- `expedition_run.gd` / `runtime_builder.gd` 仍存在但**无任何玩法调用方**。
- 若干旧缺口：`boss_armor` 未实现、`safe_radius` 从未被读取、商店稀有度权重方向反、竞技场障碍 `hp` 无人扣减（障碍不可摧毁）。

完整清单见 `agent_note.md` §8 与 `docs/design.md` §17。

---

## 许可

尚未添加许可证文件。在明确许可前，默认保留所有权利。
