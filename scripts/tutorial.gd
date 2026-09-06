class_name Tutorial
extends CanvasLayer

## 新手教程 —— 对话式引导（在 hex_game 场景上叠加播放）
## 所有台词与说话人信息都从 res://data/tutorial_dialogue.json 读取，本脚本不写死任何文案。
## 阶段门槛：
##   - resource 第一句 => 发 core_selector_highlight_requested（聚光灯照右下角核心选择区）
##   - resource 最后一句 => 等待我方部署一个触手（deploy_wait_started / notify_deployed）
##   - growth 播完 => 等待敌方第一次攻击（attack_wait_started / notify_enemy_attacked）
## 视觉：聚光灯变暗（可挖洞高亮）+ 左侧立绘 + 底部居中对话框（右下角“继续”）；点击任意位置推进。

signal finished
signal core_selector_highlight_requested
signal deploy_wait_started
signal attack_wait_started

const DIALOGUE_PATH := "res://data/tutorial_dialogue.json"
const PORTRAIT := preload("res://images/brain_washed/brain washed_001.png")

# 聚光灯遮罩：整屏变暗，但可挖出一个矩形“洞”作为高亮
class SpotlightDim:
	extends Control

	var hole := Rect2()
	var show_hole := false
	var dim_color := Color(0.0, 0.0, 0.0, 0.55)

	func _draw() -> void:
		# 遮罩画得足够大，保证教程层被缩放后仍能覆盖全屏
		var big := 100000.0
		var h := hole
		if not show_hole:
			draw_rect(Rect2(-big, -big, 2.0 * big, 2.0 * big), dim_color)
			return
		draw_rect(Rect2(-big, -big, 2.0 * big, h.position.y + big), dim_color)  # 上
		draw_rect(Rect2(-big, h.position.y + h.size.y, 2.0 * big, big - h.position.y - h.size.y), dim_color)  # 下
		draw_rect(Rect2(-big, h.position.y, h.position.x + big, h.size.y), dim_color)  # 左
		draw_rect(Rect2(h.position.x + h.size.x, h.position.y, big - h.position.x - h.size.x, h.size.y), dim_color)  # 右
		draw_rect(h.grow(3.0), Color(1.0, 0.85, 0.2, 0.9), false, 3.0)  # 洞的边框

var speaker_name := ""
var speaker_prefix := ""
var stages: Array = []   # 每个元素：{ "id": String, "lines": Array[String] }
static var enemy_stages: Dictionary = {}   # 敌人类型 -> 首次遭遇台词（与 stages 同源 JSON）
var extra_stages: Dictionary = {}   # 一次性剧情对话：id -> 台词（如 expand；不参与 start() 线性流程）
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
				_parse_enemy_stages(data)
				_parse_extra_stages(data)

# 从已解析的 JSON 数据中读取敌人首次遭遇台词（敌人类型 -> 台词数组）
static func _parse_enemy_stages(data) -> void:
	enemy_stages.clear()
	if data is Dictionary:
		var es = data.get("enemy_stages", {})
		if es is Dictionary:
			for k in es.keys():
				var lines: Array = []
				for ln in es[k]:
					lines.append(str(ln))
				enemy_stages[str(k)] = lines

# 静态加载：供主脚本在创建 Tutorial 节点之前提前获知哪些敌人有专属教程
static func load_enemy_stages() -> void:
	enemy_stages.clear()
	if FileAccess.file_exists(DIALOGUE_PATH):
		var f := FileAccess.open(DIALOGUE_PATH, FileAccess.READ)
		if f != null:
			var text := f.get_as_text()
			f.close()
			_parse_enemy_stages(JSON.parse_string(text))

# 从已解析的 JSON 数据中读取一次性剧情对话（id -> 台词；供 start_stage 按需播放）
func _parse_extra_stages(data) -> void:
	extra_stages.clear()
	if data is Dictionary:
		var es = data.get("extra_stages", {})
		if es is Dictionary:
			for k in es.keys():
				var lines: Array = []
				for ln in es[k]:
					lines.append(str(ln))
				extra_stages[str(k)] = lines

func _build_ui() -> void:
	# 1) 聚光灯遮罩（整屏变暗，可挖洞；不拦截点击）
	spotlight_dim = SpotlightDim.new()
	spotlight_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	spotlight_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(spotlight_dim)

	# 2) 立绘（屏幕左侧，下端对齐屏幕底边；高度约占屏幕 75%；Brain Washed 立绘，等比缩放）
	var portrait_size := Vector2(675, 675)
	var portrait := TextureRect.new()
	portrait.texture = PORTRAIT
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	portrait.custom_minimum_size = portrait_size
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(portrait)
	# 显式设置锚点与偏移：左侧 40px、下端对齐屏幕底边
	portrait.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	portrait.offset_left = 40.0
	portrait.offset_top = -portrait_size.y
	portrait.offset_right = 40.0 + portrait_size.x
	portrait.offset_bottom = 0.0

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

# 设置聚光灯高亮区域（矩形，屏幕坐标）。
# 教程层可能被缩放，因此把屏幕坐标换算回层内坐标，保证挖洞位置正确。
func set_spotlight(rect: Rect2) -> void:
	var s := scale.x
	var off := offset
	spotlight_dim.hole = Rect2((rect.position - off) / s, rect.size / s)
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

# 播放某个敌人类型的首次遭遇对话（单阶段、无部署/攻击门槛，播完即结束）
func start_enemy(enemy_type: String) -> void:
	var lines: Array = enemy_stages.get(enemy_type, [])
	if lines.is_empty():
		finished.emit()
		return
	stages = [{"id": "enemy_" + enemy_type, "lines": lines}]
	stage_index = 0
	line_index = 0
	active = true
	visible = true
	waiting_deploy = false
	waiting_attack = false
	_show_current()

## 播放某个一次性剧情对话（extra_stages 段，如进入拓展关卡时的 expand）；
## 单阶段、无部署/攻击门槛，播完即结束；找不到该 id 返回 false
func start_stage(stage_id: String) -> bool:
	if not extra_stages.has(stage_id):
		return false
	var lines: Array = extra_stages[stage_id]
	stages = [{"id": stage_id, "lines": lines}]
	stage_index = 0
	line_index = 0
	active = true
	visible = true
	waiting_deploy = false
	waiting_attack = false
	_show_current()
	return true

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
