extends Control

@onready var bg: Sprite2D = $Background

var _press_tween: Tween
var _base_scale: Vector2

const MEMBER_CARDS := ["Dilute", "Catkin", "Midu", "M3", "Hatori"]

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
	_press_fx($DSH, true)

func _on_dsh_button_up() -> void:
	$BIGFATFISH2.play()
	_press_fx($DSH, false)  
	
	

func _press_fx(btn: Button, down: bool) -> void:
	if btn == null:
		return
	if down:
		$BIGFATFISH1.play()          # 按下音
	else:
		$BIGFATFISH2.play()          # 松开音
	# 第一次按下时记住该按钮自己的原始 scale
	if not btn.has_meta("base_scale"):
		btn.set_meta("base_scale", btn.scale)
	var base: Vector2 = btn.get_meta("base_scale")
	if _press_tween != null and _press_tween.is_valid():
		_press_tween.kill()
	_press_tween = create_tween()
	if down:
		# 压扁：横向微撑、纵向压到约 0.7（幅度自己调到顺手）
		_press_tween.tween_property(btn, "scale", Vector2(base.x * 1.05, base.y * 0.7), 0.08) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	else:
		# 回弹到初始大小（BACK 轻微过冲）
		_press_tween.tween_property(btn, "scale", base, 0.15) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _on_catkin_button_down() -> void:
	$BIGFATFISH1.play()
	_press_fx($Catkin/CatkinBtn, true)
	
func _on_catkin_button_up() -> void:
	_toggle_card_hidden()
	$BIGFATFISH2.play()
	_press_fx($Catkin/CatkinBtn, false)
	
func _toggle_card_hidden() -> void:
	for card in MEMBER_CARDS:
		var hidden: CanvasItem = get_node_or_null("%s/Hidden" % card)
		var tile: CanvasItem = get_node_or_null("%s/BlackTile" % card)
		if hidden != null:
			hidden.visible = not hidden.visible
		if tile != null:
			tile.visible = not tile.visible
