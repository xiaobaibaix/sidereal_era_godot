# gdlint: disable=variable-name, max-line-length
## GPU 驱动行星(Phase 2)。@tool Node3D。
##
## Phase 1: MultiMesh + patch 纹理 + face-bary 位移(固定全 LOD)。
## Phase 2: LOD 四叉树遍历挪到 GPU compute(lod_traverse.glsl, 经 GpuLodCompositor PRE_OPAQUE 跑),
##          每帧 compute 选叶写 patch 纹理, vertex shader 读(1-帧延迟)→ 近处细分、远处粗。
##          vertex shader 不变(Phase 1 的回报): 仍 texelFetch 面角点 → face-bary 位移。
##
## 数据流:
##   GpuPlanet._process(主线程) → 算 C_const(=maxHeight·vp_h/(2·tan(fov/2))/sseThreshold) + cam_pos →
##     GpuLodCompositor.set_frame_data →
##   compositor PRE_OPAQUE(渲染线程) → lod_traverse.glsl 写 patch 纹理(tex[write]) + 末行 count →
##     绑 material.u_patchTex = tex[read](上一帧) →
##   terrain_gpu.gdshader vertex → texelFetch 面角点 → 位移; id≥count 坍缩。
##
## 与旧 scripts/planet/planet.gd 零耦合: 新文件、新节点, 不 import/不修改旧实现。位移噪声与
## terrain.gdshader / terrain.gd::height_at 逐位一致。
@tool
class_name GpuPlanet
extends Node3D

const PATCH_TEX_SLOTS := 6           # 每 patch 6 texel(设计文档 §8.3 终极布局)
const MAX_PATCHES := 12288           # 与 lod_traverse.glsl / terrain_gpu.gdshader META_ROW 一致(PATCH_TEX_H=12289, 留 Metal 单边 16384 上限余量)
const PATCH_TEX_H := MAX_PATCHES + 1 # patch 纹理高(末行存 count)
const DEFAULT_PATCH_RES := 32        # Phase 2 单叶分辨率/边(四叉树下够用; 越大越平滑越费)
const MM_NODE_NAME := "GpuPatchMM"
const MAX_GPU_LEVEL := 6             # 单遍遍历层数上限(4^6=82k 节点/帧, 可测; level 8=1.75M 太重, 留 Phase 6 ping-pong)
# 二十面体棱的球心张角 = arccos(1/√5) ≈ 1.10715 rad(63.43°)。level L 的 patch 张角 = 此值/2^L,
# 球面弓高(sagitta) ≈ radius·θ²/8 → 系数 = θ²/8。用于 LOD 的曲率误差项(见 lod_traverse.glsl::split_d)。
const ICO_SAGITTA_COEF := 0.15322168   # (arccos(1/√5))² / 8
# 用 preload + GDScript.new() 取代 GpuLodCompositor.new() —— 绕开 class_name 注册时序
# (@tool 脚本热重载时偶发 "Nonexistent function 'new' in base 'GDScript'", preload 总能用)。
const _GpuLodCompositor_script := preload("res://scripts/planet/gpu_lod_compositor.gd")
const _GpuHizCompositor_script := preload("res://scripts/planet/gpu_hiz_compositor.gd")

@export var params: PlanetParams:
	set(v):
		if params == v:
			return
		# 用 Object 的字符串版 has_signal/connect/disconnect, 避开 params.param_changed 属性访问。
		# 加载 / @tool 热重载瞬间, PlanetParams 脚本的信号表可能尚未就绪, 直接点 .param_changed
		# 属性会抛 "Invalid access to property or key 'param_changed'"; 字符串版走 Object 接口, 安全。
		if params != null and params.has_signal("param_changed") and params.is_connected("param_changed", _on_param_changed):
			params.disconnect("param_changed", _on_param_changed)
		params = v
		_connect_params_signal()
		_schedule_rebuild()


# 连接 params.param_changed → _on_param_changed(幂等; setter 与 _ready 兜底共用)。
# 用字符串版接口 + has_signal 门槛, 规避加载瞬间信号表未就绪的属性访问崩溃。
func _connect_params_signal() -> void:
	if params != null and params.has_signal("param_changed") and not params.is_connected("param_changed", _on_param_changed):
		params.connect("param_changed", _on_param_changed)

## 驱动 LOD 的相机(@tool 编辑器 get_viewport 相机不可靠, 用显式引用)。Phase 2 必填。
## 编辑器预览: 在场景里拖动这个 Camera3D 节点, LOD + 剔除会按它的位置/视锥实时更新, 而你从
## 编辑器自由视角(不同于该相机)观察 → 就能看到星球被剔成什么样(视锥外/背面/被遮挡的洞)。
@export var camera: Camera3D

## 编辑器内预览剔除(@tool): 开 → 编辑器视口也跑 LOD + 剔除, 拖动 camera 节点即时可见效果。
## 关 → 编辑器里停掉 compositor(省编辑器算力; 运行时不受影响, 始终开)。
## 提示: 想不拖动也持续刷新, 在 3D 视口右上"透视"菜单勾选"持续更新(Update Continuously)"。
@export var preview_in_editor: bool = true:
	set(v):
		preview_in_editor = v
		_apply_preview_enabled()

## 每叶三角形 patch 边分辨率。
@export_range(8, 64, 1) var patch_resolution: int = DEFAULT_PATCH_RES:
	set(v):
		patch_resolution = v
		_schedule_rebuild()

