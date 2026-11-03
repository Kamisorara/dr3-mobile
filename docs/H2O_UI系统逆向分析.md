# D3 (Switch 2.7.7) H2O UI 系统逆向分析

> 2026-11-04。目标：为「HUD 移位」（血球/技能条 → 左上、地图 → 右上，物理手柄接入自动还原）
> 和「UI 触控」（背包/菜单直接点）提供结构地图。
> 目标二进制：`main` build `2607a74f…`（解压镜像 `_scratch/d3_main.bin`：text 13,052,816 @0，
> rodata @0xC73C00，data @0x1098C80）；.ui 样本：ClientCommon.cpk 解出的 397 个（`_scratch/ui/`）。

---

## 一、系统概览

D3 的 UI 是 **H2O** 框架（Blizzard 自研，D3 时代）：**数据驱动布局**——每个界面一个编译后的
`.ui` 文件（节点树 + 属性 + 动画绑定），运行时加载进内存节点树，由脚本 VM 驱动事件。

```
 RomFS: CPKs/ClientCommon.cpk
   └─ UI\Console*.ui / GameHUD*.ui / BattleNet*.ui …  （397 个，编译态二进制）
        │  游戏加载（main 内的解析器，见 §5）
        ▼
 内存节点树（LayoutRoot 为根）
   ├─ 节点：路径命名（Root.NormalLayer.<面板>_main.LayoutRoot.<子树>）
   ├─ 命名属性：PositionOffset / Rectangle / Anchor / …（见 §4）
   ├─ 动画：anim_* 节点（.?^game_dialog…anim_StampA 之类绑定串）
   └─ 事件：脚本 VM 函数（UI_Inventory_OnClick 等 53 个唯一名，见 §4.2）
```

**与 D2R 的根本差异**：D2R Switch main 保留了 PC 的鼠标消息注入路径（FNV 哈希命名
InputMessage 直发 UI 根控件，d2r-mobile 的触控捷径）；**D3 没有这条路径**——15 个消息名
× 3 种哈希全零命中（阳性对照 D2R 校准过，见《D3触控适配逆向调查记录》）。D3 的 UI 输入是
**焦点/环选择**（方向键挪高亮 + A 确认 + 环形菜单摇杆转圈），没有全局软指针。

## 二、文件清单（397 个 .ui）

来源：`CPKs/ClientCommon.cpk`（基础）+ `Update/CPKs/Patch2_6_5/6/10.cpk`（增量覆盖同名）。
抽包脚本：`_scratch/dump_ui.py`（用 `tools/cpk_shaders.py` 的 StrictReader 遍历条目）。

命名规律与用途（按前缀分类）：

| 前缀/文件 | 用途 | 与本任务的关系 |
|---|---|---|
| `Console*.ui`（~150 个） | **主机版界面**（Switch 实际加载的） | 主要逆向对象 |
| `BattleNet*.ui` | 战网面板（好友/赛季/商店/成就） | 路径结构最规整的样本 |
| `GameHUDPC.ui` | **PC 版 HUD**（HotBar×17 + SkillButton） | 技能栏结构参考 |
| `GameHUD.ui` / `GameHUDPC.ui` 同名存在于 Console 系补丁 | 主机加载 Console 系 | — |
| `ConsoleControllerLayout_NX64.ui` | Switch 手柄按键图例 | 键位语义参考 |

**HUD 宿主定位**（血球/技能/地图等要在移位中动的元素）：

| 元素 | 宿主文件 | 关键节点（明文可见） |
|---|---|---|
| **血球**（左下大圆） | `ConsoleHUD.ui` | `Globes` 容器：`Globe`、`Globe_Console_Reversed`（镜像左球）、`Globe_Console_lowHealthReversed`、`Globe_Paragon`（巅峰球）、`GlobeCover` |
| 血条（跟随角色的条） | `ConsoleHUD.ui` | `LayoutRoot.hp_bar_template_player` / `hp_bar_avenger` / `hp_bar_bounty.progressbar` / `PlayerSlots.Player1` |
| **技能条**（右下） | `GameHUDPC.ui`（PC）；主机版待确认（ConsoleHUD 里 hotbar_1/2/3 字符串存在） | `HotBar`、`SkillButton` |
| **小地图**（右下） | `Minimap.ui`、`ConsoleMinimap.ui`、`ConsoleWaypointMap*.ui` | `minimap_dialog*`、`minimap_mask_sidebar` |
| 战斗提示/屠杀报告 | `ConsoleGameHUDMisc.ui` | `ArcadeCombatWrapper`、`PositionOffset` 属性 |

