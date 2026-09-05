class_name CoreSelectorUI
extends RefCounted

## 右下角部署区 UI —— 主题脚本（独立 .gd）。
## 布局（从右到左）：[费用环 COST] [核心蜂窝选择] [道具栏]。
##   - 费用环：顶部 COST 标题，中间圆环（绿色=剩余比例、黄色=消耗比例），
##     环中心显示剩余费用数字，环下方用闪烁红色显示当前核心消耗费用；
##   - 核心蜂窝：已解锁核心以六边形蜂窝排列展示贴图图标，
##     未选择发暗、已选择放大；
##   - 道具栏：复用 HexItems.build_bar，放在核心选择栏左侧。

var game

# —— 核心图标按钮 ——
var core_buttons: Array = []

# —— 费用环组件 ——
var cost_ring: CostRing
var cost_label: Label
var current_cost_label: BlinkLabel

# —— 核心蜂窝容器（解锁变化时重建按钮用） ——
var core_grid: Control

# —— 左下角选中核心信息框 ——
var info_panel: PanelContainer
var info_title: Label
var info_sub: Label
var info_desc: RichTextLabel

## 各核心 mode -> 本体贴图（图标）
const CORE_ICONS := {
	"directional": preload("res://images/Direct_core.png"),
	"radial": preload("res://images/Spread_core.png"),
	"charge": preload("res://images/Charge_core.png"),
	"speedy": preload("res://images/Fast_core.png"),
}

## 图标尺寸（放大到 3 倍）
const ICON_SIZE := 168.0
# 图标内六边形边长：ICON_SIZE × (本体六边形边长 2381 / 贴图宽 6554)
const HEX_EDGE := ICON_SIZE * (2381.0 / 6554.0)
# 六边形边相接的紧凑间距
const HEX_W := HEX_EDGE * 1.7320508   # 水平相邻中心距（√3 × 边长）
const HEX_H := HEX_EDGE * 1.5         # 垂直相邻中心距（1.5 × 边长）

func _init(g) -> void:
	game = g

# ---------------------------------------------------------------------------
# 构建
# ---------------------------------------------------------------------------
func build() -> void:
	game.core_buttons.clear()
	game.core_selector_layer = CanvasLayer.new()
	game.core_selector_layer.layer = 10
	game.add_child(game.core_selector_layer)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	game.core_selector_layer.add_child(panel)
	game.core_selector_panel = panel

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 10)
	panel.add_child(margin)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	margin.add_child(hbox)

	# —— 核心蜂窝 ——
	core_grid = Control.new()
	core_grid.custom_minimum_size = Vector2(HEX_W * 1.5 + ICON_SIZE, HEX_H + ICON_SIZE)
	hbox.add_child(core_grid)
	_populate_core_buttons()

	# —— 费用环（最右） ——
	var ring_col := VBoxContainer.new()
	ring_col.add_theme_constant_override("separation", 4)
	ring_col.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_child(ring_col)

	var caption := Label.new()
	caption.text = "COST"
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.add_theme_font_size_override("font_size", 18)
	caption.add_theme_color_override("font_color", Color("ffd166"))
	ring_col.add_child(caption)

	cost_ring = CostRing.new()
	cost_ring.game = game
	cost_ring.custom_minimum_size = Vector2(96, 96)
	ring_col.add_child(cost_ring)

	var ring_center := VBoxContainer.new()
	ring_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	ring_center.alignment = BoxContainer.ALIGNMENT_CENTER
	ring_center.add_theme_constant_override("separation", 0)
	cost_ring.add_child(ring_center)

	cost_label = Label.new()
	cost_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cost_label.add_theme_font_size_override("font_size", 18)
	cost_label.add_theme_color_override("font_color", Color("ffffff"))
	ring_center.add_child(cost_label)

	current_cost_label = BlinkLabel.new()
	current_cost_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	current_cost_label.add_theme_font_size_override("font_size", 13)
	current_cost_label.blink_color = Color(1.0, 0.25, 0.25)
	ring_center.add_child(current_cost_label)

	update_cost_ui()

	# 锚定右下角；内容变多时向左/向上生长，右下角固定
	panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 16)
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN

	_build_info_box()
	_refresh_info_box()

