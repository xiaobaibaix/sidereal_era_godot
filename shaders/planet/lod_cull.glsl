#[compute]

// GPU LOD 视锥裁剪(Phase 3 v2)。读 lod_traverse 写好的候选 patch, 用 MinMax 纹理构径向 AABB,
// 做 6-平面视锥裁剪, 通过的原子紧凑发射到 cull_tex(供下一帧 vertex shader 读)。
//
// 输入: trav_tex(lod_traverse 写好的 patch 纹理, 含末行 META_ROW count)
// 输出: cull_tex(同布局, 仅含通过裁剪的 patch), 末行 META_ROW 由 metadata 模式写
// MinMax: per-face Texture2DArray 层, R32G32_SFLOAT = (min, max) 径向位移(世界单位)
//
// 每个 invocation 处理一个候选 slot(thread_id ≥ count 直接 return)。
// 流程:
//   1. 读 trav_tex[slot] → A/B/C/face/level + bary
//   2. bary_center = (ua+ub+uc)/3, (va+vb+vc)/3
//   3. mip_k = bake_res_log2 - level(clamp [0, bake_res_log2])
//   4. textureLod(minmax_tex, vec3(bary_center, face), mip_k) → (minH, maxH)
//   5. 构 6 点 AABB: 3 角点 × {minH, maxH} 径向位移
//   6. 6-plane 视锥测试(Godot 约定: normal 内向; AABB P-vertex 任一平面 < 0 → 全外 → cull)
//   7. 通过 → atomicAdd(cull_counter) 取槽, 复制 5 texel 到 cull_tex, texel5 写 (minH, maxH, 0, 0)
//
// push constant 与 lod_traverse 同基底(48B), frustum 走 UBO 避免超 128B 限制。

#version 450
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba32f) uniform readonly image2D trav_tex;
layout(set = 1, binding = 0, rgba32f) uniform writeonly image2D cull_tex;
layout(set = 2, binding = 0) uniform sampler2DArray minmax_tex;
layout(set = 3, binding = 0, std430) buffer CountBuf { uint count; } cull_counter;
layout(set = 4, binding = 0, std140) uniform FrameData {
	vec4 frustum[6];            // 6 视锥平面方程 = (nx,ny,nz,d), normal 内向, dot(n,p)+d>=0 表示内侧
	vec4 cam_pos_pad;           // xyz=cam_pos(world), w=radius
	vec4 planet_center_pad;     // xyz=planet_center(world), w=maxHeight
	vec4 consts;                // x=bake_res_log2, y=maxLevel, z=K_sse(=vp_h/(2·tan(fov/2))), w=MAX_PATCHES
	// Phase 5 剔除参数:
	vec4 cull_params;           // x=horizonEnable, y=horizonOccluderRadius, z=smallTriPixels, w=occlusionEnable
	vec4 hiz_params;            // x=hiz_w(mip0), y=hiz_h(mip0), z=hiz_mip_count, w=hiz_ready
	mat4 view_proj;             // 建 Hi-Z 那一帧的 world→clip(= 金字塔内容所在空间; reverse-Z near→1)
	mat4 view_proj_cur;         // 本帧 world→clip(把 patch 的当前屏幕位置并入测试 → 消 disocclusion 黑洞)
} fd;
// Phase 4: LOD lookup texture, 20 face × 64×64 R8UI。每 cell 存覆盖它的叶的 level。
// 边 query 点 = mid + (1/64) * normalize(mid - 对角 bary) 外推 1 cell(详见 lodtex_selftest.gd)。
layout(set = 5, binding = 0, r8ui) readonly uniform uimage2DArray lodtex;
// Phase 4.5: 邻接表 60 ints, [face*3+edge] = neighbor_face index。OOB query 时跨面 sample 用。
layout(set = 6, binding = 0, std430) readonly buffer AdjBuf { int neighbor_face[60]; } adjacency;
// Phase 5: Hi-Z 深度金字塔(上一帧 POST_OPAQUE 归约, reverse-Z min pyramid)。遮挡剔除采样。
// 未就绪时绑 1×1 占位, 靠 fd.hiz_params.w(ready) 门控不采样。
layout(set = 7, binding = 0) uniform sampler2D hiz_tex;

