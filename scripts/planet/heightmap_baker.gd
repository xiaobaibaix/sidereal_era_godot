# gdlint: disable=variable-name, max-line-length
## MinMax 高度图烘焙器(Phase 0; Phase 3 v2 = cell 布局; v3 = 归一化 + cell 内超采样)。
##
## 把 Terrain.height_at(与 shaders/planet/terrain_gpu.gdshader 逐位一致的程序化噪声)在 20 个
## icosahedron 面上按 cell 采样, 烘成 GpuMinMaxData(mip0 per face, bake_res² cells)。混合路: 位移仍走
## 实时噪声, 这张 MinMax 只供 GPU LOD 的裁剪 —— patch 径向包围盒(视锥 / Hi-Z / 地平线)与解析射线
## 遮挡的地形下界。**不参与 LOD 层级选择**(那走 lod_traverse 的距离壳, 不碰 MinMax)。
##
## Cell 布局:
##   cell (i, j) 覆盖 face-bary 区域 u ∈ [i/res, (i+1)/res], v ∈ [j/res, (j+1)/res]
##   cell **中心**在三角形内 ⟺ (i+j+1)/res ≤ 1 ⟺ i + j < bake_res
##     ← 有效性判据, 必须与 GpuMinMaxData / lod_cull.glsl 的 cell 归属约定逐字一致
##   三角形外的 cell 存哨兵, 归约时跳过(详见 GpuMinMaxData)
##
## mip0 = **cell 区域的真实极值**(SUPERSAMPLE² 超采样), 不是 cell 中心的单点值。
## 为什么必须超采样: 单点采样时 min = max, 包围盒退化成一个点, 不包夹 cell 内的地形起伏 —— 归约上去
## 的每一级 mip 的 max 都偏小、min 都偏大, 而 lod_cull.glsl 构 AABB 时不加任何余量 → 视锥/遮挡剔除
## 有削掉伸出包围盒的山尖的风险。Unity 原版的 mip0 是高度贴图的 texel(**完备数据**, min=max 准确),
## 这里 mip0 是对程序化噪声的有限采样, 语义不同, 包夹性得自己保证。
##
## 数值单位: **归一化**(height_at 原始输出, 不乘 maxHeight)。消费侧缩放, 详见 GpuMinMaxData。
##
## dir(u, v) = normalize(A·(1-u-v) + B·u + C·v),  A/B/C = GpuIco.face_corners(fi)(单位球)
class_name HeightmapBaker
extends RefCounted

## 每 cell 每轴的采样点数(共 SUPERSAMPLE² 点/cell)。偏移含 0 与 1 两端 → 相邻 cell 在共享边上重复
## 采样, 换来严格包夹(cell 角点处的地形也进极值)。设 1 则退化成中心单点采样(不推荐, 见上文)。
## 4 是成本/质量的平衡点: bake_res=64 时总计约 65 万次 height_at(约一半 cell 在三角形外被跳过),
## 与旧的 bake_res=256 单点采样等量, 但只产出真正会被 shader 采样的那几级 mip。
const SUPERSAMPLE: int = 4


# 建空壳 data: 元数据齐全, face_mip0 已 resize 到 20 面但每面为 null。
# 面级并行的调度方先调它(主线程), 再把各面交给 worker 写 data.face_mip0[fi] —— 数组容量在主线程
# 一次性定好, worker 只写既有索引、互不重叠, 因此无需加锁。
static func new_data(params: PlanetParams, bake_res: int) -> GpuMinMaxData:
	assert(GpuMinMaxData.is_valid_res(bake_res), "bake_res 必须是 2 的幂, got %d" % bake_res)
	var data := GpuMinMaxData.new()
	data.bake_res = bake_res
	data.radius = params.radius
	data.max_height = params.maxHeight
	data.seed_hash = compute_seed_hash(params)
	data.face_mip0.resize(GpuIco.FACE_COUNT)
	return data


# 烘单个面的 mip0。纯函数(只读 terrain, 不碰 data/场景树/RD)→ 20 面可并发。
static func bake_face(terrain: Terrain, bake_res: int, fi: int) -> PackedFloat32Array:
	var corners: Array = GpuIco.face_corners(fi)
	var A: Vector3 = corners[0]
	var B: Vector3 = corners[1]
	var C: Vector3 = corners[2]
	var arr := PackedFloat32Array()
	arr.resize(bake_res * bake_res * 2)
	var inv_res: float = 1.0 / float(bake_res)
	# cell 内采样偏移(格点值 ∈ [0, 1], 含两端)。预算掉, 免得在最内层循环里反复算。
	var offs := PackedFloat32Array()
	offs.resize(SUPERSAMPLE)
	if SUPERSAMPLE <= 1:
		offs[0] = 0.5
	else:
		for a in range(SUPERSAMPLE):
			offs[a] = float(a) / float(SUPERSAMPLE - 1)
	for j in range(bake_res):
		for i in range(bake_res):
			var dst: int = (j * bake_res + i) * 2
			# cell 中心 u + v = (i + j + 1)/res; > 1 ⟺ i + j ≥ res → cell 在三角形外
			if i + j >= bake_res:
				arr[dst] = GpuMinMaxData.MIN_SENTINEL
				arr[dst + 1] = GpuMinMaxData.MAX_SENTINEL
				continue
			var hmin: float = INF
			var hmax: float = -INF
			for sj in range(SUPERSAMPLE):
				var v: float = (float(j) + offs[sj]) * inv_res
				for si in range(SUPERSAMPLE):
					var u: float = (float(i) + offs[si]) * inv_res
					# 斜边上的 cell 会有采样点落到 u+v > 1(最多 1 + 1/res), 即 bary 外推到邻面一小片:
					# w = 1-u-v 只是个小负数 → 方向偏移极小, 采到的高度并入极值 → 包围盒略微保守。
					# 保守是安全方向(宁可漏剔不误剔), 故不做裁剪。
					var dir: Vector3 = (A * (1.0 - u - v) + B * u + C * v).normalized()
					var h: float = terrain.height_at(dir.x, dir.y, dir.z)
					hmin = minf(hmin, h)
					hmax = maxf(hmax, h)
			arr[dst] = hmin
			arr[dst + 1] = hmax
	return arr


