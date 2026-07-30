# gdlint: disable=variable-name, max-line-length
## GPU 行星 LOD 调试工具。
##
## F1 — 切换线框显示(看清 patch 三角形网格)。
## F2 — 冻结 / 解冻 LOD:
##   冻结时把驱动 LOD 的相机快照定住(GpuPlanet.freeze_lod), 再生成一个独立的旁观相机接管画面,
##   于是 LOD/裁剪结果被定格, 你可以飞到任意角度看清冻结后的地形(诊断焊接裂缝 / LOD 壳环)。
##   旁观相机: WASD 平移, Q/E 升降, 右键拖动看向, 滚轮调速, Shift 加速。再按 F2 解冻恢复原相机。
##
## 自动查找场景里的 GpuPlanet 及其 LOD 相机, 无需手动接线。纯调试节点, 不影响正式渲染路径。
extends Node

@export var move_speed: float = 120.0        # 基础飞行速度(世界单位/秒)
@export var mouse_sensitivity: float = 0.003

var _gpu_planet: GpuPlanet
var _lod_camera: Camera3D
var _spectator: Camera3D
var _frozen := false
var _wireframe := false
var _spec_yaw: float = 0.0
var _spec_pitch: float = 0.0
var _speed_mult: float = 1.0

var _hud_layer: CanvasLayer   # LOD 统计 HUD(验证 Phase 6 方案 B: 提交 instance 数应远小于 MAX_PATCHES)
var _hud_label: Label


func _ready() -> void:
	_gpu_planet = _find_gpu_planet(get_tree().root)
	if _gpu_planet != null:
		_lod_camera = _gpu_planet.camera
	else:
		push_warning("[LODDebug] 未找到 GpuPlanet 节点, F2 冻结不可用")
	_build_hud()


# LOD 统计 HUD: 显示回读的可见 patch 数 + 实际提交的 instance 数。
# Phase 6 方案 B 生效时"提交"应从 MAX_PATCHES(12288)降到 可见 patch 数 + 余量。
func _build_hud() -> void:
	_hud_layer = CanvasLayer.new()
	add_child(_hud_layer)
	_hud_label = Label.new()
	_hud_label.position = Vector2(8, 44)   # 避开 fps.tscn 的 FPS Label(在 y=8)
	_hud_label.add_theme_font_size_override("font_size", 16)
	_hud_label.add_theme_color_override("font_color", Color.WHITE)
	_hud_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	_hud_label.add_theme_constant_override("shadow_offset_x", 1)
	_hud_label.add_theme_constant_override("shadow_offset_y", 1)
	_hud_layer.add_child(_hud_label)


func _update_hud() -> void:
	if _hud_label == null or _gpu_planet == null:
		return
	var s: Dictionary = _gpu_planet.get_lod_stats()
	var vis: int = int(s.get("visible", -1))
	var sub: int = int(s.get("submitted", 0))
	var mx: int = int(s.get("max", 0))
	var vis_txt: String = str(vis) if vis >= 0 else "…(回读未就绪)"
	var occ: bool = bool(s.get("occlusion", false))          # 意愿开关(F3)
	var occ_app: bool = bool(s.get("occlusion_applied", false))  # cull 实际是否应用(运动门后)
	var hor: bool = bool(s.get("horizon", false))
	var occ_txt: String = "关"
	if occ:
		occ_txt = "开" if occ_app else "开(运动暂停)"   # 意愿开但运动中被门控暂停
	_hud_label.text = "LOD 可见 patch: %s   提交 instance: %d / %d%s\n遮挡剔除(F3): %s   地平线剔除(F4): %s" % [
		vis_txt, sub, mx, ("   [LOD 冻结]" if _frozen else ""),
		occ_txt, ("开" if hor else "关")]


