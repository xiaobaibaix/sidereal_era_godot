# gdlint: disable=variable-name, max-line-length
## MinMax 高度图烘焙器(Phase 0, Phase 3 v2 重构为 cell 布局)。
##
## 把 Terrain.height_at(与 shaders/terrain.gdshader 逐位一致的程序化噪声)在 20 个 icosahedron 面上
## 按 cell 中心采样, 烘成 GpuMinMaxData(mip0 per face, bake_res² cells)。混合路: 位移仍走实时噪声,
## 这张 MinMax 只供 GPU LOD/裁剪的 patch 包围盒(径向 min/max 高度)。
##
## Cell 布局(Phase 3 v2):
##   cell (i, j) 中心位于 face-bary (u, v) = ((i+0.5)/bake_res, (j+0.5)/bake_res)
##   cell 在三角形内 ⟺ u + v ≤ 1 ⟺ i + j ≤ bake_res - 1
##   三角形外的 cell 存哨兵, 归约时跳过(详见 GpuMinMaxData)。
##
## dir(u, v) = normalize(A·(1-u-v) + B·u + C·v),  A/B/C = GpuIco.face_corners(fi)(单位球)
## disp(u, v) = Terrain.height_at(dir) × maxHeight   [世界单位]
class_name HeightmapBaker
extends RefCounted


# 烘焙。bake_res 必须 2 的幂(见 GpuMinMaxData.is_valid_res)。返回 GpuMinMaxData(未存盘)。
static func bake(params: PlanetParams, bake_res: int = 1024) -> GpuMinMaxData:
	assert(GpuMinMaxData.is_valid_res(bake_res), "bake_res 必须是 2 的幂, got %d" % bake_res)
	var terrain := Terrain.from_params(params)
	var data := GpuMinMaxData.new()
	data.bake_res = bake_res
	data.radius = params.radius
	data.max_height = params.maxHeight
	data.seed_hash = compute_seed_hash(params)
	for fi in range(GpuIco.FACE_COUNT):
		var corners: Array = GpuIco.face_corners(fi)
		var A: Vector3 = corners[0]
		var B: Vector3 = corners[1]
		var C: Vector3 = corners[2]
		var arr := PackedFloat32Array()
		arr.resize(bake_res * bake_res * 2)
		for j in range(bake_res):
			var v: float = (float(j) + 0.5) / float(bake_res)
			for i in range(bake_res):
				var dst: int = (j * bake_res + i) * 2
				# cell 中心 u + v = (i + j + 1) / bake_res; > 1 时 cell 在三角形外
				if i + j >= bake_res:
					# 无效 cell: 哨兵
					arr[dst] = GpuMinMaxData.MIN_SENTINEL
					arr[dst + 1] = GpuMinMaxData.MAX_SENTINEL
					continue
				var u: float = (float(i) + 0.5) / float(bake_res)
				var w: float = 1.0 - u - v
				var dir: Vector3 = (A * w + B * u + C * v).normalized()
				var disp: float = terrain.height_at(dir.x, dir.y, dir.z) * params.maxHeight
				arr[dst] = disp
				arr[dst + 1] = disp   # mip0 单点采样 → min=max=disp
		data.set_face_mip0(fi, arr)
	return data


# 面 fi 的 (u, v) → 单位方向(球面)。烘焙与自检共用, 保证一致。
# 注: 此函数对任意 (u, v) 都给出方向, 不要求 u, v 在三角形内; 三角形外的 (u, v) 仍能算出方向
# (但意义不大, face 边界外)。baker 只对三角形内的 cell 中心调它。
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
# 注意 **不含 radius**: 烘出来的是 disp = height_at(dir) × maxHeight, 而 height_at 只取决于噪声参数,
# 与 radius 无关 → 同一套噪声在任何半径下烘出的数据逐位相同。以前把 radius 算进 hash, 导致每换一个
# 半径就白白重烘一次(20×bake_res² ≈ 百万级噪声采样)并多存一个 .res 文件。去掉后换半径即刻命中缓存。
static func compute_seed_hash(params: PlanetParams) -> int:
	var keys := PackedStringArray([
		"bv",   # baker version, 前置使旧缓存自动失效
		"maxHeight",
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


# 默认存盘路径(按 seed hash)。
static func default_path(seed_hash: int, bake_res: int) -> String:
	return "res://data/planet_minmax_%08x_r%d.res" % [seed_hash & 0xFFFFFFFF, bake_res]


# 存/取 .res(命中则直接 load, 否则 bake+bake_res 存盘并返回)。
static func bake_or_load(params: PlanetParams, bake_res: int = 1024) -> GpuMinMaxData:
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
