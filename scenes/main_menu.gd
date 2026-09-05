extends Control


func _on_start_game_pressed() -> void:
	get_tree().change_scene_to_file("res://hex_game.tscn")


func _on_credits_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/credits.tscn")


func _on_quit_pressed() -> void:
	get_tree().quit()