var _mm: MultiMesh
var _mminst: MultiMeshInstance3D
var _mat: ShaderMaterial
var _patch_tex_fallback: ImageTexture   # 初始绑定 + 无 compositor 时的 fallback(20 面, Phase1 风格)
var _patch_mesh: ArrayMesh
var _mesh_res: int = -1
var _default_params: PlanetParams
var _dirty := false
var _lod_comp: GpuLodCompositor
var _hiz_comp: GpuHizCompositor   # Phase 5: 遮挡剔除深度金字塔(POST_OPAQUE)
# Phase 5: 地平线剔除 occluder 球半径 = radius + 全局最小位移(保证内含实心行星, 安全不误剔)。
# 这里只缓存**全局最小位移**(烘焙产物, 与 radius 无关), occluder 半径每帧用当前 radius 现算 ——
# 否则改 radius 后它会滞留旧值(旧代码只在 _apply_minmax 里算), 半径变小时遮挡球比行星还大 →
# 地平线剔除把整颗星球都判成"背面" → 大面积消失, 直到重烘完成才恢复。
# NAN = 尚无烘焙数据 → 用保守下界 radius - maxHeight。
# 单位: **归一化**(烘焙数据不含 maxHeight), 用时乘当前 params.maxHeight。
var _minmax_min_disp: float = NAN
var _frame: int = 0   # 双缓冲帧计数(GpuPlanet 主线程拥有; 决定 compositor 写哪块、绑哪块)
# 后台烘焙: 20 面 × BAKE_RES² cell × SUPERSAMPLE² 采样 ≈ 65 万次 height_at, 放主线程 _ready 会卡死
# 编辑器/运行。改为 WorkerThreadPool **面级并行**(add_group_task, 20 个面各一个 work item → 吃满
# 核数, 比单任务串行快一个数量级), 期间 minmax 未就绪 → _process 绑 fallback(20 面)先渲染, 完成后
# 切 GPU LOD。
# 为什么用 group task 而不是"单个 add_task 里再 add_group_task + wait": 后者是在 worker 线程里等
# 另一组 worker, 有死锁隐患; 直接由主线程发起 group、每帧轮询 is_group_task_completed 最干净。
# 已上传到 GPU 的那份 MinMax 对应的 seed_hash, 供 _bake_and_push_minmax 幂等守卫用。
# 用独立 bool 而不是拿 0 / -1 当哨兵: String.hash() 可以返回任意 int, 包括 0。
var _applied_seed_hash: int = 0
var _has_applied_minmax: bool = false
var _bake_group_id: int = -1
var _bake_result: GpuMinMaxData     # group task 期间由 worker 并发写 face_mip0[fi](各写各的, 无锁)
var _bake_terrain: Terrain          # 共享只读噪声实例(height_at 不写成员 → 并发安全)
var _bake_save_path: String = ""
# LOD 冻结(调试用): 冻结后 _process 用快照的相机位置/参数驱动 LOD, 不再读实时相机。
# 配合旁观相机(planet_lod_debug.gd)绕看冻结后的地形。视锥用空 → cull 全通过 → 整球可见。
var _lod_frozen := false
var _frozen_cam_pos: Vector3
var _frozen_c_const: float = 0.0
var _frozen_k: float = 0.0        # 冻结时的 K(小三角剔除像素投影用)
var _frozen_frustum: Array = []
# 相机运动历史(用于自适应视锥外扩余量, 补偿剔除 1 帧延迟)。
var _cam_hist_valid := false
var _last_cam_pos: Vector3 = Vector3.ZERO
var _last_cam_fwd: Vector3 = Vector3.ZERO
var _occlusion_applied := false   # 本帧 cull 是否实际应用了遮挡(供 HUD 显示)
# 遮挡剔除算法(F3 循环切换, 供对比):
#   1 = Hi-Z 屏幕空间(上一帧深度金字塔; 有 1 帧延迟 → 快速运动会 disocclusion 黑洞)
#   2 = 解析地形射线(方案 B; 只用当前帧相机 + 静态烘焙 MinMax → 构造上无延迟, 不产生黑洞)
const OCCL_MODE_HIZ := 1
const OCCL_MODE_RAY := 2
var _occl_mode: int = OCCL_MODE_RAY   # 默认用方案 B(无黑洞)
# 相机模式(由 CameraDirector.set_cull_mode 推): true=CHARACTER(贴地聚焦角色 → 开 Hi-Z 遮挡),
# false=PLANET(高空聚焦星球 → 关 Hi-Z, 靠地平线+视锥剔除, 避免绕球/拉近时 disocclusion 露洞)。
var _cull_surface_mode: bool = true
# Phase 6 方案 B: MultiMesh.visible_instance_count 自适应裁剪。
# 靠异步回读的可见 patch 数(滞后 frame_queue_size≈2~3 帧)+ 余量设提交上限, 砍掉空 instance。
# 露洞只发生在"可见数增长快于回读能追上"时, 而**大幅增长几乎只来自快速接近星球(拉近)**: 距离 d↓
# → 近地 count≈1/d² 暴涨。绕行/远离/静止时 count 稳定或下降, 滞后回读 + 余量足以覆盖, 可正常裁剪。
# 所以: 平时(含绕行等持续运动)都按回读收紧 → 运动中也有优化; 仅"快速拉近"时顶满 MAX 防洞
# (用距离变化率即时判定, 无回读滞后; 绕行时距离≈不变 → 不触发)。
const VIC_APPROACH_FRAC := 0.03       # 每帧接近距离的比例 > 此值 = "快速拉近" → 顶满防洞(绕行≈0 不触发)
var _vic: int = MAX_PATCHES           # 当前应用的 visible_instance_count(grow-fast/shrink-slow 平滑)
var _vic_prev_dist: float = -1.0      # 上一帧相机到球心距离(判接近速率; <0 = 未初始化)
var _vic_approaching: bool = false    # 本帧是否在快速拉近(→ 顶满)
var _overflow_warned: bool = false    # MAX_PATCHES 溢出只警告一次(避免每帧刷屏)


func _ready() -> void:
	_connect_params_signal()   # 兜底: 若 setter 在加载瞬间因信号表未就绪跳过了连接, 这里补上
	_build_all()
	_push_params()
	_setup_lod_compositor()
	_bake_and_push_minmax()


func _exit_tree() -> void:
	# 等后台烘焙结束, 避免 worker 线程写入已释放的对象。
	if _bake_group_id != -1:
		WorkerThreadPool.wait_for_group_task_completion(_bake_group_id)
		_bake_group_id = -1
		_bake_result = null
		_bake_terrain = null
	# 摘掉 compositor(避免旧 WorldEnvironment 残留 effect 空跑)
	if _lod_comp != null or _hiz_comp != null:
		var we := _find_world_environment()
		if we != null and we.compositor != null:
			var effs: Array[CompositorEffect] = we.compositor.compositor_effects.duplicate()
			if _lod_comp != null:
				effs.erase(_lod_comp)
			if _hiz_comp != null:
				effs.erase(_hiz_comp)
			we.compositor.compositor_effects = effs
		_lod_comp = null
		_hiz_comp = null


