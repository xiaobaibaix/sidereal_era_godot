# gdlint: disable=variable-name, max-line-length
## GPU LOD compositor(Phase 3: traverse + cull)。CompositorEffect 挂 PRE_OPAQUE。
##
## 拥有: 两个 compute pipeline(traverse + cull)、双缓冲 trav/cull 纹理(RD, STORAGE|SAMPLING)、
## 双 counter(storage buffer)、MinMax Texture2DArray(20 layer, 含 mip 链, 1 次烘)、frame UBO
## (uniform buffer, 每帧 buffer_update)、Texture2DRD 包装(绑给 material)、frame 数据。
##
## 1-帧延迟(消除同帧 storage→sampler 竞态): 本帧 compute 写 [write_idx], vertex 读 [read_idx]。
##
## 每帧 dispatch 序列(每个 dispatch 独立 compute_list, barrier 自动分隔 storage 依赖):
##   ─── traverse 阶段(选叶) ───
##   reset trav_counter(level=-1) →
##   [per level 0..maxLevel: dispatch(ceil(20·4^L/64), level=L)] →
##   trav metadata(level=-2): trav_counter → trav_tex META_ROW
##   ─── cull 阶段(视锥裁剪) ───
##   reset cull_counter(mode=-1) →
##   cull dispatch(ceil(MAX_PATCHES/64), mode=0): 读 trav_tex, 采样 MinMax, frustum 测试, 写 cull_tex →
##   cull metadata(mode=-2): cull_counter → cull_tex META_ROW
##
## 相机矩阵/位置由 GpuPlanet._process 主线程算好后 set_frame_data 推。MinMax 烘焙由 GpuPlanet
## 在 setup 时调 set_minmax(data) 推一次(param 变时重烘)。只在渲染线程 _render_callback 里读写 RID。
@tool
class_name GpuLodCompositor
extends CompositorEffect

const TRAVERSE_SHADER_PATH := "res://shaders/planet/lod_traverse.glsl"
const CULL_SHADER_PATH := "res://shaders/planet/lod_cull.glsl"
const LODTEX_SHADER_PATH := "res://shaders/planet/lod_lodtex.glsl"
const MAX_PATCHES := 12288         # 与 shader MAX_PATCHES 一致(PATCH_TEX_H=12289, 留 Metal 单边 16384 上限余量)
const PATCH_TEX_W := 6             # 每 patch 6 texel
const PATCH_TEX_H := MAX_PATCHES + 1   # 末行存 count metadata
const WG := 64                     # workgroup size(与 glsl local_size_x 一致)
const BAKE_RES := 256              # MinMax 烘焙分辨率(2^8=256; maxLevel 6 最细 64 细分/边 → 每 patch ~4 cell, 保守包围盒足够。512 过度精细且烘焙慢 4×)
# FrameData UBO(std140): frustum[6](96) + cam(16) + planet(16) + consts(16)
#   + cull_params(16) + hiz_params(16) + view_proj mat4(64) + view_proj_cur mat4(64) = 304 字节。
# Phase 5 新增: cull_params(地平线/小三角/遮挡开关+参数)、hiz_params(金字塔元数据)、view_proj(遮挡投影)。
# Phase 6 新增: view_proj_cur(本帧矩阵; 与 view_proj 一起做"运动并集"遮挡测试, 消 disocclusion 黑洞)。
const FRAME_UBO_SIZE := 304
const LODTEX_RES := 256            # 4×2^MAX_GPU_LEVEL: 最细叶占~4×4 格, 消除三角/方格走样+query 边界抖动。必须与 lod_lodtex/lod_cull 一致

var _rd: RenderingDevice
var _trav_shader: RID
var _trav_pipeline: RID
var _cull_shader: RID
var _cull_pipeline: RID
var _lodtex_shader: RID
var _lodtex_pipeline: RID
var _material_rid: RID

# 双缓冲(1-帧延迟): idx = _frame & 1 写, 1-idx 读。
var _trav_tex: Array = [RID(), RID()]      # 中间: traverse 输出 → cull 输入
var _trav_counter: Array = [RID(), RID()]  # traverse 的 atomicAdd 计数器
var _cull_tex: Array = [RID(), RID()]      # 终端: cull 输出 → vertex 读(就是 u_patchTex)
var _cull_counter: Array = [RID(), RID()]  # cull 的 atomicAdd 计数器
var _tex2drd: Array = [null, null]         # Texture2DRD 包装(暴露给 GpuPlanet 主线程 set_shader_parameter 绑定)

# LOD lookup texture 双缓冲(Phase 4): cull sample 用, 读上一帧 rasterize 的 lodtex[1-write_idx]
# 等等 —— 实际上 lodtex 每帧重建, 不需要双缓冲。本帧 rasterize 完, cull 同帧读。但 cull 跑在
# PRE_OPAQUE, 主线程 _process 已经把 read cull_tex 绑给 material(那是上一帧 cull 的输出)。
# 本帧的 rasterize/cull 都用本帧 write_idx 的 lodtex(本帧 compute 写, 本帧 compute 读, 同帧)。
# 所以单缓冲就够。但保留双缓冲结构为 future-proof(Phase 4.5 可能跨帧 cache 邻居)。
var _lodtex: Array = [RID(), RID()]        # 20 layer × 64×64 R8UI Texture2DArray, STORAGE 写
var _lodtex_sets: Array = [null, null]     # [write_idx] = [set0_trav_img, set1_lodtex_img]