# 串行烘全 20 面(编辑器工具 / 交叉验证用; 运行时走 GpuPlanet 的面级并行路径)。返回未存盘的 data。
static func bake(params: PlanetParams, bake_res: int = 64) -> GpuMinMaxData:
	var data := new_data(params, bake_res)
	var terrain := Terrain.from_params(params)
	for fi in range(GpuIco.FACE_COUNT):
		data.face_mip0[fi] = bake_face(terrain, bake_res, fi)
	data.invalidate_pyramid()
	return data


# 面 fi 的 (u, v) → 单位方向(球面)。烘焙与自检共用, 保证一致。
# 注: 此函数对任意 (u, v) 都给出方向, 不要求 u, v 在三角形内; 三角形外的 (u, v) 仍能算出方向
# (bary 外推, w 变负 → 方向朝邻面偏移)。
static func dir_from_bary(fi: int, u: float, v: float) -> Vector3:
	var corners: Array = GpuIco.face_corners(fi)
	var A: Vector3 = corners[0]
	var B: Vector3 = corners[1]
	var C: Vector3 = corners[2]
	var w: float = 1.0 - u - v
	return (A * w + B * u + C * v).normalized()


# 种子 hash(决定缓存命中): 只取影响 height_at 的参数 + baker 版本。参数变 → 重烘;
# baker 算法变 → BAKER_VERSION 变 → 缓存自动失效。
# 用 Godot 内置 String.hash()(稳定、跨平台)。
#
# 刻意**不含** radius 与 maxHeight —— 烘出来的是归一化的 height_at, 与两者都无关:
#   radius   : 只影响世界坐标缩放, 消费侧现算;
#   maxHeight: 只是个线性缩放, 消费侧(lod_cull.glsl 的 fd.planet_center_pad.w /
#              GpuPlanet 的 params.maxHeight)乘上去。
# 早先两者都在 hash 里, 于是拖一次半径或高度滑条就白烘一遍 20 面(百万级噪声采样)并多存一个 .res。
# 移出后, 改半径 / 改高度都即刻命中缓存。
static func compute_seed_hash(params: PlanetParams) -> int:
	var keys := PackedStringArray([
		"bv",   # baker version, 前置使旧缓存自动失效
		"continentSeed", "continentFreq", "continentOctaves", "continentGain", "continentLacunarity",
		"mountainSeed", "mountainFreq", "mountainOctaves", "mountainStrength",
		"warpSeed", "warpStrength", "warpFreq",
		"plateSeed", "plateFreq", "plateStrength",
	])
	var parts := PackedStringArray()
	for k in keys:
		if k == "bv":
			parts.append("%s=%s" % [k, GpuMinMaxData.BAKER_VERSION])
		else:
			parts.append("%s=%s" % [k, str(params.get(k))])
	return "|".join(parts).hash()


# 默认存盘路径(按 seed hash + 分辨率)。
static func default_path(seed_hash: int, bake_res: int) -> String:
	return "res://data/planet_minmax_%08x_r%d.res" % [seed_hash & 0xFFFFFFFF, bake_res]


# 存/取 .res(命中则直接 load, 否则串行 bake + 存盘并返回)。
# 注: 会**阻塞**调用线程烘完 20 面。运行时请走 GpuPlanet 的并行 + 轮询路径, 这里供工具/测试用。
static func bake_or_load(params: PlanetParams, bake_res: int = 64) -> GpuMinMaxData:
	var sh: int = compute_seed_hash(params)
	var path := default_path(sh, bake_res)
	var cached: Resource = load(path) if ResourceLoader.exists(path) else null
	if cached != null and cached is GpuMinMaxData:
		return cached as GpuMinMaxData
	var data := bake(params, bake_res)
	var dir_path := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)
	var err := ResourceSaver.save(data, path)
	if err != OK:
		push_warning("[HeightmapBaker] 存盘失败 %s: %d" % [path, err])
	return data