func _process(_delta: float) -> void:
	# 每帧: 轮询后台烘焙是否完成 → 推 LOD 帧数据 + 绑上一帧写好的纹理。
	_poll_async_bake()
	if _lod_comp == null or not is_instance_valid(camera) or _mat == null:
		return
	# 编辑器预览关: compositor 已被 _apply_preview_enabled 禁用; 绑 fallback(基础 20 面)避免读到空 cull_tex。
	if Engine.is_editor_hint() and not preview_in_editor:
		_mat.set_shader_parameter("u_patchTex", _patch_tex_fallback)
		_apply_visible_count(false)   # 不裁剪(fallback 20 面须全可见)
		return
	var p: PlanetParams = _effective_params()
	var write_idx: int = _frame & 1
	var cam_pos: Vector3
	var c_const: float
	var k_sse: float = 0.0
	var frustum: Array
	# Phase 5 剔除开关(冻结与否都按 params 驱动; 冻结时用快照相机, 便于旁观检视被剔结果)。
	var horizon_on: bool = false
	var small_tri_px: float = 0.0
	var occlusion_on: bool = false
	var frustum_margin: float = 0.0   # 视锥外扩余量(世界单位; 补偿剔除 1 帧延迟, 随相机运动自适应)
	if _lod_frozen:
		# 冻结: 用快照的相机位置/参数 + 快照的视锥。剔除**保留**(按冻结相机的视角)→ 旁观相机可绕到
		# 任意角度检视"被剔成什么样"(视锥/地平线/小三角/遮挡的洞)。遮挡用冻结的 Hi-Z 金字塔(见下)。
		# 冻结时不外扩(要看精确的冻结视锥); 清运动历史, 解冻后重新起算避免一帧巨跳。
		cam_pos = _frozen_cam_pos
		c_const = _frozen_c_const
		k_sse = _frozen_k
		frustum = _frozen_frustum
		horizon_on = p.horizonCulling
		small_tri_px = p.smallTriPixels
		occlusion_on = p.occlusionCulling
		_cam_hist_valid = false
	else:
		var vp := camera.get_viewport()
		var vp_h: float = float(vp.size.y) if vp != null else 1080.0
		var fov_rad: float = deg_to_rad(camera.fov)
		k_sse = vp_h / (2.0 * tan(fov_rad * 0.5))
		c_const = p.maxHeight * k_sse / max(p.sseThresholdPixels, 0.001)
		cam_pos = camera.global_position
		# 6 视锥平面(world-space, Godot 内向法线约定)。Camera3D.get_frustum 返回顺序:
		# near, far, left, top, right, bottom(本项不依赖顺序, shader 全 6 平面测一遍)。
		frustum = camera.get_frustum() if camera.is_inside_tree() else []
		horizon_on = p.horizonCulling
		small_tri_px = p.smallTriPixels
		occlusion_on = p.occlusionCulling
		# 视锥外扩余量 = 常驻保险带 + 本帧运动量, 换算成世界单位后外推 6 平面。
		#   常驻保险带(base_angle): 消除静止/近静止时紧贴屏幕边缘的空洞(贴近地表、地形铺满全屏时最明显)。
		#   运动量(ang/lin, 本帧增量, 天然随帧率自适配): 补偿剔除的 1 帧延迟, 快速运动时额外多留。
		#   d_ref 用"相机→地平线切点"距离 sqrt(dist²-R²): 贴地小(边缘 patch 近, 不必大外扩)、太空大
		#   (随距离放大), 比 dist-to-center 更贴合可见地形的实际距离, 避免贴地时过度外扩浪费。
		if p.cullFrustumMargin > 0.0:
			var fwd: Vector3 = -camera.global_transform.basis.z
			var ang: float = 0.0   # 本帧转过的弧度
			var lin: float = 0.0   # 本帧移动的世界距离
			if _cam_hist_valid:
				ang = acos(clampf(fwd.dot(_last_cam_fwd), -1.0, 1.0))
				lin = (cam_pos - _last_cam_pos).length()
			var dist_c: float = cam_pos.distance_to(global_position)
			var horizon_d: float = sqrt(maxf(dist_c * dist_c - p.radius * p.radius, 0.0))
			var d_ref: float = clampf(horizon_d, p.radius * 0.1, maxf(dist_c, p.radius * 0.1))
			var base_angle: float = 0.04   # 常驻角度保险带(~2.3°), 再乘 cullFrustumMargin 系数
			frustum_margin = clampf(p.cullFrustumMargin * ((base_angle + ang) * d_ref + lin), 0.0, p.radius)
			_last_cam_pos = cam_pos
			_last_cam_fwd = fwd
			_cam_hist_valid = true
		else:
			_cam_hist_valid = false
	# Phase 6 方案 B: 快速拉近检测(即时 CPU 信号, 无回读滞后)。仅快速接近星球时可见 patch 数才会暴涨到
	# 超过滞后回读 → 顶满防洞; 绕行/远离/静止时 count 稳定或下降 → 不触发, 走裁剪分支(持续运动也有优化)。
	if _lod_frozen:
		_vic_approaching = false
		_vic_prev_dist = -1.0
	else:
		var dist_now: float = cam_pos.distance_to(global_position)
		if _vic_prev_dist > 0.0:
			var approach_frac: float = (_vic_prev_dist - dist_now) / maxf(dist_now, 1.0)
			_vic_approaching = approach_frac > VIC_APPROACH_FRAC
		else:
			_vic_approaching = false
		_vic_prev_dist = dist_now
	# 遮挡剔除(Hi-Z)按相机模式选择性启用 —— 不同视角下有价值的剔除不同, 全开反而在不合适的模式添乱:
	#   PLANET(高空聚焦星球, 绕球/拉近拉远): 关。地平线剔除已把行星背面剔干净, Hi-Z 额外收益极小, 却因
	#     用上一帧深度在运动时 disocclusion(新露出地形被误判遮挡)露黑洞(用户实测)。关掉即无洞。
	#   CHARACTER(贴地聚焦角色): 开(按 params.occlusionCulling)。贴地时近山遮挡后方地形, 正是 Hi-Z 的价值。
	# 冻结时按冻结前的 params 值。注: 旧的高度门(occlusionMinAltitudeFrac)恰好反了 —— 贴地(最该开)关、
	# 高空(最不该开)开, 故用模式门取代。occlusion_on 此处 = params.occlusionCulling。
	var occlusion_want: bool = occlusion_on if (_lod_frozen or _cull_surface_mode) else false
	_occlusion_applied = occlusion_want
	# LOD 曲率误差项系数(与 c_const 同量纲, 共用 K/T): 让大半径在粗层提前细分, 消除多边形棱角。
	# 用当前 radius(冻结时 k_sse 取快照值, radius 取实时 —— 冻结是调试用, 这点差异无碍)。
	var c_curve: float = ICO_SAGITTA_COEF * p.radius * k_sse / max(p.sseThresholdPixels, 0.001)
	# occluder 半径: 用**当前** radius 现算(不缓存) → 改半径立即生效, 无滞后误剔。
	# 有烘焙数据 → radius + 全局最小位移(更紧); 没有 → 保守下界 radius - maxHeight。
	var occluder_r: float = maxf(p.radius - p.maxHeight, 1.0)
	if not is_nan(_minmax_min_disp):
		# _minmax_min_disp 是**归一化**的(烘焙产物不含 maxHeight) → 这里用当前 maxHeight 缩放,
		# 于是改半径、改高度都立即生效且都不触发重烘。
		occluder_r = maxf(p.radius + _minmax_min_disp * p.maxHeight, 1.0)
	_lod_comp.set_frame_data({
		"cam_pos": cam_pos,
		"planet_center": global_position,
		"radius": p.radius,
		"maxHeight": p.maxHeight,
		"C_const": c_const,
		"C_curve": c_curve,
		"K": k_sse,
		"maxLevel": min(p.maxLevel, MAX_GPU_LEVEL),
		"write_idx": write_idx,
		"frustum": frustum,
		"horizonCulling": horizon_on,
		"horizonOccluderRadius": occluder_r,
		"smallTriPixels": small_tri_px,
		# 传**模式值**(0=关, 1=Hi-Z, 2=解析射线), 不是 bool —— shader 按它选算法。
		"occlusionCulling": (float(_occl_mode) if occlusion_want else 0.0),
		"frustumMargin": frustum_margin,
		"lod_frozen": _lod_frozen,
	})
	# Phase 5: 驱动 Hi-Z compositor。
	#   非冻结 + 遮挡开 → 每帧重建金字塔。
	#   冻结 → 停止重建 → 冻住冻结瞬间(冻结相机最后一帧)的金字塔; cull 用冻结的 view_proj 采它,
	#          于是遮挡剔除也定格在冻结视角, 旁观相机可绕看被遮挡剔除的洞。
	#   遮挡关 → 不建。
	if _hiz_comp != null:
		# 金字塔只在**真正用 Hi-Z 的模式**才重建: CHARACTER 模式 + 遮挡开 + mode==Hi-Z。
		# 方案 B(解析射线)不需要深度金字塔 → 不建, 省掉每帧 copy+reduce 的开销。
		_hiz_comp.set_active(occlusion_want and _occl_mode == OCCL_MODE_HIZ and not _lod_frozen)
	# minmax 未就绪时 cull 被跳过 → cull_tex 全 0 → vertex 坍缩无渲染(灰屏);
	# 此时保持绑 fallback(20 面 Phase-1 风格), 让用户看到东西而不是空屏。
	# 一旦 set_minmax 成功(下帧起), cull 写出有效 count, 切到 cull_tex 真正的 GPU LOD。
	var use_gpu_lod: bool = _lod_comp.is_minmax_ready()
	if use_gpu_lod:
		_mat.set_shader_parameter("u_patchTex", _lod_comp.get_read_texture(write_idx))
		if _frame == 1:
			print("[GpuPlanet] minmax ready → bind cull_tex (GPU LOD active)")
	else:
		_mat.set_shader_parameter("u_patchTex", _patch_tex_fallback)
		if _frame == 1:
			print("[GpuPlanet] minmax NOT ready → bind fallback (20 面). 检查 set_minmax 是否失败")
	# Phase 6 方案 B: GPU LOD 激活且未冻结时, 用回读的可见 patch 数设 visible_instance_count。
	# 冻结时不裁剪(旁观相机要看冻结视角被剔成什么样, 且 count 回读路径已停)。
	_apply_visible_count(use_gpu_lod and not _lod_frozen)
	_frame += 1