# Phase 4.5 跨面焊接邻接表: 60 ints(每 (face, edge) 1 个 neighbor_face index)。
# cull 检测到 patch edge 沿 face 边界时, 查这张表得邻居 face, 把 self query 3D 方向投影到
# neighbor face-bary, sample lodtex[neighbor]。
var _adjacency_buf: RID

# MinMax 资源(per-frame 只读; param 变时 set_minmax 重建)
var _minmax_tex: RID
var _minmax_sampler: RID
var _minmax_ready := false

# FrameData UBO(每帧 buffer_update; cull shader set 4 用)
var _frame_ubo: RID

# Phase 5: Hi-Z 遮挡剔除。_hiz_provider = GpuHizCompositor(POST_OPAQUE 建金字塔), 本 compositor
# (PRE_OPAQUE)读它上一帧建好的金字塔纹理。两者都跑渲染线程且同帧内 PRE 先于 POST → 读的是上帧结果。
# 未就绪时 cull set 7 绑 1×1 占位纹理, 靠 UBO hiz_params.w(ready)=0 门控 shader 不采样。
var _hiz_provider: CompositorEffect
var _hiz_dummy_tex: RID           # 1×1 R32F 占位(hiz 未就绪时绑 set 7)
var _hiz_sampler: RID             # NEAREST + clamp, textureLod 显式 mip
var _cur_hiz_set: RID             # 本帧 cull set 7(每帧按当前绑定的 hiz 纹理取缓存)
# 本帧算好的 view_proj(world→clip, 渲染线程从 render_data 取, 保证与深度缓冲 reverse-Z 约定一致)
var _view_proj: Projection = Projection()
# 本帧 world→clip。与 _view_proj(建金字塔那帧)一起做"运动并集"遮挡测试: patch 在两个视点下的屏幕
# 矩形取并集 → 因相机运动而新露出的 patch 不会被上一帧的深度误剔(消 disocclusion 黑洞)。
var _view_proj_cur: Projection = Projection()
var _hiz_info: Dictionary = {}    # {tex, width, height, mips} 或空(未就绪)

# 缓存的 uniform sets(按 RID 经 UniformSetCacheRD 缓存)
var _trav_sets: Array = [null, null]   # [write_idx] = [set0_image, set1_counter]
var _cull_sets: Array = [null, null]   # [write_idx] = [set0..4]

var _cb_count: int = 0   # 调试: _render_callback 被调用次数
var _mutex := Mutex.new()
var _frame_data: Dictionary = {}
var _ready := false

# Phase 6 方案 B: 异步回读的可见 patch 数(-1 = 未就绪 → 主线程降级为不裁剪, 安全)。
# 回调可能在渲染线程触发, 用 _mutex 保护。
var _visible_count: int = -1
var _readback_warned := false


func _init() -> void:
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_OPAQUE
	enabled = true
	_rd = RenderingServer.get_rendering_device()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if _rd == null:
			_rd = RenderingServer.get_rendering_device()
		if _rd == null:
			return   # RenderingDevice 已随引擎/场景先行析构; RID 由其自身回收, 无需(也不能)再 free。
		_ready = false
		# 释放顺序关键(见 Godot issue #103073: free_rid 级联释放关联 RID; UniformSetCacheRD 用
		# uniform_set_set_invalidation_callback 登记失效回调): 先放纹理/缓冲/采样器/UBO(此时引用它们的
		# uniform set 仍在, free 触发的失效回调能干净移除缓存条目), 再放 shader(级联清由该 shader 建的
		# set)。反序(先放 shader)会让后续纹理 free 的失效回调拿到已删的 set → "Parameter us is null" /
		# "not a valid texture" 报错。
		for i in range(2):
			_free_res(_trav_tex[i]); _trav_tex[i] = RID()
			_free_res(_trav_counter[i]); _trav_counter[i] = RID()
			_free_res(_cull_tex[i]); _cull_tex[i] = RID()
			_free_res(_cull_counter[i]); _cull_counter[i] = RID()
			_free_res(_lodtex[i]); _lodtex[i] = RID()
		_free_res(_minmax_tex); _minmax_tex = RID()
		_free_res(_minmax_sampler); _minmax_sampler = RID()
		_free_res(_frame_ubo); _frame_ubo = RID()
		_free_res(_adjacency_buf); _adjacency_buf = RID()
		_free_res(_hiz_dummy_tex); _hiz_dummy_tex = RID()
		_free_res(_hiz_sampler); _hiz_sampler = RID()
		_free_res(_trav_shader); _trav_shader = RID(); _trav_pipeline = RID()
		_free_res(_cull_shader); _cull_shader = RID(); _cull_pipeline = RID()
		_free_res(_lodtex_shader); _lodtex_shader = RID(); _lodtex_pipeline = RID()


static func _free_res(rid: RID) -> void:
	if rid.is_valid():
		RenderingServer.get_rendering_device().free_rid(rid)


