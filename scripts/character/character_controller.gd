# gdlint: disable=variable-name, max-line-length
## 自包含球面行星角色控制器(挂在 robot_character.tscn 根节点)。
##
## 设计目标: 把预制体拖进场景放到星球附近即可行走, 不改动/不依赖 GpuPlanet、大气、LOD 等其余系统。
## 只**只读**地取星球的中心/半径/高度场(Terrain), 绝不写它们。
##
## 重力: 优先用 GravityFields 的 get_custom_gravity()(若角色进入了某个 GravityDetector 区域,
##   支持将来太阳系多天体/SOI 平滑切换); 否则回退到"指向最近 GpuPlanet 球心的径向重力"。
##
## 贴地: GPU 星球是纯视觉(无碰撞网格), 所以不走物理碰撞, 而是每帧用 Terrain.height_at(与着色器
##   位移逐位一致)程序化把角色夹到地表(radius + h*maxHeight)。move_and_slide 不调用(无地面碰撞体)。
##
## 相机: 内置重力对齐的第三人称相机(鼠标看向, 滚轮无), 独立于角色朝向。可用 use_own_camera 关掉。
##
## 非 @tool: 只在运行时工作(编辑器里不自动跑, 免得干扰编辑)。
extends GravityCharacter3D

## 相机旋转控制方式。
##   MOUSE_LOOK : 捕获鼠标, 移动鼠标即持续看向(FPS 式)。
##   MIDDLE_DRAG: 鼠标自由(可见), 按住鼠标中键拖动才旋转相机(WASD 移动不影响相机角度)。
enum CamControl { MOUSE_LOOK, MIDDLE_DRAG }

# ---- 运动参数 ----
@export_group("Movement")
## 行走速度(单位/秒)。
@export var walk_speed: float = 8.0
## 奔跑速度(按住 Shift)。
@export var run_speed: float = 16.0
## 起跳初速度(沿"上"方向)。
@export var jump_speed: float = 12.0
## 无重力场时的回退重力强度(指向星球中心)。有 GravityDetector 时以场为准。
@export var gravity_strength: float = 20.0
## 水平加减速平滑(越大越跟手)。
@export var accel: float = 12.0
## 转向/立正平滑速度。
@export var align_speed: float = 12.0

@export_group("Grounding")
## 角色原点到脚底的距离(= 胶囊半高)。Model 也据此下移, 让脚踩在地面。
@export var foot_offset: float = 0.9
## 低于海平面时是否夹到海面(可在水面上行走)。关则会走到海床。
@export var stick_to_water: bool = true
## 贴地高度的平滑速率(帧率无关, 越大越紧跟地表、越小越丝滑)。
## 为什么需要: 地形高度来自**程序化噪声**(无限细节), 角色水平走动时脚下采样点每帧都变, 高频噪声让
## 目标半径逐帧小跳; 若像原来那样每帧硬赋值 global_position, 模型竖直方向就会逐帧颤抖、局部凹陷处
## 还会"掉一下"。这里对"离球心半径"做低通吸收高频噪声, 让行走丝滑。
@export var ground_smooth: float = 20.0
## 贴地平滑的"大落差"阈值(占 foot_offset 的比例)。误差超过它 → 判定为真实地形落差(台阶/悬崖),
## 直接快速跟上(不平滑), 避免视觉穿地/悬空; 误差小于它 → 判定为噪声抖动, 走平滑。
## 这样"吸收噪声"与"陡峭处不脱地"两头兼顾。
@export var ground_snap_threshold: float = 0.5

@export_group("Planet")
## 可选: 显式指定 GpuPlanet。留空则自动查找(父级链 → 全场景)。
@export var planet_path: NodePath