func _find_gpu_planet(n: Node) -> GpuPlanet:
	if n is GpuPlanet:
		return n as GpuPlanet
	for c in n.get_children():
		var r: GpuPlanet = _find_gpu_planet(c)
		if r != null:
			return r
	return null


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F1:
			_toggle_wireframe()
		elif event.keycode == KEY_F2:
			_toggle_freeze()
		elif event.keycode == KEY_F3:
			if _gpu_planet != null:
				print("[LODDebug] 遮挡剔除(Hi-Z): %s" % ("开" if _gpu_planet.debug_toggle_occlusion() else "关"))
		elif event.keycode == KEY_F4:
			if _gpu_planet != null:
				print("[LODDebug] 地平线剔除: %s" % ("开" if _gpu_planet.debug_toggle_horizon() else "关"))
	if not _frozen or not is_instance_valid(_spectator):
		return
	# 旁观相机: 右键拖动看向。
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		_spec_yaw -= event.relative.x * mouse_sensitivity
		_spec_pitch = clamp(_spec_pitch - event.relative.y * mouse_sensitivity, -1.55, 1.55)
		_apply_spectator_rotation()
	# 滚轮调速。
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_speed_mult = min(_speed_mult * 1.25, 64.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_speed_mult = max(_speed_mult / 1.25, 0.05)


func _toggle_wireframe() -> void:
	_wireframe = not _wireframe
	if _gpu_planet != null:
		_gpu_planet.set_wireframe(_wireframe)   # 单遍着色器线框, 无额外 line pass, 不掉帧
	print("[LODDebug] 线框: %s" % ("开" if _wireframe else "关"))


func _toggle_freeze() -> void:
	if _gpu_planet == null:
		push_warning("[LODDebug] 未找到 GpuPlanet, F2 无效")
		return
	if not _frozen:
		_enter_freeze()
	else:
		_exit_freeze()


func _enter_freeze() -> void:
	_gpu_planet.freeze_lod()
	# 建旁观相机, 初始位姿 = 当前 LOD 相机, 画面不跳变。
	_spectator = Camera3D.new()
	_spectator.name = "SpectatorCam"
	_spectator.fov = 60.0
	_spectator.near = 0.1
	_spectator.far = 500000.0
	add_child(_spectator)
	if is_instance_valid(_lod_camera):
		_spectator.global_transform = _lod_camera.global_transform
	# 从当前朝向反推 yaw/pitch(去掉可能的 roll), 之后鼠标控制才连续。
	var fwd: Vector3 = -_spectator.global_transform.basis.z
	_spec_yaw = atan2(-fwd.x, -fwd.z)
	_spec_pitch = asin(clamp(fwd.y, -1.0, 1.0))
	_apply_spectator_rotation()
	_spectator.current = true
	_frozen = true
	print("[LODDebug] LOD 已冻结; 旁观相机激活 —— WASD 平移 / Q,E 升降 / 右键拖动看向 / 滚轮调速 / Shift 加速")


func _exit_freeze() -> void:
	_gpu_planet.unfreeze_lod()
	if is_instance_valid(_lod_camera):
		_lod_camera.current = true
	if is_instance_valid(_spectator):
		_spectator.queue_free()
	_spectator = null
	_frozen = false
	print("[LODDebug] 已解冻; 恢复 LOD 相机")


func _apply_spectator_rotation() -> void:
	if not is_instance_valid(_spectator):
		return
	var t: Transform3D = _spectator.global_transform
	t.basis = Basis.from_euler(Vector3(_spec_pitch, _spec_yaw, 0.0))
	_spectator.global_transform = t


func _process(delta: float) -> void:
	_update_hud()
	if not _frozen or not is_instance_valid(_spectator):
		return
	var input := Vector3.ZERO
	if Input.is_action_pressed("move_forward"):
		input.z -= 1.0
	if Input.is_action_pressed("move_back"):
		input.z += 1.0
	if Input.is_action_pressed("move_left"):
		input.x -= 1.0
	if Input.is_action_pressed("move_right"):
		input.x += 1.0
	if Input.is_physical_key_pressed(KEY_E):
		input.y += 1.0
	if Input.is_physical_key_pressed(KEY_Q):
		input.y -= 1.0
	if input == Vector3.ZERO:
		return
	var speed: float = move_speed * _speed_mult
	if Input.is_physical_key_pressed(KEY_SHIFT):
		speed *= 4.0
	var move: Vector3 = _spectator.global_transform.basis * input.normalized()
	_spectator.global_position += move * speed * delta
