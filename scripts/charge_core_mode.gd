class_name ChargeCoreMode
extends CoreMode

## 蓄力模式：持续时间内存活但不扩散；到期后一次性向周围所有方向扩张两格。
## 扩散形状由 burst_candidates() 给出（周围距离 1~2 的所有地块），
## 由主脚本在核心到期时调用 spread.burst_from() 一次性写入污染。

## 部署该模式核心的费用消耗（点；接线方在部署入口使用）
const DEPLOY_COST := 3

func mode() -> String:
	return "charge"

func interval_fallback() -> float:
	return 999999.0  # 蓄力核心不周期性分裂

func display_name() -> String:
	return "蓄力"

## 存活期间不扩散
func spread_candidates(_cell: Vector2i, _payload: Dictionary) -> Array[Vector2i]:
	return []

## 到期爆发：周围两格内（距离 1~2）所有地块
func burst_candidates(cell: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for dq in range(-2, 3):
		for dr in range(-2, 3):
			var n := cell + Vector2i(dq, dr)
			var d := _cube_dist(n, cell)
			if d >= 1 and d <= 2:
				out.append(n)
	return out

static func _cube_dist(a: Vector2i, b: Vector2i) -> int:
	var dx := a.x - b.x
	var dz := a.y - b.y
	var dy := -dx - dz
	return maxi(absi(dx), maxi(absi(dy), absi(dz)))
