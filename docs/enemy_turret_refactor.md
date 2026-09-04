# 敌方炮台分拆说明（EnemyTurret 节点模块 · 多炮台版）

> 目标：把散落在 `scripts/hex_game.gd`（**多炮台版本**）中的“敌方炮台”
> **状态与攻击逻辑**抽成独立、可复用的节点模块，并打包为独立场景
> （`scenes/enemy_turret.tscn`）后接入主脚本，方便后续修改与扩展。
> 接线（§6 的 B 阶段）已经你确认完成，`hex_game.gd` 本次有修改；
> 除炮台改用场景实例外其余行为不变（已实测，见 §8）。
>
> 本文档针对的是现版代码：地图数据来自 `maps/level1.json`（半径 6，
> 敌方炮台位于 `(0,0)` 与 `(0,3)`，含墙），核心数据来自 `maps/cores.json`
> （径向 / 定向两种核心）。

## 1. 新增 / 变更文件

| 文件 | 作用 |
| --- | --- |
| `scripts/enemy_turret.gd` | 新模块：`class_name EnemyTurret`（`extends Node2D`），**一个节点 = 一个敌方炮台** |
| `scenes/enemy_turret.tscn` | 炮台独立场景：根节点挂 `enemy_turret.gd`，预留 `Visuals` 子节点 |
| `scripts/hex_game.gd` | B 阶段已接线：原 `turrets` 字典改为 `EnemyTurret` 场景实例（见 §6） |
| 本说明文档 | 模块边界、API 说明与接线记录 |

`hex_game.tscn` 未修改；`hex_game.gd` 已在 B 阶段（§6）按你的确认完成接线。

## 2. 拆分边界

沿用既定方案：只搬运**状态与攻击逻辑**。

**搬入节点（本模块负责，每个炮台一个节点）**
- 状态：坐标 `coord`、存活 `alive`、攻击计时 `attack_timer`、攻击间隔 `attack_interval`
- 行为：按间隔计时 → 选“离自己最近”的污染地块 → 清除该地块（若其上是我方核心则一并摧毁）
- 损毁规则：污染覆盖本炮台所在格 ⇒ 损毁（通过返回值 / `destroyed` 信号告知接入方）
- 清除时的数据面：与现版一致，一次攻击会同时从
  `polluted` / `radial_polluted` / `directional_polluted` / `units` 四套字典中移除目标地块

**留在主脚本（本模块不负责）**
- 读取 `maps/*.json`、得到炮台位置数组 `turret_positions`（属地图数据）
- 全部绘制（炮台外观、充能环、损毁叉号等）与颜色常量
- 胜负判定与阶段切换（`Phase.WON / LOST`）、HUD 文案、控制台数值项
- `polluted` / `units` / `radial_polluted` / `directional_polluted` 的数据所有权

绘制所需数据可只读获取：`coord`、`alive`、`charge_fraction()`。

## 3. 与现版 hex_game.gd 的逐条对照

现版把“所有炮台”压在一个字典里：`turrets: Dictionary`（键=炮台坐标，值=距下次攻击秒数，
键存在即存活）。分拆后把它展开为 N 个节点，语义一一对应：

| hex_game.gd（现版） | EnemyTurret（新） | 行为 |
| --- | --- | --- |
| `turrets` 字典的**键**（炮台位置） | `coord` | 一个节点对应一个炮台坐标 |
| `turrets` 字典的**值**（计时秒数） | `attack_timer` | 距下次攻击累计秒数 |
| “键存在于 `turrets`”= 存活 | `alive == true` | 存活标记 |
| `enemy_attack_interval` | `attack_interval` | 攻击间隔（运行时/控制台可调，改后需同步到各节点） |
| `ENEMY_ATTACK_INTERVAL_DEFAULT` | `ATTACK_INTERVAL_DEFAULT` | 默认 0.5s，数值一致 |
| `_enemy_attack(from)` | `tick()` 内部 | 计时到点 → 清除最近污染地块（含三集合 + 摧毁核心） |
| `_nearest_polluted(from)` | `choose_target(polluted)` | 返回最近的污染地块；无目标返回 `NO_TARGET` |
| `_check_turret_destruction()` | `check_contamination(polluted)` | 逐节点：污染到本炮台格 ⇒ 损毁，返回 `true`、发 `destroyed` |
| `_draw()` 充能环 `turrets[p] / enemy_attack_interval` | `charge_fraction()` | 充能进度 0..1 |
| `_draw()` 存活分支 `turrets.has(p)` / 死亡叉号 | `alive` | 绘制判断数据源 |
| HUD `存活炮台 %d = turrets.size()` | 遍历各节点 `alive` 计数 | 存活炮台数 |
| `_start()` / `_reset()` 重建并清零 `turrets` | `reset()` / 重建节点列表 | 关卡开始/重置 |
| —— | `setup(cell, interval)` | 初始化单个炮台 |
| —— | `attacked(target)` / `destroyed` | 新信号（特效 / 音效 / 判定钩子） |