@export_group("Camera")
## 外部相机(可选): 在**实例**上把场景里已有的 Camera3D 拖到这里。
## 留空 → 用预制体内置的 Camera3D 子节点(默认, 拖进去即用)。
@export var external_camera: Camera3D
## 是否由本控制器驱动相机(重力对齐第三人称跟随 + 鼠标看向)。
## 开(默认): 无论内置还是外部相机, 都由本控制器接管其位姿/朝向。
## 关: 只**读**相机朝向来决定移动方向, 相机位姿完全交给外部(它自己的脚本/rig)控制。
@export var control_camera: bool = true
## 相机旋转方式: MOUSE_LOOK = 捕获鼠标持续看向(FPS 式); MIDDLE_DRAG = 鼠标自由, 按住中键拖动才转相机。
@export var cam_control: CamControl = CamControl.MIDDLE_DRAG
@export var mouse_sensitivity: float = 0.003
## 相机与角色的第三人称距离(初始值)。运行时可用鼠标滚轮拉远/拉近, 在 [cam_distance_min, cam_distance_max] 间调节。
@export var cam_distance: float = 8.0
## 滚轮缩放的最近/最远距离。
@export var cam_distance_min: float = 3.0
@export var cam_distance_max: float = 40.0
## 每格滚轮改变的距离量。
@export var cam_zoom_step: float = 2.0
## 缩放平滑速率(帧率无关; 越大越跟手, 越小越缓)。
@export var cam_zoom_smooth: float = 14.0
@export var cam_height: float = 2.2
## 相机整体跟随平滑(帧率无关速率, 越大越紧跟、越小越飘)。主要用来抹掉 60Hz 物理步进的水平台阶感。
@export var cam_follow_smooth: float = 18.0
## 相机"离球心高度"的平滑(越小越平滑)。专门吸收角色贴地时的竖直起伏/颤抖(下坡尤其明显)——
## 这样水平方向照常紧跟, 而竖直方向被低通, 画面不再随地形上下抖。太小会让跳跃时相机竖直跟得偏慢。
@export var cam_height_smooth: float = 6.0
@export var cam_pitch_min_deg: float = -60.0
@export var cam_pitch_max_deg: float = 75.0

@export_group("Animation")
## 动画名(默认对应 Quaternius Animated Robot 的 clip 名)。
@export var anim_idle: String = "Robot_Idle"
@export var anim_walk: String = "Robot_Walking"
@export var anim_run: String = "Robot_Running"
@export var anim_jump: String = "Robot_Jump"
## 切换到跑步动画的速度阈值。
@export var run_anim_threshold: float = 10.0
## 美术朝向修正(度, 绕自身 Y)。Quaternius 机器人美术朝向为 +Z, 而 Godot 前方是 -Z, 故默认 180
## 让模型正面对准移动方向(否则会"倒着走 / 前后左右都反")。若换了朝 -Z 的模型就设 0。
@export var model_yaw_offset_deg: float = 180.0

# ---- 内部状态 ----
var _planet: GpuPlanet
var _center: Vector3 = Vector3.ZERO
var _radius: float = 100.0
var _max_height: float = 8.0
var _sea: float = 0.0
var _terrain: Terrain

var _model: Node3D
var _anim: AnimationPlayer
var _camera: Camera3D

var _up: Vector3 = Vector3.UP
var _face: Vector3 = Vector3.FORWARD   # 维护的"朝向"(切平面内单位向量); up 每帧精确对齐, 只平滑转 yaw
var _v_up: float = 0.0            # 沿"上"的速度分量(重力/跳跃)
var _grounded: bool = false
var _ground_dt: float = 1.0 / 60.0   # 本帧物理步长(供 _snap_to_ground 做帧率无关平滑)
var _cam_yaw: float = 0.0
var _cam_pitch: float = -0.2
var _cur_anim: String = ""
var _cam_active: bool = false     # 本控制器当前是否在驱动相机(由 set_camera_active 切换)
var _input_active: bool = false   # 角色是否响应键盘移动/跳跃(角色模式 true; 星球模式 false → WASD 不控制角色)
var _input_suspended: bool = false  # 外部临时挂起输入(如 LOD 调试冻结: WASD 归旁观相机, 不能同时驱动角色)
var _cam_snap: bool = false       # 接管相机后第一帧直接放到位(不 lerp), 避免从旧位置(可能在星球内)飞入
var _cam_anchor_r: float = -1.0   # 平滑后的相机锚点"离球心半径"(消竖直颤抖); <0 = 未初始化
var _cam_anchor_dir: Vector3 = Vector3.UP   # 平滑后的锚点方向(消 60Hz 物理步进造成的 look_at 朝向抽动)
var _cam_dist_target: float = 8.0 # 滚轮设定的目标距离(_ready 初始化为 cam_distance)
var _cam_dist_cur: float = 8.0    # 平滑后的当前距离(每帧向 target 逼近)
var _orbiting: bool = false       # MIDDLE_DRAG 模式: 是否正按住中键拖动旋转
var _cam_smooth_pos: Vector3 = Vector3.ZERO   # 自存的相机平滑世界坐标(不回读子相机, 免被父级转身带偏)


