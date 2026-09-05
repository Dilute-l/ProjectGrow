class_name HexLevelSelect
extends RefCounted

## 随机关卡选择 —— 纯数字难度模型。
## 第 (completed + 1) 关在难度 == completed + 1 的关卡中随机选择。
## 关卡难度从 JSON 顶层 "difficulty"（兼容 "Difficulty"）读取，缺省 1。
## 当前每个难度只有一关（level_i 的难度 = i），故第 i 关实际就是 level_i。

var game

func _init(g) -> void:
	game = g

## 默认难度（difficulty 缺失时）
const DEFAULT_DIFFICULTY := 1

var _difficulty_cache: Dictionary = {}

# ---------------------------------------------------------------------------
# 关卡列表
# ---------------------------------------------------------------------------
## 全部关卡路径（顺序 = game.LEVEL_PATHS）
func level_paths() -> Array:
	var out: Array = []
	for p in game.LEVEL_PATHS:
		out.append(str(p))
	return out

## 指定下标对应的关卡路径（越界返回 ""）
func path_of_index(idx: int) -> String:
	if idx < 0 or idx >= game.LEVEL_PATHS.size():
		return ""
	return str(game.LEVEL_PATHS[idx])

## 指定路径在关卡表中的下标（不在表中返回 -1）
func index_of_path(path: String) -> int:
	for i in range(game.LEVEL_PATHS.size()):
		if str(game.LEVEL_PATHS[i]) == path:
			return i
	return -1

## 读取某关卡的难度（整数；顶层 "difficulty"/"Difficulty"，缺省 1）
func difficulty_of(path: String) -> int:
	if _difficulty_cache.has(path):
		return int(_difficulty_cache[path])
	var diff := DEFAULT_DIFFICULTY
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			var text := f.get_as_text()
			f.close()
			var data = JSON.parse_string(text)
			if data is Dictionary:
				diff = int(data.get("difficulty", data.get("Difficulty", DEFAULT_DIFFICULTY)))
	_difficulty_cache[path] = diff
	return diff

## 清空难度缓存（关卡文件被改动后调用以重新读取）
func clear_cache() -> void:
	_difficulty_cache.clear()

# ---------------------------------------------------------------------------
# 随机下一关
# ---------------------------------------------------------------------------
## 核心接口：在结束一关后调用。
## completed = 已完成的总关卡数；下一关目标难度 = completed + 1。
## 在难度 == 目标难度的关卡中随机选一个；exclude 用于排除指定路径（可传 ""）。
## 返回随机选中的下一关路径；没有任何符合条件的关卡时返回 ""。
func pick_next_level(completed: int, exclude: String = "") -> String:
	var target := completed
	var candidates: Array = []
	for p in level_paths():
		if exclude != "" and str(p) == str(exclude):
			continue
		if difficulty_of(str(p)) == target:
			candidates.append(str(p))
	if candidates.is_empty():
		return ""
	candidates.shuffle()
	return str(candidates[0])