# Phase 6 方案 B: 按回读的可见 patch 数设 MultiMesh.visible_instance_count, 砍掉空 instance 的
# 顶点 shader 开销。现状: 提交 MAX_PATCHES=12288 个 instance, vertex 靠 META_ROW count 把 id≥count
# 的坍缩成退化点(rasterizer 丢弃), 但坍缩前每个空 instance 的顶点 shader 仍全跑。可见通常仅几百 →
# 上万空 instance 白跑顶点 shader。设 visible_instance_count 让 GPU 干脆不提交它们。
#
# 正确性: vertex 的 META_ROW 坍缩守卫仍在 → visible_instance_count 只是"上限优化", 过大无害
# (多出的 instance 坍缩丢弃), 过小才会把有效 patch 裁掉露洞。异步回读延迟 frame_queue_size 帧,
# 快速运动时可见数增长会超过回读值 → 露洞。故改用**相机运动门控**(见 _process 里 _stable_frames):
#   • apply=false(编辑器预览关/冻结)、回读未就绪、或相机运动/刚停不足 VIC_STABLE_FRAMES 帧 →
#     顶满 MAX_PATCHES(不裁剪, 保证不露洞)。相机运动是即时信号、无回读滞后。
#   • 相机稳定 >= VIC_STABLE_FRAMES 帧(回读已追上真实值, 且静止时 count 不变)→ 收紧到 rc×1.3+128。
func _apply_visible_count(apply: bool) -> void:
	if _mm == null:
		return
	var target: int
	var rc: int = _lod_comp.get_visible_count() if apply else -1
	# patch 上限溢出检测: cull shader 的 counter 对**所有**通过剔除的 patch 都 atomicAdd, 超过
	# MAX_PATCHES 的槽才丢弃 → 回读值 > MAX_PATCHES 就是精确的溢出信号(丢了 rc-MAX_PATCHES 个 patch,
	# 表现为地形露洞, 且原本静默无提示)。常见诱因: 半径调太小、maxHeight 调太大、sseThresholdPixels
	# 调太小 —— 都会让细分壳内塞进过多 patch。
	if rc > MAX_PATCHES and not _overflow_warned:
		_overflow_warned = true
		push_warning(("[GpuPlanet] patch 数溢出: 需要 %d 个, 上限 MAX_PATCHES=%d → 丢弃 %d 个(地形会露洞)。"
			+ "解决: 调大 sseThresholdPixels(更省)、调小 maxHeight、或调大 radius; "
			+ "要真正提高上限需同步改 gpu_planet/gpu_lod_compositor 的 MAX_PATCHES 与 lod_traverse/lod_cull/"
			+ "terrain_gpu 里的同名常量(必须一致)。") % [rc, MAX_PATCHES, rc - MAX_PATCHES])
	if not apply or rc < 0 or _vic_approaching:
		# 顶满不裁剪。命中: 编辑器预览关/冻结(apply=false); 回读未就绪(rc<0); 或快速拉近(count 暴涨超
		# 回读 → 顶满防洞, 瞬态)。绕行/静止/远离都不在此列 → 走下面收紧分支, 持续运动中照样有优化。
		target = MAX_PATCHES
	else:
		# 回读×1.4 + 256 余量: 覆盖回读滞后窗口内 count 的**缓慢**增长(绕行 / 慢速接近)。快速接近已由
		# _vic_approaching 兜底顶满, 故此处余量不必很大。
		target = clampi(int(ceil(float(rc) * 1.4)) + 256, 0, MAX_PATCHES)
	# 增长立即跟上(安全方向: 过量 instance 坍缩无害); 收缩缓降(~12.5%/帧, 至少 64), 防抖 + 抹回读噪声。
	if target >= _vic:
		_vic = target
	else:
		_vic = maxi(target, _vic - maxi(64, int(float(_vic - target) / 8.0)))
	if _mm.visible_instance_count != _vic:
		_mm.visible_instance_count = _vic


