extends Control

## 游戏开始界面（主菜单）
## 标题与背景均为占位符。点击「开始游戏」进入游戏；新手教程由游戏侧根据首次标记自动决定是否播放。
## 「退出」直接关闭游戏。

const GAME_SCENE := "res://hex_game.tscn"

var menu_container: CenterContainer
var title_label: Label
var start_btn: Button
var quit_btn: Button

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()

func _build_ui() -> void:
	# 背景占位符
	var bg := ColorRect.new()
	bg.color = Color("131a2e")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	menu_container = CenterContainer.new()
	menu_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(menu_container)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 28)
	menu_container.add_child(vbox)

	title_label = Label.new()
	title_label.text = "这里是占位符标题"
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_label.add_theme_font_size_override("font_size", 48)
	vbox.add_child(title_label)

	start_btn = Button.new()
	start_btn.text = "开始游戏"
	start_btn.custom_minimum_size = Vector2(260, 56)
	start_btn.pressed.connect(_on_start_pressed)
	vbox.add_child(start_btn)

	quit_btn = Button.new()
	quit_btn.text = "退出"
	quit_btn.custom_minimum_size = Vector2(260, 56)
	quit_btn.pressed.connect(_on_quit_pressed)
	vbox.add_child(quit_btn)

func _on_start_pressed() -> void:
	get_tree().change_scene_to_file(GAME_SCENE)

func _on_quit_pressed() -> void:
	get_tree().quit()
