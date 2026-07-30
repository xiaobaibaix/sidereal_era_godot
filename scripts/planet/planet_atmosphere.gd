# gdlint: disable=variable-name, max-line-length
## 行星大气 + 体积云 + 体积光(godray)+ 海洋 驱动。挂在 GpuPlanet 下(或场景任意处并指定 planet)。
##
## 复刻已删除的旧 planet.gd 的大气/海洋接线, 但数据源改成 GpuPlanet + PlanetParams:
##   1. 把 AtmosphereCompositor(POST_TRANSPARENT 全屏后处理: 大气散射 + 体积云 + godray)接到场景
##      WorldEnvironment.compositor, 每帧从 params 推场景参数(半径/散射/云/太阳)给它(经 Mutex)。
##   2. 建一个海平面球壳(shaders/ocean.gdshader), 半径 = radius + seaLevel×maxHeight; 写不透明色+深度,
##      让大气/云能正确合成在海面之上。
##
## 太阳方向取自场景里的 DirectionalLight3D(其 +Z 轴 = 指向太阳, 与 Godot 对地形的光照方向一致);
## 没有光源则用 params.sunElevation/sunAzimuth 兜底。
##
## @tool: 编辑器里也预览(改 showOcean / 大气 / 云参数, 视口里的球体即时变化)。
## 曾经刻意不做 @tool 以躲开"序列化污染", 现在改为正面解决 —— 与 GpuPlanet 用同一套防护:
##   ① compositor effect: NOTIFICATION_EDITOR_PRE_SAVE 摘下 / POST_SAVE 挂回 → 不会被写进 .tscn。
##      (GpuPlanet 踩过这个坑: 早期每次 setup 都往 Compositor 资源 append, 保存后重开累积一堆空跑
##       的旧 effect, planet.tscn 里曾攒到 5 个。)
##   ② 建之前先 _purge_atmo_effects 剔掉同类残留, 保证场上只有 1 份。
##   ③ ocean 壳: _ocean_mesh.owner = null(本来就有)→ 不入盘; 另外 @tool 下每次脚本重载都会重跑
##      _ready, 所以建壳前要清掉上一轮的同名节点, 否则编辑器里累积一堆 OceanShell。
## 编辑器预览的总开关复用 GpuPlanet.preview_in_editor(见 _preview_on), 不再单开一个。
@tool
class_name PlanetAtmosphere
extends Node3D

const _OCEAN_SHADER_PATH := "res://shaders/ocean.gdshader"
# 瑞利/臭氧的波长配比(移植 web): 乘以 params 的强度得到最终 RGB 散射系数。
const _RAY_RATIO := Vector3(0.1066, 0.3245, 0.6830)
const _OZO_RATIO := Vector3(0.35, 1.0, 0.045)

## 行星(提供 params + 世界中心)。留空 → 自动用父节点(若父是 GpuPlanet)或全场景查找第一个 GpuPlanet。
@export var planet: GpuPlanet
## 主太阳(DirectionalLight3D)。留空 → 全场景查找第一个 DirectionalLight3D。
@export var sun_light: DirectionalLight3D
## 总开关(关 = 不建/不驱动大气与海洋)。
@export var enabled: bool = true

var _atmo: AtmosphereCompositor
var _we: WorldEnvironment
var _ocean_mesh: MeshInstance3D
var _ocean_mat: ShaderMaterial
var _ocean_shader: Shader
var _sun_dir: Vector3 = Vector3(0.739, 0.443, 0.515)


func _ready() -> void:
	if not enabled:
		return
	_resolve_planet()
	if not _preview_on():
		return   # 编辑器里预览关 → 什么都不建(省编辑器算力), 运行时不受影响
	_resolve_sun()
	_build_ocean()
	_build_compositor()


# 编辑器预览是否启用。复用 GpuPlanet.preview_in_editor —— 一个开关管住全部编辑器预览
# (LOD 地形 + 大气/云/海洋), 免得两处各有一个还得同步。运行时恒 true。
func _preview_on() -> bool:
	if not Engine.is_editor_hint():
		return true
	if planet == null:
		_resolve_planet()
	# `in` 做属性存在性检查: 编辑器加载/热重载瞬间 GpuPlanet 脚本可能还没就绪, 直接点属性会抛
	# "Invalid access to property or key"(params setter 里那段字符串版 has_signal 是同一个成因)。
	if planet != null and "preview_in_editor" in planet:
		return planet.preview_in_editor
	return false   # 编辑器里连 GpuPlanet 都找不到 → 不预览(免得拿默认参数瞎画)