func _ready() -> void:
	_resolve_planet()
	_read_planet()
	# 相机距离初始化(夹进 [min, max]); target 与 cur 同步, 避免开局插值。
	cam_distance = clampf(cam_distance, cam_distance_min, cam_distance_max)
	_cam_dist_target = cam_distance
	_cam_dist_cur = cam_distance
	# 找模型/动画/相机(路径无关, 靠名字/类型查找, 换预制体结构也不怕)。
	_model = get_node_or_null("Model")
	if _model == null:
		_model = _find_first_child_node3d_except_camera()
	_anim = find_child("AnimationPlayer", true, false) as AnimationPlayer
	# 相机解析: 外部指定优先(场景那台), 否则找子 Camera3D, 都没有再运行时建一个(单独拖预制体也能玩)。
	# 预制体本身不再内置 Camera3D 节点 —— 避免和场景相机并存造成"两个相机"的困惑。
	_camera = external_camera
	if _camera == null:
		_camera = get_node_or_null("Camera3D") as Camera3D
		if _camera == null:
			_camera = find_child("Camera3D", true, false) as Camera3D
	if _camera == null and control_camera:
		var auto_cam := Camera3D.new()
		auto_cam.name = "AutoCamera"
		auto_cam.far = 500000.0
		add_child(auto_cam)
		_camera = auto_cam
	# 应用美术朝向修正。
	if _model != null and absf(model_yaw_offset_deg) > 0.001:
		_model.rotation = Vector3(0.0, deg_to_rad(model_yaw_offset_deg), 0.0)
	_make_locomotion_loop()
	# 落到地面(初始摆放不必精确; 若被放在球心附近, 用北极兜底)。
	_snap_to_ground(true)
	# 初始立正: 直接按重力 up 摆正朝向。否则会以场景里的 identity 姿态"趴"在地面(因为出生点的
	# 径向 up 与角色 +Y 差 90°), 再慢慢 slerp 起来, 且在极点处 looking_at 退化 → 抖动。
	_up = _current_up()
	_face = _initial_face()
	_apply_orientation()
	# 初始相机激活: 用**内置**相机(未指定 external_camera)时自激活, 保证预制体单独拖进去也能玩;
	# 指定了外部相机时(场景管理)默认不激活, 交给场景的 CameraDirector 调 set_camera_active 接管。
	set_camera_active(control_camera and external_camera == null)


# ---- 星球解析(自动查找, 零耦合) ----
func _resolve_planet() -> void:
	if planet_path != NodePath():
		var n := get_node_or_null(planet_path)
		if n is GpuPlanet:
			_planet = n
			return
	# 父级链
	var p := get_parent()
	while p != null:
		if p is GpuPlanet:
			_planet = p
			return
		p = p.get_parent()
	# 全场景搜索(取第一个)
	_planet = _search_planet(get_tree().root)


func _search_planet(n: Node) -> GpuPlanet:
	if n is GpuPlanet:
		return n
	for c in n.get_children():
		var r := _search_planet(c)
		if r != null:
			return r
	return null