# ---------------------------------------------------------------------------
# 左下角选中核心信息框
# ---------------------------------------------------------------------------
## 构建左下角信息框（样式与奖励卡一致，展示当前选中核心的名称/费用/模式/描述）
func _build_info_box() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	game.add_child(layer)
	game.core_info_layer = layer

	info_panel = PanelContainer.new()
	layer.add_child(info_panel)

	var cm := MarginContainer.new()
	cm.add_theme_constant_override("margin_left", 12)
	cm.add_theme_constant_override("margin_top", 10)
	cm.add_theme_constant_override("margin_right", 12)
	cm.add_theme_constant_override("margin_bottom", 10)
	info_panel.add_child(cm)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	cm.add_child(box)

	info_title = Label.new()
	info_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info_title.add_theme_font_size_override("font_size", 20)
	info_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(info_title)

	info_sub = Label.new()
	info_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info_sub.add_theme_font_size_override("font_size", 13)
	info_sub.add_theme_color_override("font_color", Color("cfe0ff"))
	info_sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(info_sub)

	info_desc = RichTextLabel.new()
	info_desc.bbcode_enabled = true
	info_desc.fit_content = true
	info_desc.scroll_active = false
	info_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info_desc.add_theme_font_size_override("normal_font_size", 13)
	info_desc.add_theme_color_override("default_color", Color("9fb0cc"))
	info_desc.custom_minimum_size = Vector2(260, 0)
	box.add_child(info_desc)

	# 锚定左下角；内容变高时向上生长，左下角固定
	info_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 16)
	info_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN

## 刷新左下角信息框：无选中核心时隐藏；有选中核心时显示其名称/费用/模式/描述
func _refresh_info_box() -> void:
	if info_panel == null:
		return
	if game.selected_core < 0 or game.selected_core >= game.core_types.size():
		info_panel.visible = false
		return
	info_panel.visible = true
	var t: Dictionary = game.core_types[game.selected_core]
	var mode_name := str(t.get("mode", ""))
	var bm = game.map_data.behavior_for_mode(mode_name)
	var col: Color = game.map_data.core_color(t)
	var cid := str(t.get("id", ""))
	var upgraded: bool = game.drop_effects.is_upgraded(cid)
	info_title.text = str(t.get("name", "核心")) + ("+" if upgraded else "")
	info_title.add_theme_color_override("font_color", Color("ffd166") if upgraded else col.lightened(0.25))
	info_sub.text = "费用 %d · %s扩散" % [game.drop_effects.deploy_cost(game.selected_core), bm.display_name()]
	if upgraded:
		info_desc.text = game.drop_effects.upgraded_desc(game.selected_core, true, false)
	else:
		info_desc.text = bm.description()
	var style := StyleBoxFlat.new()
	style.bg_color = col.darkened(0.78)
	style.border_color = col
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	info_panel.add_theme_stylebox_override("panel", style)

# ---------------------------------------------------------------------------
# 核心蜂窝按钮
# ---------------------------------------------------------------------------
## 重建核心图标：仅列出已解锁核心，用贴图做蜂窝状展示
func _populate_core_buttons() -> void:
	for b in game.core_buttons:
		if is_instance_valid(b):
			b.queue_free()
	game.core_buttons.clear()
	var idx := 0
	for i in range(game.core_types.size()):
		if not _type_unlocked(i):
			continue
		var mode := str(game.core_types[i].get("mode", ""))
		var icon: Texture2D = CORE_ICONS.get(mode, null)
		if icon == null:
			continue
		var btn := TextureButton.new()
		btn.texture_normal = icon
		btn.ignore_texture_size = true
		btn.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
		btn.custom_minimum_size = Vector2(ICON_SIZE, ICON_SIZE)
		btn.size = Vector2(ICON_SIZE, ICON_SIZE)
		btn.toggle_mode = true
		btn.set_meta("core_type", i)
		btn.pressed.connect(select_core.bind(i))
		var center := core_grid.custom_minimum_size * 0.5
		var pos := _parallelogram_position(idx)
		btn.position = center - _range_center() + pos - Vector2(ICON_SIZE * 0.5, ICON_SIZE * 0.5)
		core_grid.add_child(btn)
		game.core_buttons.append(btn)
		idx += 1
	refresh_button_states()

## 平行四边形位置（向右边倒）：上排2个，下排2个向右偏移半格
func _parallelogram_position(idx: int) -> Vector2:
	var col := idx % 2
	var row := idx / 2
	return Vector2(col * HEX_W + row * HEX_W * 0.5, row * HEX_H)

## 平行四边形整体范围中心（居中用）
func _range_center() -> Vector2:
	return Vector2(HEX_W * 0.75, HEX_H * 0.5)

## 刷新图标视觉：选中高亮，未选发暗
func refresh_button_states() -> void:
	for b in game.core_buttons:
		var i := int(b.get_meta("core_type", -1))
		if i == game.selected_core:
			b.button_pressed = true
			b.self_modulate = Color(1.0, 1.0, 1.0)
		else:
			b.button_pressed = false
			b.self_modulate = Color(0.5, 0.5, 0.55)

