# 我方核心拆分说明（PlayerCore 场景 + CoreMode 模式注册机制）

> 目标：沿用敌方炮台的分拆方法，把“我方两种核心”（径向 / 定向）的运行期状态与
> 行为从 `scripts/hex_game.gd` 中拆出 —— **每颗部署的核心 = 一个 PlayerCore 场景实例**，
> 每种核心的“扩散行为”由 **CoreMode 注册表**描述 —— 方便后续
> **修改核心数据**（cores.json）与**添加新核心**（同模式加条目；新模式加一个子类 + 一行注册）。

## 1. 文件清单

| 文件 | 作用 |
| --- | --- |
| `scripts/player_core.gd` | `class_name PlayerCore`（`extends Node2D`）：**一颗部署中的核心** = 一个节点，持有坐标/类型数据/剩余时间/定向方向 |
| `scenes/player_core.tscn` | 核心独立场景：根节点挂 `player_core.gd`，预留 `Visuals` 子节点（将来放各类型专属视觉） |
| `scripts/core_mode.gd` | `class_name CoreMode`：模式行为抽象基类 + **静态注册表**（`register / for_mode / known_modes`） |
| `scripts/radial_core_mode.gd` | `RadialCoreMode`：径向行为（6 邻居扩散，默认间隔 0.9s） |
| `scripts/directional_core_mode.gd` | `DirectionalCoreMode`：定向行为（沿部署方向单向扩散，需选方向，默认间隔 0.6s） |
| `scripts/hex_game.gd` | 已接线：`units` 存 PlayerCore 节点；扩散由注册表驱动（见 §4） |
| `docs/player_core_refactor.md` | 本文档 |

## 2. 职责划分

**PlayerCore 节点（每颗核心）**
- 类型数据快照 `config`（来自 `cores.json`：id/name/mode/duration/spread_interval/color）
- 运行状态：`coord`、`remaining`（`advance()` 递减，<=0 到期）、`direction`
- 便捷接口：`mode()`、`behavior()`、`payload()`、`is_directional()`

**CoreMode 注册表（每种“模式”一个对象）**
- 虚接口：`mode()`、`needs_direction()`、`make_payload(dir)`、
  `spread_candidates(cell, payload)`、`interval_fallback()`、`display_name()`
- 主脚本只按模式名 `CoreMode.for_mode(m)` 拿行为，其余全是通用代码 ——
  不再为 radial / directional 写任何分支

**主脚本（hex_game.gd，接线后）**
- `units: Dictionary`：坐标 → PlayerCore 节点；`core_container` 存放场景实例
- `polluted`：统一污染字典，值 = `{mode, dir}`（原先的三套字典 `polluted /
  radial_polluted / directional_polluted` 合并为一套）
- 通用扩散循环 `_spread_mode(m, bm)`：按模式间隔推进 `mode_spread_timers`，
  对属于该模式的所有污染地块调用 `bm.spread_candidates()` 后统一过滤
  （越界 / 墙 / 已污染），新增地块用同一 `payload` 继承方向
- 部署流程：`_try_place` 询问 `behavior.needs_direction()`；其余模式立即
  `_spawn_core()` 实例化场景放置
- 绘制仍留主脚本（读 `n.config` / `n.mode()` / `n.direction` 等节点数据）

## 3. 与改造前 hex_game.gd 的对应关系

| 改造前（hex_game.gd） | 改造后 |
| --- | --- |
| `units[cell]` 为 Dictionary `{type,remaining,direction}` | `units[cell]` 为 **PlayerCore 节点**（scene 实例） |
| `core_types[u["type"]]` 查类型 | `node.config`（setup 时快照） |
| `u["remaining"]` | `node.remaining`（`advance(delta)` 推进，<=0 到期） |
| `u["direction"]` | `node.direction` |
| `_make_unit(type_idx)` | `CORE_SCENE.instantiate()` + `node.setup(cell, idx, cfg, dir)`（`_spawn_core`） |
| `_pollute / _radial_pollute / _directional_pollute` | `_pollute_with(cell, node.payload())`（`{mode, dir}` 统一字典） |
| `radial_polluted` / `directional_polluted` 两套集合 | 并入 `polluted` 的 `mode` 标记 |
| `_radial_spread()` / `_directional_spread()` | `_spread_mode(mode, CoreMode.for_mode(mode))` 通用实现 |
| `radial_interval` / `directional_interval` | `mode_intervals[mode]`（来自 cores.json，逐模式） |
| `radial_spread_timer` / `directional_spread_timer` | `mode_spread_timers[mode]` |
| `_has_radial_core()` / `_has_directional_core()` | `_process` 里收集存活节点模式 `active_modes` |
| `if t["mode"] == "directional": …`（放置/绘制分支） | `behavior.needs_direction()` / `node.mode() == "directional"` |
| `_try_remove` 清三套字典 | 只清 `polluted`（已统一） |

