# gdlint: disable=variable-name, max-line-length
## Phase 5: Hi-Z 深度金字塔 compositor(遮挡剔除用)。CompositorEffect 挂 POST_OPAQUE。
##
## 每帧(不透明几何已写深度后):
##   1. hiz_copy.glsl: 场景深度(reverse-Z) → 自有 R32F 金字塔 mip0(同尺寸)。
##   2. hiz_reduce.glsl: 逐级 2×2 取 min(reverse-Z 最远 = 保守) → mip1..mipN。
##
## 金字塔纹理(STORAGE|SAMPLING, 带 mip 链)持久化跨帧; GpuLodCompositor 在 PRE_OPAQUE 读**上一帧**
## 建好的金字塔(1 帧延迟, 见设计文档 §3.4/§7.4)采样做 AABB 遮挡测试。
##
## 与 GpuLodCompositor 的接线: GpuPlanet 建两者, 调 lod_comp.set_hiz_provider(self)。lod_comp 每帧
## 调 self.get_hiz() 拿金字塔 RID + 元数据。两者同渲染线程、同帧内 PRE 先于 POST → 读到的是上帧结果。
##
## _active(由 GpuPlanet 按 params.occlusionCulling 推): false → 跳过建金字塔 + get_hiz 返回空
## → cull 侧 hiz_ready=0 → 不做遮挡剔除(零开销)。
@tool
class_name GpuHizCompositor
extends CompositorEffect

const COPY_SHADER_PATH := "res://shaders/planet/hiz_copy.glsl"
const REDUCE_SHADER_PATH := "res://shaders/planet/hiz_reduce.glsl"
const WG := 8   # local_size_x/y

var _rd: RenderingDevice
var _copy_shader: RID
var _copy_pipeline: RID
var _reduce_shader: RID
var _reduce_pipeline: RID
var _depth_sampler: RID

# 金字塔: 单张 R32F 纹理(mip 链) + per-mip slice view(STORAGE image, 供 compute 读写)。
var _pyr_tex: RID
var _mip_views: Array = []       # [k] = mip k 的 slice view RID
var _size: Vector2i = Vector2i.ZERO
var _mip_count: int = 0
var _ready := false              # 至少建成一次金字塔(get_hiz 才返回有效)

var _mutex := Mutex.new()
var _active := true              # 主线程按 params.occlusionCulling 推


func _init() -> void:
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_OPAQUE
	enabled = true
	_rd = RenderingServer.get_rendering_device()


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	# 用缓存的 _rd(镜像 atmosphere_compositor 的稳妥写法); 引擎/场景关闭时 RD 可能已析构。
	if _rd == null:
		return
	# 全部 inline 释放, 不调用任何实例方法(如 _free_pyramid): PREDELETE 时本实例正在析构, 调用自身
	# 脚本方法会报 "Attempt to call function '_free_pyramid' ... on a null instance"(报错栈里的
	# gpu_hiz_compositor.gd:60 @ _free_pyramid 即此), 随后纹理/uniform_set 的连锁报错都是它的余波。
	# atmosphere_compositor 全程 inline + _rd.free_rid + is_valid 守卫, 稳妥无报错, 这里照搬。
	# 先放 mip slice view(texture_create_shared_from_slice 建的关联 RID), 再放父纹理 _pyr_tex。
	for v in _mip_views:
		if v.is_valid():
			_rd.free_rid(v)
	_mip_views = []
	if _pyr_tex.is_valid():
		_rd.free_rid(_pyr_tex)
	_pyr_tex = RID()
	_size = Vector2i.ZERO
	_mip_count = 0
	_ready = false
	if _depth_sampler.is_valid():
		_rd.free_rid(_depth_sampler)
	_depth_sampler = RID()
	if _copy_shader.is_valid():
		_rd.free_rid(_copy_shader)   # 连带释放 pipeline(RD 做依赖追踪)
	_copy_shader = RID()
	_copy_pipeline = RID()
	if _reduce_shader.is_valid():
		_rd.free_rid(_reduce_shader)
	_reduce_shader = RID()
	_reduce_pipeline = RID()


static func _free_res(rid: RID) -> void:
	if rid.is_valid():
		RenderingServer.get_rendering_device().free_rid(rid)


func _free_pyramid() -> void:
	for v in _mip_views:
		_free_res(v)
	_mip_views = []
	_free_res(_pyr_tex)
	_pyr_tex = RID()
	_size = Vector2i.ZERO
	_mip_count = 0
	_ready = false


# 主线程按 params.occlusionCulling 推。false → 本 compositor 空跑。
func set_active(a: bool) -> void:
	_mutex.lock()
	_active = a
	_mutex.unlock()


# GpuLodCompositor(PRE_OPAQUE)调: 返回上一帧建好的金字塔。就绪 → {tex,width,height,mips}, 否则空。
func get_hiz() -> Dictionary:
	if not _ready or not _pyr_tex.is_valid():
		return {}
	return {"tex": _pyr_tex, "width": _size.x, "height": _size.y, "mips": _mip_count}


func _compile() -> bool:
	if _copy_pipeline.is_valid() and _reduce_pipeline.is_valid():
		return true
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		return false
	if not _copy_pipeline.is_valid():
		var a := _compile_one(COPY_SHADER_PATH)
		_copy_shader = a[0]
		_copy_pipeline = a[1]
	if not _reduce_pipeline.is_valid():
		var b := _compile_one(REDUCE_SHADER_PATH)
		_reduce_shader = b[0]
		_reduce_pipeline = b[1]
	return _copy_pipeline.is_valid() and _reduce_pipeline.is_valid()


