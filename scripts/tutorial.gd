class_name Tutorial
extends CanvasLayer

## 新手教程 —— 对话式引导（在 hex_game 场景上叠加播放）
## 所有台词与说话人信息都从 res://data/tutorial_dialogue.json 读取，本脚本不写死任何文案。
## 阶段门槛：
##   - resource 第一句 => 发 core_selector_highlight_requested（聚光灯照右下角核心选择区）
##   - resource 最后一句 => 等待我方部署一个触手（deploy_wait_started / notify_deployed）
##   - growth 播完 => 等待敌方第一次攻击（attack_wait_started / notify_enemy_attacked）
## 视觉：聚光灯变暗（可挖洞高亮）+ 左侧占位符立绘 + 底部居中对话框（右下角“继续”）；点击任意位置推进。

signal finished
signal core_selector_highlight_requested
signal deploy_wait_started
signal attack_wait_started

const DIALOGUE_PATH := "res://data/tutorial_dialogue.json"

# 聚光灯遮罩：整屏变暗，但可挖出一个矩形“洞”作为高亮
class SpotlightDim:
	extends Control

	var hole := Rect2()
	var show_hole := false
	var dim_color := Color(0.0, 0.0, 0.0, 0.55)

	func _draw() -> void:
		if not show_hole:
			draw_rect(Rect2(Vector2.ZERO, size), dim_color)
			return
		var s := size
		var h := hole
		draw_rect(Rect2(0, 0, s.x, h.position.y), dim_color)  # 上
		draw_rect(Rect2(0, h.position.y + h.size.y, s.x, s.y - h.position.y - h.size.y), dim_color)  # 下
		draw_rect(Rect2(0, h.position.y, h.position.x, h.size.y), dim_color)  # 左
		draw_rect(Rect2(h.position.x + h.size.x, h.position.y, s.x - h.position.x - h.size.x, h.size.y), dim_color)  # 右
		draw_rect(h.grow(3.0), Color(1.0, 0.85, 0.2, 0.9), false, 3.0)  # 洞的边框

var speaker_name := ""
var speaker_prefix := ""
var stages: Array = []   # 每个元素：{ "id": String, "lines": Array[String] }
var stage_index := 0
var line_index := 0
var active := false
var waiting_deploy := false
var waiting_attack := false

var spotlight_dim: SpotlightDim
var panel: PanelContainer
var name_label: Label
var text_label: Label
var continue_button: Button

func _ready() -> void:
	layer = 30
	visible = false
	_load_dialogue()
	_build_ui()
	set_process_unhandled_input(true)

# 从 JSON 读取说话人信息与全部台词
func _load_dialogue() -> void:
	stages.clear()
	speaker_name = ""
	speaker_prefix = ""
	if FileAccess.file_exists(DIALOGUE_PATH):
		var f := FileAccess.open(DIALOGUE_PATH, FileAccess.READ)
		if f != null:
			var text := f.get_as_text()
			f.close()
			var data = JSON.parse_string(text)
			if data is Dictionary:
				speaker_name = str(data.get("speaker_name", ""))
				speaker_prefix = str(data.get("speaker_prefix", ""))
				var arr = data.get("stages", [])
				if arr is Array:
					for entry in arr:
						if entry is Dictionary:
							var lines: Array = []
							for ln in entry.get("lines", []):
								lines.append(str(ln))
							stages.append({"id": str(entry.get("id", "")), "lines": lines})

func _build_ui() -> void:
	# 1) 聚光灯遮罩（整屏变暗，可挖洞；不拦截点击）
	spotlight_dim = SpotlightDim.new()
	spotlight_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	spotlight_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(spotlight_dim)

	# 2) 占位符立绘（屏幕左侧，垂直居中）
	var portrait := Panel.new()
	portrait.custom_minimum_size = Vector2(220, 420)
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(portrait)
	portrait.set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT, Control.PRESET_MODE_MINSIZE, 40)
	var portrait_label := Label.new()
	portrait_label.text = "立绘占位符"
	portrait_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	portrait_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	portrait_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	portrait.add_child(portrait_label)

	# 3) 对话框（底部居中，右下角含“继续”按钮）
	panel = PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_bottom", 14)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	name_label = Label.new()
	name_label.add_theme_font_size_override("font_size", 18)
	name_label.add_theme_color_override("font_color", Color("ffd166"))
	vbox.add_child(name_label)

	text_label = Label.new()
	text_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text_label.add_theme_font_size_override("font_size", 17)
	text_label.custom_minimum_size = Vector2(520, 0)
	vbox.add_child(text_label)

	# 底部行：左侧留空，右侧放“继续”
	var bottom := HBoxContainer.new()
	vbox.add_child(bottom)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(spacer)
	continue_button = Button.new()
	continue_button.text = "继续 ▸"
	continue_button.pressed.connect(_advance)
	bottom.add_child(continue_button)

	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_MINSIZE, 24)

# 设置聚光灯高亮区域（矩形，屏幕坐标）
func set_spotlight(rect: Rect2) -> void:
	spotlight_dim.hole = rect
	spotlight_dim.show_hole = true
	spotlight_dim.queue_redraw()

# 取消聚光灯高亮（整屏均匀变暗）
func clear_spotlight() -> void:
	spotlight_dim.show_hole = false
	spotlight_dim.queue_redraw()

# 从头开始播放
func start() -> void:
	stage_index = 0
	line_index = 0
	active = true
	visible = true
	waiting_deploy = false
	waiting_attack = false
	_show_current()

func _show_current() -> void:
	if stage_index >= stages.size():
		_finish()
		return
	var lines: Array = stages[stage_index]["lines"]
	var stage_id: String = stages[stage_index]["id"]
	name_label.text = speaker_name if speaker_name != "" else "？"
	text_label.text = str(lines[line_index])
	# resource 第一句：请求高亮右下角核心选择区
	if stage_id == "resource" and line_index == 0:
		core_selector_highlight_requested.emit()
	# resource 最后一句：等待玩家部署一个触手
	if stage_id == "resource" and line_index == lines.size() - 1:
		waiting_deploy = true
		deploy_wait_started.emit()

func _advance() -> void:
	if not active:
		return
	if waiting_deploy or waiting_attack:
		return
	line_index += 1
	var lines: Array = stages[stage_index]["lines"]
	if line_index >= lines.size():
		line_index = 0
		stage_index += 1
		if stage_index >= stages.size():
			_finish()
			return
		var next_id: String = stages[stage_index]["id"]
		if next_id == "magical_girl":
			# growth 播完：先隐藏对话框，等待敌方第一次攻击
			waiting_attack = true
			visible = false
			attack_wait_started.emit()
			return
	_show_current()

# 玩家已部署一个触手：继续播放 growth 阶段
func notify_deployed() -> void:
	if not waiting_deploy:
		return
	waiting_deploy = false
	_advance()

# 我方地块已受到敌方第一次攻击：暂停游戏并播放 magical_girl 阶段
func notify_enemy_attacked() -> void:
	if not waiting_attack:
		return
	waiting_attack = false
	visible = true
	_show_current()

func _finish() -> void:
	active = false
	visible = false
	finished.emit()

func _unhandled_input(event: InputEvent) -> void:
	if not active:
		return
	if event is InputEventKey and event.pressed and (event.keycode == KEY_SPACE or event.keycode == KEY_ENTER):
		_advance()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_advance()
