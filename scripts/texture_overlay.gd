class_name TextureOverlay
extends Node2D

## 定向蔓延贴图覆盖层（只画蔓延地块；核心本体贴图已并入 player_core.tscn / PlayerCore）
##
## 作为 hex_game.tscn 里 Main 的子节点运行，把“带方向载荷”的污染地块（非核心格，
## polluted[cell].dir 非零，即会朝某方向继续蔓延的定向式扩散）按方向叠画：
##   images/Direct_{left,right,upleft,upright,downleft,downright}.png。
## 核心所在格的本体贴图 Direct_core.png 由 PlayerCore 节点在自身 _draw() 里绘制。
##
## 说明：
##   - 本脚本只【读取】父节点 Main（hex_game.gd 与其 geometry 模块）公开的
##     polluted / units / hex_size / map_offset 以及 main.geometry.hex_center()；
##   - 贴图按格中心居中绘制，微调偏移 art_offset 以 hex_size 为单位（随窗口缩放），
##     方向→贴图的选择见 _dir_entry()；贴图按原始方向绘制，不做旋转。

# ---------------------------------------------------------------------------
# 贴图资源
# ---------------------------------------------------------------------------
const TEX_LEFT := preload("res://images/Direct_left.png")
const TEX_RIGHT := preload("res://images/Direct_right.png")
const TEX_UPLEFT := preload("res://images/Direct_upleft.png")
const TEX_UPRIGHT := preload("res://images/Direct_upright.png")
const TEX_DOWNLEFT := preload("res://images/Direct_downleft.png")
const TEX_DOWNRIGHT := preload("res://images/Direct_downright.png")

# 贴图内六边形的单边边长（像素）：实测非透明包围盒反推（约 2687~2691，取 2690）
const HEX_ART_EDGE := 2690.0
# 触手贴图内六边形底座中心（像素坐标）；作为锚点对齐格子中心，补偿透明边不对称
const TENTACLE_ART_CENTER := Vector2(3196.0, 3377.0)
# 灰度触手贴图（形状与 Direct_* 一致，供非定向核心 modulate 换色）
const TEX_GREY_LEFT := preload("res://images/tentacles/tentacle_left.png")
const TEX_GREY_RIGHT := preload("res://images/tentacles/tentacle_right.png")
const TEX_GREY_UPLEFT := preload("res://images/tentacles/tentacle_upleft.png")
const TEX_GREY_UPRIGHT := preload("res://images/tentacles/tentacle_upright.png")
const TEX_GREY_DOWNLEFT := preload("res://images/tentacles/tentacle_downleft.png")
const TEX_GREY_DOWNRIGHT := preload("res://images/tentacles/tentacle_downright.png")
# 傲慢之眼 id（用原玫红贴图，不换色）；其余核心用灰度贴图按占位符色上色
const DIRECTIONAL_CORE_ID := "beam"
# 贴图微调偏移（以 hex_size 为单位，随窗口缩放）
@export var art_offset := Vector2.ZERO

var _last_hex_size := -1.0
var _last_offset := Vector2(-1e9, -1e9)
var _had_any := false          # 上一帧是否画过内容（用于“清空后立刻清屏”的重绘）
var _color_cache := {}         # 核心 id -> 占位符色（modulate 用）

# ---------------------------------------------------------------------------
# 每帧：需要时重绘（跟随扩散/移除/窗口缩放）
# ---------------------------------------------------------------------------
func _process(_delta: float) -> void:
	# 触手贴图 + 可部署提示都需跟随状态变化；每帧重绘（开销小）
	queue_redraw()

func _has_items(main) -> bool:
	for cell in main.polluted.keys():
		if main.units.has(cell):
			continue
		var pl: Dictionary = main.polluted[cell]
		if pl.get("dir", Vector2i.ZERO) != Vector2i.ZERO:
			return true
	return false

