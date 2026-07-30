#[compute]

// GPU LOD 四叉树遍历(Phase 2 + Phase 3 bary 输出)。单遍距离壳测试 + 原子紧凑发射, 无 ping-pong。
//
// 每个 invocation = 一个候选节点 (face, level, idx)。寄存器内中点递推重建 3 角点(同 qnode._split 子序:
//   子0=[A,ab,ca] 子1=[ab,B,bc] 子2=[ca,bc,C] 子3=[ab,bc,ca]), 算节点中心到相机距离, 用【保守几何误差
//   g_err = maxHeight / 2^level】的 SSE 距离壳判定是否为选中叶:
//     level==0:              dist >= split_d(0)             → 叶(根不细分); 否则根细分, 往下找
//     level>0, <maxLevel:    split_d(L) <= dist < 2·split_d(L) → 叶(父细分了、自己不细分)
//     level==maxLevel:       dist < 2·split_d(L)            → 叶(最深, 父细分了)
//   其中 split_d(L) = max(C_height/2^L, C_curve/4^L) —— 详见下方 split_d() 注释(高度误差 + 球面曲率误差),
//   C_height = maxHeight·K/T, C_curve = radius·θ0²/8·K/T, K=vp_h/(2·tan(fov/2)), T=sseThresholdPixels。
//   证明(单调): split_d 随 L 单调降 → dist<2·split_d(L)=split_d(L-1) 蕴含 dist<split_d(L-2)<...<split_d(0),
//   即所有祖先都细分 → 本节点存在; 再加 dist>=split_d(L) → 自己不细分 → 是叶。无需 ping-pong。
//
// 选中叶 → atomicAdd(counter) 取槽, imageStore 6 texel 到 patch 纹理:
//   texel0 = (A.xyz, face)         texel1 = (B.xyz, lod)        texel2 = (C.xyz, _)
//   texel3 = (ua, va, ub, vb)      texel4 = (uc, vc, _, _)      texel5 = (0,0,0,0) ← Phase 6 MinMax
//   其中 (ua,va)/(ub,vb)/(uc,vc) 是 A/B/C 在 face-bary 空间的 (u,v) 坐标。face-bary 与方向同步递推:
//   初始 A_face.bary=(0,0), B_face.bary=(1,0), C_face.bary=(0,1); 子节点 bary = 父 bary 中点平均。
//   Phase 3 lod_cull 读 bary 中心 = ((ua+ub+uc)/3, (va+vb+vc)/3), 用于采样 MinMax 纹理构 AABB。
//   Phase 4 焊接将用 bary 边匹配算 lodTrans(目前 texel4.zw 空)。
//
// dispatch: 每帧 per-level 一次(group 数 = ceil(20·4^level / 64)), push constant 带 level。
//   level == -1: reset 模式(线程0 把 counter=0, 帧首调一次)。
//   level == -2: metadata 模式(遍历完后线程0 把 counter 写进 patch 纹理末行, 供 vertex shader 读 count 坍缩)。
//
// 面角点硬编码(黄金比 PHI, 与 gpu_ico.gd RAW_VERTS/FACES 逐位一致)——消除 uniform buffer, 简化绑定。
// 不依赖任何主线程数据; 相机/参数全走 push constant(每帧 GpuPlanet._process 推)。

#version 450
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba32f) uniform writeonly image2D patch_tex;
layout(set = 1, binding = 0, std430) buffer CountBuf { uint count; } counter;

layout(push_constant, std430) uniform Push {
	vec4 cam_pos_pad;        // xyz = cam_pos(world), w = radius
	vec4 planet_center_pad;  // xyz = planet_center(world), w = maxHeight
	vec4 consts;             // x = C_height, y = maxLevel, z = level, w = MAX_PATCHES
	vec4 consts2;            // x = C_curve(球面曲率项系数), yzw = 预留
} pc;

