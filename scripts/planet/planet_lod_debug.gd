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

# 冻结画中画(右上角): 显示冻结瞬间视点看到的画面, 用于判断剔除是否误剔(见 _build_frozen_pip)。
var _pip_layer: CanvasLayer
var _pip_viewport: SubViewport
var _pip_camera: Camera3D


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
	var occ_app: bool = bool(s.get("occlusion_applied", false))  # cull 实际是否应用(经模式门后)
	var hor: bool = bool(s.get("horizon", false))
	var surface: bool = bool(s.get("surface_mode", true))
	var mode_txt: String = "CHARACTER(贴地)" if surface else "PLANET(高空)"
	var occ_txt: String = "关"
	if occ:
		occ_txt = "开" if occ_app else "开(此模式停用)"   # 意愿开但当前模式门控停用
	_hud_label.text = "模式(M): %s   LOD 可见 patch: %s   提交 instance: %d / %d%s\n遮挡剔除(F3): %s   地平线剔除(F4): %s" % [
		mode_txt, vis_txt, sub, mx, ("   [LOD 冻结]" if _frozen else ""),
		occ_txt, ("开" if hor else "关")]


func _find_gpu_planet(n: Node) -> GpuPlanet:
	if n is GpuPlanet:
		return n as GpuPlanet
	for c in n.get_children():
		var r: GpuPlanet = _find_gpu_planet(c)
		if r != null:
			return r
	return null


# 冻结期间挂起/恢复角色键盘输入(WASD 归旁观相机)。靠 has_method 鸭子类型查找, 不硬依赖角色脚本类型;
# 场景里没有角色(纯星球测试场景)时静默跳过。
func _suspend_character_input(suspended: bool) -> void:
	var n: Node = _find_character(get_tree().root)
	if n != null:
		n.call("set_input_suspended", suspended)


func _find_character(n: Node) -> Node:
	if n.has_method("set_input_suspended"):
		return n
	for c in n.get_children():
		var r: Node = _find_character(c)
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
	# 挂起角色键盘输入: 冻结期间 WASD 用来飞旁观相机, 否则会同时驱动角色(角色跑走 + 画面乱)。
	_suspend_character_input(true)
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
	_build_frozen_pip()
	_frozen = true
	print("[LODDebug] LOD 已冻结; 旁观相机激活 —— WASD 平移 / Q,E 升降 / 右键拖动看向 / 滚轮调速 / Shift 加速")
	print("[LODDebug] 右上角画中画 = 冻结瞬间的视角(剔除就是按它算的): 那里画面完整 → 剔除正确; 缺地形 → 误剔")


func _exit_freeze() -> void:
	_gpu_planet.unfreeze_lod()
	_suspend_character_input(false)   # 恢复角色键盘控制
	if is_instance_valid(_lod_camera):
		_lod_camera.current = true
	if is_instance_valid(_spectator):
		_spectator.queue_free()
	_spectator = null
	_free_frozen_pip()
	_frozen = false
	print("[LODDebug] 已解冻; 恢复 LOD 相机")


# 右上角画中画: 渲染**冻结瞬间那个视点**看到的画面。
# 用途: 剔除是按冻结视点算的 —— 画中画里画面**完整** = 剔除正确(只剔了看不见的); 缺地形 = 误剔。
# 而主画面(旁观相机)从别的角度看必然有洞(那是被剔的 patch), 不能用来判断对错。两者一起看才能下结论。
#
# 实现: SubViewport 复用**主世界**(world_3d), 于是渲染的是同一份 GPU LOD 地形(冻结后的 patch 集合);
# 里面放一台相机, 位姿锁定为冻结瞬间的 LOD 相机位姿(不再跟随)。
func _build_frozen_pip() -> void:
	if not is_instance_valid(_lod_camera):
		return
	_free_frozen_pip()
	var vp_size := Vector2i(384, 216)   # 16:9 小窗
	_pip_layer = CanvasLayer.new()
	add_child(_pip_layer)
	_pip_viewport = SubViewport.new()
	_pip_viewport.size = vp_size
	# 复用主世界 → 同一份地形/剔除结果; 不复用会渲染空世界(什么都看不到)。
	_pip_viewport.world_3d = get_viewport().world_3d
	_pip_viewport.own_world_3d = false
	_pip_viewport.transparent_bg = false
	_pip_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_pip_layer.add_child(_pip_viewport)
	# 冻结视点相机: 位姿锁死为冻结瞬间的 LOD 相机(复制 transform/fov/near/far)。
	_pip_camera = Camera3D.new()
	_pip_camera.fov = _lod_camera.fov
	_pip_camera.near = _lod_camera.near
	_pip_camera.far = _lod_camera.far
	_pip_viewport.add_child(_pip_camera)
	_pip_camera.global_transform = _lod_camera.global_transform
	_pip_camera.current = true
	# 右上角显示 + 边框 + 标题, 免得与主画面混淆。
	var panel := Panel.new()
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.offset_left = -float(vp_size.x) - 12.0
	panel.offset_top = 8.0
	panel.offset_right = -8.0
	panel.offset_bottom = 8.0 + float(vp_size.y) + 22.0
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 不挡鼠标(旁观相机要右键拖动)
	_pip_layer.add_child(panel)
	var title := Label.new()
	title.text = "冻结瞬间视角(剔除依据) — 此处画面完整=剔除正确"
	title.add_theme_font_size_override("font_size", 11)
	title.add_theme_color_override("font_color", Color(1, 1, 0.6))
	title.position = Vector2(4, 2)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(title)
	var tr := TextureRect.new()
	tr.texture = _pip_viewport.get_texture()
	tr.position = Vector2(2, 20)
	tr.size = Vector2(float(vp_size.x), float(vp_size.y))
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(tr)


func _free_frozen_pip() -> void:
	if is_instance_valid(_pip_layer):
		_pip_layer.queue_free()
	_pip_layer = null
	_pip_viewport = null
	_pip_camera = null


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
