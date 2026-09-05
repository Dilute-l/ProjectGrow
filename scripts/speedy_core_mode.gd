class_name SpeedyCoreMode
extends CoreMode

## 定向模式：部署时须点击相邻地块选择方向；此后每块该模式的污染地块
## 都沿该方向单向扩散一格。方向存在 polluted[cell]["dir"] 中，扩散时继承。

func mode() -> String:
	return "speedy"

func needs_direction() -> bool:
	return true

func interval_fallback() -> float:
	return 0.3

func display_name() -> String:
	return "高速"

func description() -> String:
	return "17消耗，核心存在15s，每1s向指定方向扩散一格\n为什么这个触手看起来这么像舌头啊”“这不就是舌头吗”"

func spread_candidates(cell: Vector2i, payload: Dictionary) -> Array[Vector2i]:
	var dir: Vector2i = payload.get("dir", Vector2i.ZERO)
	return [cell + dir]