# GpuPlanet._ready 调: 编两个 shader + 建双缓冲纹理/counter/UBO/包装。
func setup(material_rid: RID) -> bool:
	_material_rid = material_rid
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		push_error("[GpuLodCompositor] 无 RenderingDevice")
		return false
	if not _compile_traverse():
		return false
	if not _compile_cull():
		return false
	if not _compile_lodtex():
		return false
	for i in range(2):
		if not _trav_tex[i].is_valid():
			_trav_tex[i] = _create_patch_tex()
			_trav_counter[i] = _create_counter()
			_cull_tex[i] = _create_patch_tex()
			_cull_counter[i] = _create_counter()
			_lodtex[i] = _create_lodtex_tex()
			var t := Texture2DRD.new()
			t.texture_rd_rid = _cull_tex[i]   # vertex 读的是 cull 输出
			_tex2drd[i] = t
			_trav_sets[i] = null
			_cull_sets[i] = null
			_lodtex_sets[i] = null
	if not _frame_ubo.is_valid():
		var zeros := PackedByteArray()
		zeros.resize(FRAME_UBO_SIZE)
		_frame_ubo = _rd.uniform_buffer_create(FRAME_UBO_SIZE, zeros)
	if not _adjacency_buf.is_valid():
		_adjacency_buf = _create_adjacency_buf()
	if not _hiz_dummy_tex.is_valid():
		_hiz_dummy_tex = _create_hiz_dummy_tex()
	if not _hiz_sampler.is_valid():
		_hiz_sampler = _create_hiz_sampler()
	_ready = true
	return true


# 1×1 R32F 占位纹理: Hi-Z 未就绪(首帧 / 无 provider)时绑 cull set 7, 靠 UBO hiz_params.w=0 门控不采样。
func _create_hiz_dummy_tex() -> RID:
	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	fmt.width = 1
	fmt.height = 1
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var bytes := PackedByteArray()
	bytes.resize(4)   # 单 float 0.0(reverse-Z 远平面 → 永不遮挡; 但 ready=0 时根本不采)
	return _rd.texture_create(fmt, RDTextureView.new(), [bytes])


# Hi-Z 采样器: NEAREST + clamp, textureLod 显式选 mip(min-pyramid 手动归约, 不能线性插值)。
func _create_hiz_sampler() -> RID:
	var st := RDSamplerState.new()
	st.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	st.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	st.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	st.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	st.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	return _rd.sampler_create(st)


# GpuPlanet 接线: 把 GpuHizCompositor 引用给本 compositor, 供 PRE_OPAQUE 读上帧金字塔。
func set_hiz_provider(provider: CompositorEffect) -> void:
	_hiz_provider = provider


# Phase 4.5: 60 ints, 每 (face*3+edge) → neighbor_face index。从 GpuIco.build_adjacency() 提取。
# 全局只此一份(ico 拓扑固定), setup() 一次创建, cull shader 只读。
func _create_adjacency_buf() -> RID:
	var adj := GpuIco.build_adjacency()
	var lut := PackedInt32Array()
	lut.resize(GpuIco.FACE_COUNT * GpuIco.EDGE_PER_FACE)
	for fi in range(GpuIco.FACE_COUNT):
		for ei in range(GpuIco.EDGE_PER_FACE):
			var entry: Dictionary = adj[fi][ei]
			lut[fi * GpuIco.EDGE_PER_FACE + ei] = int(entry.get("neighbor_face", -1))
	return _rd.storage_buffer_create(lut.size() * 4, lut.to_byte_array())


# GpuPlanet 烘 MinMax 后调一次, 把金字塔上传为 Texture2DArray。param 变 → 重新调。
func set_minmax(data: GpuMinMaxData) -> bool:
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		push_error("[GpuLodCompositor] set_minmax: 无 RenderingDevice")
		return false
	if data.bake_res != BAKE_RES:
		push_error("[GpuLodCompositor] set_minmax: bake_res 不匹配(got %d, expect %d)" % [data.bake_res, BAKE_RES])
		return false
	_free_res(_minmax_tex)
	_minmax_tex = _create_minmax_tex(data)
	if not _minmax_tex.is_valid():
		return false
	if not _minmax_sampler.is_valid():
		var st := RDSamplerState.new()
		st.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		st.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		st.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST   # textureLod 显式 mip; NEAREST 避免跨 mip 插值
		st.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		st.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		_minmax_sampler = _rd.sampler_create(st)
	# 失效缓存的 cull uniform sets(minmax_tex RID 变了)
	_cull_sets[0] = null
	_cull_sets[1] = null
	_minmax_ready = true
	return true


# GpuPlanet._process(主线程)调: 取上一帧写好的 cull 纹理(Texture2DRD)绑给 material。
func get_read_texture(write_idx: int) -> Texture2DRD:
	return _tex2drd[1 - write_idx]


# MinMax 是否就绪(set_minmax 成功后 true)。未就绪时 cull 被跳过, cull_tex 全 0 →
# GpuPlanet 应继续绑 fallback 纹理(否则 shader 读到 count=0 → 坍缩无渲染 → 灰屏)。
func is_minmax_ready() -> bool:
	return _minmax_ready


# ---- Phase 6 方案 B: 可见 patch 数异步回读(消除空 instance 顶点开销) ----
# _render_callback 里发起: 读本帧 cull_counter(atomicAdd 的可见 patch 数)。async → 不 stall GPU,
# RD 在 frame_queue_size 帧后调 _on_visible_count_readback。失败(某后端不支持)→ _visible_count 保持
# -1 → 主线程降级为不裁剪(等价旧行为, 正确无洞)。
func _request_visible_count_readback(write_idx: int) -> void:
	if _rd == null or not _cull_counter[write_idx].is_valid():
		return
	var err: Error = _rd.buffer_get_data_async(_cull_counter[write_idx], _on_visible_count_readback, 0, 4)
	if err != OK and not _readback_warned:
		_readback_warned = true
		push_warning("[GpuLodCompositor] buffer_get_data_async 失败(err=%d); visible_instance_count 降级为不裁剪(无优化但正确)" % err)


