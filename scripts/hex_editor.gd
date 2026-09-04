class_name HexEditor
extends RefCounted

## 地图编辑器 —— 从 scripts/hex_game.gd 拆分出来的模块。
##
## 职责：游玩/编辑模式切换、编辑器的输入处理（放置/擦除墙与炮台）、笔刷与半径调整、
## 导入/导出对话框，以及编辑器工具栏与文件对话框的 UI 构建。

var game

func _init(g) -> void:
	game = g

func toggle_mode() -> void:
	set_mode(game.Mode.EDIT if game.mode == game.Mode.PLAY else game.Mode.PLAY)

func set_mode(m: int) -> void:
	game.mode = m
	game.deploy.reset()
	game.editor_layer.visible = (game.mode == game.Mode.EDIT)
	game.core_selector_layer.visible = (game.mode == game.Mode.PLAY)
	if game.mode_button:
		game.mode_button.text = "编辑模式" if game.mode == game.Mode.PLAY else "游玩模式"
	game.hud.update_status()
	game.queue_redraw()

func handle_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		game.hover_cell = game.geometry.pixel_to_hex(event.position)
		game.queue_redraw()
	elif event is InputEventMouseButton and event.pressed:
		var cell: Vector2i = game.geometry.pixel_to_hex(event.position)
		if not game.geometry.in_bounds(cell):
			return
		if event.button_index == MOUSE_BUTTON_LEFT:
			place(cell)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			erase(cell)

func place(cell: Vector2i) -> void:
	if game.editor_brush == 0:  # 墙
		game.walls[cell] = true
		game.turret_positions.erase(cell)  # 墙与炮台不重叠
	else:  # 炮台
		game.walls.erase(cell)
		if not game.turret_positions.has(cell):
			game.turret_positions.append(cell)
	game.queue_redraw()

func erase(cell: Vector2i) -> void:
	game.walls.erase(cell)
	game.turret_positions.erase(cell)
	game.queue_redraw()

func select_brush(i: int) -> void:
	game.editor_brush = i
	if game.wall_btn:
		game.wall_btn.button_pressed = (i == 0)
	if game.turret_btn:
		game.turret_btn.button_pressed = (i == 1)

func change_radius(delta: int) -> void:
	game.map_radius = clampi(game.map_radius + delta, 1, 10)
	game.map_data.prune_map()
	game.total_hexes = game.geometry.all_cells().size()
	game.geometry.fit_hex_size()
	game.geometry.recenter()
	if game.radius_label:
		game.radius_label.text = "半径 %d" % game.map_radius
	game.queue_redraw()

func open_import_dialog() -> void:
	game.file_dialog_purpose = 0
	game.file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	game.file_dialog.current_dir = ProjectSettings.globalize_path("res://maps")
	game.file_dialog.popup_centered()

func open_export_dialog() -> void:
	game.file_dialog_purpose = 1
	game.file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	game.file_dialog.current_dir = ProjectSettings.globalize_path("res://maps")
	game.file_dialog.popup_centered()

func on_file_selected(path: String) -> void:
	if game.file_dialog_purpose == 0:
		game.map_data.import_map(path)
	else:
		game.map_data.export_map(path)

func build_editor_ui() -> void:
	game.editor_layer = CanvasLayer.new()
	game.editor_layer.layer = 10
	game.editor_layer.visible = false
	game.add_child(game.editor_layer)

	var panel := PanelContainer.new()
	game.editor_layer.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 8)
	panel.add_child(margin)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	margin.add_child(hbox)

	var lbl := Label.new()
	lbl.text = "地图编辑："
	hbox.add_child(lbl)

	var group := ButtonGroup.new()
	game.wall_btn = Button.new()
	game.wall_btn.text = "墙"
	game.wall_btn.toggle_mode = true
	game.wall_btn.button_group = group
	game.wall_btn.button_pressed = true
	game.wall_btn.pressed.connect(select_brush.bind(0))
	hbox.add_child(game.wall_btn)

	game.turret_btn = Button.new()
	game.turret_btn.text = "炮台"
	game.turret_btn.toggle_mode = true
	game.turret_btn.button_group = group
	game.turret_btn.pressed.connect(select_brush.bind(1))
	hbox.add_child(game.turret_btn)

	hbox.add_child(VSeparator.new())

	var minus := Button.new()
	minus.text = "-"
	minus.pressed.connect(change_radius.bind(-1))
	hbox.add_child(minus)

	game.radius_label = Label.new()
	game.radius_label.text = "半径 %d" % game.map_radius
	hbox.add_child(game.radius_label)

	var plus := Button.new()
	plus.text = "+"
	plus.pressed.connect(change_radius.bind(1))
	hbox.add_child(plus)

	hbox.add_child(VSeparator.new())

	var import_btn := Button.new()
	import_btn.text = "导入 JSON"
	import_btn.pressed.connect(open_import_dialog)
	hbox.add_child(import_btn)

	var export_btn := Button.new()
	export_btn.text = "导出 JSON"
	export_btn.pressed.connect(open_export_dialog)
	hbox.add_child(export_btn)

	# 先添加子节点再设置锚点，确保按实际内容尺寸居中于顶部
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_MINSIZE, 12)

func build_file_dialog() -> void:
	game.file_dialog = FileDialog.new()
	game.file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	game.file_dialog.add_filter("*.json", "JSON 文件")
	game.file_dialog.file_selected.connect(on_file_selected)
	game.add_child(game.file_dialog)