func _read_planet() -> void:
	if _planet == null:
		push_warning("[RobotCharacter] 未找到 GpuPlanet, 用默认 radius=100/maxHeight=8, 无地形起伏。")
		return
	_center = _planet.global_position
	var p: PlanetParams = _planet.params
	if p == null:
		push_warning("[RobotCharacter] GpuPlanet.params 为空, 用默认值。")
		return
	_radius = p.radius
	_max_height = p.maxHeight
	_sea = p.seaLevel
	_terrain = Terrain.from_params(p)


## 参数运行时改变后可调此刷新(可选)。
func refresh_planet() -> void:
	_read_planet()


func _find_first_child_node3d_except_camera() -> Node3D:
	for c in get_children():
		if c is Node3D and not (c is Camera3D) and not (c is CollisionShape3D):
			return c
	return null


func _make_locomotion_loop() -> void:
	if _anim == null:
		return
	for n in [anim_idle, anim_walk, anim_run]:
		if _anim.has_animation(n):
			var a := _anim.get_animation(n)
			if a != null:
				a.loop_mode = Animation.LOOP_LINEAR


# ---- 地表半径(与 GPU 着色器位移逐位一致) ----
func _ground_radius(dir: Vector3) -> float:
	if _terrain == null:
		return _radius
	var h := _terrain.height_at(dir.x, dir.y, dir.z)
	if stick_to_water:
		h = maxf(h, _sea)
	return _radius + h * _max_height


func _current_up() -> Vector3:
	var g := _gravity_vector()
	if g.length() > 0.0001:
		return (-g).normalized()
	var radial := global_position - _center
	if radial.length() > 0.0001:
		return radial.normalized()
	return Vector3.UP


func _gravity_vector() -> Vector3:
	# GravityFields 场(若进入了 detector 区域)
	var g := get_custom_gravity()
	if g.length() > 0.0001:
		return g
	# 回退: 指向星球中心的径向重力
	var to_center := _center - global_position
	if to_center.length() > 0.0001:
		return to_center.normalized() * gravity_strength
	return Vector3.DOWN * gravity_strength


# 角色运动更新。**跑在 _process(渲染帧率)而非 _physics_process(60Hz)** —— 由 _process 调用。
# 原因: 本控制器是纯手动积分(不用 move_and_slide, 无地面碰撞体, 靠 Terrain.height_at 程序化贴地),
# 完全不依赖物理步进。放在 60Hz 的 _physics_process 里, 高刷屏(120/144Hz)下角色位置/朝向就以 60Hz
# 阶跃更新, 而相机在 _process 逐帧跟随 → 模型颤抖、动画不丝滑。挪到 _process 后角色/模型/相机在
# 同一帧、同一时刻更新, 从源头消除不同步(也不需要引擎物理插值 —— 那反而会与本控制器自己的平滑打架)。
func _update_movement(delta: float) -> void:
	_ground_dt = delta   # 供 _snap_to_ground 做帧率无关的贴地平滑
	_up = _current_up()

	# --- 水平朝向参考 ---
	var fwd_t: Vector3
	if _cam_active:
		fwd_t = _camera_horizontal_dir()                                # 我们驱动的相机: 用内部 yaw
	elif _camera != null:
		fwd_t = _project_on_tangent(-_camera.global_transform.basis.z)  # 外部/轨道相机: 读它的实际朝向
	else:
		fwd_t = _project_on_tangent(-global_transform.basis.z)          # 无相机: 用当前朝向
	var right_t := fwd_t.cross(_up).normalized()

	# --- 输入 → 期望水平速度(仅角色模式且未被挂起时响应键盘; 否则不读 WASD, 角色静止贴地)---
	var accepts: bool = _input_active and not _input_suspended
	var iy := 0.0
	var ix := 0.0
	if accepts:
		iy = Input.get_action_strength("move_forward") - Input.get_action_strength("move_back")
		ix = Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
	var wish := (right_t * ix + fwd_t * iy)
	var moving := wish.length() > 0.05
	if moving:
		wish = wish.normalized()
	var sprinting := accepts and Input.is_physical_key_pressed(KEY_SHIFT)
	var target_speed := (run_speed if sprinting else walk_speed) if moving else 0.0
	var target_v := wish * target_speed

	# 当前水平速度(去掉沿 up 的分量)
	var v_tan := velocity - _up * velocity.dot(_up)
	v_tan = v_tan.lerp(target_v, clampf(accel * delta, 0.0, 1.0))

	# --- 重力 / 跳跃(沿 up 的分量) ---
	var g_mag := _gravity_vector().length()
	_v_up -= g_mag * delta
	if accepts and _grounded and Input.is_action_just_pressed("jump"):
		_v_up = jump_speed
		_grounded = false

	velocity = v_tan + _up * _v_up

	# --- 位移(手动积分; 无地面碰撞体所以不用 move_and_slide) ---
	global_position += velocity * delta

	# --- 程序化贴地 ---
	_snap_to_ground(false)

	# --- 立正 + 面向移动方向 ---
	_orient(delta, v_tan)

	# --- 动画 ---
	_update_animation(v_tan.length())