# RD 回调(frame_queue_size 帧后, 可能在渲染线程)。存 mutex 保护变量供主线程 get_visible_count 读。
func _on_visible_count_readback(bytes: PackedByteArray) -> void:
	if bytes.size() < 4:
		return
	var c: int = int(bytes.decode_u32(0))
	_mutex.lock()
	_visible_count = c
	_mutex.unlock()


# 主线程(GpuPlanet._process)调: 返回最近回读的可见 patch 数; -1 = 未就绪(主线程应降级不裁剪)。
func get_visible_count() -> int:
	_mutex.lock()
	var c: int = _visible_count
	_mutex.unlock()
	return c


func _compile_traverse() -> bool:
	if _trav_pipeline.is_valid():
		return true
	var sf := load(TRAVERSE_SHADER_PATH) as RDShaderFile
	if sf == null:
		push_error("[GpuLodCompositor] load 失败: " + TRAVERSE_SHADER_PATH)
		return false
	var spirv: RDShaderSPIRV = sf.get_spirv()
	if spirv == null or spirv.compile_error_compute != "":
		push_error("[GpuLodCompositor] traverse 编译错误: " + (spirv.compile_error_compute if spirv != null else "null"))
		return false
	_trav_shader = _rd.shader_create_from_spirv(spirv)
	if not _trav_shader.is_valid():
		return false
	_trav_pipeline = _rd.compute_pipeline_create(_trav_shader)
	return _trav_pipeline.is_valid()


func _compile_cull() -> bool:
	if _cull_pipeline.is_valid():
		return true
	var sf := load(CULL_SHADER_PATH) as RDShaderFile
	if sf == null:
		push_error("[GpuLodCompositor] load 失败: " + CULL_SHADER_PATH)
		return false
	var spirv: RDShaderSPIRV = sf.get_spirv()
	if spirv == null or spirv.compile_error_compute != "":
		push_error("[GpuLodCompositor] cull 编译错误: " + (spirv.compile_error_compute if spirv != null else "null"))
		return false
	_cull_shader = _rd.shader_create_from_spirv(spirv)
	if not _cull_shader.is_valid():
		return false
	_cull_pipeline = _rd.compute_pipeline_create(_cull_shader)
	return _cull_pipeline.is_valid()


func _compile_lodtex() -> bool:
	if _lodtex_pipeline.is_valid():
		return true
	var sf := load(LODTEX_SHADER_PATH) as RDShaderFile
	if sf == null:
		push_error("[GpuLodCompositor] load 失败: " + LODTEX_SHADER_PATH)
		return false
	var spirv: RDShaderSPIRV = sf.get_spirv()
	if spirv == null or spirv.compile_error_compute != "":
		push_error("[GpuLodCompositor] lodtex 编译错误: " + (spirv.compile_error_compute if spirv != null else "null"))
		return false
	_lodtex_shader = _rd.shader_create_from_spirv(spirv)
	if not _lodtex_shader.is_valid():
		return false
	_lodtex_pipeline = _rd.compute_pipeline_create(_lodtex_shader)
	return _lodtex_pipeline.is_valid()


# 6 × (MAX_PATCHES+1) RGBA32F, STORAGE|SAMPLING。零填充(末行 count=0 → 首帧坍缩无渲染, 安全)。
func _create_patch_tex() -> RID:
	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.width = PATCH_TEX_W
	fmt.height = PATCH_TEX_H
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var bytes := PackedByteArray()
	bytes.resize(PATCH_TEX_W * PATCH_TEX_H * 16)   # 全 0
	# 零填充必需: 首帧读 read_idx 未写过 → META_ROW count=0 → 坍缩守卫生效(否则读显存垃圾绕过守卫渲染 NaN)。
	var layers: Array = [bytes]
	return _rd.texture_create(fmt, RDTextureView.new(), layers)


func _create_counter() -> RID:
	var bytes := PackedByteArray()
	bytes.resize(4)   # uint32 = 0
	return _rd.storage_buffer_create(4, bytes)


# Phase 4 LOD lookup texture: 20 layer × LODTEX_RES² R8UI Texture2DArray。
# compute shader(rasterize) 写 → compute shader(cull) 读(都是 STORAGE, 不走 sampler)。
# 零填充(0 表示 "无 owner"; cull 边 query 落到 0 → lodDelta=0 → 不焊; Phase 4.5 加跨面表)。
func _create_lodtex_tex() -> RID:
	var fmt := RDTextureFormat.new()
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	# R8UI = DATA_FORMAT_R8_UINT; Godot 4.7 支持。若某后端不支持, 退 R32_UINT(4× 内存)。
	fmt.format = RenderingDevice.DATA_FORMAT_R8_UINT
	fmt.width = LODTEX_RES
	fmt.height = LODTEX_RES
	fmt.depth = 1
	fmt.array_layers = GpuIco.FACE_COUNT
	fmt.mipmaps = 1
	# STORAGE_BIT: lodtex.glsl 用 imageStore 写; 同时加 SAMPLING_BIT 给未来可能的 debug 可视化。
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	# texture_create 期望 per-layer byte array: 每 layer = width*height*bytes_per_texel = 64*64*1 = 4096 字节。
	# 之前我传了 81920 字节(整个纹理), Godot 会拒绝 → RID 无效 → uniform set 失败 → cull 不写。
	var layers: Array = []
	for i in range(GpuIco.FACE_COUNT):
		var layer := PackedByteArray()
		layer.resize(LODTEX_RES * LODTEX_RES)
		layer.fill(0)
		layers.append(layer)
	var rid := _rd.texture_create(fmt, RDTextureView.new(), layers)
	if not rid.is_valid():
		push_error("[GpuLodCompositor] lodtex texture_create 失败(可能 R8UI storage 不支持, 改 R32_UINT 重试)")
	return rid