# ---- LOD 冻结接口(供 planet_lod_debug.gd 调; 调试用) ----
# 冻结: 快照当前相机位置/C_const/K/视锥, 之后 _process 用快照驱动 LOD **和全部剔除**(视锥/地平线/
# 小三角/遮挡)。遮挡的 Hi-Z 金字塔也一并冻住(停止重建)。于是 LOD + 剔除结果定格在冻结相机视角,
# 旁观相机(planet_lod_debug.gd)可绕到任意角度检视"被剔成什么样"(缺面 = 被剔的 patch)。
func freeze_lod() -> void:
	if not is_instance_valid(camera):
		return
	var p: PlanetParams = _effective_params()
	var vp := camera.get_viewport()
	var vp_h: float = float(vp.size.y) if vp != null else 1080.0
	var fov_rad: float = deg_to_rad(camera.fov)
	var k: float = vp_h / (2.0 * tan(fov_rad * 0.5))
	_frozen_c_const = p.maxHeight * k / max(p.sseThresholdPixels, 0.001)
	_frozen_k = k
	_frozen_cam_pos = camera.global_position
	# 快照**真实**视锥(不再置空): 冻结后仍按冻结相机做剔除, 旁观相机绕看能看到被剔的洞。
	_frozen_frustum = camera.get_frustum() if camera.is_inside_tree() else []
	_lod_frozen = true


func unfreeze_lod() -> void:
	_lod_frozen = false


func is_lod_frozen() -> bool:
	return _lod_frozen


# 调试用(planet_lod_debug HUD): 返回 LOD 提交统计, 验证 Phase 6 方案 B 生效。
#   visible   = 最近回读的可见 patch 数(-1 = 未就绪)
#   submitted = 当前 MultiMesh.visible_instance_count(= 实际提交 GPU 的 instance 数)
#   max       = MAX_PATCHES(未优化时的提交数)
func get_lod_stats() -> Dictionary:
	var rc: int = _lod_comp.get_visible_count() if _lod_comp != null else -1
	var p: PlanetParams = _effective_params()
	return {
		"visible": rc, "submitted": _vic, "max": MAX_PATCHES,
		"occlusion_text": occlusion_mode_text(),
		"horizon": p.horizonCulling, "surface_mode": _cull_surface_mode,
	}


# CameraDirector 切换相机模式时调: 决定本模式下 Hi-Z 遮挡剔除是否启用(见 _process 的 occlusion_want)。
#   surface=true  → CHARACTER 模式(贴地聚焦角色): 开遮挡(近山遮挡后方地形)。
#   surface=false → PLANET 模式(高空聚焦星球): 关遮挡(靠地平线+视锥, 避免运动 disocclusion 露洞)。
func set_cull_mode(surface: bool) -> void:
	_cull_surface_mode = surface


# 调试用(planet_lod_debug F3/F4): 运行时开关遮挡 / 地平线剔除, 快速定位"快速运动黑洞"来自哪种剔除。
# 剔除跑在上一帧数据上(1 帧延迟), 快速运动时被剔集合滞后 → 露洞。逐个关掉即可定位元凶。
## F3 循环切换遮挡: 关 → Hi-Z(屏幕空间, 1 帧延迟) → 解析地形射线(方案 B, 无延迟) → 关。
## 返回当前状态字符串, 供调试 HUD/日志显示。方便直接对比两种算法的黑洞与剔除量。
func debug_cycle_occlusion() -> String:
	var p: PlanetParams = _effective_params()
	if not p.occlusionCulling:
		p.occlusionCulling = true
		_occl_mode = OCCL_MODE_HIZ
	elif _occl_mode == OCCL_MODE_HIZ:
		_occl_mode = OCCL_MODE_RAY
	else:
		p.occlusionCulling = false
	return occlusion_mode_text()


## 当前遮挡状态文字(HUD 用)。
func occlusion_mode_text() -> String:
	var p: PlanetParams = _effective_params()
	if not p.occlusionCulling:
		return "关"
	# 不用局部变量名 name —— 会遮蔽 Node.name 触发 SHADOWED_VARIABLE 警告。
	# 括号内用 ASCII: 之前写"延迟", 但「迟」字在 HUD 的 fallback 字体里缺字形, 渲染成方框(tofu)。
	# 技术词直接用英文既避开缺字, 也不影响可读性。
	var algo: String = "Hi-Z(1-frame lag)" if _occl_mode == OCCL_MODE_HIZ else "RayMarch(realtime)"
	if not _occlusion_applied:
		return algo + "[off in this cam mode]"   # 意愿开但当前相机模式(PLANET)不启用
	return algo


func debug_toggle_horizon() -> bool:
	var p: PlanetParams = _effective_params()
	p.horizonCulling = not p.horizonCulling
	return p.horizonCulling


# 切换单遍着色器线框(F1 用)。不走 DEBUG_DRAW_WIREFRAME(那会额外 line pass, 12288 instance 爆帧)。
func set_wireframe(on: bool) -> void:
	if _mat != null:
		_mat.set_shader_parameter("u_wireframe", on)