func _snap_to_ground(initial: bool) -> void:
	var radial := global_position - _center
	var dist := radial.length()
	var dir: Vector3
	if dist < 0.001:
		dir = Vector3.UP   # 被放在球心 → 用北极兜底
	else:
		dir = radial / dist
	var target_r := _ground_radius(dir) + foot_offset
	if initial:
		global_position = _center + dir * target_r
		_v_up = 0.0
		_grounded = true
		return
	if dist <= target_r:
		# 贴地: 不再每帧硬赋值(那会把程序化噪声的高频抖动直接搬到模型上 → 竖直颤抖/"掉一下"),
		# 而是让半径帧率无关地逼近 target_r。自适应: 误差大(真实台阶/悬崖)→ 快速跟上不脱地;
		# 误差小(噪声抖动)→ 平滑吸收。跳跃落地(_v_up<0 且刚穿地)也走快速, 免得软绵绵下沉。
		var err: float = target_r - dist
		# 落地判定不能用 _v_up<0 —— 重力在贴地【之前】累积(_physics_process 里 _v_up -= g*delta),
		# 站着走时 _v_up 每帧也是 -g*dt(≈-0.33), 那样会恒判"硬贴"→ 平滑失效。用"明显快于单帧重力增量"
		# 的下落速度(3 倍余量)区分真实空中坠落 vs 贴地行走的常态负值。
		var fall_thr: float = -3.0 * _gravity_vector().length() * _ground_dt
		var hard: bool = err > foot_offset * ground_snap_threshold or _v_up < fall_thr
		if hard:
			global_position = _center + dir * target_r
		else:
			var t: float = 1.0 - exp(-ground_smooth * _ground_dt)
			global_position = _center + dir * lerpf(dist, target_r, t)
		if _v_up < 0.0:
			_v_up = 0.0
		_grounded = true
	else:
		# 离地一点点也算站着(容差), 否则动画会抖
		_grounded = (dist - target_r) <= 0.05
		# 站着但略高于地表(容差内, 常见于上坡/噪声): 同样平滑贴回, 消除"悬空一点点"造成的抖动。
		# 同样不能用 _v_up<=0(恒真); 只排除**上升中**(跳跃)以免把人往地面拽。
		if _grounded and _v_up <= 0.001:
			var t2: float = 1.0 - exp(-ground_smooth * _ground_dt)
			global_position = _center + dir * lerpf(dist, target_r, t2)


func _project_on_tangent(v: Vector3) -> Vector3:
	var t := v - _up * v.dot(_up)
	if t.length() < 0.0001:
		return -global_transform.basis.z
	return t.normalized()


