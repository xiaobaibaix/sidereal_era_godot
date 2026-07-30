## 行星参数资源(对应 web 版 params 对象 / presets/default.json)。
## 全部用 @export, 直接在 Godot 编辑器 Inspector 调节(分组 + 范围滑块 + 撤销重做)。
## 运行时改属性也会触发 setter -> param_changed(key) 信号, 应用层据此实时响应。
##
## 持久化: 保存场景即持久化(资源内嵌或存 .tres); 也可 save_as_tres() 导出预设。
##
## 收录范围: **只放真的有消费者的参数**。这份资源曾经攒下 21 个无人读取的死字段(角色速度/重力、
## 观察者速度、线框与画中画开关、自动日照、CPU LOD 时代的 splitFactor/prefetchFactor/splitBudget/
## mergeHysteresis/nearRadius/geometricErrorScale/patchResolution/frustumMargin、大气重构后失效的
## atmoACES/atmoLUT、已被替换的 occlusionMinAltitudeFrac), 在 Inspector 里调了却毫无反应, 是持续的
## 困惑源。加字段前请确认有代码真的读它。
## 反例参考: 角色的速度/跳跃/重力在 character_controller.gd 自己的 @export 上; 线框与画中画在
## planet_lod_debug.gd 自己的状态里; patch 网格分辨率在 GpuPlanet.patch_resolution 上 —— 都不经这里。
##
## @tool 是**必须**的, 否则编辑器里 Inspector 调参毫无反应:
## 非 @tool 的脚本在编辑器里被实例化成"占位实例"(placeholder) —— 属性读写走 placeholder 的存储,
## setter **不执行** → param_changed 永不发出 → GpuPlanet._on_param_changed 不触发 → _push_params()
## 不跑 → shader uniform(噪声种子/频率、配色、海洋、气候…)一直是旧值。
## 只有 radius/maxHeight/maxLevel/sseThresholdPixels 例外, 因为 GpuPlanet._process 每帧重读它们,
## 不依赖信号 —— 这正是"改半径有反应、改噪声没反应"的原因。
## 同样的坑 GpuMinMaxData 也踩过(见该文件头部注释)。
@tool
class_name PlanetParams
extends Resource

signal param_changed(key: String)
signal bulk_changed

# ---- 几何 ----
@export_group("几何")
## 行星半径(世界单位)。GPU LOD 下改它会实时生效(地形/大气/海面/角色/剔除都会跟随)。
## or_greater: 滑条上限 2000 只是常用区间, 可手填更大值。但注意两个尺度耦合:
##   ① 半径越大, 同 maxLevel 下地形越粗(MAX_GPU_LEVEL=6 是硬上限) → 贴地细节变少;
##   ② 半径越小(或 maxHeight 越大 / sseThresholdPixels 越小), 可见 patch 数越多 → 可能超 MAX_PATCHES
##      而丢 patch 露洞(现在会在控制台 push_warning 提示, 并给出调参建议)。
@export_range(10.0, 2000.0, 1.0, "or_greater") var radius: float = 100.0:
	set(v): radius = v; param_changed.emit("radius")
## 地形隆起的最大高度(相对半径的比例, 实际位移 = height_at × maxHeight)。越大山脉越夸张。
@export_range(0.0, 50.0, 0.1) var maxHeight: float = 8.0:
	set(v): maxHeight = v; param_changed.emit("maxHeight")

# ---- 外观 ----
@export_group("外观")
## 海面 mesh 开关(Phase 2)。
@export var showOcean: bool = true:
	set(v): showOcean = v; param_changed.emit("showOcean")
## 大气散射壳开关(Phase 2)。
@export var showAtmosphere: bool = true:
	set(v): showAtmosphere = v; param_changed.emit("showAtmosphere")
## 体积云开关(Phase 2)。
@export var showClouds: bool = true:
	set(v): showClouds = v; param_changed.emit("showClouds")
## 体积光(godray)开关(Phase 5)。
@export var showGodrays: bool = true:
	set(v): showGodrays = v; param_changed.emit("showGodrays")