// Phase 4.5: RAW_VERTS + FACES(与 lod_traverse.glsl 逐位一致), 用来构邻居 face 3 角点方向。
const float PHI = 1.6180339887498948482;
const vec3 RAW_VERTS[12] = vec3[12](
	vec3(-1.0, PHI, 0.0), vec3(1.0, PHI, 0.0), vec3(-1.0, -PHI, 0.0), vec3(1.0, -PHI, 0.0),
	vec3(0.0, -1.0, PHI), vec3(0.0, 1.0, PHI), vec3(0.0, -1.0, -PHI), vec3(0.0, 1.0, -PHI),
	vec3(PHI, 0.0, -1.0), vec3(PHI, 0.0, 1.0), vec3(-PHI, 0.0, -1.0), vec3(-PHI, 0.0, 1.0)
);
const int FACES[60] = int[60](
	0, 11, 5,  0, 5, 1,  0, 1, 7,  0, 7, 10, 0, 10, 11,
	1, 5, 9,  5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
	3, 9, 4,  3, 4, 2,  3, 2, 6,  3, 6, 8,  3, 8, 9,
	4, 9, 5,  2, 4, 11, 6, 2, 10, 8, 6, 7,  9, 8, 1
);
const int FACE_COUNT = 20;

layout(push_constant, std430) uniform Push {
	int mode;        // 0 = cull, -1 = reset counter, -2 = metadata(count → META_ROW)
	int _p0;
	int _p1;
	int _p2;
} pc;

const int MAX_PATCHES = 12288;
const int META_ROW = MAX_PATCHES;

// Phase 4: lodtex 面内采样。OOB(u<0||v<0||u+v>1) → 返回 -1(哨兵, 让调用方走跨面路径)。
int _sample_lodtex_inface(int face, vec2 uv) {
	if (uv.x < 0.0 || uv.y < 0.0 || uv.x + uv.y > 1.0) return -1;
	int ci = clamp(int(floor(uv.x * 256.0)), 0, 255);
	int cj = clamp(int(floor(uv.y * 256.0)), 0, 255);
	return int(imageLoad(lodtex, ivec3(ci, cj, face)).x);
}

