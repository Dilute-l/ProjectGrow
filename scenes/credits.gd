extends Control

var _press_tween: Tween

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