// 该层的"细分阈值距离": 相机比它更近 → 应细分。split_d(L) = g_err(L)·K/T, K/T 已由 CPU 预乘进系数。
// g_err(L) = max(高度误差, 球面曲率误差):
//   高度误差   = maxHeight / 2^L                      → C_height / 2^L
//   曲率误差   = radius·θ0²/8 / 4^L (球面弓高 sagitta) → C_curve / 4^L,  θ0 = 二十面体棱角 ≈1.1071rad
// 【为什么要曲率项】只按高度估误差时, split_d 与 radius 无关 → 半径调大后 patch 物理尺寸变大、球面
// 逼近误差(弓高)随 radius 线性增长, 却不会更早细分 → 轮廓出现多边形棱角、地形变粗。加入曲率项后
// 大半径会在**粗层**提前细分, 消除棱角; 细层仍由高度项主导, 故 patch 数不会失控。
// 单调性: 两项都随 L 严格递减 → max 也递减 → 距离壳判定(依赖 split_d 单调)依然成立。
float split_d(float L) {
	return max(pc.consts.x / exp2(L), pc.consts2.x / exp2(2.0 * L));
}

const float PHI = 1.6180339887498948482;   // (1+√5)/2, 与 gpu_ico.gd T 一致
const vec3 RAW[12] = vec3[12](
	vec3(-1.0, PHI, 0.0), vec3(1.0, PHI, 0.0), vec3(-1.0, -PHI, 0.0), vec3(1.0, -PHI, 0.0),
	vec3(0.0, -1.0, PHI), vec3(0.0, 1.0, PHI), vec3(0.0, -1.0, -PHI), vec3(0.0, 1.0, -PHI),
	vec3(PHI, 0.0, -1.0), vec3(PHI, 0.0, 1.0), vec3(-PHI, 0.0, -1.0), vec3(-PHI, 0.0, 1.0)
);
// 20 面 × 3 顶点索引(绕序与 gpu_ico.gd FACES 一致)。
const int FACES[60] = int[60](
	0, 11, 5,  0, 5, 1,  0, 1, 7,  0, 7, 10, 0, 10, 11,
	1, 5, 9,  5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
	3, 9, 4,  3, 4, 2,  3, 2, 6,  3, 6, 8,  3, 8, 9,
	4, 9, 5,  2, 4, 11, 6, 2, 10, 8, 6, 7,  9, 8, 1
);
const int MAX_PATCHES = 12288;
const int META_ROW = MAX_PATCHES;   // patch 纹理末行(第 4096 行)存 count, 供 vertex shader 坍缩