敌方炮台模块（`EnemyTurret.tick`）无需改动：它只对 `polluted` 与 `units`
做 `has/erase`，现在 `units` 值变为 PlayerCore 节点、`polluted` 变为统一字典，
语义不变；敌方攻击后由主脚本 `_free_orphan_cores()` 释放被 erase 的核心节点。

## 4. 如何修改数据 / 添加新核心

**改数据（颜色、持续时间、扩散间隔、名字等）** —— 直接改 `maps/cores.json`：
```json
{
  "cores": [
    { "id": "spread", "name": "扩散核心", "mode": "radial", "duration": 15.0, "spread_interval": 0.9, "color": "#3fc1ff" },
    { "id": "beam",   "name": "定向核心", "mode": "directional", "duration": 20.0, "spread_interval": 0.6, "color": "#7dff5a" }
  ]
}
```
加一条即出现新的可选核心（右侧选择 UI 与数字键自动生成）。

**新增“同模式”核心** —— 只在 JSON 加条目，什么都不用写代码。

**新增“新模式”**（例如“十字 core = 只向四个方向扩散”），只需三步，不改玩法主逻辑：
1. 新建 `scripts/cross_core_mode.gd`：
```gdscript
class_name CrossCoreMode
extends CoreMode

const CROSS_DIRS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
]

func mode() -> String:
	return "cross"

func interval_fallback() -> float:
	return 0.8

func spread_candidates(cell: Vector2i, _payload: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for d in CROSS_DIRS:
		out.append(cell + d)
	return out
```
2. 在 `hex_game.gd` 的 `_register_core_modes()` 加一行：
   `CoreMode.register("cross", CrossCoreMode.new())`
3. 在 `maps/cores.json` 加一条 `{ "id": "...", "mode": "cross", ... }`。

部署流程、倒计时、扩散、绘制数据、敌方互动、胜负判定全部自动适用新模式。

## 5. 接线记录（已在 hex_game.gd 落实并实机验证）

- 新增 `CORE_SCENE`/`core_container`、`mode_spread_timers`/`mode_intervals`；
  删除 radial/directional 两套集合、两个间隔变量与对应函数；
- `_ready()` 增加 `_register_core_modes()`；
- 放置/移除/倒计时/绘制全部改为 PlayerCore 节点；
- 扩散统一为 `_spread_mode`（CoreMode 驱动）；`polluted` 并入 `{mode,dir}` 标记；
- 敌方攻击后 `_free_orphan_cores()` 回收被摧毁的核心节点。

实机验证（Godot 4.7.2，运行中进程逐项断言）：
- 注册表：`known_modes == ["radial", "directional"]`；`mode_intervals == {radial: 0.9, directional: 0.6}`（与 cores.json 一致）；
- 径向放置：`units` 出现 PlayerCore 节点、`polluted[cell].mode == "radial"`；
- 定向放置：先 `awaiting_direction`，选相邻格后节点 `direction=(0,1)`、`polluted[cell].dir=(0,1)`；
- 径向一次扩散新增的 6 邻居与旧算法期望**逐格一致**（含顺序）；定向一次扩散单格继承方向；
- 真实对局：径向+定向混合开局 → 敌方攻击逐格清除、可摧毁核心（孤儿节点被回收）；
  贴脸径向多核心 → 污染扩散至 115 格、两个炮台相继损毁 → `Phase.WON`；全程游戏日志无脚本错误。