// Phase 4.5: lodtex 跨面采样。从 self patch edge midpoint 3D 方向出发, 沿"指向 neighbor face
// center"方向走一小步, 投影到 neighbor face-bary 平面, sample lodtex[neighbor]。
// 关键: 不能用 bary uv OOB 外推 → 3D, 因为 normalize 会让 q3 离开 face plane, 落到别处。
// 必须直接在 3D 算"指向邻居"的方向。
// A/B/C 是 self patch 3 角点方向(单位球)。self_edge: 0=AB, 1=BC, 2=CA。
int _sample_lodtex_cross(int self_face, int self_edge, vec3 A, vec3 B, vec3 C) {
	int nf = adjacency.neighbor_face[self_face * 3 + self_edge];
	if (nf < 0) return 0;
	// self edge midpoint 3D 方向(落在共享的二十面体棱上)
	vec3 mid_3d;
	if (self_edge == 0) mid_3d = normalize(A + B);
	else if (self_edge == 1) mid_3d = normalize(B + C);
	else mid_3d = normalize(C + A);
	vec3 A_n = normalize(RAW_VERTS[FACES[nf * 3]]);
	vec3 B_n = normalize(RAW_VERTS[FACES[nf * 3 + 1]]);
	vec3 C_n = normalize(RAW_VERTS[FACES[nf * 3 + 2]]);
	// 直接把 mid_3d 投影到 nf 的 face-bary 平面: 解 mid_3d-A_n = u*(B_n-A_n) + v*(C_n-A_n)。
	// mid_3d 就在 nf 的共享边上, 细 patch 边弧极小 → 投影落在该边上、误差可忽略。
	vec3 ABn = B_n - A_n;
	vec3 ACn = C_n - A_n;
	vec3 AQn = mid_3d - A_n;
	float a11 = dot(ABn, ABn);
	float a12 = dot(ABn, ACn);
	float a22 = dot(ACn, ACn);
	float b1 = dot(AQn, ABn);
	float b2 = dot(AQn, ACn);
	float det = a11 * a22 - a12 * a12;
	if (abs(det) < 1e-10) return 0;
	float u_n = (a22 * b1 - a12 * b2) / det;
	float v_n = (a11 * b2 - a12 * b1) / det;
	// 在 nf 的 bary 空间朝质心迈 2 格(与面内 eps_uv 同尺度、与 level 无关)→ 稳稳落进"紧邻"的
	// 跨面邻居 cell。取代原 eps_3d=0.1 固定 3D 步: 那个 ≈5.7° 步长对 ≈1° 的细 patch 会跨过好几个
	// patch、采到远处错误 LOD → 沿二十面体棱(非细分边界)产生假接缝。
	vec2 q = vec2(u_n, v_n);
	vec2 to_centroid = vec2(1.0 / 3.0, 1.0 / 3.0) - q;
	q += (2.0 / 256.0) * normalize(to_centroid + vec2(1e-8));
	if (q.x < 0.0 || q.y < 0.0 || q.x + q.y > 1.0) return 0;
	int ci = clamp(int(floor(q.x * 256.0)), 0, 255);
	int cj = clamp(int(floor(q.y * 256.0)), 0, 255);
	return int(imageLoad(lodtex, ivec3(ci, cj, nf)).x);
}

// 综合: OOB → 跨面(用 3D 方向算 query), 否则面内(用 bary query)。
int _sample_lodtex_smart(int face, int edge, vec2 uv, vec3 A, vec3 B, vec3 C) {
	int inface = _sample_lodtex_inface(face, uv);
	if (inface >= 0) return inface;
	return _sample_lodtex_cross(face, edge, A, B, C);
}

// ---- Phase 5: 地平线剔除 ----
// occluder = 以 planet_center 为心、Rocc 为半径的球(Rocc = radius + 全局最小径向位移 →
// 保证内含于实心行星, 不会误剔可见 patch)。判定单点 P 是否被该球挡在背面:
// Cesium isScaledSpacePointVisible 移植(缩放到单位球空间)。
//   csp  = (cam - center) / Rocc                       (相机的缩放空间坐标)
//   vhSq = dot(csp, csp) - 1                            (相机在球外 → >0; 在球内 → <0, 全可见)
//   vt   = P/Rocc(相对 center) - csp                    (相机指向 P 的缩放向量)
//   vtDotVc = -dot(vt, csp)
//   occluded = vhSq<0 ? false : (vtDotVc > vhSq && vtDotVc² / dot(vt,vt) > vhSq)
bool _point_below_horizon(vec3 P, vec3 center, float Rocc, vec3 csp, float vhSq) {
	if (vhSq < 0.0) {
		return false;   // 相机在 occluder 球内 → 不做地平线剔除(全可见)
	}
	vec3 vt = (P - center) / Rocc - csp;
	float vtDotVc = -dot(vt, csp);
	if (vtDotVc <= vhSq) {
		return false;
	}
	return (vtDotVc * vtDotVc) / max(dot(vt, vt), 1e-20) > vhSq;
}