void main() {
	int level = int(pc.consts.z);
	uint t = gl_GlobalInvocationID.x;

	// ---- 特殊模式: reset / metadata(单线程, 帧首/帧末各一次) ----
	if (level < 0) {
		if (t == 0u) {
			if (level == -1) {
				counter.count = 0u;
			} else if (level == -2) {
				float c = float(counter.count);
				imageStore(patch_tex, ivec2(0, META_ROW), vec4(c, 0.0, 0.0, 0.0));
			}
		}
		return;
	}

	// ---- 解码 (face, idx): t = face·4^level + idx ----
	int nodesPerFace = 1;
	for (int i = 0; i < level; i++) { nodesPerFace *= 4; }
	int totalNodes = 20 * nodesPerFace;
	if (int(t) >= totalNodes) {
		return;
	}
	int face = int(t) / nodesPerFace;
	int idx = int(t) - face * nodesPerFace;

	// ---- 重建 3 角点 + face-bary(中点递推, MSB 先: b=level-1 是第一层细分选择) ----
	// face-bary 与 heightmap_baker 一致: A=(u=0,v=0), B=(u=1,v=0), C=(u=0,v=1);
	// 子节点角点 bary = 父对应角点 bary(角点保留) 或父两角点 bary 中点(新引入的边中点)。
	vec3 A = normalize(RAW[FACES[face * 3]]);
	vec3 B = normalize(RAW[FACES[face * 3 + 1]]);
	vec3 C = normalize(RAW[FACES[face * 3 + 2]]);
	vec2 A_bary = vec2(0.0, 0.0);
	vec2 B_bary = vec2(1.0, 0.0);
	vec2 C_bary = vec2(0.0, 1.0);
	// 记录父三角形(level-1)角点, 供下方 parent_split 的"父中心距离"判据用。level==0 时无父, 不用。
	vec3 pA = A, pB = B, pC = C;
	for (int b = level - 1; b >= 0; b--) {
		if (b == 0) { pA = A; pB = B; pC = C; }   // 应用最后一次细分前的状态 = 父三角形
		int digit = (idx >> (2 * b)) & 3;
		vec3 ab = normalize(A + B);
		vec3 bc = normalize(B + C);
		vec3 ca = normalize(C + A);
		vec2 ab_bary = (A_bary + B_bary) * 0.5;
		vec2 bc_bary = (B_bary + C_bary) * 0.5;
		vec2 ca_bary = (C_bary + A_bary) * 0.5;
		if (digit == 0) {
			// 子0=[A,ab,ca]: A 保留, B<-ab, C<-ca
			vec3 oA = A; vec2 oA_bary = A_bary;
			B = ab; C = ca; A = oA;
			B_bary = ab_bary; C_bary = ca_bary; A_bary = oA_bary;
		} else if (digit == 1) {
			// 子1=[ab,B,bc]: B 保留, A<-ab, C<-bc
			vec3 oB = B; vec2 oB_bary = B_bary;
			A = ab; C = bc; B = oB;
			A_bary = ab_bary; C_bary = bc_bary; B_bary = oB_bary;
		} else if (digit == 2) {
			// 子2=[ca,bc,C]: C 保留, A<-ca, B<-bc
			vec3 oC = C; vec2 oC_bary = C_bary;
			A = ca; B = bc; C = oC;
			A_bary = ca_bary; B_bary = bc_bary; C_bary = oC_bary;
		} else {
			// 子3=[ab,bc,ca]
			A = ab; B = bc; C = ca;
			A_bary = ab_bary; B_bary = bc_bary; C_bary = ca_bary;
		}
	}

	// ---- SSE 距离壳判定(保守 g_err = maxHeight/2^level) ----
	int maxLevel = int(pc.consts.y);
	vec3 center_dir = normalize(A + B + C);
	vec3 center_world = pc.planet_center_pad.xyz + center_dir * pc.cam_pos_pad.w;   // radius
	float dist = distance(pc.cam_pos_pad.xyz, center_world);
	float sd_l = split_d(float(level));
	bool self_no_split = (level >= maxLevel) || (dist >= sd_l);
	// parent_split 必须用【父三角形中心】到相机的距离, 而不是本节点中心的 dist。
	// 每个节点中心 ≠ 其父中心; 若用自己的 dist 判"父是否细分", 父子会在 LOD 壳边界(dist≈sd)
	// 上产生分歧 → 出现空洞(无叶)/重叠(双叶), 表现为一圈 artifact。用父中心距离则父子判断一致。
	bool parent_split;
	if (level == 0) {
		parent_split = true;
	} else {
		vec3 p_center_dir = normalize(pA + pB + pC);
		vec3 p_center_world = pc.planet_center_pad.xyz + p_center_dir * pc.cam_pos_pad.w;
		float parent_dist = distance(pc.cam_pos_pad.xyz, p_center_world);
		parent_split = (parent_dist < split_d(float(level - 1)));   // parent_dist < sd_{level-1}
	}
	if (!(self_no_split && parent_split)) {
		return;
	}

	// ---- 选中叶 → 原子发射(槽超 MAX_PATCHES 则丢弃, 防越界) ----
	uint slot = atomicAdd(counter.count, 1u);
	if (slot >= uint(MAX_PATCHES)) {
		return;
	}
	imageStore(patch_tex, ivec2(0, int(slot)), vec4(A, float(face)));
	imageStore(patch_tex, ivec2(1, int(slot)), vec4(B, float(level)));
	imageStore(patch_tex, ivec2(2, int(slot)), vec4(C, 0.0));
	imageStore(patch_tex, ivec2(3, int(slot)), vec4(A_bary.x, A_bary.y, B_bary.x, B_bary.y));
	imageStore(patch_tex, ivec2(4, int(slot)), vec4(C_bary.x, C_bary.y, 0.0, 0.0));   // z/w = lodTrans(Phase4)
	imageStore(patch_tex, ivec2(5, int(slot)), vec4(0.0));   // minmax(Phase6)
}
