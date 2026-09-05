class_name RadialCoreMode
extends CoreMode

## 径向模式：污染地块每隔一段时间向四周所有相邻地块扩散。
## 与 hex_game.gd 里 NEIGHBORS 的六个轴向偏移保持一致。

const NEIGHBOR_OFFSETS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0),
	Vector2i(1, -1), Vector2i(-1, 1),
	Vector2i(0, 1), Vector2i(0, -1),
]

func mode() -> String:
	return "radial"

func interval_fallback() -> float:
	return 0.9

func display_name() -> String:
	return "径向"

func description() -> String:
	return "20消耗，核心存在60s，每5s向外扩散一圈\n看起来生命力好像很旺盛，也不知道到底是什么在驱使着它，总不能是对魔法少女的渴望吧"

func spread_candidates(cell: Vector2i, _payload: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for d in NEIGHBOR_OFFSETS:
		out.append(cell + d)
	return out