// ---- Phase 5: Hi-Z 遮挡剔除 ----
// 把 patch 的 12 个代表点投影到屏幕, 取屏幕矩形 + 最近点深度(reverse-Z 最大 z), 选合适 mip,
// 采矩形 4 角的 Hi-Z(min = 该区域最远的最近面), 若 patch 最近点仍比它更远 → 全被挡 → cull。
// 跨近平面(clip.w<=0)时投影不可靠 → 保守返回 false(不剔)。
//
// 【为什么传 12 个实际点, 而不是世界 AABB 的 8 角】patch 是球面上一个**倾斜的三角壳**; 压成世界轴
// 对齐 AABB 会大幅膨胀(斜薄片外套正方盒), 盒子的最近角点会戳到遮挡它的山丘**前面** → 判"没被完全
// 挡住" → 漏剔。patch 越粗(远处低 LOD)盒子越夸张, 漏剔越明显(实测: 远处被山挡住的海洋 patch 剔不掉)。
// 改投影 patch 自身的 12 点(3 角点 + 3 边中点, 各取 minH/maxH 位移): 边中点覆盖球面三角的鼓出, 仍
// 完整包住 patch(保守、不误剔), 但比世界 AABB 紧得多 → 该剔的能剔掉。
bool _occluded_hiz(vec3 pts[12]) {
	vec2 uv_min = vec2(1.0e9);
	vec2 uv_max = vec2(-1.0e9);
	float z_near = -1.0e9;   // reverse-Z: 最近点 = 最大 z
	for (int i = 0; i < 12; i++) {
		vec3 p = pts[i];
		// 【运动并集测试 —— 消 disocclusion 黑洞】两个视点各投一次:
		//   fd.view_proj     = 建金字塔那一帧(= 深度所在空间, 决定"当时哪儿被挡")
		//   fd.view_proj_cur = 本帧(= patch 现在出现在屏幕哪儿)
		// 取屏幕矩形【并集】+ 两者中【更近】的 z。若 patch 因相机转动/靠近而移到"上一帧没有遮挡物"的
		// 屏幕区域, 并集就会覆盖那里 → Hi-Z 取 min 后变得很远 → 判定不成立 → 不剔 → 无黑洞。
		// 关键性质: 矩形取并集只会让 hz 更小、z_near 取更近只会让阈值更难满足 → 相比单视点【严格更
		// 保守】。因此本策略只可能【减少】黑洞, 数学上不可能引入新的黑洞。
		vec4 c0 = fd.view_proj * vec4(p, 1.0);
		vec4 c1 = fd.view_proj_cur * vec4(p, 1.0);
		if (c0.w <= 1.0e-6 || c1.w <= 1.0e-6) {
			return false;   // 任一视点下跨近平面/在相机后 → 投影不可靠, 保守不剔
		}
		vec3 n0 = c0.xyz / c0.w;
		vec3 n1 = c1.xyz / c1.w;
		vec2 uv0 = n0.xy * 0.5 + 0.5;
		vec2 uv1 = n1.xy * 0.5 + 0.5;
		uv_min = min(uv_min, min(uv0, uv1));
		uv_max = max(uv_max, max(uv0, uv1));
		z_near = max(z_near, max(n0.z, n1.z));
	}
	// 夹到屏幕 [0,1]; 完全出屏交给 frustum, 这里不重复剔。
	uv_min = clamp(uv_min, vec2(0.0), vec2(1.0));
	uv_max = clamp(uv_max, vec2(0.0), vec2(1.0));
	// 选 mip: 让屏幕矩形跨度 ≤ ~2 texel, 4 角采样即可覆盖。
	float w_px = (uv_max.x - uv_min.x) * fd.hiz_params.x;
	float h_px = (uv_max.y - uv_min.y) * fd.hiz_params.y;
	float mip = ceil(log2(max(max(w_px, h_px), 1.0)));
	mip = clamp(mip, 0.0, fd.hiz_params.z - 1.0);
	// reverse-Z: 取 min = 该屏幕区域内"最远的最近面"(保守)。
	float hz = textureLod(hiz_tex, vec2(uv_min.x, uv_min.y), mip).r;
	hz = min(hz, textureLod(hiz_tex, vec2(uv_max.x, uv_min.y), mip).r);
	hz = min(hz, textureLod(hiz_tex, vec2(uv_min.x, uv_max.y), mip).r);
	hz = min(hz, textureLod(hiz_tex, vec2(uv_max.x, uv_max.y), mip).r);
	// AABB 最近点(z_near) 仍比最远 occluder(hz) 更远 → 整个 AABB 被挡。
	return z_near < hz;
}