func _compile_one(path: String) -> Array:
	var sf := load(path) as RDShaderFile
	if sf == null:
		push_error("[GpuHizCompositor] load 失败: " + path)
		return [RID(), RID()]
	var spirv: RDShaderSPIRV = sf.get_spirv()
	if spirv == null or spirv.compile_error_compute != "":
		push_error("[GpuHizCompositor] 编译错误(%s): %s" % [path, spirv.compile_error_compute if spirv != null else "null"])
		return [RID(), RID()]
	var sh := _rd.shader_create_from_spirv(spirv)
	if not sh.is_valid():
		return [RID(), RID()]
	return [sh, _rd.compute_pipeline_create(sh)]


func _ensure_depth_sampler() -> RID:
	if _depth_sampler.is_valid():
		return _depth_sampler
	var st := RDSamplerState.new()
	st.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	st.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	_depth_sampler = _rd.sampler_create(st)
	return _depth_sampler


# 建金字塔纹理 + per-mip slice view。size 变时重建。
func _ensure_pyramid(size: Vector2i) -> bool:
	if _pyr_tex.is_valid() and _size == size:
		return true
	_free_pyramid()
	if size.x <= 0 or size.y <= 0:
		return false
	var mips := 1
	var d: int = maxi(size.x, size.y)
	while d > 1:
		d >>= 1
		mips += 1
	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	fmt.width = size.x
	fmt.height = size.y
	fmt.depth = 1
	fmt.array_layers = 1
	fmt.mipmaps = mips
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var tex := _rd.texture_create(fmt, RDTextureView.new(), [])
	if not tex.is_valid():
		push_error("[GpuHizCompositor] 金字塔 texture_create 失败")
		return false
	_pyr_tex = tex
	_mip_views = []
	for k in range(mips):
		var view := _rd.texture_create_shared_from_slice(
			RDTextureView.new(), _pyr_tex, 0, k, 1, RenderingDevice.TEXTURE_SLICE_2D)
		if not view.is_valid():
			push_error("[GpuHizCompositor] mip %d slice view 建失败" % k)
			_free_pyramid()
			return false
		_mip_views.append(view)
	_size = size
	_mip_count = mips
	return true


static func _mip_size(base: int, k: int) -> int:
	return maxi(1, base >> k)


func _render_callback(_effect_callback_type: int, render_data: RenderData) -> void:
	if _effect_callback_type != CompositorEffect.EFFECT_CALLBACK_TYPE_POST_OPAQUE:
		return
	if _rd == null:
		return
	_mutex.lock()
	var active := _active
	_mutex.unlock()
	if not active:
		return   # 遮挡剔除关 → 不建金字塔(零开销)
	if not _compile():
		return
	if render_data == null:
		return
	var rsb = render_data.get_render_scene_buffers()
	if rsb == null:
		return
	var size: Vector2i = rsb.get_internal_size()
	if size.x == 0 or size.y == 0:
		return
	var depth: RID = rsb.get_depth_layer(0)
	if not depth.is_valid():
		return
	if not _ensure_pyramid(size):
		return

	# 1) copy: 深度 → mip0
	var u_depth := RDUniform.new()
	u_depth.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_depth.binding = 0
	u_depth.add_id(_ensure_depth_sampler())
	u_depth.add_id(depth)
	var u_dst0 := RDUniform.new()
	u_dst0.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_dst0.binding = 0
	u_dst0.add_id(_mip_views[0])
	var cset0 := UniformSetCacheRD.get_cache(_copy_shader, 0, [u_depth])
	var cset1 := UniformSetCacheRD.get_cache(_copy_shader, 1, [u_dst0])
	var cpush := PackedInt32Array([size.x, size.y, 0, 0])
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _copy_pipeline)
	_rd.compute_list_bind_uniform_set(cl, cset0, 0)
	_rd.compute_list_bind_uniform_set(cl, cset1, 1)
	_rd.compute_list_set_push_constant(cl, cpush.to_byte_array(), cpush.size() * 4)
	@warning_ignore("integer_division")
	_rd.compute_list_dispatch(cl, (size.x - 1) / WG + 1, (size.y - 1) / WG + 1, 1)
	_rd.compute_list_end()

	# 2) reduce: mip k = min(mip k-1 的 2×2)。每级独立 compute_list → 自动 barrier 隔离。
	for k in range(1, _mip_count):
		var sw: int = _mip_size(size.x, k - 1)
		var sh: int = _mip_size(size.y, k - 1)
		var dw: int = _mip_size(size.x, k)
		var dh: int = _mip_size(size.y, k)
		var u_src := RDUniform.new()
		u_src.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u_src.binding = 0
		u_src.add_id(_mip_views[k - 1])
		var u_dst := RDUniform.new()
		u_dst.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u_dst.binding = 0
		u_dst.add_id(_mip_views[k])
		var rset0 := UniformSetCacheRD.get_cache(_reduce_shader, 0, [u_src])
		var rset1 := UniformSetCacheRD.get_cache(_reduce_shader, 1, [u_dst])
		var rpush := PackedInt32Array([dw, dh, sw, sh])
		var rl := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(rl, _reduce_pipeline)
		_rd.compute_list_bind_uniform_set(rl, rset0, 0)
		_rd.compute_list_bind_uniform_set(rl, rset1, 1)
		_rd.compute_list_set_push_constant(rl, rpush.to_byte_array(), rpush.size() * 4)
		@warning_ignore("integer_division")
		_rd.compute_list_dispatch(rl, (dw - 1) / WG + 1, (dh - 1) / WG + 1, 1)
		_rd.compute_list_end()

	_ready = true