# ---- 太阳 ----
@export_group("太阳")
## 太阳仰角(度, -90..90): 控制日高低。
@export_range(-90.0, 90.0, 0.5) var sunElevation: float = 35.0:
	set(v): sunElevation = v; param_changed.emit("sunElevation")
## 太阳方位角(度, 0..360): 控制日照方向。
@export_range(0.0, 360.0, 0.5) var sunAzimuth: float = 40.0:
	set(v): sunAzimuth = v; param_changed.emit("sunAzimuth")

# ---- 大气散射 ----
@export_group("大气散射")
## 大气壳半径 = 行星半径 × atmoScale(壳要略大于行星)。
## 1.15: 壳越薄, 辉光被挤进越窄的环、外沿越像硬边; 加厚给辉光平滑衰减的空间。
@export_range(1.0, 1.5, 0.001) var atmoScale: float = 1.15:
	set(v): atmoScale = v; param_changed.emit("atmoScale")
## 瑞利散射强度(短波长, 主导天空蓝/日间色)。
@export_range(0.0, 8.0, 0.01) var atmoRayleigh: float = 0.08:
	set(v): atmoRayleigh = v; param_changed.emit("atmoRayleigh")
## 米氏散射强度(全波长, 主导雾霭/地平线光晕)。
## Mie 是无色(灰白)散射, 过强会在日照临边形成泛白银边; 0.008 让瑞利(蓝)主导, 只留淡淡银边。
@export_range(0.0, 4.0, 0.01) var atmoMie: float = 0.008:
	set(v): atmoMie = v; param_changed.emit("atmoMie")
## 米氏相位不对称量(-1..1): 越大越聚集向前(强银边/前向光晕)。
## 0.5: 降低前向峰值(0.76 时峰值约 4.9 → 0.5 时约 1.0), 把白色前向光晕摊开、削弱。
@export_range(0.0, 0.99, 0.01) var atmoMieG: float = 0.5:
	set(v): atmoMieG = v; param_changed.emit("atmoMieG")
## 大气密度随高度衰减指数(越大越贴地表衰减越快; 调到≈0 则整层都稠 → 连高空晕都能浓雾挡住后方星球, 但本星球会变雾球)。
@export_range(0.0, 16.0, 0.05) var atmoDensityFalloff: float = 6.0:
	set(v): atmoDensityFalloff = v; param_changed.emit("atmoDensityFalloff")
## 米氏衰减指数(通常比密度衰减大, 贴近地表的雾; 调到≈0 同样让高空米氏变稠)。
@export_range(0.0, 32.0, 0.05) var atmoMieFalloff: float = 16.0:
	set(v): atmoMieFalloff = v; param_changed.emit("atmoMieFalloff")
## 太阳光照强度(亮度倍率)。
## 14: 过高会让临边内散射过曝, 经色调映射被推成灰白; 调低让临边保持蓝紫。
@export_range(0.0, 80.0, 0.1) var atmoSunIntensity: float = 14.0:
	set(v): atmoSunIntensity = v; param_changed.emit("atmoSunIntensity")
## 曝光(最终亮度倍率, 接近 HDR 输出后)。
@export_range(0.0, 4.0, 0.01) var atmoExposure: float = 1.0:
	set(v): atmoExposure = v; param_changed.emit("atmoExposure")
## 大气/体积云渲染分辨率比例(0.5 = 半分辨率, 后处理开销约降至 1/4; 1.0 = 全分辨率最清晰)。
## 大气/云场在低分辨率算完后双线性上采样合成到全分辨率场景色上 → 场景/地形边缘仍清晰, 只有云边缘随比例变软。
@export_range(0.25, 1.0, 0.05) var atmoRenderScale: float = 0.5:
	set(v): atmoRenderScale = v; param_changed.emit("atmoRenderScale")
## 视线积分步数: 越多越精确、越慢(主光线步进)。
@export_range(4, 64, 1) var atmoSteps: int = 16:
	set(v): atmoSteps = v; param_changed.emit("atmoSteps")