# MinMax Texture2DArray(20 layer × bake_res² × R32G32_SFLOAT, 含 mip 链 log2(bake_res)+1 级)。
# per (face, mip) 调 texture_update 写入对应 PackedFloat32Array(从 data.build_pyramid())。
func _create_minmax_tex(data: GpuMinMaxData) -> RID:
	var fmt := RDTextureFormat.new()
	# Godot 4.x 属性名是 array_layers(不是 layers, 改名自旧 API)。
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32_SFLOAT
	fmt.width = data.bake_res
	fmt.height = data.bake_res
	fmt.depth = 1
	fmt.array_layers = GpuIco.FACE_COUNT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	# mip levels: Godot 按位宽自动推导 = floor(log2(max(w,h))) + 1
	# 但 Godot 4.x RDTextureFormat.mipmaps 需显式设
	var nmip: int = 1
	var s: int = data.bake_res
	while s > 1:
		s >>= 1
		nmip += 1
	fmt.mipmaps = nmip
	var tex := _rd.texture_create(fmt, RDTextureView.new(), [])
	if not tex.is_valid():
		push_error("[GpuLodCompositor] texture_create minmax 失败")
		return RID()
	var pyr: Array = data.build_pyramid()
	# Godot 4 texture_update(tex, layer, data): layer = 数组层索引(0..array_layers-1),
	# data 必须是该层**整条 mip 链**拼接后的字节(mip0 + mip1 + ... + mip(nmip-1), 每段按
	# 该 mip 的 width*height*bytes_per_texel)。per face 一次调用, 不是 per mip。
	for fi in range(GpuIco.FACE_COUNT):
		var fmips: Array = pyr[fi]
		var blob := PackedByteArray()
		for mip in range(nmip):
			var arr: PackedFloat32Array = fmips[mip]
			blob.append_array(arr.to_byte_array())
		_rd.texture_update(tex, fi, blob)
	return tex


# 主线程(GpuPlanet._process)每帧调: 推相机/参数/frustum 快照。
func set_frame_data(d: Dictionary) -> void:
	_mutex.lock()
	_frame_data = d
	_mutex.unlock()


func _render_callback(_effect_callback_type: int, render_data: RenderData) -> void:
	_cb_count += 1
	if not _ready or not _trav_pipeline.is_valid() or not _cull_pipeline.is_valid() or not _lodtex_pipeline.is_valid():
		return
	if _effect_callback_type != CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_OPAQUE:
		return
	_mutex.lock()
	var fd: Dictionary = _frame_data
	_mutex.unlock()
	if not fd.has("cam_pos"):
		return

	var write_idx: int = int(fd.get("write_idx", 0))
	var max_level: int = int(fd["maxLevel"])

	# Phase 5: 查 Hi-Z provider(上一帧建好的金字塔); 未就绪 → 空 → 绑占位、ready=0。
	_hiz_info = _query_hiz()
	# 遮挡测试用的 view_proj **必须取自建金字塔那一帧**(provider 随金字塔一起返回), 而不是本帧相机 ——
	# 否则"AABB 投影视点"(本帧)与"被采样的深度视点"(上一帧)不一致, 相机一动就错剔/漏剔, 表现为相邻
	# patch 一个剔一个不剔的碎斑锯齿。用金字塔自带的矩阵 → 投影与深度同一空间, 自洽; 只剩固有的 1 帧
	# 内容延迟。冻结时金字塔停更, 其矩阵也一并定格 → 遮挡结果定格在冻结视角(旁观相机可绕看)。
	var frozen: bool = bool(fd.get("lod_frozen", false))
	if _hiz_info.has("view_proj"):
		_view_proj = _hiz_info["view_proj"]
	elif not frozen:
		_view_proj = _compute_view_proj(render_data)   # 无 provider 时的兜底(遮挡实际也不会跑)
	# 本帧矩阵(运动并集用)。冻结时**不能**取 render_data —— 那时渲染相机是旁观相机(甚至画中画相机),
	# 会把无关视点并进测试。冻结时令 cur = 金字塔矩阵 → 并集退化为单视点 → 遮挡结果定格在冻结视角。
	if frozen:
		_view_proj_cur = _view_proj
	else:
		_view_proj_cur = _compute_view_proj(render_data)

	# 每帧更新 FrameData UBO(frustum + cam + planet + consts + Phase5 剔除参数)
	_update_frame_ubo(fd)

	# 确保 uniform sets 缓存(首帧或 minmax 变后建)
	_ensure_trav_sets(write_idx)
	_ensure_lodtex_sets(write_idx)
	if _minmax_ready:
		_ensure_cull_sets(write_idx)
		_cur_hiz_set = _make_hiz_set()   # set 7: 每帧按当前 hiz 纹理取(UniformSetCacheRD 去重)

	# === Traverse 阶段 ===
	var pcn: Vector3 = fd["planet_center"]
	var cam: Vector3 = fd["cam_pos"]
	var pc_base := PackedFloat32Array([
		cam.x, cam.y, cam.z, float(fd["radius"]),
		pcn.x, pcn.y, pcn.z, float(fd["maxHeight"]),
		float(fd["C_const"]), float(max_level), 0.0, float(MAX_PATCHES),
	])
	_dispatch_traverse(write_idx, pc_base, -1.0, 1)                       # reset trav_counter
	for lvl in range(max_level + 1):                                     # per-level 遍历
		_dispatch_traverse(write_idx, pc_base, float(lvl), _groups_for_level(lvl))
	_dispatch_traverse(write_idx, pc_base, -2.0, 1)                       # trav metadata: count → trav_tex META_ROW

	# === LOD lookup texture 阶段(Phase 4): 每帧 reset + rasterize → cull 同帧读 ===
	_dispatch_lodtex(write_idx, -1, _lodtex_reset_groups())                # reset: 清零 81920 cells
	_dispatch_lodtex(write_idx, 0, _cull_groups())                         # rasterize: 每 trav slot 1 thread

	# === Cull 阶段(minmax 就绪才跑; 否则 cull_tex 保持上帧内容/全 0 → 坍缩无渲染) ===
	if _minmax_ready:
		# cull push constant: mode(0=cull, -1=reset, -2=metadata)
		_dispatch_cull(write_idx, -1, 1)                # reset cull_counter
		_dispatch_cull(write_idx, 0, _cull_groups())     # cull dispatch
		_dispatch_cull(write_idx, -2, 1)                # cull metadata: count → cull_tex META_ROW
		# Phase 6 方案 B: 异步回读本帧可见 patch 数(延迟 frame_queue_size 帧, 不 stall GPU) →
		# 主线程据此设 MultiMesh.visible_instance_count, 砍掉空 instance 的顶点 shader 开销。
		# 冻结时也回读: visible_instance_count 在冻结下固定 MAX_PATCHES(不受此值影响), 但 HUD 的
		# "可见 patch" 需要实时值 —— 这样可以冻结不动、只按 F3 开关遮挡, 直接看剔除到底省了多少 patch。
		_request_visible_count_readback(write_idx)


