class_name DirectionalCoreMode
extends CoreMode

## 定向模式：部署时须点击相邻地块选择方向；此后每块该模式的污染地块
## 都沿该方向单向扩散一格。方向存在 polluted[cell]["dir"] 中，扩散时继承。

func mode() -> String:
	return "directional"

func needs_direction() -> bool:
	return true

func interval_fallback() -> float:
	return 0.6

func display_name() -> String:
	return "定向"

func spread_candidates(cell: Vector2i, payload: Dictionary) -> Array[Vector2i]:
	var dir: Vector2i = payload.get("dir", Vector2i.ZERO)
	return [cell + dir]