func _orient(delta: float, v_tan: Vector3) -> void:
	# 1) 把 _face 重新投影到当前切平面(绕球走动时 up 变了, 保持 _face ⟂ up)。
	var f := _face - _up * _face.dot(_up)
	if f.length() < 1.0e-4:
		f = _initial_face()
	else:
		f = f.normalized()
	# 2) 移动时把 _face 朝移动方向"限速"旋转(绕 up 转 yaw), 不用 slerp 整个 basis → up 不滞后、不抖。
	if v_tan.length() > 0.5:
		var want := v_tan - _up * v_tan.dot(_up)
		if want.length() > 1.0e-4:
			want = want.normalized()
			var ang := f.signed_angle_to(want, _up)
			var step := clampf(ang, -align_speed * delta, align_speed * delta)
			f = f.rotated(_up, step)
	_face = f
	# 3) 每帧按 (_face, _up) 精确重建 basis: Y 恰为 up(立正, 不趴), -Z 为 _face。
	_apply_orientation()


# 用 _face + _up 精确构造角色 basis(Y=up 立正, -Z=_face 朝向)。_face 已保证 ⟂ up。
func _apply_orientation() -> void:
	var b := Basis.looking_at(_face, _up)
	var t := global_transform
	t.basis = b
	global_transform = t


# 初始朝向: 取一个落在当前切平面(⟂ up)内的前向。依次尝试当前 -Z / +X / 任意, 直到非退化。
func _initial_face() -> Vector3:
	var candidates := [-global_transform.basis.z, global_transform.basis.x, Vector3.RIGHT, Vector3.FORWARD]
	for c in candidates:
		var t: Vector3 = c - _up * c.dot(_up)
		if t.length() > 1.0e-4:
			return t.normalized()
	return _up.cross(Vector3.UP).normalized()


# ---- 动画状态机 ----
func _update_animation(speed: float) -> void:
	if _anim == null:
		return
	var want: String
	if not _grounded:
		want = anim_jump
	elif speed > run_anim_threshold:
		want = anim_run
	elif speed > 0.5:
		want = anim_walk
	else:
		want = anim_idle
	if want == _cur_anim:
		return
	if not _anim.has_animation(want):
		return
	_anim.play(want, 0.15)
	_cur_anim = want


## 由外部(如 CameraDirector)调用, 接管/交还本控制器对相机的驱动。
## active=true : 脱离父变换 + 设为当前相机 + 捕获鼠标 + 每帧第三人称跟随驱动。
## active=false: 停止驱动、不再碰鼠标(相机位姿交给外部, 如轨道相机)。
## 注: control_camera=false(外部完全自驱)时本方法不接管相机, 仅保证不干扰。
func set_camera_active(active: bool) -> void:
	# 角色是否响应键盘移动: 直接跟随 active(= CameraDirector 的"是否角色模式")。与相机驱动分开 ——
	# 相机驱动还要看 control_camera/相机是否存在, 但键盘控制只看是不是角色模式。
	_input_active = active
	_cam_active = active and control_camera and _camera != null
	if not _cam_active:
		_cam_anchor_r = -1.0   # 交出相机驱动: 重置高度平滑, 下次接管时重新初始化(过渡结束不跳)
		_orbiting = false
		return
	# 相机现在是真正的子节点(由 CameraDirector 重挂到角色下), 不再用 top_level。
	# 控制器每帧直接设它的**世界**位姿(global_position + look_at), 所以即便挂在会转身的角色下也不会跟着转。
	_camera.current = true
	_cam_snap = true   # 下一帧 _process 把相机直接放到跟随位, 避免从星球内/远处 lerp 飞入
	_orbiting = false
	# MOUSE_LOOK: 捕获鼠标持续看向; MIDDLE_DRAG: 鼠标自由(可见), 按中键拖动时才临时捕获。
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if cam_control == CamControl.MOUSE_LOOK else Input.MOUSE_MODE_VISIBLE