# ---------------------------------------------------------------------------
# 选择 / 解锁刷新
# ---------------------------------------------------------------------------
func select_core(i: int) -> void:
	if i < 0:
		game.selected_core = -1
		game.awaiting_direction = false
		refresh_button_states()
		update_cost_ui()
		_refresh_info_box()
		return
	if i >= game.core_types.size():
		return
	if not _type_unlocked(i):
		game.hud.set_status("「%s」尚未解锁（通关后的掉落中可选）" % str(game.core_types[i].get("name", "核心")))
		return
	game.selected_core = i
	game.awaiting_direction = false
	refresh_button_states()
	update_cost_ui()
	_refresh_info_box()
	if game.tutorial_spotlight == "core":
		game.tutorial_spotlight = "map"
		game.guide.update_spotlight()
	game.hud.update_status()
	game.queue_redraw()

func refresh_core_unlocks() -> void:
	if game.selected_core >= 0 and not _type_unlocked(game.selected_core):
		game.selected_core = -1
	if core_grid != null:
		_populate_core_buttons()
	update_cost_ui()
	_refresh_info_box()
	game.hud.update_status()
	game.queue_redraw()

func visible_core_indices() -> Array[int]:
	var out: Array[int] = []
	for i in range(game.core_types.size()):
		if _type_unlocked(i):
			out.append(i)
	return out

func _type_unlocked(i: int) -> bool:
	if game.rewards != null:
		return game.rewards.is_type_unlocked(i)
	return game.unlocked_core_ids.has(str(game.core_types[i].get("id", "")))

# ---------------------------------------------------------------------------
# 费用
# ---------------------------------------------------------------------------
func cost_text() -> String:
	return "%d/%d" % [game.deploy_points, PlayerCore.DEPLOY_COST_MAX]

func update_cost_ui() -> void:
	if cost_label != null:
		cost_label.text = str(game.deploy_points)
	if cost_ring != null:
		cost_ring.queue_redraw()
	if current_cost_label != null:
		if game.selected_core >= 0 and game.selected_core < game.core_types.size():
			var cost: int = game.drop_effects.deploy_cost(game.selected_core)
			current_cost_label.text = "消耗 %d" % cost
			current_cost_label.visible = true
		else:
			current_cost_label.visible = false


# ---------------------------------------------------------------------------
# 内嵌组件：费用环（黄=已消耗 / 绿=剩余 / 红=将要消耗，红色闪烁）
# ---------------------------------------------------------------------------
class CostRing:
	extends Control

	var game
	var thickness := 7.0
	var _t := 0.0

	func _process(delta: float) -> void:
		_t += delta
		queue_redraw()  # 红色闪烁需要每帧重绘

	func _draw() -> void:
		if game == null:
			return
		var total := float(PlayerCore.DEPLOY_COST_MAX)
		var remaining := float(game.deploy_points)
		var consumed := total - remaining
		# 将要消耗 = 当前选中核心的费用
		var cost := 0.0
		if game.selected_core >= 0 and game.selected_core < game.core_types.size():
			cost = float(game.drop_effects.deploy_cost(game.selected_core))
		var center := size * 0.5
		var r := minf(size.x, size.y) * 0.5 - thickness
		var a0 := -PI * 0.5
		var blink := 0.55 + 0.45 * sin(_t * 8.0)
		var red := Color(1.0, 0.2, 0.2, blink)
		# 费用不足：整个环红色闪烁
		if cost > remaining:
			draw_arc(center, r, a0, a0 + TAU, 64, red, thickness)
			return
		# 三段：黄（已消耗）→ 红（将要消耗）→ 绿（剩余）
		var green := remaining - cost
		draw_arc(center, r, a0, a0 + TAU * (consumed / total), 64, Color("ffc107"), thickness)
		draw_arc(center, r, a0 + TAU * (consumed / total), a0 + TAU * ((consumed + cost) / total), 64, red, thickness)
		draw_arc(center, r, a0 + TAU * ((consumed + cost) / total), a0 + TAU, 64, Color("46d160"), thickness)


# ---------------------------------------------------------------------------
# 内嵌组件：闪烁红色文字（显示当前核心消耗费用）
# ---------------------------------------------------------------------------
class BlinkLabel:
	extends Label

	var blink_color := Color(1.0, 0.25, 0.25)
	var _t := 0.0

	func _process(delta: float) -> void:
		_t += delta
		var a := 0.7 + 0.3 * sin(_t * 8.0)
		add_theme_color_override("font_color", Color(blink_color.r, blink_color.g, blink_color.b, a))