## 光照(自散射/阴影)积分步数: 较少即可。
@export_range(2, 32, 1) var atmoLightSteps: int = 8:
	set(v): atmoLightSteps = v; param_changed.emit("atmoLightSteps")
## 云在地表的投影柔和度。
@export_range(0.0, 1.0, 0.01) var atmoShadowSoftness: float = 0.6:
	set(v): atmoShadowSoftness = v; param_changed.emit("atmoShadowSoftness")
## 暮光增强(日出日落时暖色加强)。
@export_range(0.0, 1.0, 0.01) var atmoTwilight: float = 0.3:
	set(v): atmoTwilight = v; param_changed.emit("atmoTwilight")
## 臭氧吸收量(影响天空/日落的青绿调)。
@export_range(0.0, 0.3, 0.001) var atmoOzone: float = 0.02:
	set(v): atmoOzone = v; param_changed.emit("atmoOzone")
## 抖动(去 banding 色带)强度。
@export_range(0.0, 1.0, 0.01) var atmoDither: float = 0.5:
	set(v): atmoDither = v; param_changed.emit("atmoDither")

# ---- 体积云 ----
@export_group("体积云")
## 云层底部高度 = 行星半径 × cloudBottom。
@export_range(1.0, 1.1, 0.001) var cloudBottom: float = 1.01:
	set(v): cloudBottom = v; param_changed.emit("cloudBottom")
## 云层顶部高度 = 行星半径 × cloudTop(必须 > cloudBottom)。
@export_range(1.01, 1.3, 0.001) var cloudTop: float = 1.06:
	set(v): cloudTop = v; param_changed.emit("cloudTop")
## 云覆盖量(0 无云, 1 满天)。
@export_range(0.0, 1.0, 0.01) var cloudCoverage: float = 0.5:
	set(v): cloudCoverage = v; param_changed.emit("cloudCoverage")
## 云密度(单点消光, Beer-Lambert; 越大云越厚实越不透明)。
@export_range(0.0, 30.0, 0.1) var cloudDensity: float = 1.2:
	set(v): cloudDensity = v; param_changed.emit("cloudDensity")
## 云噪声细节频率(越大细节越密)。
@export_range(0.0, 0.5, 0.001) var cloudFreq: float = 0.06:
	set(v): cloudFreq = v; param_changed.emit("cloudFreq")
## 云域扭曲(让云边缘自然卷曲)。
@export_range(0.0, 2.0, 0.01) var cloudWarp: float = 0.5:
	set(v): cloudWarp = v; param_changed.emit("cloudWarp")
## 风速(云层平移速度, 制造动效)。
@export_range(0.0, 5.0, 0.01) var cloudWindSpeed: float = 0.6:
	set(v): cloudWindSpeed = v; param_changed.emit("cloudWindSpeed")
## 云层主积分步数(越多越精细、越慢)。
@export_range(4, 96, 1) var cloudSteps: int = 16:
	set(v): cloudSteps = v; param_changed.emit("cloudSteps")
## 云光照(自阴影)积分步数。
@export_range(2, 16, 1) var cloudLightSteps: int = 4:
	set(v): cloudLightSteps = v; param_changed.emit("cloudLightSteps")
## 云光吸收强度(自阴影, 越大云底越暗、越显厚实)。
@export_range(0.0, 20.0, 0.1) var cloudAbsorb: float = 1.0:
	set(v): cloudAbsorb = v; param_changed.emit("cloudAbsorb")
## 银边强度(前向散射, 云迎光边缘发亮)。
@export_range(0.0, 4.0, 0.01) var cloudSilver: float = 1.0:
	set(v): cloudSilver = v; param_changed.emit("cloudSilver")
## 粉末效应(云深处更亮, 增强体积感)。
@export_range(0.0, 2.0, 0.01) var cloudPowder: float = 0.6:
	set(v): cloudPowder = v; param_changed.emit("cloudPowder")
## 云在地表的投影强度。
@export_range(0.0, 1.0, 0.01) var cloudShadow: float = 0.7:
	set(v): cloudShadow = v; param_changed.emit("cloudShadow")
