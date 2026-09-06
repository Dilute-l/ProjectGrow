extends Control

@onready var bg: Sprite2D = $Background

var _press_tween: Tween
var _base_scale: Vector2


func _ready() -> void:
	_base_scale = bg.scale
	_update_bg()
	get_viewport().size_changed.connect(_update_bg)
	# 音乐音量与游戏内绑定：BGM 挂到 Music 总线并按 volume.cfg 应用音量
	if has_node("BGM"):
		VolumeSettings.bind_music($BGM)


## 窗口尺寸变化时，让背景图跟着一起缩放并居中（以 1600×900 设计分辨率为基准）
func _update_bg() -> void:
	var vs := get_viewport_rect().size
	bg.scale = _base_scale * Vector2(vs.x / 1600.0, vs.y / 900.0)
	bg.position = vs * 0.5


func _on_button_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


func _on_dsh_button_down() -> void:
	$BIGFATFISH1.play()
	_press_anim($DSH, true)

func _on_dsh_button_up() -> void:
	$BIGFATFISH2.play()
	_press_anim($DSH, false)  

func _press_anim(btn: Button, down: bool) -> void:
	# 打断上一次还没播完的动画，避免快速连点卡形变
	if _press_tween != null and _press_tween.is_valid():
		_press_tween.kill()
	_press_tween = create_tween()
	if down:
		# 平滑压扁：0.08s 内缩到 0.9（可改 0.85~0.95 控制幅度）
		_press_tween.tween_property(btn, "scale", Vector2(0.32, 0.25), 0.08) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	else:
		# 平滑回弹：0.15s 回到原始大小，BACK 曲线会轻微过冲
		_press_tween.tween_property(btn, "scale", Vector2(0.3, 0.3), 0.15) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