// ---- Phase 6 方案 B: 解析式地形射线遮挡(根除 disocclusion 黑洞) ----
// 与 Hi-Z 的本质区别: **只用当前帧相机 + 静态烘焙高度场, 不用任何跨帧数据** → 构造上不存在
// "用上一帧深度决定这一帧可见性"的问题 → 不产生 disocclusion 黑洞。
//
// 判据: 沿"相机 → patch 点"线段步进, 查该处地形的**最小**高度 minH(烘焙 MinMax 的 R 通道)。
// 若线段在某处的半径 < radius + minH, 则线段位于该处地形的**下界之下** → 地形【确定】挡住 → 可剔。
// 用 minH(下界)而非 maxH 是保守性的关键: 实际地形 ≥ minH, 所以"低于 minH"必然被挡, 不会误剔。

// 球面方向 d → 所属 ico 面 + face-bary。找到返回 face index 并写 uv; 找不到返回 -1。
int _dir_to_face_bary(vec3 d, out vec2 uv) {
	for (int f = 0; f < FACE_COUNT; f++) {
		vec3 A = normalize(RAW_VERTS[FACES[f * 3]]);
		vec3 B = normalize(RAW_VERTS[FACES[f * 3 + 1]]);
		vec3 C = normalize(RAW_VERTS[FACES[f * 3 + 2]]);
		// 球面三角内测试(与绕序无关): 三个大圆平面的符号一致即在内部。
		float s0 = dot(d, cross(A, B));
		float s1 = dot(d, cross(B, C));
		float s2 = dot(d, cross(C, A));
		bool inside = (s0 >= -1e-6 && s1 >= -1e-6 && s2 >= -1e-6)
			|| (s0 <= 1e-6 && s1 <= 1e-6 && s2 <= 1e-6);
		if (!inside) {
			continue;
		}
		// 精确投影: 射线 origin→d 与平面 ABC 的交点, 再在平面内解 bary(比直接用 d 解更准)。
		vec3 n = cross(B - A, C - A);
		float dn = dot(d, n);
		if (abs(dn) < 1e-12) {
			continue;
		}
		vec3 P = d * (dot(A, n) / dn);
		vec3 AB = B - A;
		vec3 AC = C - A;
		vec3 AP = P - A;
		float a11 = dot(AB, AB);
		float a12 = dot(AB, AC);
		float a22 = dot(AC, AC);
		float b1 = dot(AP, AB);
		float b2 = dot(AP, AC);
		float det = a11 * a22 - a12 * a12;
		if (abs(det) < 1e-12) {
			continue;
		}
		uv = vec2((a22 * b1 - a12 * b2) / det, (a11 * b2 - a12 * b1) / det);
		return f;
	}
	uv = vec2(0.0);
	return -1;
}

// 线段 cam→P 是否被地形确定挡住。mip 越粗 → minH 越小 → 越难判定被挡 → 越保守(宁可漏剔不误剔)。
bool _blocked_by_terrain(vec3 P, vec3 cam, vec3 center, float radius, float mip) {
	const int STEPS = 16;
	for (int i = 1; i < STEPS; i++) {
		vec3 S = mix(cam, P, float(i) / float(STEPS));
		vec3 rel = S - center;
		float r_S = length(rel);
		if (r_S < 1e-4) {
			continue;
		}
		vec2 uv;
		int f = _dir_to_face_bary(rel / r_S, uv);
		if (f < 0 || uv.x < 0.0 || uv.y < 0.0 || uv.x + uv.y > 1.0) {
			continue;   // 落在面外(数值边界) → 跳过, 不判被挡(保守)
		}
		float minH = textureLod(minmax_tex, vec3(uv, float(f)), mip).r;
		if (r_S < radius + minH) {
			return true;   // 线段低于该处地形下界 → 确定被挡
		}
	}
	return false;
}