另注：`_try_place()` / `_tile_color()` / 定向高亮里对 `turret_positions.has(cell)`
的“炮台格不可部署/不悬停”判断属于**静态位置列表**（地图数据），节点化后仍可继续
使用 `turret_positions`，无需改动。

## 4. API 摘要

- `setup(cell: Vector2i, interval := 0.5)`：摆放并复位
- `reset()`：复活并清零计时
- `destroy()`：外部摧毁（发 `destroyed`）
- `tick(delta, polluted, units, radial_polluted := {}, directional_polluted := {}) -> bool`：
  推进计时；到点清除最近污染地块（四字典引用直改）；返回是否真的攻击
- `charge_fraction() -> float`：充能进度，供绘制
- `check_contamination(polluted) -> bool`：本格被污染 ⇒ 损毁
- `choose_target(polluted) -> Vector2i`：攻击目标选择（**子类可覆写**做自定义规则）
- 信号：`attacked(target)`、`destroyed`

## 5. 独立测试（不依赖主脚本）

```gdscript
# 按 level1.json 的炮台位置生成两个节点
var nodes := []
for p in [Vector2i(0, 0), Vector2i(0, 3)]:
	var t := EnemyTurret.new()
	t.setup(p, 0.5)
	add_child(t)
	nodes.append(t)

var polluted := { Vector2i(1, 0): true, Vector2i(0, 4): true }  # 一个离甲近，一个离乙近
var units    := { Vector2i(1, 0): { "type": 0, "remaining": 3.0 } }

for t in nodes:                       # 每帧各节点独立计时、各打各的
	if t.tick(0.6, polluted, units):
		print("attacked")             # 甲清 (1,0) 并摧毁核心；乙清 (0,4)
# polluted / units 中对应项已被清除（与现版一次攻击清四字典一致）

if nodes[0].check_contamination({ Vector2i(0, 0): true }):
	print("甲炮台被污染摧毁")
```

## 6. 接线清单与落地记录（B 阶段已按你确认在 hex_game.gd 中执行）

以下为已落地的改动点（可对照代码审查；代码中的实际实现见 §9 B）：

1. **变量区**：删除 `turrets: Dictionary`；新增
   `var turret_nodes: Array = []`（`EnemyTurret` 节点列表）。
2. **`_ready()` / `_reset()`**：在两者里重建节点列表代替原来对 `turrets` 的
   clear + 重建：
   ```gdscript
   turret_nodes.clear()
   for p in turret_positions:
	   var t := EnemyTurret.new()
	   t.setup(p, enemy_attack_interval)
	   add_child(t)
	   turret_nodes.append(t)
   ```
   （`_reset()` 若只想复位而不重建，可改为遍历 `reset()`。）
3. **`_process()` 第 5 步**：`_check_turret_destruction()` 改为逐节点：
   ```gdscript
   for t in turret_nodes:
	   if t.check_contamination(polluted):
		   queue_redraw()
   if _all_turrets_dead():        # 遍历 alive 计数 == 0
	   phase = Phase.WON
   ```
4. **`_process()` 第 6 步**：原 `for tcell in turrets.keys(): ...` 循环替换为：
   ```gdscript
   for t in turret_nodes:
	   if t.tick(delta, polluted, units, radial_polluted, directional_polluted):
		   queue_redraw()
   ```
   失败判断 `not turrets.is_empty()` 改为“仍有存活节点”。
5. **`_draw()` 炮台段**：`for p in turret_positions:` 内改为在节点列表里找对应
   节点（或直接遍历节点）：存活分支读 `t.alive`，充能环用 `t.charge_fraction()`；
   死亡叉号数据读 `t.coord`（绘制代码本身不变，只换数据源）。
6. **HUD / 控制台**：`_update_status()` 的 `turrets.size()` 改为存活节点计数；
   `_console_apply()` / `_console_defaults()` 修改 `enemy_attack_interval` 后
   同步给各节点：`for t in turret_nodes: t.attack_interval = enemy_attack_interval`。
7. **`_start()`**：`for p in turrets.keys(): turrets[p] = 0.0` 改为遍历节点
   `t.reset()`（或只清零 `attack_timer`）。

行为等价点：攻击时机、最近目标选取、平局取先遍历者、无目标空过、
一次攻击清四字典、被污染即损毁等语义，全部保留在
`tick() / choose_target() / check_contamination()` 中。

## 7. 后续扩展方向

- **不同攻击规则**：继承 `EnemyTurret` 覆写 `choose_target()`（最远 / 随机 /
  范围攻击），或监听 `attacked` 信号做额外效果。
- **每炮台独立数值**：`attack_interval` 已是实例字段 —— 未来可在
  `maps/*.json` 的炮台条目里加 `interval`，接入时按条 `setup(pos, interval)`。
- **血量 / 护盾**：在节点内加字段，扩展 `check_contamination()` / `destroy()`，
  对外仍只暴露 `alive` 与 `destroyed`。
- **胜利反馈**：监听 `destroyed` 信号播放特效 / 音效（绘制本身仍留在主脚本）。