# ---------------------------------------------------------------------------
# 绘制
# ---------------------------------------------------------------------------
func _draw() -> void:
	var main = get_parent()
	if main == null:
		return
	var off: Vector2 = art_offset * main.hex_size
	# 带方向的污染地块（非核心格，方向载荷非零）：按方向画蔓延形态
	for cell in main.polluted.keys():
		if main.units.has(cell):
			continue
		var pl: Dictionary = main.polluted[cell]
		var dir: Vector2i = pl.get("dir", Vector2i.ZERO)
		if dir == Vector2i.ZERO:
			continue
		var origin_id := str(pl.get("origin_id", ""))
		var center: Vector2 = main.geometry.hex_center(cell) + off
		if origin_id == DIRECTIONAL_CORE_ID or origin_id == "":
			# 傲慢之眼（或未知来源）：原玫红贴图，不上色
			var tex := _dir_entry(dir)
			if tex == null:
				continue
			var span: float = float(tex.get_width()) * (main.hex_size / HEX_ART_EDGE)
			_draw_art(center, tex, span, Color.WHITE)
		else:
			# 其他核心：灰度贴图 + 按占位符色上色
			var tex := _dir_entry_grey(dir)
			if tex == null:
				continue
			var span: float = float(tex.get_width()) * (main.hex_size / HEX_ART_EDGE)
			_draw_art(center, tex, span, _core_tint(origin_id, main))
	# 可部署提示：画在触手贴图之上（本节点 z=0，位于 Main 的格子层之上）
	if main.mode == main.Mode.PLAY and (main.phase == main.Phase.DEPLOY or main.phase == main.Phase.RUNNING):
		var anywhere := false
		if main.selected_core >= 0 and main.selected_core < main.core_types.size():
			var t: Dictionary = main.core_types[main.selected_core]
			var bm = main.map_data.behavior_for_mode(str(t.get("mode", "")))
			anywhere = bm.deploy_anywhere()
		for cell in main.geometry.all_cells():
			if main.walls.has(cell) or main.turret_positions.has(cell) or main.units.has(cell):
				continue
			if anywhere or main.geometry.is_edge(cell):
				draw_arc(main.geometry.hex_center(cell), main.hex_size * 0.55, 0.0, TAU, 24, Color(0.8, 1.0, 1.0, 0.30), 2.0)

## 在中心 center 处居中画一张贴图（span 为渲染边长），不旋转，方向由图片本身保证。
## mod 为颜色调制：灰度贴图乘上占位符色即可精确换色；原玫红贴图传 Color.WHITE 保持不变。
func _draw_art(center: Vector2, tex: Texture2D, span: float, mod: Color) -> void:
	var scale: float = span / float(tex.get_width())
	var top_left: Vector2 = center - TENTACLE_ART_CENTER * scale
	draw_texture_rect(tex, Rect2(top_left, Vector2(span, span)), false, mod)

## 六邻居方向 -> 贴图。贴图自身已按对应方向制作，此处只负责按方向选取，不旋转。
func _dir_entry(dir: Vector2i) -> Texture2D:
	match dir:
		Vector2i(1, 0):
			return TEX_RIGHT
		Vector2i(-1, 0):
			return TEX_LEFT
		Vector2i(0, 1):
			return TEX_DOWNRIGHT
		Vector2i(0, -1):
			return TEX_UPLEFT
		Vector2i(1, -1):
			return TEX_UPRIGHT
		Vector2i(-1, 1):
			return TEX_DOWNLEFT
		_:
			return null

## 六邻居方向 -> 灰度触手贴图（供非定向核心换色）
func _dir_entry_grey(dir: Vector2i) -> Texture2D:
	match dir:
		Vector2i(1, 0):
			return TEX_GREY_RIGHT
		Vector2i(-1, 0):
			return TEX_GREY_LEFT
		Vector2i(0, 1):
			return TEX_GREY_DOWNRIGHT
		Vector2i(0, -1):
			return TEX_GREY_UPLEFT
		Vector2i(1, -1):
			return TEX_GREY_UPRIGHT
		Vector2i(-1, 1):
			return TEX_GREY_DOWNLEFT
		_:
			return null

## 取某核心 id 的占位符色（来自 main.core_types 的 color）；未知 id 返回白色（不调制）
func _core_tint(origin_id: String, main) -> Color:
	if origin_id == "":
		return Color.WHITE
	if _color_cache.has(origin_id):
		return _color_cache[origin_id]
	for t in main.core_types:
		if str(t.get("id", "")) == origin_id:
			var c := Color(str(t.get("color", "#ffffff")))
			_color_cache[origin_id] = c
			return c
	return Color.WHITE