void main() {
	// ---- 特殊模式: reset / metadata(单线程, 与 lod_traverse 同模式) ----
	if (pc.mode < 0) {
		if (gl_GlobalInvocationID.x == 0u) {
			if (pc.mode == -1) {
				cull_counter.count = 0u;
			} else if (pc.mode == -2) {
				float c = float(cull_counter.count);
				imageStore(cull_tex, ivec2(0, META_ROW), vec4(c, 0.0, 0.0, 0.0));
			}
		}
		return;
	}

	uint slot = gl_GlobalInvocationID.x;
	if (slot >= uint(MAX_PATCHES)) {
		return;
	}
	// 读候选数(末行 META_ROW)。读一次, 跨过 count 后的线程全部早退。
	float patch_cnt_f = imageLoad(trav_tex, ivec2(0, META_ROW)).x;
	int patch_cnt = int(patch_cnt_f);
	if (int(slot) >= patch_cnt) {
		return;
	}

	vec4 t0 = imageLoad(trav_tex, ivec2(0, int(slot)));
	vec4 t1 = imageLoad(trav_tex, ivec2(1, int(slot)));
	vec4 t2 = imageLoad(trav_tex, ivec2(2, int(slot)));
	vec4 t3 = imageLoad(trav_tex, ivec2(3, int(slot)));
	vec4 t4 = imageLoad(trav_tex, ivec2(4, int(slot)));

	vec3 A = t0.xyz;
	vec3 B = t1.xyz;
	vec3 C = t2.xyz;
	int face = int(t0.w);
	int level = int(t1.w);
	vec2 A_bary = t3.xy;
	vec2 B_bary = t3.zw;
	vec2 C_bary = t4.xy;
	vec2 bary_center = (A_bary + B_bary + C_bary) * (1.0 / 3.0);

	// ---- 采样 MinMax: mip = bake_res_log2 - level(size-matched) ----
	int bake_res_log2 = int(fd.consts.x);
	int mip = clamp(bake_res_log2 - level, 0, bake_res_log2);
	vec2 minmax = textureLod(minmax_tex, vec3(bary_center, float(face)), float(mip)).rg;
	float minH = minmax.x;
	float maxH = minmax.y;
	// 哨兵(三角形外的 cell, 不应发生但守卫): 不裁剪这一槽, 视为通过(让 vertex 处理)
	bool sentinel = (minH > 1.0e20) || (maxH < -1.0e20);

	// ---- 6 点 AABB: 3 角点 × {minH, maxH} 径向位移 ----
	vec3 center = fd.planet_center_pad.xyz;
	float radius = fd.cam_pos_pad.w;
	vec3 A_min = center + A * (radius + minH);
	vec3 A_max = center + A * (radius + maxH);
	vec3 B_min = center + B * (radius + minH);
	vec3 B_max = center + B * (radius + maxH);
	vec3 C_min = center + C * (radius + minH);
	vec3 C_max = center + C * (radius + maxH);
	vec3 box_min = min(min(A_min, A_max), min(min(B_min, B_max), min(C_min, C_max)));
	vec3 box_max = max(max(A_min, A_max), max(max(B_min, B_max), max(C_min, C_max)));

	// ---- 6-plane 视锥测试(Godot 法线内向: dot(n,P-vertex)+d<0 任一平面 → 全外 → cull) ----
	bool culled = false;
	if (!sentinel) {
		for (int i = 0; i < 6; i++) {
			vec4 plane = fd.frustum[i];
			vec3 p_vert;
			p_vert.x = plane.x > 0.0 ? box_max.x : box_min.x;
			p_vert.y = plane.y > 0.0 ? box_max.y : box_min.y;
			p_vert.z = plane.z > 0.0 ? box_max.z : box_min.z;
			if (dot(plane.xyz, p_vert) + plane.w < 0.0) {
				culled = true;
				break;
			}
		}
	}
	if (culled) {
		return;
	}

	// ---- Phase 5: 地平线剔除(3 角点 + 3 边中点, 都在 radius+maxH 的最高面; 全被行星本体挡 → cull) ----
	// 用 patch 自身的 maxH(而非全局 maxHeight)→ 背面低地形更易剔; 测 6 点(角+边中)避免边中鼓出漏剔。
	if (!sentinel && fd.cull_params.x > 0.5) {
		float Rocc = fd.cull_params.y;
		vec3 csp = (fd.cam_pos_pad.xyz - center) / Rocc;
		float vhSq = dot(csp, csp) - 1.0;
		vec3 AB = normalize(A + B);
		vec3 BC = normalize(B + C);
		vec3 CA = normalize(C + A);
		float rmax = radius + maxH;
		if (_point_below_horizon(center + A * rmax, center, Rocc, csp, vhSq)
				&& _point_below_horizon(center + B * rmax, center, Rocc, csp, vhSq)
				&& _point_below_horizon(center + C * rmax, center, Rocc, csp, vhSq)
				&& _point_below_horizon(center + AB * rmax, center, Rocc, csp, vhSq)
				&& _point_below_horizon(center + BC * rmax, center, Rocc, csp, vhSq)
				&& _point_below_horizon(center + CA * rmax, center, Rocc, csp, vhSq)) {
			return;
		}
	}

	// ---- Phase 5: 小三角剔除(patch 最长边投影像素跨度 < 阈 → cull) ----
	// proj_px = edge_world × K / dist; edge_world 用 radius+maxH 处的角点(过估 → 保守, 不误剔)。
	if (fd.cull_params.z > 0.0) {
		float edge = max(max(distance(A_max, B_max), distance(B_max, C_max)), distance(C_max, A_max));
		vec3 pc_w = (A_max + B_max + C_max) * (1.0 / 3.0);
		float dist_c = distance(fd.cam_pos_pad.xyz, pc_w);
		float proj_px = edge * fd.consts.z / max(dist_c, 1.0e-3);
		if (proj_px < fd.cull_params.z) {
			return;
		}
	}

	// ---- 遮挡剔除。cull_params.w = 模式: 0=关, 1=Hi-Z(屏幕空间, 有 1 帧延迟), 2=解析地形射线(无延迟) ----
	if (!sentinel && fd.cull_params.w > 0.5) {
		vec3 mAB = normalize(A + B);
		vec3 mBC = normalize(B + C);
		vec3 mCA = normalize(C + A);
		float r_lo = radius + minH;
		float r_hi = radius + maxH;
		if (fd.cull_params.w < 1.5) {
			// 模式 1: Hi-Z。用 patch 自身 12 点(不是世界 AABB 的 8 角, 见 _occluded_hiz 注释):
			// 3 角点 + 3 边中点(球面三角的鼓出处), 各取 minH/maxH → 完整包住 patch 但远比 AABB 紧。
			if (fd.hiz_params.w > 0.5) {
				vec3 pts[12];
				pts[0] = A_min;  pts[1] = A_max;
				pts[2] = B_min;  pts[3] = B_max;
				pts[4] = C_min;  pts[5] = C_max;
				pts[6] = center + mAB * r_lo;  pts[7] = center + mAB * r_hi;
				pts[8] = center + mBC * r_lo;  pts[9] = center + mBC * r_hi;
				pts[10] = center + mCA * r_lo; pts[11] = center + mCA * r_hi;
				if (_occluded_hiz(pts)) {
					return;
				}
			}
		} else {
			// 模式 2: 解析地形射线(方案 B)。只测 **maxH 处** 的 6 点(3 角 + 3 边中): 同方向上半径越高
			// 越容易越过山脊被看见, 所以"最高点都被挡" ⇒ 其下方各点也被挡 → 测最高点即保守充分。
			// 任一点未被挡 → patch 可能可见 → 立即不剔(早退, 可见 patch 的常见路径也最省)。
			// mip 取 2(min over 4×4 cell): 比 mip0(单点采样, 不严格包夹)更保守, 抗实时噪声偏差。
			float mip_occ = min(2.0, fd.consts.x);
			vec3 cam_w = fd.cam_pos_pad.xyz;
			if (_blocked_by_terrain(center + A * r_hi, cam_w, center, radius, mip_occ)
					&& _blocked_by_terrain(center + B * r_hi, cam_w, center, radius, mip_occ)
					&& _blocked_by_terrain(center + C * r_hi, cam_w, center, radius, mip_occ)
					&& _blocked_by_terrain(center + mAB * r_hi, cam_w, center, radius, mip_occ)
					&& _blocked_by_terrain(center + mBC * r_hi, cam_w, center, radius, mip_occ)
					&& _blocked_by_terrain(center + mCA * r_hi, cam_w, center, radius, mip_occ)) {
				return;
			}
		}
	}

	// ---- Phase 4 + 4.5: 算 3 边的 lodDelta(自己 - 邻居, max(0, ...)) ----
	// 面内邻居: 直接 sample lodtex[face]。跨面邻居(OOB query): 投影到 neighbor face-bary,
	// sample lodtex[neighbor]。A/B/C 是 self patch 3 角点方向(用于跨面 3D→bary 投影)。
	float lod_self = float(level);
	float eps_uv = 2.0 / 256.0;   // 2 格外推(LODTEX_RES=256): 稳稳落进邻居格中心, 不卡边界、不越过 4 格宽的最细同级邻居
	// AB 边(edge_idx=0)
	vec2 mid_ab = (A_bary + B_bary) * 0.5;
	vec2 out_ab = mid_ab - C_bary;
	// lodtex 现存 level+1: raw==0 表示空 cell(无叶)→ 不焊(n_lod=lod_self → lodDelta=0);
	// raw>=1 → neighbor_level = raw-1。避免空 cell 被误当 level 0 → 巨大 lodDelta → 外插尖刺。
	int raw_ab = _sample_lodtex_smart(face, 0, mid_ab + eps_uv * normalize(out_ab + vec2(1e-8)), A, B, C);
	float n_lod_ab = (raw_ab <= 0) ? lod_self : float(raw_ab - 1);
	float lod_d_ab = max(0.0, lod_self - n_lod_ab);
	// BC 边(edge_idx=1)
	vec2 mid_bc = (B_bary + C_bary) * 0.5;
	vec2 out_bc = mid_bc - A_bary;
	int raw_bc = _sample_lodtex_smart(face, 1, mid_bc + eps_uv * normalize(out_bc + vec2(1e-8)), A, B, C);
	float n_lod_bc = (raw_bc <= 0) ? lod_self : float(raw_bc - 1);
	float lod_d_bc = max(0.0, lod_self - n_lod_bc);
	// CA 边(edge_idx=2)
	vec2 mid_ca = (C_bary + A_bary) * 0.5;
	vec2 out_ca = mid_ca - B_bary;
	int raw_ca = _sample_lodtex_smart(face, 2, mid_ca + eps_uv * normalize(out_ca + vec2(1e-8)), A, B, C);
	float n_lod_ca = (raw_ca <= 0) ? lod_self : float(raw_ca - 1);
	float lod_d_ca = max(0.0, lod_self - n_lod_ca);

	// ---- 通过 → 原子发射到 cull_tex ----
	uint out_slot = atomicAdd(cull_counter.count, 1u);
	if (out_slot >= uint(MAX_PATCHES)) {
		return;
	}
	// texel2.w = lodDelta_CA; texel4.zw = (lodDelta_AB, lodDelta_BC)。其余字段不变。
	imageStore(cull_tex, ivec2(0, int(out_slot)), t0);
	imageStore(cull_tex, ivec2(1, int(out_slot)), t1);
	imageStore(cull_tex, ivec2(2, int(out_slot)), vec4(C.xyz, lod_d_ca));
	imageStore(cull_tex, ivec2(3, int(out_slot)), t3);
	imageStore(cull_tex, ivec2(4, int(out_slot)), vec4(C_bary.x, C_bary.y, lod_d_ab, lod_d_bc));
	imageStore(cull_tex, ivec2(5, int(out_slot)), vec4(minH, maxH, 0.0, 0.0));
}
