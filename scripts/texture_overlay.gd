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

# 贴图内六边形的单边边长（像素）：贴图四周有透明边，按此边长换算缩放
const HEX_ART_EDGE := 2400.0
# 贴图微调偏移（以 hex_size 为单位，随窗口缩放）
@export var art_offset := Vector2.ZERO

var _last_hex_size := -1.0
var _last_offset := Vector2(-1e9, -1e9)
var _had_any := false          # 上一帧是否画过内容（用于“清空后立刻清屏”的重绘）

# ---------------------------------------------------------------------------
# 每帧：需要时重绘（跟随扩散/移除/窗口缩放）
# ---------------------------------------------------------------------------
func _process(_delta: float) -> void:
	var main = get_parent()
	if main == null:
		return
	var any := _has_items(main)
	var geometry_changed: bool = main.hex_size != _last_hex_size or main.map_offset != _last_offset
	# 有内容、几何变化、或“上一帧有内容但现在被清空（如重置）”时都要重绘
	if any or geometry_changed or (_had_any and not any):
		_last_hex_size = main.hex_size
		_last_offset = main.map_offset
		_had_any = any
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
		var tex := _dir_entry(dir)
		if tex == null:
			continue
		_draw_art(main.geometry.hex_center(cell) + off, tex, float(tex.get_width()) * (main.hex_size / HEX_ART_EDGE))

## 在中心 center 处居中画一张贴图（span 为渲染边长），不旋转，方向由图片本身保证。
func _draw_art(center: Vector2, tex: Texture2D, span: float) -> void:
	draw_texture_rect(tex, Rect2(center.x - span * 0.5, center.y - span * 0.5, span, span), false)

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
