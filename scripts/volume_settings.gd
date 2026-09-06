class_name VolumeSettings
extends RefCounted

## 全场景共享的音量设置（主菜单 / 制作组 / 游戏内共用）。
## 方案：音乐统一走 Music 总线、音效走 SFX 总线、其余走 Master；
## 数值存到 user://volume.cfg，任何场景修改后其它场景读同一份配置 → 音量“绑定”。

const VOLUME_PATH := "user://volume.cfg"
const MASTER_DEFAULT := 1.0
# 音乐默认音量：相对旧默认 0dB 调小 10dB → 线性 10^(-10/20) ≈ 0.3162
const MUSIC_DEFAULT := 0.3162277660168379
const SFX_DEFAULT := 1.0


## 确保 Music / SFX 总线存在（Master 恒为 0 号，不可改名/删除）
static func ensure_buses() -> void:
	_ensure_bus("Music")
	_ensure_bus("SFX")


static func _ensure_bus(bus_name: String) -> void:
	if AudioServer.get_bus_index(bus_name) != -1:
		return
	AudioServer.add_bus()
	var idx := AudioServer.bus_count - 1
	AudioServer.set_bus_name(idx, bus_name)
	AudioServer.set_bus_send(idx, "Master")


## 读取音量配置（缺失键用默认值；音乐默认 -10dB）
static func load_values() -> Dictionary:
	var out := {"master": MASTER_DEFAULT, "music": MUSIC_DEFAULT, "sfx": SFX_DEFAULT}
	var cf := ConfigFile.new()
	if cf.load(VOLUME_PATH) == OK:
		out["master"] = clampf(float(cf.get_value("volume", "master", MASTER_DEFAULT)), 0.0, 1.0)
		out["music"] = clampf(float(cf.get_value("volume", "music", MUSIC_DEFAULT)), 0.0, 1.0)
		out["sfx"] = clampf(float(cf.get_value("volume", "sfx", SFX_DEFAULT)), 0.0, 1.0)
	return out


## 保存音量配置（游戏内滑杆修改时调用）
static func save_values(master: float, music: float, sfx: float) -> void:
	var cf := ConfigFile.new()
	cf.set_value("volume", "master", clampf(master, 0.0, 1.0))
	cf.set_value("volume", "music", clampf(music, 0.0, 1.0))
	cf.set_value("volume", "sfx", clampf(sfx, 0.0, 1.0))
	cf.save(VOLUME_PATH)


## 把保存的音量应用到各总线
static func apply() -> void:
	ensure_buses()
	var v := load_values()
	AudioServer.set_bus_volume_linear(0, v["master"])
	var mi := AudioServer.get_bus_index("Music")
	if mi != -1:
		AudioServer.set_bus_volume_linear(mi, v["music"])
	var si := AudioServer.get_bus_index("SFX")
	if si != -1:
		AudioServer.set_bus_volume_linear(si, v["sfx"])


## 把某个音乐播放器挂到 Music 总线并应用已保存音量（主菜单 / 制作组在 _ready 调用）
static func bind_music(player: AudioStreamPlayer) -> void:
	if player == null:
		return
	ensure_buses()
	player.bus = "Music"
	apply()