# 把 frame_data 打包进 _frame_ubo(std140, 144 字节)。
func _update_frame_ubo(fd: Dictionary) -> void:
	var floats := PackedFloat32Array()
	@warning_ignore("integer_division")
	floats.resize(FRAME_UBO_SIZE / 4)   # 304 字节 / 4 = 76 floats(view_proj 44..59, view_proj_cur 60..75)
	# frustum[6]: Godot Camera3D.get_frustum() 返回**外向法线** N(指向视锥外),
	# Godot Plane 存 d = dot(N, p_on_plane), 平面方程 dot(N,P)=d。
	# 外向 N 下: 视锥内 dot(N,P) < d, 视锥外 dot(N,P) > d。
	# 但 lod_cull.glsl 的 P-vertex 测试 (dot+plane.w<0 = 外侧) 是按**内向法线**设计的
	# (P-vertex 选 max-dot 方向的角点; 内向 N 下这是"最易出外侧"的角点)。
	# → 打包时翻 N → 内向: vec4(-N.xyz, +d)。同一几何平面, 内向 N'=−N 时 d'=−d;
	# shader plane.w = -d' = +d。详见 cull_selftest.gd (A)(验证内向 + vec4(N,-d) + 测 <0 这套约定)。
	var frustum: Array = fd.get("frustum", [])
	# 视锥外扩余量(世界单位): 内向法线约定下, plane.w += margin 把平面沿外向法线外推 margin →
	# 视锥整体放大一圈。补偿剔除 1 帧延迟(相机快速运动时保住边缘刚进视野的 patch)。
	var fmargin: float = float(fd.get("frustumMargin", 0.0))
	for i in range(6):
		if i < frustum.size():
			var p: Plane = frustum[i]
			floats[i * 4 + 0] = -p.normal.x   # 翻 N: 外向 → 内向
			floats[i * 4 + 1] = -p.normal.y
			floats[i * 4 + 2] = -p.normal.z
			floats[i * 4 + 3] = p.d + fmargin  # = -d_inward + 外扩余量(沿外向法线放大视锥)
		else:
			floats[i * 4 + 0] = 0.0
			floats[i * 4 + 1] = 0.0
			floats[i * 4 + 2] = 0.0
			floats[i * 4 + 3] = 0.0
	# cam_pos_pad: xyz=cam_pos, w=radius
	var cam: Vector3 = fd["cam_pos"]
	floats[24] = cam.x
	floats[25] = cam.y
	floats[26] = cam.z
	floats[27] = float(fd["radius"])
	# planet_center_pad: xyz=center, w=maxHeight
	var pcn: Vector3 = fd["planet_center"]
	floats[28] = pcn.x
	floats[29] = pcn.y
	floats[30] = pcn.z
	floats[31] = float(fd["maxHeight"])
	# consts: x=bake_res_log2, y=maxLevel, z=K_sse, w=MAX_PATCHES
	floats[32] = log(float(BAKE_RES)) / log(2.0)   # bake_res_log2(自然 log 换底)
	floats[33] = float(int(fd["maxLevel"]))
	floats[34] = float(fd.get("K", 0.0))           # K = vp_h/(2·tan(fov/2)); 小三角剔除的像素投影用
	floats[35] = float(MAX_PATCHES)
	# Phase 5 cull_params: x=horizonEnable, y=horizonOccluderRadius, z=smallTriPixels, w=occlusionEnable
	floats[36] = 1.0 if bool(fd.get("horizonCulling", false)) else 0.0
	floats[37] = float(fd.get("horizonOccluderRadius", float(fd["radius"])))
	floats[38] = float(fd.get("smallTriPixels", 0.0))
	# 遮挡开关: 需 provider 开 + 本帧金字塔就绪(hiz_ready)才真正跑; enable 仅表用户意愿。
	floats[39] = 1.0 if bool(fd.get("occlusionCulling", false)) else 0.0
	# Phase 5 hiz_params: x=hiz_w, y=hiz_h, z=hiz_mip_count, w=hiz_ready
	if not _hiz_info.is_empty():
		floats[40] = float(_hiz_info.get("width", 1))
		floats[41] = float(_hiz_info.get("height", 1))
		floats[42] = float(_hiz_info.get("mips", 1))
		floats[43] = 1.0
	else:
		floats[40] = 1.0
		floats[41] = 1.0
		floats[42] = 1.0
		floats[43] = 0.0   # 未就绪 → shader 不采样
	# Phase 5 view_proj: mat4 列主序(4 列 × xyzw), 与 shader mat4 * vec4 一致。
	var vp := _view_proj
	var cols := [vp.x, vp.y, vp.z, vp.w]
	for ci in range(4):
		var col: Vector4 = cols[ci]
		floats[44 + ci * 4 + 0] = col.x
		floats[44 + ci * 4 + 1] = col.y
		floats[44 + ci * 4 + 2] = col.z
		floats[44 + ci * 4 + 3] = col.w
	# Phase 6 view_proj_cur: 本帧矩阵(运动并集遮挡测试)。紧随 view_proj, 偏移 60 floats。
	var vpc := _view_proj_cur
	var cols_c := [vpc.x, vpc.y, vpc.z, vpc.w]
	for ci in range(4):
		var col_c: Vector4 = cols_c[ci]
		floats[60 + ci * 4 + 0] = col_c.x
		floats[60 + ci * 4 + 1] = col_c.y
		floats[60 + ci * 4 + 2] = col_c.z
		floats[60 + ci * 4 + 3] = col_c.w
	_rd.buffer_update(_frame_ubo, 0, FRAME_UBO_SIZE, floats.to_byte_array())