## 晨昏线位移(云的明暗分界线): 正值→分界线向阳侧移动(云更早变暗、收进夜侧, 更贴近晨昏线);
## 负值→分界线向背阳侧延伸(云在夜侧延伸更远才变暗)。默认 0 = 原行为(环境光延伸到 sunUp≈-0.4)。
@export_range(-0.5, 0.5, 0.01) var cloudTerminatorShift: float = 0.0:
	set(v): cloudTerminatorShift = v; param_changed.emit("cloudTerminatorShift")

# ---- 海洋 ----
@export_group("海洋")
## 海平面高度阈值: height_at < seaLevel 视为海洋(陆地/海洋配色); 海洋球壳半径 = radius + seaLevel×maxHeight。
## 改它会重建地形网格(陆地/海洋分布变)。
@export_range(-1.0, 1.0, 0.01) var seaLevel: float = 0.0:
	set(v): seaLevel = v; param_changed.emit("seaLevel")
## 深水色(海平面看向深处的主色)。
@export var oceanDeep: Color = Color(0.039, 0.118, 0.247):
	set(v): oceanDeep = v; param_changed.emit("oceanDeep")
## 浅水色(菲涅尔边缘/浅滩亮色)。
@export var oceanShallow: Color = Color(0.180, 0.471, 0.659):
	set(v): oceanShallow = v; param_changed.emit("oceanShallow")
## 夜侧基础亮度(0=全黑, 1=日夜同亮)。
@export_range(0.0, 1.0, 0.01) var oceanAmbient: float = 0.2:
	set(v): oceanAmbient = v; param_changed.emit("oceanAmbient")
## 高光锐度(Blinn-Phong power, 越大高光越集中越亮)。
@export_range(1.0, 512.0, 1.0) var oceanSpecPower: float = 120.0:
	set(v): oceanSpecPower = v; param_changed.emit("oceanSpecPower")
## 高光强度。
@export_range(0.0, 4.0, 0.01) var oceanSpecStrength: float = 0.9:
	set(v): oceanSpecStrength = v; param_changed.emit("oceanSpecStrength")

# ---- 体积光 ----
@export_group("体积光")
## 体积光(godray)强度。
@export_range(0.0, 2.0, 0.01) var godrayStrength: float = 0.6:
	set(v): godrayStrength = v; param_changed.emit("godrayStrength")
## 体积光介质密度(越浓光束越明显)。
@export_range(0.0, 2.0, 0.01) var godrayDensity: float = 0.7:
	set(v): godrayDensity = v; param_changed.emit("godrayDensity")
## 体积光采样数(越多越平滑、越慢)。
@export_range(8, 128, 1) var godraySamples: int = 32:
	set(v): godraySamples = v; param_changed.emit("godraySamples")
## 体积光阈值(遮挡深度, 控制光束出现的范围)。
@export_range(0.0, 1.0, 0.01) var godrayThreshold: float = 0.45:
	set(v): godrayThreshold = v; param_changed.emit("godrayThreshold")

# ---- LOD ----
@export_group("LOD")
## 最大细分层数: 越大近处 patch 越细(细节越多, 但 patch 越多越费)。
## 注: GPU 路径会被 GpuPlanet.MAX_GPU_LEVEL(=6) 钳住(min(maxLevel, 6)), 调到 6 以上不再有效果 ——
## 该上限同时定死了 MinMax 烘焙分辨率(GpuLodCompositor.BAKE_RES = 2^6 = 64), 要动得两边一起改。
@export_range(1, 12, 1) var maxLevel: int = 8:
	set(v): maxLevel = v; param_changed.emit("maxLevel")
## 屏幕空间误差阈值(像素): chunk 在屏幕上的几何误差超过此值才细分。
## SSE = geometric_error × viewport_height / (distance × 2 × tan(fov_y/2))。
## 越小越严格(更精细, 更费 GPU); 越大越省(更粗糙)。
## 推荐: 2~3 像素(电影级), 5~8 像素(平衡), 10+ 像素(性能优先/移动端)。
## 默认 5.0(平衡档, 比 web 版旧 splitFactor=2.5 略省 → 近地 FPS 略升); 卡顿就调到 8~12, 想精细就调到 3。
@export_range(1.0, 32.0, 0.5) var sseThresholdPixels: float = 5.0:
	set(v): sseThresholdPixels = v; param_changed.emit("sseThresholdPixels")
