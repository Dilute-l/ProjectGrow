class_name HexTutorial
extends RefCounted

## 新手教程 —— 从 scripts/hex_game.gd 拆分出来的模块。
##
## 职责：首次运行检测、教程播放、聚光灯高亮、部署/攻击门槛的挂起与恢复、
## 以及重新播放教程。实际对话与 UI 由 Tutorial 场景类提供，本模块只负责
## 在教程与游戏状态之间来回切换。

var game

func _init(g) -> void:
	game = g

func check_first_run() -> void:
	if not FileAccess.file_exists(game.FIRST_RUN_FLAG):
		play()

func play() -> void:
	game.tutorial_active = true
	game.tutorial_node = Tutorial.new()
	game.add_child(game.tutorial_node)
	game.tutorial_node.finished.connect(on_finished)
	game.tutorial_node.core_selector_highlight_requested.connect(on_highlight)
	game.tutorial_node.deploy_wait_started.connect(on_deploy_wait)
	game.tutorial_node.attack_wait_started.connect(on_attack_wait)
	game._update_ui_scale()
	game.tutorial_node.start()

func on_finished() -> void:
	game.tutorial_active = false
	game.tutorial_spotlight = ""
	if game.tutorial_node != null:
		game.tutorial_node.queue_free()
		game.tutorial_node = null
	var f := FileAccess.open(game.FIRST_RUN_FLAG, FileAccess.WRITE)
	if f != null:
		f.close()

func on_highlight() -> void:
	# 聚光灯照右下角核心选择区，且取消已选核心，引导玩家先选核心类型
	game.tutorial_spotlight = "core"
	game.selected_core = -1
	game.core_selector_ui.refresh_button_states()
	game.hud.update_status()
	update_spotlight()
	game.queue_redraw()

func on_deploy_wait() -> void:
	# 教程要求玩家先部署一个触手：放开游戏输入
	game.tutorial_active = false
	game.tutorial_gate = "deploy"

func on_attack_wait() -> void:
	# growth 播完：让游戏继续运行，等待敌方第一次攻击
	game.tutorial_active = false
	game.tutorial_gate = "attack"
	game._set_paused(false)   # 需要战斗运行以触发敌方攻击，取消开局暂停

func on_deployed() -> void:
	game.tutorial_spotlight = ""
	game.tutorial_gate = ""
	game.tutorial_active = true
	update_spotlight()
	if game.tutorial_node != null:
		game.tutorial_node.notify_deployed()

func on_attack() -> void:
	game.tutorial_gate = ""
	game.tutorial_active = true
	if game.tutorial_node != null:
		game.tutorial_node.notify_enemy_attacked()

func replay() -> void:
	# 关闭控制台、清掉旧教程，复位游戏后重新播放
	game.console.close()
	if game.tutorial_node != null and is_instance_valid(game.tutorial_node):
		game.tutorial_node.queue_free()
		game.tutorial_node = null
	game.tutorial_active = false
	game.tutorial_gate = ""
	game.tutorial_spotlight = ""
	if game.mode != game.Mode.PLAY:
		game.editor.set_mode(game.Mode.PLAY)
	else:
		game.deploy.reset()
	play()

func update_spotlight() -> void:
	if game.tutorial_node == null:
		return
	match game.tutorial_spotlight:
		"core":
			game.tutorial_node.set_spotlight(game.core_selector_screen_rect())
		"map":
			game.tutorial_node.set_spotlight(game.geometry.map_spotlight_rect())
		_:
			game.tutorial_node.clear_spotlight()
