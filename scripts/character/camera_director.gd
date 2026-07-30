# gdlint: disable=variable-name, max-line-length
## 相机导演: 按键(默认 M)在两种模式间切换 ——
##   CHARACTER: 相机贴到角色, 由 character_controller 第三人称驱动(捕获鼠标看向)。
##   PLANET:    相机拉远聚焦星球, 由 OrbitCamera 驱动(左键拖拽 / 滚轮缩放)。
##
## 全场景共用**一台**相机(= orbit_camera 指向的那台, 同时也是角色的 external_camera)。切换只是把这台
## 相机的"驱动权"在 角色控制器 ↔ 轨道相机脚本 之间交接, 并切鼠标模式。因为始终是同一台相机,
## GpuPlanet.camera 指向它即可, LOD/剔除自动跟随当前视角, 两模式都正确。
##
## 非侵入: 不改角色/轨道相机脚本。角色侧靠公开的 set_camera_active(); 轨道相机侧靠 set_process() /
## set_process_unhandled_input()(内置方法, 决定其 _process / _unhandled_input 是否触发)。
extends Node

enum Mode { CHARACTER, PLANET }

## 挂 character_controller.gd 的角色节点(需提供 set_camera_active(bool))。
@export var character: Node
## 聚焦星球的轨道相机(OrbitCamera; 也就是全场景共用的那台相机)。
@export var orbit_camera: OrbitCamera
## 星球(用于把轨道相机的聚焦目标/距离按半径自适应, 避免相机落进星球内部)。
@export var planet: GpuPlanet
## 切换键(默认 M)。
@export var toggle_key: Key = KEY_M
## 起始模式。
@export var start_mode: Mode = Mode.CHARACTER
## 模式切换的平滑过渡时长(秒)。过渡期间两个驱动都暂停, 由本导演在【起始位姿→目标位姿】间插值。0 = 立即硬切。
@export var transition_time: float = 0.6

var _mode: int = Mode.CHARACTER
var _transitioning: bool = false
var _transition_t: float = 0.0
var _from_xform: Transform3D = Transform3D.IDENTITY


func _ready() -> void:
	_mode = start_mode
	# 延迟到所有节点 _ready 之后再应用初始模式(立即, 不做过渡动画), 避免与角色/轨道相机自身 _ready 时序打架。
	_apply_mode.call_deferred(true)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == toggle_key:
		toggle()


## 在两模式间切换(带平滑过渡)。
func toggle() -> void:
	_mode = (Mode.PLANET if _mode == Mode.CHARACTER else Mode.CHARACTER)
	_apply_mode(false)


## 直接设定模式(Mode.CHARACTER / Mode.PLANET)(带平滑过渡)。
func set_mode(m: int) -> void:
	_mode = m
	_apply_mode(false)


func get_mode() -> int:
	return _mode


func _apply_mode(instant := false) -> void:
	var to_character := _mode == Mode.CHARACTER
	# 按相机模式选择 GpuPlanet 剔除组合(尽早设 —— 切到 PLANET 时过渡期间就已关遮挡, 避免过渡运动露洞):
	# CHARACTER(贴地)开 Hi-Z 遮挡; PLANET(高空)关遮挡(靠地平线+视锥, 无运动 disocclusion 洞)。
	if planet != null:
		planet.set_cull_mode(to_character)
	# 把相机**重挂**到当前聚焦对象下: 角色模式 → 挂到角色; 星球模式 → 挂回星球。
	# keep_global_transform=true → 世界位姿不变, 于是"聚焦谁相机就在谁身上"。
	if orbit_camera != null:
		var new_parent: Node = character if to_character else planet
		if new_parent != null and orbit_camera.get_parent() != new_parent:
			orbit_camera.reparent(new_parent, true)
	# 先把目标模式的轨道参数调好(供过渡计算目标位姿; 星球模式绕球心、按半径定距离)。
	if not to_character:
		_focus_planet()
	# 立即模式(初始/关闭过渡): 直接交接。
	if instant or transition_time <= 0.0 or orbit_camera == null:
		_transitioning = false
		_finish_handoff(to_character)
		return
	# 平滑过渡: 暂停两个驱动, 记下起始位姿, 由 _process 每帧插值到目标位姿。
	orbit_camera.current = true
	_from_xform = orbit_camera.global_transform
	_transition_t = 0.0
	_transitioning = true
	orbit_camera.set_process(false)
	orbit_camera.set_process_unhandled_input(false)
	if character != null and character.has_method("set_camera_active"):
		character.set_camera_active(false)


# 过渡结束(或立即模式): 把相机驱动权正式交给目标模式, 并设好鼠标模式。
func _finish_handoff(to_character: bool) -> void:
	if orbit_camera != null:
		if not to_character:
			orbit_camera.snap_to_target()   # 同步平滑量, 交接后不再 lerp 跳变
		orbit_camera.set_process(not to_character)
		orbit_camera.set_process_unhandled_input(not to_character)
		if not to_character:
			orbit_camera.current = true
	# 角色模式交给角色(内部会设 current + _cam_snap + 捕获鼠标), 星球模式收回。
	if character != null and character.has_method("set_camera_active"):
		character.set_camera_active(to_character)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if to_character else Input.MOUSE_MODE_VISIBLE


func _process(delta: float) -> void:
	if not _transitioning or orbit_camera == null:
		return
	_transition_t = minf(_transition_t + delta / maxf(transition_time, 0.0001), 1.0)
	var e := _transition_t * _transition_t * (3.0 - 2.0 * _transition_t)   # smoothstep 缓入缓出
	# 目标位姿每帧取(角色会动/轨道参数可能变), interpolate_with 对位置 lerp、朝向 slerp → 平滑。
	orbit_camera.global_transform = _from_xform.interpolate_with(_target_xform(), e)
	if _transition_t >= 1.0:
		_transitioning = false
		_finish_handoff(_mode == Mode.CHARACTER)


# 目标模式此刻期望的相机世界位姿(过渡终点)。
func _target_xform() -> Transform3D:
	if _mode == Mode.CHARACTER:
		if character != null and character.has_method("get_follow_transform"):
			var xf: Transform3D = character.call("get_follow_transform")
			return xf
	elif orbit_camera != null:
		return orbit_camera.get_desired_transform()
	return orbit_camera.global_transform if orbit_camera != null else Transform3D.IDENTITY


# 切到星球视角: 相机绕【球心】旋转(不是角色)。按半径把目标/距离调好, 保证相机在星球外部、
# 缩放不进球内(半径变了也自适应)。角色相对星球很小, 整球视角下会小到看不见, 属正常。
func _focus_planet() -> void:
	if orbit_camera == null:
		return
	var center: Vector3 = planet.global_position if planet != null else Vector3.ZERO
	var r: float = 100.0
	if planet != null and planet.params != null:
		r = planet.params.radius
	orbit_camera.target = center
	orbit_camera.min_distance = maxf(r * 1.1, 2.0)      # 禁止缩放进球内
	orbit_camera.max_distance = maxf(orbit_camera.max_distance, r * 8.0)
	# 距离若在球内/太近, 拉到能看到整颗星球的观察距离(保留用户已有的更远缩放)。
	if orbit_camera.distance < r * 1.2:
		orbit_camera.set_orbit(center, r * 2.5)