## 8. 验证记录（Godot 4.7.2 实测）

- 新脚本解析零错误；`EnemyTurret` 已注册为全局类。
- 在运行中的游戏进程内做行为冒烟测试，全部符合现版逻辑：
  - 计时到点攻击并清除最近污染地块；一次攻击同时清 `polluted` / 径向 /
	定向集合，并摧毁该格核心（`radial_left=0`、`units_left=0` 等验证通过）；
  - 双炮台各自独立计时、各自打离自己最近的目标（甲→(1,0)、乙→(0,4)）；
  - 计时未到不攻击、无目标空过；
  - 污染到本格 ⇒ `check_contamination()` 返回 true、`alive=false`、`destroyed`
	发出；损毁后不再攻击；`reset()` 可复活；
  - `charge_fraction()` 充能进度正确。
- 接线（B 阶段）完成后再次实测：主场景启动零报错；`EnemyTurrets` 容器含 2 个
  `EnemyTurret` 场景实例（坐标 `(0,0)` / `(0,3)`、间隔 0.5）；接线攻击同时清除
  `polluted` / 径向集合并摧毁核心；逐炮台污染损毁，全部损毁后进入 `Phase.WON`；
  `_reset()` 重建后全部复活（容器/节点数恢复 2）。游戏日志无脚本错误。
- 阶段说明：模块与场景化前期（A 阶段）不动原文件；B 阶段按你的确认修改了
  `hex_game.gd`（`hex_game.tscn` 仍保持未修改）。

## 9. 炮台场景化路线图（模块化下一步）

把炮台从“脚本类”升级为“独立场景”，从而在编辑器里把它当做一个可复用、
可配置、可携带可视化子节点的单元。

### A. 场景打包（已完成）

新建 `scenes/enemy_turret.tscn`：

```
[gd_scene format=3 uid="uid://cc18caq7lyw54"]
[ext_resource type="Script" uid="uid://cmsghivs87o7o" path="res://scripts/enemy_turret.gd" ...]
[node name="EnemyTurret" type="Node2D"]   script = ExtResource(...)
[node name="Visuals" type="Node2D" parent="."]
```

- 根节点 `EnemyTurret`（Node2D）挂 `scripts/enemy_turret.gd`，字段/逻辑与第 3、4 节完全一致；
- 子节点 `Visuals`（Node2D）是预留的**视觉挂载点**：将来阶段 C 的绘制 / 充能环 /
  特效脚本都挂在这里，不改根脚本结构；
- 用法：`var t := (load("res://scenes/enemy_turret.tscn") as PackedScene).instantiate()`，
  然后 `t.setup(cell, interval)` 后 `add_child`（已实测可实例化并正常攻击）。

### B. 场景实例接入主脚本（已完成 —— hex_game.gd 已接线）

已在 `hex_game.gd` 落地（对照第 6 节清单），实际实现要点：

1. 成员：`const TURRET_SCENE := preload("res://scenes/enemy_turret.tscn")`、
   `turret_map: Dictionary`（坐标 → 节点）、`turret_container: Node2D`（容器 `EnemyTurrets`）；
2. `_reset()` → `_rebuild_turrets()`：释放旧容器 → 新建容器 → 遍历 `turret_positions`
   实例化场景、`setup(p, enemy_attack_interval)`、入容器并登记进 `turret_map`；
3. `_process` 第 5 / 6 步遍历 `turret_map`：`check_contamination()` / `tick()`；
   两处失败判定改用 `_alive_turret_count()`；
4. `_draw()` 炮台段从节点读 `alive` / `charge_fraction()`（编辑模式仍按位置直接绘制，
   不依赖节点，故刷墙/放炮台即时可见）；
5. 控制台“应用 / 恢复默认”修改攻击间隔后同步给各节点；
6. 原 `_enemy_attack()` / `_nearest_polluted()` 已删除（逻辑内聚在
   `tick()` / `choose_target()`）。

好处：炮台在编辑器的场景面板里可见、可单独编辑；后续给单个炮台加子节点
（命中特效、血条、音效）不需要改主脚本逻辑。

### C. 视觉下放（可选，进一步解耦）

把炮台绘制从主脚本 `_draw()` 移进场景：`Visuals` 挂一个绘制脚本，
主脚本每帧只做两件事：`turret.position = hex_center(coord)` 与
`turret.hex_size = hex_size`（缩放变化时同步），节点在自己的局部坐标系画
圆形 / 三角 / 充能环 / 损毁叉号。主脚本的绘制段与相关颜色常量即可删除，
炮台成为真正自包含的场景。

### D. 数据驱动与变体（远期）

- `maps/*.json` 的炮台条目可扩展 `interval` 等字段，按条 `setup(pos, interval)`；
- 想有多种炮台：把 `enemy_turret.tscn` 复制为变体场景或子类化
  `EnemyTurret`（覆写 `choose_target()` / 自定义字段），主脚本按 JSON 里的
  `type` 选对应场景实例化。