# 烘 MinMax(首次 + param 变时)。命中缓存 → 主线程直接 load; 未命中 → 后台线程烘焙, 不阻塞。
func _bake_and_push_minmax() -> void:
	if _lod_comp == null:
		return
	var p: PlanetParams = _effective_params()
	var sh: int = HeightmapBaker.compute_seed_hash(p)
	# 幂等守卫: param_changed 对**任何** PlanetParams 属性都会来(线框/遮挡剔除/地平线开关这些纯
	# 渲染项也算), 而 MinMax 只依赖 seed_hash 里那批噪声参数。不比一下, 每按一次调试键都要
	# load .res + 重建金字塔 + 重建 GPU 纹理 + 20 次 texture_update —— 日志里能看到十几次
	# "缓存命中"连着刷。
	# 用 hash 比较而不是维护一份 key 白名单: compute_seed_hash 是唯一数据源, 不会漂移;
	# 顺带把 radius / maxHeight 这类"在 hash 之外"的参数也自动跳过。
	if _has_applied_minmax and sh == _applied_seed_hash:
		return
	var path: String = HeightmapBaker.default_path(sh, GpuLodCompositor.BAKE_RES)
	# 命中缓存 → 主线程直接 load(快, 无需烘焙), 立即应用。
	if ResourceLoader.exists(path):
		var cached: Resource = load(path)
		if cached is GpuMinMaxData:
			print("[GpuPlanet] MinMax 缓存命中 → 直接加载, GPU LOD 立即激活")
			_apply_minmax(cached as GpuMinMaxData)
			return
	# 未命中 → 后台面级并行烘焙(避免主线程/编辑器卡死); 期间用 fallback 20 面渲染。
	if _bake_group_id != -1:
		return   # 已有烘焙在跑, 不重复提交
	_bake_save_path = path
	# 空壳 + 共享噪声实例都在主线程建好: face_mip0 容量一次性定好, 20 个 worker 只写各自的索引,
	# 既不 resize 也不碰 _pyramid → 无需加锁。
	_bake_result = HeightmapBaker.new_data(p, GpuLodCompositor.BAKE_RES)
	_bake_terrain = Terrain.from_params(p)
	_bake_group_id = WorkerThreadPool.add_group_task(
		_bake_face_task, GpuIco.FACE_COUNT, -1, false, "planet minmax bake")
	print("[GpuPlanet] MinMax 缓存未命中 → 后台并行烘焙中(先用 20 面 fallback, 烘完自动切 GPU LOD)")


# group task 体(worker 线程, 每面一个): 纯 CPU 噪声采样, 不碰 RenderingDevice / 场景树。
# 只写 face_mip0[fi] 这一个槽, 与其它 fi 互不重叠。结果由主线程 _poll_async_bake 取走。
func _bake_face_task(fi: int) -> void:
	if _bake_result == null or _bake_terrain == null:
		return
	_bake_result.face_mip0[fi] = HeightmapBaker.bake_face(
		_bake_terrain, GpuLodCompositor.BAKE_RES, fi)


# 主线程每帧轮询: 后台烘焙完成 → 存盘缓存(下次秒开) + 上传 GPU。
func _poll_async_bake() -> void:
	if _bake_group_id == -1 or not WorkerThreadPool.is_group_task_completed(_bake_group_id):
		return
	WorkerThreadPool.wait_for_group_task_completion(_bake_group_id)   # 已完成, 立即返回; 提供内存屏障
	var data: GpuMinMaxData = _bake_result
	_bake_group_id = -1
	_bake_result = null
	_bake_terrain = null
	if data == null:
		return
	# worker 直接写了 face_mip0(绕过 set_face_mip0)→ 显式丢弃可能的旧金字塔缓存。
	data.invalidate_pyramid()
	# 齐全性校验: 面级并行下任何一面没写成(worker 异常 / 提前退出)都会留 null, 而 build_pyramid
	# 会拿空数组去索引 → 崩在 _build_face_pyramid。宁可这里整批丢弃, 等下次触发重烘。
	var expect_len: int = GpuLodCompositor.BAKE_RES * GpuLodCompositor.BAKE_RES * 2
	for fi in range(GpuIco.FACE_COUNT):
		var face_arr: Variant = data.face_mip0[fi] if fi < data.face_mip0.size() else null
		if not (face_arr is PackedFloat32Array) \
				or (face_arr as PackedFloat32Array).size() != expect_len:
			push_warning(
				"[GpuPlanet] 烘焙结果不完整(face %d), 丢弃本次结果; 下次参数变更或重启会重烘" % fi)
			return
	# 存盘: 下次启动 _bake_and_push_minmax 命中缓存, 直接 load 跳过烘焙。
	if _bake_save_path != "":
		var dir_path: String = _bake_save_path.get_base_dir()
		if not DirAccess.dir_exists_absolute(dir_path):
			DirAccess.make_dir_recursive_absolute(dir_path)
		var err: Error = ResourceSaver.save(data, _bake_save_path)
		if err != OK:
			push_warning("[GpuPlanet] MinMax 缓存存盘失败 %s: %d" % [_bake_save_path, err])
	print("[GpuPlanet] 后台烘焙完成: bake_res=%d → 上传 GPU" % data.bake_res)
	_apply_minmax(data)


# 上传烘焙数据到 compositor(缓存命中 / 后台烘焙完成 共用)。
func _apply_minmax(data: GpuMinMaxData) -> void:
	if _lod_comp == null:
		return
	# Phase 5: 只缓存全局最小位移(归一化, 与 radius / maxHeight 都无关);
	# occluder 半径由 _process 每帧用当前 radius + maxHeight 现算。
	_minmax_min_disp = data.global_min_disp()
	if not _lod_comp.set_minmax(data):
		push_warning("[GpuPlanet] MinMax 上传失败(占位 fallback; LOD 不裁剪)")
	else:
		# data.seed_hash 由 HeightmapBaker.new_data 写入, 与缓存文件名里的 hash 同源 → 必然等于
		# 调用侧刚算的 sh。上传成功才记, 失败时保持未应用状态以便下次重试。
		_applied_seed_hash = data.seed_hash
		_has_applied_minmax = true
		print("[GpuPlanet] set_minmax OK → 下帧起 cull 跑, GPU LOD 激活")


func _on_param_changed(key: String) -> void:
	_push_params()
	# 影响高度的参数变 → 重烘 MinMax(种子/频率/振幅类; 半径/海平面等不影响 MinMax, 且 seed_hash 已不含
	# radius → 改半径直接命中缓存, 不会重烘)。
	_bake_and_push_minmax()
	# 通知依赖行星几何的节点刷新其缓存(角色把 radius/maxHeight/seaLevel/Terrain 缓存在 _ready,
	# 不通知就会按旧半径贴地 → 悬空或沉地)。鸭子类型调用, 不硬依赖角色脚本类型。
	# 只在**几何相关**的 key 上通知: refresh_planet 会把角色硬贴回地表并清零竖直速度, 若对
	# 大气/海洋配色之类无关参数也触发, 会在跳跃中途把人拽回地面。
	if key == "seaLevel" or _effective_params().requires_rebuild(key):
		_notify_geometry_dependents()