## 三、.ui 文件格式（编译态）

### 3.1 已确认

**头部**（0x20 字节，397/397 一致）：

```
+0x00  u32  0xDEADBEEF                    魔数
+0x04  u32  0x1E0                         头区大小（全部文件相同）
+0x08  u32  1                             版本
+0x0C  u32  （每文件不同）                 校验/哈希 A
+0x10  u32  （> 文件大小）                 含义未知（未压缩尺寸？字符串数据总量？）
+0x14  u32  0
+0x18  u32  0
+0x1C  u32  （每文件不同）                 校验/哈希 B
```

**目录表**（+0xD0 起，**固定 2 条**，每条 24 字节 `{u64 hash, u32 offset, u32 count}`）：

```
条目 = {表名哈希(64 位), 字符串区偏移, 条目数}
例（ConsoleHUD_SinglePlayerFrame.ui）：
  {bc35acf3ec46311f, 0x15118, 20}   ← 表 1：20 个字符串
  {2325cc11_07b0a638, 0x15130, 73}  ← 表 2：73 个字符串
两个表指向的区域都是明文字符串（\0 结尾、4 字节对齐填充），表 1 头部带 16 字节 0
（可能是前置字段）。哈希算法未破解（FNV-1a/1 64 对表名与内容拼接均不中）。
397 个文件全部恰好 2 条 —— 猜测 = 「节点名表」+「其余字符串表」。
```

**字符串区**（明文）：

- 节点路径全文可见：`ConsoleHUD_main.LayoutRoot.hp_bar_template_player`、
  `game_dialog_backgroundScreen.ArcadeCombatWrapper…`
- `$anon$<名字>` 前缀标记（模板实例/匿名引用名，出现在路径引用旁）
- `UI:<纹理名>`（`UI:Console_EnemyHPbar04_Base`）、`Callouts:<名>`、`H2OLayout:<名>`、
  `anim_<名>` —— 资源与动画绑定串
- 部分区域是 `[u64 长度][字节]` 条目（长度含尾随结构，详见 0xeb78 处样本：
  `u64 0x10` + `u32 指针` + `u32 长度 0x1d` + 字符串 29 字节——32 位文件偏移指针
  指向池内字符串，ConsoleHUD.ui @0xebdc 的 0xebe0 即一例）
- 节点路径字符串**没有**绝对偏移/64 位指针引用（搜 0x60b3 的 u32/u64 引用零命中）
  —— 引用要么是池内相对偏移、要么是表序号索引、要么路径内嵌于节点记录

### 3.2 未解（下一步）

| 问题 | 候选方法 |
|---|---|
| 节点记录边界与字段（**位置/锚点存在哪**） | ① 反汇编加载器 main+0x4AE810（被 0x74C470 两次调用，w3=0xC、w6=0x3E8 参数）；② 真机/模拟器加载前后内存对比；③ 破解目录哈希后按表语义对号 |
| 目录表哈希算法 | 全 397 文件 {hash,offset,count} 数据集已可批量测试（h2o_survey.py 可扩展） |
| 0x10 处 ">文件大小" 字段的意义 | 多文件对照（已采集） |
| `$anon$` 的确切语义 | 对照模板与实例节点 |

**工具**（已入库）：
- `tools/h2o_parse.py` —— 单文件结构摘要（头/目录/字符串池样本）+ 格式笔记
- `tools/h2o_survey.py` —— 397 文件批量普查（头一致性/目录形状/属性名/事件名/路径）
- `_scratch/dump_ui.py` —— 从 CPK 抽 .ui（StrictReader）