## 返回第三人称跟随相机应处的世界位姿(供 CameraDirector 做模式切换过渡时的目标位姿; 不改动相机)。
func get_follow_transform() -> Transform3D:
	var up := _current_up()
	var dir := _camera_horizontal_dir()
	var right := dir.cross(up).normalized()
	var look := (Quaternion(right, _cam_pitch) * dir).normalized()
	var head := global_position + up * cam_height
	var rel := head - _center
	var hr := rel.length()
	var hdir := (rel / hr) if hr > 1.0e-4 else up
	var ar := _cam_anchor_r if _cam_anchor_r > 0.0 else hr
	# 与 _process 一致: 用平滑后的锚点方向(未初始化时退回瞬时 hdir), 保证过渡目标位姿与接管后不跳。
	var adir := _cam_anchor_dir if _cam_anchor_r > 0.0 else hdir
	var anchor := _center + adir * ar
	var cam_pos := anchor - look * _cam_dist_cur
	return Transform3D(Basis.looking_at(look, up), cam_pos)


func is_camera_active() -> bool:
	return _cam_active


## 临时挂起/恢复键盘输入(WASD/跳跃/加速), **不改动相机驱动状态**。
## 用途: LOD 调试冻结(planet_lod_debug F2)期间 WASD 归旁观相机飞行, 不能同时驱动角色。
## 与 set_camera_active 正交 —— 解冻后无需恢复模式, CameraDirector 的模式状态不受影响。
func set_input_suspended(suspended: bool) -> void:
	_input_suspended = suspended


# ---- 内置第三人称相机(重力对齐, 独立朝向) ----
func _camera_horizontal_dir() -> Vector3:
	# 以世界参考在切平面上取一个稳定的"前"方向, 再按 _cam_yaw 绕 up 旋转。
	var ref := Vector3.FORWARD
	if absf(ref.dot(_up)) > 0.99:
		ref = Vector3.RIGHT
	var base_fwd := (ref - _up * ref.dot(_up)).normalized()
	return (Quaternion(_up, _cam_yaw) * base_fwd).normalized()


func _process(delta: float) -> void:
	# 先更新角色运动(渲染帧率, 见 _update_movement 注释), 再摆相机 —— 顺序要紧: 相机必须跟随
	# 本帧**最终**的角色位姿, 否则又会差一帧产生抖动。
	_update_movement(delta)
	# 只有本控制器处于激活(驱动相机)状态时才摆放相机; 否则相机交给外部(轨道相机/CameraDirector)。
	if not _cam_active:
		return
	var up := _current_up()
	var dir := _camera_horizontal_dir()
	var right := dir.cross(up).normalized()
	# 鼠标看向(look)不平滑, 保持跟手。
	var look := (Quaternion(right, _cam_pitch) * dir).normalized()

	# 锚点 = 角色头部, 拆成"方向 × 半径"两个分量各自做帧率无关低通:
	#   半径(_cam_anchor_r): 吸收地形起伏造成的竖直颤抖(下坡尤其明显), 用较慢的 cam_height_smooth。
	#   方向(_cam_anchor_dir): 吸收角色位置的 60Hz 物理步进, 用较快的 cam_follow_smooth(水平仍跟手)。
	# 【方向必须也平滑】: anchor 同时是 look_at 的**目标**。角色在 _physics_process(60Hz)更新位置,
	# 而本函数在渲染帧率(可能 120/144Hz)跑 —— 若 hdir 直接取自 global_position, anchor 就以 60Hz 阶跃,
	# look_at 每帧朝一个跳变的目标 → 相机**朝向**逐帧抽动。朝向抖动会甩动整个画面, 表现为"星球/地形在
	# 剧烈抖动"(而星球其实没动)。原实现只平滑了半径、注释误以为"方向随水平移动平滑变化", 故竖直不抖
	# 但水平朝向仍抖。这里把方向也低通, 让 look 目标与相机位置一样平滑。
	var head := global_position + up * cam_height
	var rel := head - _center
	var hr := rel.length()
	var hdir := (rel / hr) if hr > 1.0e-4 else up
	var snapping := _cam_snap or _cam_anchor_r < 0.0
	if snapping:
		_cam_anchor_r = hr
		_cam_anchor_dir = hdir
		_cam_dist_cur = _cam_dist_target   # 接管首帧: 距离直接到位, 不插值
	else:
		_cam_anchor_r = lerpf(_cam_anchor_r, hr, 1.0 - exp(-cam_height_smooth * delta))
		# slerp 保持单位长度(球面插值); 方向变化极小时 slerp 退化安全, 仍用 normalized 兜底。
		_cam_anchor_dir = _cam_anchor_dir.slerp(hdir, 1.0 - exp(-cam_follow_smooth * delta)).normalized()
		_cam_dist_cur = lerpf(_cam_dist_cur, _cam_dist_target, 1.0 - exp(-cam_zoom_smooth * delta))
	var anchor := _center + _cam_anchor_dir * _cam_anchor_r
	var desired := anchor - look * _cam_dist_cur
	# 相机位置平滑(帧率无关): 吸收 60Hz 物理步进, 水平跟随顺滑不台阶。
	# 关键: lerp 的起点用【自存的世界坐标 _cam_smooth_pos】, **绝不回读 _camera.global_position**——
	# 相机是角色的子节点, 角色转身面向移动方向时(_physics_process 里转 basis)会把子相机的世界坐标一起
	# 转走; 若拿这个"被带偏"的坐标做 lerp 起点, 相机就会被拽一下再恢复(= 你看到的转弯时相机抖一下)。
	# 自存世界坐标做低通则完全无视父级旋转, 无带偏。
	if snapping:
		_cam_smooth_pos = desired
	else:
		_cam_smooth_pos = _cam_smooth_pos.lerp(desired, 1.0 - exp(-cam_follow_smooth * delta))
	_camera.global_position = _cam_smooth_pos
	_camera.look_at(anchor, up)
	_cam_snap = false