# 渲染线程从 render_data 取 world→clip(= proj · view)。view = cam_transform.affine_inverse()。
# 与 atmosphere_compositor 的 world_to_clip 同款(那边 godray 用), 保证与深度缓冲 reverse-Z 一致。
func _compute_view_proj(render_data: RenderData) -> Projection:
	if render_data == null:
		return Projection()
	var rsd = render_data.get_render_scene_data()
	if rsd == null:
		return Projection()
	var cam_xform: Transform3D = rsd.get_cam_transform()
	var proj: Projection = rsd.get_cam_projection()
	return proj * Projection(cam_xform.affine_inverse())


# 查 Hi-Z provider(GpuHizCompositor)上一帧建好的金字塔。就绪返回 {tex,width,height,mips}, 否则空。
func _query_hiz() -> Dictionary:
	if _hiz_provider == null or not _hiz_provider.has_method("get_hiz"):
		return {}
	var info: Dictionary = _hiz_provider.call("get_hiz")
	if info.is_empty() or not info.has("tex"):
		return {}
	var tex: RID = info["tex"]
	if not tex.is_valid():
		return {}
	return info


# 建 cull set 7(Hi-Z 采样): 就绪绑真金字塔, 否则绑 1×1 占位。UniformSetCacheRD 按内容去重。
func _make_hiz_set() -> RID:
	var tex: RID = _hiz_dummy_tex
	if not _hiz_info.is_empty():
		tex = _hiz_info["tex"]
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.binding = 0
	u.add_id(_hiz_sampler)
	u.add_id(tex)
	return UniformSetCacheRD.get_cache(_cull_shader, 7, [u])


# 缓存 traverse uniform sets(per write_idx)
func _ensure_trav_sets(write_idx: int) -> void:
	if _trav_sets[write_idx] != null:
		return
	var u_img := RDUniform.new()
	u_img.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_img.binding = 0
	u_img.add_id(_trav_tex[write_idx])
	var u_ctr := RDUniform.new()
	u_ctr.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_ctr.binding = 0
	u_ctr.add_id(_trav_counter[write_idx])
	var s0 := UniformSetCacheRD.get_cache(_trav_shader, 0, [u_img])
	var s1 := UniformSetCacheRD.get_cache(_trav_shader, 1, [u_ctr])
	_trav_sets[write_idx] = [s0, s1]