## 四、节点、属性与事件

### 4.1 属性（明文可见的命名属性）

全 397 文件普查（h2o_survey.py）：

| 属性名 | 出现 | 说明 |
|---|---|---|
| `PositionOffset` | ×14 | **位置偏移**——HUD 移位要写的属性；`ConsoleGameHUDMisc.ui` 里有完整属性路径
（`game_dialog_backgroundScreen…MassacreReportWrapper.PositionOffset`） |
| `Rectangle` | ×12 | 矩形（尺寸/裁剪） |
| `Anchor` | ×4 | 锚点 |
| `Location` | ×3 | 位置 |

属性名以**明文**出现在部分文件（其余文件可能是哈希存储或未用到）。
属性路径 = 节点路径 + `.属性名`——脚本 VM 里有按路径取属性的证据（见 §4.2）。

### 4.2 事件（脚本 VM 函数）

53 个唯一事件处理器名（全量在 h2o_survey.py 输出），命名规则 `UI<面板>_On<事件>`：

```
UI_Inventory_OnClick ×4        UI_InvOpen_OnClick ×3          UI_CharDetails_OnClick ×3
UI_DungeonFinder_OnClick ×2    UI_HelpButton_OnClick ×2       UI_HirelingToggle_OnClick ×2
UI_RemoveGem_OnClick ×2        UIBattlenet_*_OnHotKey ×N      UI_PublicChat*_OnClick ×…
UI_SkillWalk_OnClick（ExeFS 字符串，xref main+0x3C619C）
```

**运行时形态**（main+0x3C619C 处的初始化器）：脚本 VM 全局表把 `{名字指针, 值}` 成对存入
大对象（x19 基址、0x20 步长），随后 `bl 0xA49690`（intern/查表，返回值入库）——
**UI 事件 = 脚本 VM 函数**。这给 UI 触控留了一条路：找到 VM 的「按名字调用」入口，
宿主就能直接调 `UI_Inventory_OnClick`（= 程序化点击背包）。

Power 脚本 VM 的原生注册表（另一套，1123 项 ×0x30：
`{名字指针, 数据指针, 0x403, 原生函数指针, 数据指针+8, 0x403}`，rodata 0xD60F70–0xD6E1D0）
已完整逆向（见触控记录 §4.1），含 74 个 PowerCursor* 函数——UI 侧如果同构，事件表也应可枚举。

### 4.3 布局与坐标系

- `mobile_graphics_profile.py` 验证过的 UI 数学：UI 像素投影（main+0x29B8C8）从
  「屏幕宽高全局」算 `2/w`、`-2/h`（左上原点）；宽高全局 = main+0x264F0/0x264F4，
  由 main+0x29A2F4 写——**UI 投影直接吃渲染尺寸**（参数槽给多少 UI 就铺多少，
  无独立 UI 尺寸全局，这也是「屏幕全局欺骗」路线不可行的原因）
- 界面常量缓冲 0x15 号槽 = `[屏宽, 屏高, 宽高比上限]`（KASPECTUI 位点注释，
  main+0x1663EE8）：界面精灵着色器按它在比例上限外画黑柱（D2R 用；D3 的对应位点
  在 mobile_graphics_profile.SITES）
- `.ui` 里**没有** 1280/720 浮点常量、没有左下角像素/归一化位置对
  → 节点位置要么是锚定+相对偏移（PositionOffset 即此），要么在节点记录里以
  其他形式存（待 §3.2 破解节点记录后确认）

## 五、运行时接入点（main NSO）