func _exit_tree() -> void:
	# 摘掉大气 compositor effect(避免残留空跑)。
	if _atmo != null and _we != null and is_instance_valid(_we) and _we.compositor != null:
		var effs: Array[CompositorEffect] = _we.compositor.compositor_effects.duplicate()
		effs.erase(_atmo)
		_we.compositor.compositor_effects = effs
	_atmo = null


func _process(_delta: float) -> void:
	if planet == null or planet.params == null:
		return
	if not enabled or not _preview_on():
		# 中途关掉时把已建的东西静默下来, 否则会留着上一帧的状态(海面还在、大气还在跑)。
		if _atmo != null:
			_atmo.enabled = false
		if _ocean_mesh != null and is_instance_valid(_ocean_mesh):
			_ocean_mesh.visible = false
		return
	# 编辑器里预览可能是刚被打开的(_ready 时还关着 → 什么都没建)→ 这里补建, 幂等。
	if Engine.is_editor_hint() and _atmo == null:
		_resolve_sun()
		_build_ocean()
		_build_compositor()
	_update_sun()
	_resize_ocean()
	_apply_ocean_uniforms()
	_push_frame()


# ---- 解析引用 ----
func _resolve_planet() -> void:
	if planet != null:
		return
	var p := get_parent()
	while p != null:
		if p is GpuPlanet:
			planet = p
			return
		p = p.get_parent()
	planet = _scan(get_tree().root, "GpuPlanet") as GpuPlanet


func _resolve_sun() -> void:
	if sun_light != null:
		return
	sun_light = _scan(get_tree().root, "DirectionalLight3D") as Node3D


func _scan(n: Node, type_name: String) -> Node:
	if (type_name == "GpuPlanet" and n is GpuPlanet) or (type_name == "DirectionalLight3D" and n is DirectionalLight3D):
		return n
	for c in n.get_children():
		var r := _scan(c, type_name)
		if r != null:
			return r
	return null


func _scan_world_env(n: Node) -> WorldEnvironment:
	if n is WorldEnvironment:
		return n as WorldEnvironment
	for c in n.get_children():
		var r := _scan_world_env(c)
		if r != null:
			return r
	return null


func _center() -> Vector3:
	return planet.global_position if planet != null else global_position


# ---- 海洋球壳 ----
func _build_ocean() -> void:
	if _ocean_mesh != null and is_instance_valid(_ocean_mesh):
		return   # 幂等: @tool 下 _ready 会随脚本重载反复触发
	# 清掉上一轮留下的壳: @tool 重载时成员变量丢了但子节点还挂在树上, 不清就会累积一堆 OceanShell。
	for c in get_children():
		if c.name == "OceanShell":
			remove_child(c)
			c.queue_free()
	if _ocean_shader == null:
		_ocean_shader = load(_OCEAN_SHADER_PATH)
	_ocean_mesh = MeshInstance3D.new()
	_ocean_mesh.name = "OceanShell"
	_ocean_mesh.top_level = true   # 由脚本直接设世界位姿(球心 + 半径缩放), 不受父变换影响
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 128
	sm.rings = 96
	_ocean_mesh.mesh = sm
	_ocean_mat = ShaderMaterial.new()
	_ocean_mat.shader = _ocean_shader
	_ocean_mesh.material_override = _ocean_mat
	add_child(_ocean_mesh)
	_ocean_mesh.owner = null   # 运行时创建, 不写入 .tscn


func _resize_ocean() -> void:
	if _ocean_mesh == null:
		return
	var p := planet.params
	var ground_r: float = p.radius + p.seaLevel * p.maxHeight
	# 世界: 单位球缩到 ground_r, 中心 = 行星中心。
	_ocean_mesh.global_transform = Transform3D(Basis().scaled(Vector3.ONE * ground_r), _center())
	_ocean_mesh.visible = p.showOcean


