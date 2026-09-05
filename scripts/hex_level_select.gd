class_name HexLevelSelect
extends RefCounted

## 随机关卡选择 —— 独立模块（暂未接入 hex_game，接入时照其它模块在
## hex_game.gd 的 _create_modules() 里装配即可）。
##
## 职责：
##   - 读取每个关卡 JSON 的 Difficulty 参数（当前全部为占位符 "easy"）；
##   - 根据「已完成的总关卡数」推断本次允许的难度集合；
##   - 在符合难度条件的关卡中随机指定一个作为下一关。
##
## 难度模型（扩展点）：
##   DIFFICULTY_ORDER 决定难度大小顺序；
##   DIFFICULTY_UNLOCK 记录每种难度需要至少完成几关才解锁。
##   当前只有 "easy"（解锁门槛 0），后续新增 medium/hard 时只需：
##     1) 在 DIFFICULTY_ORDER 中按顺序加入；
##     2) 在 DIFFICULTY_UNLOCK 中写解锁门槛；
##     3) 在个别关卡 JSON 里把 "difficulty" 改成对应值。
##
## 关卡来源：沿用 game.LEVEL_PATHS（hex_game.gd 里的关卡路径表），
## 每关的 difficulty 从该 JSON 顶层字段 "difficulty"（兼容 "Difficulty"）读取。

var game

func _init(g) -> void:
	game = g

## 难度由易到难排序（先 easy；后续加 medium / hard 时按序追加）
const DIFFICULTY_ORDER: Array[String] = ["easy"]

## 每种难度最少需要完成的关卡数（<= completed 才允许进入候选池）
const DIFFICULTY_UNLOCK := {
	"easy": 0,
	# "medium": 3,   # 示例：完成 3 关后才允许 medium
	# "hard": 6,     # 示例：完成 6 关后才允许 hard
}

## difficulty 字段读取失败 / 缺失时的默认值
const DEFAULT_DIFFICULTY := "easy"

## 缓存：关卡路径 -> difficulty（首次读取后缓存，关卡文件改动可调 clear_cache()）
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

## 读取某关卡的 difficulty（顶层 "difficulty" / "Difficulty"；缺省 easy）
func difficulty_of(path: String) -> String:
	if _difficulty_cache.has(path):
		return str(_difficulty_cache[path])
	var diff := DEFAULT_DIFFICULTY
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			var text := f.get_as_text()
			f.close()
			var data = JSON.parse_string(text)
			if data is Dictionary:
				var v = data.get("difficulty", data.get("Difficulty", DEFAULT_DIFFICULTY))
				diff = str(v)
	_difficulty_cache[path] = diff
	return diff

## 清空难度缓存（关卡文件被改动后调用以重新读取）
func clear_cache() -> void:
	_difficulty_cache.clear()

# ---------------------------------------------------------------------------
# 难度判定
# ---------------------------------------------------------------------------
## 给定已完成关卡数，返回本次允许的难度集合（按 DIFFICULTY_ORDER 顺序）
func allowed_difficulties(completed: int) -> Array:
	var out: Array = []
	for d in DIFFICULTY_ORDER:
		if completed >= int(DIFFICULTY_UNLOCK.get(d, 0)):
			out.append(d)
	return out

## 某关卡的难度是否在给定集合里
func _level_matches(path: String, allowed: Array) -> bool:
	return allowed.has(difficulty_of(path))

# ---------------------------------------------------------------------------
# 随机下一关
# ---------------------------------------------------------------------------
## 核心接口：在结束一关后调用。
## completed   = 已完成的总关卡数（决定解锁哪些难度）；
## exclude     = 想排除的关卡路径（通常是刚打完的那关，避免立刻重打同关；可传 ""）。
## 返回随机选中的下一关路径；没有任何符合条件的关卡时返回 ""。
func pick_next_level(completed: int, exclude: String = "") -> String:
	var allowed := allowed_difficulties(completed)
	if allowed.is_empty():
		return ""
	var candidates: Array = []
	for p in level_paths():
		if exclude != "" and str(p) == str(exclude):
			continue
		if _level_matches(str(p), allowed):
			candidates.append(str(p))
	# 若排除后一个都不剩（例如全表只有一关且被排除），则放宽：允许再算上排除项
	if candidates.is_empty() and exclude != "":
		for p in level_paths():
			if _level_matches(str(p), allowed):
				candidates.append(str(p))
	if candidates.is_empty():
		return ""
	candidates.shuffle()
	return str(candidates[0])