# 递归通知子树里实现了 refresh_planet() 的节点(目前是角色控制器)。
# 只在 param 变时调用(低频), 递归开销可忽略。
func _notify_geometry_dependents() -> void:
	if not is_inside_tree():
		return
	_notify_refresh_recursive(get_tree().root)


func _notify_refresh_recursive(n: Node) -> void:
	if n.has_method("refresh_planet"):
		n.call("refresh_planet")
	for c in n.get_children():
		_notify_refresh_recursive(c)
	# 参数变可能改变可见 patch 数(如 maxLevel/sseThreshold)而相机没动 → 先顶满, 靠 shrink-slow 慢慢收紧,
	# 给异步回读时间追上新 count, 防止用旧 count 收得过紧露洞。
	_vic = MAX_PATCHES


func _schedule_rebuild() -> void:
	if _dirty:
		return
	_dirty = true
	_rebuild_deferred.call_deferred()


func _rebuild_deferred() -> void:
	_dirty = false
	_build_all()
	_push_params()


func _build_all() -> void:
	if _patch_tex_fallback == null:
		_patch_tex_fallback = _build_patch_tex_fallback()
	if _patch_mesh == null or _mesh_res != patch_resolution:
		_patch_mesh = _build_patch_mesh(patch_resolution)
		_mesh_res = patch_resolution
		if _mm != null:
			_mm.mesh = _patch_mesh
	if _mminst != null and not is_instance_valid(_mminst):
		_mminst = null
	if _mminst == null:
		_mminst = get_node_or_null(MM_NODE_NAME)
	if _mminst == null:
		_mminst = MultiMeshInstance3D.new()
		_mminst.name = MM_NODE_NAME
		add_child(_mminst)
		_mminst.owner = null
	if _mm == null:
		_mm = MultiMesh.new()
		_mm.transform_format = MultiMesh.TRANSFORM_3D
		_mm.mesh = _patch_mesh
		_mm.instance_count = MAX_PATCHES   # 方案 A: 固定上限, shader 坍缩 id≥count
		for i in range(MAX_PATCHES):
			_mm.set_instance_transform(i, Transform3D.IDENTITY)
		_mminst.multimesh = _mm
	if _mat == null:
		var sh: Shader = load("res://shaders/planet/terrain_gpu.gdshader")
		_mat = ShaderMaterial.new()
		_mat.shader = sh
		_mminst.material_override = _mat


func _push_params() -> void:
	if _mat == null:
		return
	var p: PlanetParams = _effective_params()
	_mat.set_shader_parameter("u_radius", p.radius)
	_mat.set_shader_parameter("u_max_height", p.maxHeight)
	_mat.set_shader_parameter("u_patch_res", float(patch_resolution))   # Phase 4: 边检测 tol 用
	_mat.set_shader_parameter("u_sea", p.seaLevel)
	_mat.set_shader_parameter("u_warp", p.warpStrength)
	_mat.set_shader_parameter("u_warp_freq", p.warpFreq)
	_mat.set_shader_parameter("u_cont_freq", p.continentFreq)
	_mat.set_shader_parameter("u_cont_oct", p.continentOctaves)
	_mat.set_shader_parameter("u_cont_gain", p.continentGain)
	_mat.set_shader_parameter("u_cont_lac", p.continentLacunarity)
	_mat.set_shader_parameter("u_mtn_freq", p.mountainFreq)
	_mat.set_shader_parameter("u_mtn_oct", p.mountainOctaves)
	_mat.set_shader_parameter("u_mtn_strength", p.mountainStrength)
	_mat.set_shader_parameter("u_plate", p.plateStrength)
	_mat.set_shader_parameter("u_plate_freq", p.plateFreq)
	_mat.set_shader_parameter("u_moist_freq", p.moistureFreq)
	_mat.set_shader_parameter("u_alt_range", p.climateAltRange)
	_mat.set_shader_parameter("u_use_climate", 1.0 if p.useClimate else 0.0)
	_mat.set_shader_parameter("u_off_warp", Terrain.off(p.warpSeed))
	_mat.set_shader_parameter("u_off_cont", Terrain.off(p.continentSeed))
	_mat.set_shader_parameter("u_off_mtn", Terrain.off(p.mountainSeed))
	_mat.set_shader_parameter("u_off_plate", Terrain.off(p.plateSeed))
	_mat.set_shader_parameter("u_off_moist", Terrain.off(p.moistureSeed))
	# 初始/fallback 绑定; compositor 运行后每帧覆盖 u_patchTex 为 GPU 写的纹理。
	_mat.set_shader_parameter("u_patchTex", _patch_tex_fallback)
	var r_extent: float = p.radius + p.maxHeight * 1.2 + 1.0
	_mminst.custom_aabb = AABB(Vector3(-r_extent, -r_extent, -r_extent), Vector3(2.0 * r_extent, 2.0 * r_extent, 2.0 * r_extent))


func _effective_params() -> PlanetParams:
	if params != null:
		return params
	if _default_params == null:
		_default_params = PlanetParams.new()
	return _default_params


# ---- LOD compositor 接线: 找场景 WorldEnvironment, 建 GpuLodCompositor 挂其 compositor.effects ----
func _setup_lod_compositor() -> void:
	if _lod_comp != null:
		return
	if _mat == null:
		return
	var we: WorldEnvironment = _find_world_environment()
	if we == null:
		push_warning("[GpuPlanet] 场景无 WorldEnvironment, GPU LOD 不生效(用 fallback 20 面渲染)")
		return
	var comp: Compositor = we.compositor
	if comp == null:
		comp = Compositor.new()
		we.compositor = comp
	# 清理历史遗留: 早期版本每次 setup 都 append 一个 GpuLodCompositor 到场景的 Compositor 资源,
	# 在编辑器保存时被序列化进 .tscn → 反复重开累积一堆空跑的旧 effect(planet.tscn 里曾有 5 个)。
	# 这里先剔掉所有我方类型的 effect, 再挂新建的, 保证同类只 1 份。配合 PRE/POST_SAVE 钩子(不入盘)。
	_purge_planet_effects(comp)
	_lod_comp = (_GpuLodCompositor_script as GDScript).new() as GpuLodCompositor
	if not _lod_comp.setup(_mat.get_rid()):
		push_error("[GpuPlanet] GpuLodCompositor.setup 失败(compute shader 编译错误?)")
		_lod_comp = null
		return
	# 新 compositor = 新 RenderingDevice 资源, 之前上传的 MinMax 纹理跟着旧实例没了 → 复位幂等
	# 守卫的标记, 否则 seed_hash 没变会被守卫拦住、永远不重传, minmax 一直 not ready。
	_has_applied_minmax = false
	# Phase 5: Hi-Z 遮挡剔除 compositor(POST_OPAQUE 建深度金字塔)。接线给 lod_comp 供 PRE_OPAQUE 读。
	# 编译失败不致命 —— 降级到无遮挡剔除(lod_comp 读不到金字塔 → hiz_ready=0 → 跳过遮挡测试)。
	_hiz_comp = (_GpuHizCompositor_script as GDScript).new() as GpuHizCompositor
	_lod_comp.set_hiz_provider(_hiz_comp)
	# 重新赋值整个数组(而非 in-place append)→ 触发 Compositor 属性 setter → 重新注册 effects 到渲染服务器。
	# 顺序: lod_comp(PRE_OPAQUE) 在前, hiz_comp(POST_OPAQUE) 在后 —— 回调按 pass 时机触发, 顺序无碍。
	var effs: Array[CompositorEffect] = comp.compositor_effects.duplicate()
	effs.append(_lod_comp)
	effs.append(_hiz_comp)
	comp.compositor_effects = effs
	_apply_preview_enabled()   # 编辑器里按 preview_in_editor 决定是否启用