## 地平线剔除(移植 web 版): 剔掉被行星本体挡在背面的 chunk。站在地表/贴近时约一半 chunk 在背面 →
## 直接跳过遍历与渲染, 大幅降 patch/三角数(角色模式性能主要来源)。远距观察全球时天然无剔除。
@export var horizonCulling: bool = true:
	set(v): horizonCulling = v; param_changed.emit("horizonCulling")
## 小三角剔除(像素阈): patch 投影到屏幕的估算像素跨度 < 此值 → 剔除(太小不值得画)。
## 估算 = world_size × K / dist(K = vp_h/(2·tan(fov/2))), 与 SSE 同量纲。0 = 关闭。
## 收益: 极远/掠射角下的碎 patch 直接砍掉; 太大(>3)会在远处露洞, 建议 0.5~2。
@export_range(0.0, 8.0, 0.1) var smallTriPixels: float = 1.0:
	set(v): smallTriPixels = v; param_changed.emit("smallTriPixels")
## 遮挡剔除(Hi-Z): 用上一帧深度金字塔(reverse-Z 取 min)剔掉被山体/近处地形挡住的 patch。
## 仅在 CHARACTER(贴地)模式生效(见 gpu_planet.set_cull_mode) —— 贴地时近山遮挡后方地形收益最大;
## PLANET(高空)模式由地平线剔除负责行星背面, Hi-Z 收益小故停用。
## 注: 遮挡用的是**上一帧**深度(1 帧内容延迟), 快速运动时新露出的地形仍可能短暂被误剔(disocclusion)。
## 投影视点已与金字塔视点对齐(gpu_hiz_compositor 记录建图时的 view_proj), 消除了几何不一致造成的碎斑。
## 运行时可按 F3 开关对比。
@export var occlusionCulling: bool = true:
	set(v): occlusionCulling = v; param_changed.emit("occlusionCulling")
## 视锥外扩余量的安全系数(补偿 GPU 剔除的 1 帧延迟)。剔除结果比画面晚一帧, 且贴近地表、地形铺满全屏时,
## 紧贴屏幕边缘的 patch 稍有偏差就露出黑色空洞。此系数控制视锥外扩量 = 常驻保险带(消除静止时的边缘空洞)
## + 本帧相机运动量(补偿快速平移/俯仰的 1 帧延迟), 都按"相机→地平线"距离换算。静止时仍留常驻保险带。
## 0 = 完全关闭(最省, 但会有边缘空洞); 越大越不会有空洞, 但会多留一圈屏幕外 patch(近距时略增开销)。
## 建议 2~4; 贴近地表还看到边缘黑三角就往上调。
@export_range(0.0, 8.0, 0.1) var cullFrustumMargin: float = 2.5:
	set(v): cullFrustumMargin = v; param_changed.emit("cullFrustumMargin")

# ---- 大陆噪声 fBm ----
@export_group("大陆噪声")
## 大陆随机种子: 改它整张地形图案换样。
@export_range(0, 999999, 1) var continentSeed: int = 1337:
	set(v): continentSeed = v; param_changed.emit("continentSeed")
## 大陆频率: 越大大陆块越小越碎。
@export_range(0.01, 8.0, 0.01) var continentFreq: float = 1.2:
	set(v): continentFreq = v; param_changed.emit("continentFreq")
## 大陆 fBm 叠加层数: 越多细节越丰富、越慢。
@export_range(1, 8, 1) var continentOctaves: int = 5:
	set(v): continentOctaves = v; param_changed.emit("continentOctaves")
## 大陆每层增益(振幅衰减): 越大高频细节越突出。
@export_range(0.0, 1.0, 0.01) var continentGain: float = 0.5:
	set(v): continentGain = v; param_changed.emit("continentGain")
## 大陆每层频率倍率(通常 2.0)。
@export_range(1.0, 4.0, 0.01) var continentLacunarity: float = 2.0:
	set(v): continentLacunarity = v; param_changed.emit("continentLacunarity")

