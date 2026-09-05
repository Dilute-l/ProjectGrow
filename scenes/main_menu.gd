extends Control

@onready var bg: Sprite2D = $Something

var _base_scale: Vector2


func _ready() -> void:
	_base_scale = bg.scale
	_update_bg()
	get_viewport().size_changed.connect(_update_bg)


## 窗口尺寸变化时，让背景图跟着一起缩放并居中（以 1600×900 设计分辨率为基准）
func _update_bg() -> void:
	var vs := get_viewport_rect().size
	bg.scale = _base_scale * Vector2(vs.x / 1600.0, vs.y / 900.0)
	bg.position = vs * 0.5


func _on_start_game_pressed() -> void:
	get_tree().change_scene_to_file("res://hex_game.tscn")


func _on_credits_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/credits.tscn")


func _on_quit_pressed() -> void:
	get_tree().quit()