func _unhandled_input(event: InputEvent) -> void:
	# 只有激活(驱动相机)时才处理鼠标看向; 否则鼠标交给外部(轨道相机/CameraDirector)。
	if not _cam_active:
		return
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				# 滚轮拉近(改目标距离, _process 里平滑逼近)。
				if event.pressed:
					_cam_dist_target = clampf(_cam_dist_target - cam_zoom_step, cam_distance_min, cam_distance_max)
			MOUSE_BUTTON_WHEEL_DOWN:
				# 滚轮拉远。
				if event.pressed:
					_cam_dist_target = clampf(_cam_dist_target + cam_zoom_step, cam_distance_min, cam_distance_max)
			MOUSE_BUTTON_MIDDLE:
				# MIDDLE_DRAG 模式: 按住中键才旋转相机。拖动期间临时捕获鼠标(相对位移旋转、光标不跑出窗口),
				# 松开恢复自由光标。MOUSE_LOOK 模式下中键不处理(交给外部)。
				if cam_control == CamControl.MIDDLE_DRAG:
					_orbiting = event.pressed
					Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if event.pressed else Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseMotion:
		# 旋转条件: MOUSE_LOOK 且鼠标已捕获(持续看向); 或 MIDDLE_DRAG 且正按住中键拖动。
		var do_rotate := (cam_control == CamControl.MOUSE_LOOK and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED) \
			or (cam_control == CamControl.MIDDLE_DRAG and _orbiting)
		if do_rotate:
			_cam_yaw -= event.relative.x * mouse_sensitivity
			_cam_pitch = clampf(_cam_pitch - event.relative.y * mouse_sensitivity,
				deg_to_rad(cam_pitch_min_deg), deg_to_rad(cam_pitch_max_deg))
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		# 仅 MOUSE_LOOK 模式: Esc 释放/捕获鼠标, 方便调试。MIDDLE_DRAG 下光标本就自由, 无需处理。
		if cam_control == CamControl.MOUSE_LOOK:
			Input.mouse_mode = (Input.MOUSE_MODE_VISIBLE
				if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
				else Input.MOUSE_MODE_CAPTURED)