# ---- 山脉 Ridged ----
@export_group("山脉")
## 山脉随机种子。
@export_range(0, 999999, 1) var mountainSeed: int = 9001:
	set(v): mountainSeed = v; param_changed.emit("mountainSeed")
## 山脉频率: 越大山脊越密。
@export_range(0.01, 8.0, 0.01) var mountainFreq: float = 3.0:
	set(v): mountainFreq = v; param_changed.emit("mountainFreq")
## 山脉 ridged 噪声层数。
@export_range(1, 8, 1) var mountainOctaves: int = 5:
	set(v): mountainOctaves = v; param_changed.emit("mountainOctaves")
## 山脉强度: 山脉对高度的贡献权重(海里不叠山)。
@export_range(0.0, 2.0, 0.01) var mountainStrength: float = 0.6:
	set(v): mountainStrength = v; param_changed.emit("mountainStrength")

# ---- 结构增强 ----
@export_group("结构增强")
## 域扭曲种子: 扰动采样坐标, 让大陆/山脉边缘更自然。
@export_range(0, 999999, 1) var warpSeed: int = 777:
	set(v): warpSeed = v; param_changed.emit("warpSeed")
## 域扭曲强度(越大地形越扭曲变形)。
@export_range(0.0, 1.0, 0.01) var warpStrength: float = 0.2:
	set(v): warpStrength = v; param_changed.emit("warpStrength")
## 域扭曲频率。
@export_range(0.01, 8.0, 0.01) var warpFreq: float = 1.0:
	set(v): warpFreq = v; param_changed.emit("warpFreq")
## 板块边界种子: cellular 噪声形成板块, 边界起脊(造山脉带)。
@export_range(0, 999999, 1) var plateSeed: int = 555:
	set(v): plateSeed = v; param_changed.emit("plateSeed")
## 板块频率: 越大板块越小越密。
@export_range(0.01, 8.0, 0.01) var plateFreq: float = 1.6:
	set(v): plateFreq = v; param_changed.emit("plateFreq")
## 板块脊强度(边界造山幅度)。
@export_range(0.0, 2.0, 0.01) var plateStrength: float = 0.5:
	set(v): plateStrength = v; param_changed.emit("plateStrength")
## 湿度噪声种子: 决定干旱/湿润分布(影响生物群系配色)。
@export_range(0, 999999, 1) var moistureSeed: int = 333:
	set(v): moistureSeed = v; param_changed.emit("moistureSeed")
## 湿度频率。
@export_range(0.01, 8.0, 0.01) var moistureFreq: float = 1.2:
	set(v): moistureFreq = v; param_changed.emit("moistureFreq")
## 气候配色开关: 关闭则用单一高度配色, 开启则温度×湿度→生物群系。
@export var useClimate: bool = true:
	set(v): useClimate = v; param_changed.emit("useClimate")
## 气候海拔归一范围: 把(高度-海平面)映射到此范围算温度。
@export_range(0.01, 2.0, 0.01) var climateAltRange: float = 1.0:
	set(v): climateAltRange = v; param_changed.emit("climateAltRange")


## 批量通知(载入预设/重置后调用)
func emit_bulk_changed() -> void:
	bulk_changed.emit()


## 导出为 .tres 预设文件(对应 web 版 "存到项目 presets/")
func save_as_tres(path: String) -> Error:
	return ResourceSaver.save(self, path)


## 这些 key 的变更需要重建地形网格(而非实时更新)
const REBUILD_KEYS := [
	"radius", "maxHeight",
	"continentSeed", "continentFreq", "continentOctaves", "continentGain", "continentLacunarity",
	"mountainSeed", "mountainFreq", "mountainOctaves", "mountainStrength",
	"warpSeed", "warpStrength", "warpFreq",
	"plateSeed", "plateFreq", "plateStrength",
	"moistureSeed", "moistureFreq", "useClimate", "climateAltRange",
]


func requires_rebuild(key: String) -> bool:
	return key in REBUILD_KEYS