func _apply_ocean_uniforms() -> void:
	if _ocean_mat == null:
		return
	var p := planet.params
	_ocean_mat.set_shader_parameter("u_deep", Vector3(p.oceanDeep.r, p.oceanDeep.g, p.oceanDeep.b))
	_ocean_mat.set_shader_parameter("u_shallow", Vector3(p.oceanShallow.r, p.oceanShallow.g, p.oceanShallow.b))
	_ocean_mat.set_shader_parameter("u_ambient", p.oceanAmbient)
	_ocean_mat.set_shader_parameter("u_spec_power", p.oceanSpecPower)
	_ocean_mat.set_shader_parameter("u_spec_strength", p.oceanSpecStrength)


# ---- 大气 compositor ----
func _build_compositor() -> void:
	if _atmo != null:
		return
	_we = _scan_world_env(get_tree().root)
	if _we == null:
		push_warning("[PlanetAtmosphere] 场景无 WorldEnvironment, 大气不生效")
		return
	var comp: Compositor = _we.compositor
	if comp == null:
		comp = Compositor.new()
		_we.compositor = comp
	# 先剔掉同类残留(@tool 重载留下的、或历史上被序列化进 .tscn 的), 保证场上只有 1 份。
	_purge_atmo_effects(comp)
	_atmo = AtmosphereCompositor.new()
	# 追加到现有 effects(与 GpuPlanet 的 LOD/Hi-Z compositor 共存; 各按 pass 时机触发, 顺序无碍)。
	var effs: Array[CompositorEffect] = comp.compositor_effects.duplicate()
	effs.append(_atmo)
	comp.compositor_effects = effs


# 剔掉 Compositor 上所有本类型的 effect(同 GpuPlanet._purge_planet_effects)。
func _purge_atmo_effects(comp: Compositor) -> void:
	if comp == null:
		return
	var kept: Array[CompositorEffect] = []
	var changed := false
	for e in comp.compositor_effects:
		if e is AtmosphereCompositor:
			changed = true
			continue
		kept.append(e)
	if changed:
		comp.compositor_effects = kept


# 编辑器保存前/后: 摘下 / 挂回动态挂的 effect, 避免它被序列化进 .tscn。
# ocean 壳那侧靠 _ocean_mesh.owner = null 防护, 本来就不入盘。
func _notification(what: int) -> void:
	if what == NOTIFICATION_EDITOR_PRE_SAVE:
		_detach_atmo_effect()
	elif what == NOTIFICATION_EDITOR_POST_SAVE:
		_reattach_atmo_effect()


func _detach_atmo_effect() -> void:
	if not is_inside_tree():
		return
	var we: WorldEnvironment = _scan_world_env(get_tree().root)
	if we == null or we.compositor == null:
		return
	_purge_atmo_effects(we.compositor)


func _reattach_atmo_effect() -> void:
	if _atmo == null or not is_inside_tree():
		return
	var we: WorldEnvironment = _scan_world_env(get_tree().root)
	if we == null or we.compositor == null:
		return
	var comp: Compositor = we.compositor
	var effs: Array[CompositorEffect] = comp.compositor_effects.duplicate()
	if not effs.has(_atmo):
		effs.append(_atmo)
	comp.compositor_effects = effs


# ---- 太阳方向 ----
func _update_sun() -> void:
	var p := planet.params
	if sun_light != null and is_instance_valid(sun_light):
		# DirectionalLight3D: 光沿 -Z 传播 → +Z(basis.z)= 指向太阳, 与 Godot 对地形的光照方向一致。
		_sun_dir = sun_light.global_transform.basis.z.normalized()
	else:
		var el := deg_to_rad(p.sunElevation)
		var az := deg_to_rad(p.sunAzimuth)
		_sun_dir = Vector3(cos(el) * cos(az), sin(el), cos(el) * sin(az)).normalized()
	if _ocean_mat != null:
		_ocean_mat.set_shader_parameter("u_sun_dir", _sun_dir)
		_ocean_mat.set_shader_parameter("u_sun_pos", _center() + _sun_dir * 1.0e9)
		_ocean_mat.set_shader_parameter("u_sun_is_local", 0.0)
		_ocean_mat.set_shader_parameter("u_sun_range", 1.0e9)
		_ocean_mat.set_shader_parameter("u_sun_atten", 0.0)
		_ocean_mat.set_shader_parameter("u_sun_count", 1)