# 剔掉 Compositor 里所有本插件类型(GpuLodCompositor / GpuHizCompositor)的 effect。
func _purge_planet_effects(comp: Compositor) -> void:
	if comp == null:
		return
	var kept: Array[CompositorEffect] = []
	var changed := false
	for e in comp.compositor_effects:
		if e is GpuLodCompositor or e is GpuHizCompositor:
			changed = true
			continue
		kept.append(e)
	if changed:
		comp.compositor_effects = kept


# 编辑器里按 preview_in_editor 开关 compositor; 运行时始终开。
func _apply_preview_enabled() -> void:
	var on: bool = (not Engine.is_editor_hint()) or preview_in_editor
	if _lod_comp != null:
		_lod_comp.enabled = on
	if _hiz_comp != null:
		_hiz_comp.enabled = on


# 编辑器保存前/后: 把动态挂的 effect 摘下/挂回, 避免它们被序列化进 .tscn(否则重开累积垃圾)。
func _notification(what: int) -> void:
	if what == NOTIFICATION_EDITOR_PRE_SAVE:
		_detach_planet_effects()
	elif what == NOTIFICATION_EDITOR_POST_SAVE:
		_reattach_planet_effects()


func _detach_planet_effects() -> void:
	var we: WorldEnvironment = _find_world_environment()
	if we == null or we.compositor == null:
		return
	_purge_planet_effects(we.compositor)


func _reattach_planet_effects() -> void:
	var we: WorldEnvironment = _find_world_environment()
	if we == null or we.compositor == null or _lod_comp == null:
		return
	var comp: Compositor = we.compositor
	var effs: Array[CompositorEffect] = comp.compositor_effects.duplicate()
	if not effs.has(_lod_comp):
		effs.append(_lod_comp)
	if _hiz_comp != null and not effs.has(_hiz_comp):
		effs.append(_hiz_comp)
	comp.compositor_effects = effs


func _find_world_environment() -> WorldEnvironment:
	var root := get_tree().root if is_inside_tree() else null
	if root == null:
		return null
	return _scan_world_environment(root)


func _scan_world_environment(n: Node) -> WorldEnvironment:
	if n is WorldEnvironment:
		return n as WorldEnvironment
	for c in n.get_children():
		var r: WorldEnvironment = _scan_world_environment(c)
		if r != null:
			return r
	return null


# ---- fallback patch 纹理: 6×(MAX_PATCHES+1), 前 20 行填面角点, 末行 count=20 ----
# 用途: ① 首帧/compositor 未跑时绑定(避免 u_patchTex 空); ② 无 camera/compositor 时 Phase1 风格渲染。
static func _build_patch_tex_fallback() -> ImageTexture:
	var W: int = PATCH_TEX_SLOTS
	var H: int = PATCH_TEX_H
	var floats := PackedFloat32Array()
	floats.resize(W * H * 4)
	floats.fill(0.0)
	for fi in range(GpuIco.FACE_COUNT):
		var corners: Array = GpuIco.face_corners(fi)
		var A: Vector3 = corners[0]
		var B: Vector3 = corners[1]
		var C: Vector3 = corners[2]
		var b: int = fi * W * 4
		floats[b + 0] = A.x; floats[b + 1] = A.y; floats[b + 2] = A.z; floats[b + 3] = float(fi)
		floats[b + 4] = B.x; floats[b + 5] = B.y; floats[b + 6] = B.z; floats[b + 7] = 0.0
		floats[b + 8] = C.x; floats[b + 9] = C.y; floats[b + 10] = C.z; floats[b + 11] = 0.0
		# texel3/4: 根面的 face-bary(A=(0,0), B=(1,0), C=(0,1))。shader 改用 face_dir_from_bary 后,
		# fallback 也必须带 bary, 否则 fb 全 0 → 所有顶点坍到 V0 → 20 面退化。
		floats[b + 12] = 0.0; floats[b + 13] = 0.0; floats[b + 14] = 1.0; floats[b + 15] = 0.0
		floats[b + 16] = 0.0; floats[b + 17] = 1.0; floats[b + 18] = 0.0; floats[b + 19] = 0.0
	# 末行 metadata: count = 20(渲染前 20 个 instance = 20 面)
	var mb: int = MAX_PATCHES * W * 4
	floats[mb + 0] = float(GpuIco.FACE_COUNT)
	var img := Image.create_from_data(W, H, false, Image.FORMAT_RGBAF, floats.to_byte_array())
	return ImageTexture.create_from_image(img)


# ---- 共享三角形 patch 网格: n 细分, 顶点 (i,j) i+j<=n, uv=(i/n, j/n) ----
static func _build_patch_mesh(n: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var idmap: Dictionary = {}
	for j in range(n + 1):
		for i in range(n + 1):
			if i + j <= n:
				idmap[Vector2i(i, j)] = verts.size()
				var u: float = float(i) / float(n)
				var v: float = float(j) / float(n)
				verts.append(Vector3(u, v, 0.0))
				uvs.append(Vector2(u, v))
	for j in range(n):
		for i in range(n):
			if i + j <= n - 1:
				idx.append(idmap[Vector2i(i, j)])
				idx.append(idmap[Vector2i(i + 1, j)])
				idx.append(idmap[Vector2i(i, j + 1)])
				if i + j <= n - 2:
					idx.append(idmap[Vector2i(i + 1, j)])
					idx.append(idmap[Vector2i(i + 1, j + 1)])
					idx.append(idmap[Vector2i(i, j + 1)])
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m
