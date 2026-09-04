class_name TextureOverlay
extends Node2D

## 贴图覆盖层（不修改 hex_game.gd）
##
## 作为 hex_game.tscn 里 Main 的子节点运行，把“上色方案”中能用贴图表达的部分
## 叠画在原矢量色块之上：
##   - 定向式核心（部署时带方向，如 directional / speedy 等）的所在格：
##     画 images/Direct_core.png（本体）；
##   - 任何“带方向载荷”的污染地块（非核心格，polluted[cell].dir 非零，
##     即会朝某方向继续蔓延的定向式扩散）：按该方向画
##     images/Direct_{left,right,upleft,upright,downleft,downright}.png；
##   - 径向核心、普通地块、墙等维持原矢量色块（本层不画）。
##
## 说明：
##   - 本脚本只【读取】父节点 Main（hex_game.gd 与其 geometry 模块）公开的
##     units / polluted / hex_size / map_offset 以及 main.geometry.hex_center()，
##     不改任何 hex_game.gd / hex_*.gd 代码；
##   - 数值可调项（跨幅）集中在下方导出变量里；方向→贴图的选择见 _dir_entry()。
##     贴图按原始方向绘制，不做旋转 —— 各方向图的朝向由图片本身保证。

# ---------------------------------------------------------------------------
# 贴图资源
# ---------------------------------------------------------------------------
const TEX_CORE := preload("res://images/Direct_core.png")
const TEX_LEFT := preload("res://images/Direct_left.png")
const TEX_RIGHT := preload("res://images/Direct_right.png")
const TEX_UPLEFT := preload("res://images/Direct_upleft.png")
const TEX_UPRIGHT := preload("res://images/Direct_upright.png")
const TEX_DOWNLEFT := preload("res://images/Direct_downleft.png")
const TEX_DOWNRIGHT := preload("res://images/Direct_downright.png")
const ART_BOX := 154.0                 # 素材画布边长（像素）

# 绘制大小（以 hex_size 为单位；相邻格中心距 ≈ √3 ≈ 1.732×hex_size）
# 已导出：在编辑器选中 Main/GroundOverlay 节点，Inspector 里可实时调整
@export_range(0.05, 4.0, 0.01) var core_span := 0.06        # 定向核心本体贴图跨幅
@export_range(0.05, 4.0, 0.01) var tentacle_span := 0.06    # 定向污染蔓延贴图跨幅
@export var draw_offset := Vector2.ZERO                     # 贴图整体位移（像素：x>0 向右、y>0 向下）

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
	if main.units.size() > 0:
		for n in main.units.values():
			if n != null and n.is_directional():
				return true
	if main.polluted.size() > 0:
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
	# 1) 定向式核心所在格：本体（Direct_core；径向核心维持原色块，本层不画）
	for cell in main.units:
		var n: PlayerCore = main.units[cell]
		if n == null or not n.is_directional():
			continue
		_draw_art(main.geometry.hex_center(cell), TEX_CORE, main.hex_size * core_span)
	# 2) 带方向的污染地块（非核心格，方向载荷非零）：按方向画蔓延形态
	for cell in main.polluted.keys():
		if main.units.has(cell):
			continue
		var pl: Dictionary = main.polluted[cell]
		var dir: Vector2i = pl.get("dir", Vector2i.ZERO)
		if dir == Vector2i.ZERO:
			continue
		var tex := _dir_entry(dir)
		_draw_art(main.geometry.hex_center(cell), tex, main.hex_size * tentacle_span)

## 在中心 center 处画一张 154x154 贴图（不旋转，贴图按原始方向绘制），span 为渲染边长。
## 导出的 draw_offset 会叠加到中心坐标上，用于把贴图整体向上下左右微调对齐。
func _draw_art(center: Vector2, tex: Texture2D, span: float) -> void:
	var s := span / ART_BOX
	draw_set_transform(center + draw_offset, 0.0, Vector2(s, s))
	draw_texture(tex, Vector2(-ART_BOX * 0.5, -ART_BOX * 0.5))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

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
			return TEX_CORE