# ---- 每帧推参数给大气 compositor(主线程 → 渲染线程经 Mutex) ----
func _push_frame() -> void:
	if _atmo == null:
		return
	var p := planet.params
	var R: float = p.radius
	var center := _center()
	var ground_r: float = R + p.seaLevel * p.maxHeight
	# --- 自适应壳层几何(随地形/半径缩放, 不再直接吃 cloudBottom×R 这种小比例) ---
	# 地形峰值(maxHeight×1.2 留冗余) → 云底必须高过峰值, 否则云被埋进山里。
	var peak: float = R + p.maxHeight * 1.2
	# 云底: 取 "半径比例" 与 "峰值+四分之一 maxHeight 间隙" 的较大者。
	var cbottom: float = maxf(R * p.cloudBottom, peak + p.maxHeight * 0.25)
	# 云层厚度: 至少 0.8×maxHeight, 保证薄壳半径下云层仍有可见体积。
	var thickness: float = maxf(R * (p.cloudTop - p.cloudBottom), p.maxHeight * 0.8)
	var ctop: float = cbottom + thickness
	# 大气壳: 取 atmoScale×R 与 "云顶+半个 maxHeight" 的较大者, 确保云被包在大气壳内。
	var ratmo: float = maxf(R * p.atmoScale, ctop + p.maxHeight * 0.5)
	# 散射的光学深度 ∝ 系数 × 壳厚(世界单位积分)。壳被地形撑厚后会过度变暗,
	# 用 thick_k 把系数按 "参考壳厚 / 实际壳厚" 收回, 让散射浓度跨半径一致。
	var ref_thick: float = R * maxf(p.atmoScale - 1.0, 0.01)
	var thick_k: float = clampf(ref_thick / maxf(ratmo - ground_r, 1.0), 0.05, 1.0)
	var sun_pos := center + _sun_dir * 1.0e9
	_atmo.enabled = p.showAtmosphere   # 关 = 跳过整条后处理(含云/godray)
	_atmo.set_frame_data({
		"time": Time.get_ticks_msec() / 1000.0,
		"sun_dir": _sun_dir,
		"sun_pos": sun_pos,
		"sun_is_local": 0.0,
		"sun_dirs": [_sun_dir],
		"sun_positions": [sun_pos],
		"sun_is_locals": [0.0],
		"sun_ranges": [1.0e9],
		"sun_attens": [0.0],
		"sun_count": 1,
		"planet_center": center,
		"rground": ground_r,
		"ratmo": ratmo,
		"cbottom": cbottom,
		"ctop": ctop,
		"scatter_r": _RAY_RATIO * p.atmoRayleigh * thick_k,
		"scatter_m": p.atmoMie * thick_k,
		"mie_g": p.atmoMieG,
		"ozone": _OZO_RATIO * p.atmoOzone * thick_k,
		"density_falloff": p.atmoDensityFalloff,
		"mie_falloff": p.atmoMieFalloff,
		"sun_intensity": p.atmoSunIntensity,
		"exposure": p.atmoExposure,
		"render_scale": p.atmoRenderScale,   # 大气/云 pass 分辨率比例(0.5=半分辨率省 ~4x)
		"steps": p.atmoSteps,
		"cloud_steps": p.cloudSteps,
		"light_steps": p.atmoLightSteps,
		"cloud_light_steps": p.cloudLightSteps,
		"dither": p.atmoDither,
		"shadow_softness": p.atmoShadowSoftness,
		"twilight": p.atmoTwilight,
		"clouds_on": 1.0 if p.showClouds else 0.0,
		"coverage": p.cloudCoverage,
		"cdensity": p.cloudDensity,
		"cfreq": p.cloudFreq / R * 100.0,   # 云频率按半径归一(对齐 web)
		"cwarp": p.cloudWarp,
		"cwindspeed": p.cloudWindSpeed,
		"absorb": p.cloudAbsorb,
		"silver": p.cloudSilver,
		"powder": p.cloudPowder,
		"cshadow": p.cloudShadow,
		"cterminator": p.cloudTerminatorShift,
		"godrays_on": 1.0 if p.showGodrays else 0.0,
		"godray_strength": p.godrayStrength,
		"godray_density": p.godrayDensity,
		"godray_samples": p.godraySamples,
		"godray_threshold": p.godrayThreshold,
		"godray_decay": 0.96,
		"godray_weight": 0.6,
	})