# 缓存 cull uniform sets(per write_idx); minmax_tex 变时强制重建。
func _ensure_cull_sets(write_idx: int) -> void:
	if _cull_sets[write_idx] != null:
		return
	var u_trav := RDUniform.new()
	u_trav.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_trav.binding = 0
	u_trav.add_id(_trav_tex[write_idx])
	var u_cull := RDUniform.new()
	u_cull.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_cull.binding = 0
	u_cull.add_id(_cull_tex[write_idx])
	var u_mm := RDUniform.new()
	u_mm.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_mm.binding = 0
	u_mm.add_id(_minmax_sampler)
	u_mm.add_id(_minmax_tex)
	var u_ctr := RDUniform.new()
	u_ctr.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_ctr.binding = 0
	u_ctr.add_id(_cull_counter[write_idx])
	var u_ubo := RDUniform.new()
	u_ubo.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	u_ubo.binding = 0
	u_ubo.add_id(_frame_ubo)
	# Phase 4: set 5 = lodtex(同 write_idx 的 LOD lookup texture, 本帧 rasterize 写, 本帧 cull 读)
	var u_lod := RDUniform.new()
	u_lod.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_lod.binding = 0
	u_lod.add_id(_lodtex[write_idx])
	# Phase 4.5: set 6 = adjacency buffer(60 ints, 全局共享, cull 跨面 query 用)
	var u_adj := RDUniform.new()
	u_adj.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_adj.binding = 0
	u_adj.add_id(_adjacency_buf)
	var s0 := UniformSetCacheRD.get_cache(_cull_shader, 0, [u_trav])
	var s1 := UniformSetCacheRD.get_cache(_cull_shader, 1, [u_cull])
	var s2 := UniformSetCacheRD.get_cache(_cull_shader, 2, [u_mm])
	var s3 := UniformSetCacheRD.get_cache(_cull_shader, 3, [u_ctr])
	var s4 := UniformSetCacheRD.get_cache(_cull_shader, 4, [u_ubo])
	var s5 := UniformSetCacheRD.get_cache(_cull_shader, 5, [u_lod])
	var s6 := UniformSetCacheRD.get_cache(_cull_shader, 6, [u_adj])
	_cull_sets[write_idx] = [s0, s1, s2, s3, s4, s5, s6]


func _dispatch_traverse(write_idx: int, pc_base: PackedFloat32Array, level: float, groups: int) -> void:
	pc_base[10] = level   # consts.z = level
	var sets: Array = _trav_sets[write_idx]
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _trav_pipeline)
	_rd.compute_list_bind_uniform_set(cl, sets[0], 0)
	_rd.compute_list_bind_uniform_set(cl, sets[1], 1)
	_rd.compute_list_set_push_constant(cl, pc_base.to_byte_array(), pc_base.size() * 4)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_end()


func _dispatch_cull(write_idx: int, mode: int, groups: int) -> void:
	var pc := PackedInt32Array([mode, 0, 0, 0])   # mode + 3 pad int(16 字节)
	var sets: Array = _cull_sets[write_idx]
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _cull_pipeline)
	_rd.compute_list_bind_uniform_set(cl, sets[0], 0)
	_rd.compute_list_bind_uniform_set(cl, sets[1], 1)
	_rd.compute_list_bind_uniform_set(cl, sets[2], 2)
	_rd.compute_list_bind_uniform_set(cl, sets[3], 3)
	_rd.compute_list_bind_uniform_set(cl, sets[4], 4)
	_rd.compute_list_bind_uniform_set(cl, sets[5], 5)   # Phase 4: lodtex
	_rd.compute_list_bind_uniform_set(cl, sets[6], 6)   # Phase 4.5: adjacency
	if _cur_hiz_set.is_valid():
		_rd.compute_list_bind_uniform_set(cl, _cur_hiz_set, 7)   # Phase 5: Hi-Z(占位或真金字塔)
	_rd.compute_list_set_push_constant(cl, pc.to_byte_array(), pc.size() * 4)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_end()


# 缓存 lodtex uniform sets(per write_idx)。set0 = trav_tex(image), set1 = lodtex(image array)。
func _ensure_lodtex_sets(write_idx: int) -> void:
	if _lodtex_sets[write_idx] != null:
		return
	var u_trav := RDUniform.new()
	u_trav.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_trav.binding = 0
	u_trav.add_id(_trav_tex[write_idx])
	var u_lod := RDUniform.new()
	u_lod.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_lod.binding = 0
	u_lod.add_id(_lodtex[write_idx])
	var s0 := UniformSetCacheRD.get_cache(_lodtex_shader, 0, [u_trav])
	var s1 := UniformSetCacheRD.get_cache(_lodtex_shader, 1, [u_lod])
	_lodtex_sets[write_idx] = [s0, s1]


# mode=-1: reset 清零 lodtex(20×64×64=81920 cells, 1280 workgroup 各清 1 cell)
# mode=0:  rasterize —— 每 trav_tex slot(叶)一个 thread, 写三角形覆盖的 cell
func _dispatch_lodtex(write_idx: int, mode: int, groups: int) -> void:
	var pc := PackedInt32Array([mode, 0, 0, 0])
	var sets: Array = _lodtex_sets[write_idx]
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _lodtex_pipeline)
	_rd.compute_list_bind_uniform_set(cl, sets[0], 0)
	_rd.compute_list_bind_uniform_set(cl, sets[1], 1)
	_rd.compute_list_set_push_constant(cl, pc.to_byte_array(), pc.size() * 4)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_end()


# reset 组数: 20 face × 64×64 = 81920 cells / 64 = 1280 workgroup
func _lodtex_reset_groups() -> int:
	@warning_ignore("integer_division")
	return (GpuIco.FACE_COUNT * LODTEX_RES * LODTEX_RES + WG - 1) / WG


static func _groups_for_level(level: int) -> int:
	var nodes := 20
	for i in range(level):
		nodes *= 4
	@warning_ignore("integer_division")
	return (nodes - 1) / WG + 1


static func _cull_groups() -> int:
	@warning_ignore("integer_division")
	return (MAX_PATCHES - 1) / WG + 1