| 接入点 | 地址 | 证据 |
|---|---|---|
| .ui 分块/记录解析器（候选） | `0x4AE810` | 被 0x74C470 两次调用，参数 `(buf, len, ?, 0xC, &out, ?, 0x3E8)`；管理全局 vector（0x7D98/0x7DA0/0x7DA8） |
| 0xDEADBEEF 构造（对齐） | `0x74C7F0`（函数头 0x74C470） | movz/movk x8；全 text 唯一对齐命中 |
| H2OLayout: 错误/事件报告 | `0x3CE700`（10 路 switch）、0xBFF50 等 | `H2OLayout:<名>` 字符串 34 处、ADRP+ADD xref 13 处，抽查均为报告路径 |
| 脚本 VM 全局表初始化 | `0x3C619C` 一带 | UI_SkillWalk_OnClick 注册；intern 调用 0xA49690 |
| 触屏读取 | `0x1B65260` | `nn::hid::GetTouchScreenStates`（16 点，面板坐标 **1280×720 常量**，Start/End 属性）；宿主 hle_touch.c 已实现合成 |
| UI 投影（尺寸全局） | 写 0x29A2F4 / 投影 0x29B8C8 / 全局 0x264F0-F4 | mobile_graphics_profile unicorn 验证 |

## 六、触控相关结论（汇总自触控记录，此处为 UI 视角）

1. **没有鼠标消息注入**（D2R 捷径不存在的实证见触控记录 §3.1）
2. **导航是焦点/环**：方向键挪高亮 + A 确认；环形菜单（`RingGlow.Cursor` 节点群，
   `ConsoleInventoryRing_main.LayoutRoot.InventoryRing.RingGlow.Cursor` 等 25+ 处）
   用摇杆转圈选——**没有全屏软指针**（cursor_hand_* 纹理是世界光标的）
3. **触屏 API 完整保留**且宿主已接通（hle_touch.c → 游戏 0x1B65260）；
   游戏内部哪些面板消费触摸 = 待真机观察（`DM_TOUCH_LOG=1`，启动器已有开关）
4. UI 事件的脚本 VM 形态（§4.2）→ 「程序化点击」候选：按名字调 `UI_*_OnClick`

## 七、HUD 移位实施方案（约束已定）

**约束**（用户确认）：物理手柄接入时 HUD 必须恢复原位——与虚拟手柄随物理手柄隐藏/
出现同一触发（`dm_gamepad_start` 的 on_present / `dm_pad_set` 有无）。因此**不做
静态 .ui 改写**（改死了回不来），**只走运行时节点位置改写**：

```
触摸模式（无物理手柄）：
  每帧（或 ui_gen 变化时）把目标节点位置写为上角值
手柄模式（物理手柄连接）：
  写回 .ui 原始值（或直接不写，让游戏自持）
切换瞬间：一次写回
```

待完成链路：
1. 节点记录结构（§3.2）→ 找到 PositionOffset/位置字段在记录内的偏移
2. 运行时定位节点：按节点路径在内存中找对应记录（内存搜路径字符串的运行时副本 →
   引用结构 → 节点本体）；d2r 的 dm_wref/界面代号机制防悬垂指针（跨帧缓存必须带代号）
3. 宿主模块（拟 `dm_hudmove.c`）：每帧检查手柄 presence → 写/还原位置；
   写值来源 = 启动器配置（左上/右上偏移量）
4. 验收：iPad 触摸模式四角 HUD 上移；插手柄原位；拔手柄再移位

## 八、暂缓项（记录待续）

- **菜单/背包快捷键**：包=+、单=− 已实测定标（30cd774）；进一步减按钮（低频键隐藏）
  等触摸成熟后做
- **触控 v2**（世界光标直写 / UI 脚本 VM 点击）：路线见《移动端触控适配设计与实施.md》§三
- **触摸面板响应范围**：等 DM_TOUCH_LOG 真机数据

## 九、复现命令

```bash
# 抽 .ui（397 个）
cd dr3-mobile && python -I _scratch/dump_ui.py
# 批量普查（头/目录/属性名/事件名/路径）
python -I tools/h2o_survey.py
# 单文件结构摘要
python -I tools/h2o_parse.py _scratch/ui/ConsoleHUD.ui
# main NSO 解压（字符串/xref 分析前置）
python -I ../_tools/decomp_nso.py "../game_resources/解包资源/ExeFS/main" ../_scratch/d3_main.bin ../_scratch/d3_main.json
```
