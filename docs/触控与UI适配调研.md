# D3 移动端：UI 移位与技能释放调研记录

> 2026-11-03。任务：①全屏原生适配（参数槽，已实施）；②HUD（血条/技能/地图）移到屏幕上角；
> ③虚拟按键释放技能/拾取物品。

## 任务 ①：全屏适配（已实施，等真机验证）

- 客体侧：`patch_nso.py` PARAMS 加 D3 (2607a74f) 三对位点（0xe7858/60 KRES1 主机、
  0xe785c/64 KRES0 掌机、0xe7868/6c KASPECT 显示宽高比 float）——相邻 mov+movk 对改
  参数蹦床（键页 LDR），宿主每线程给值（`thread.c guest_thread_init`）。三处仅宿主剪口：
  16:9 约束谓词 0x29b480/84 → `mov w0,#0`/`ret`、贴图 full/half/quarter 比例 0xebb48 →
  `fmov s1,#1.0`。位点与 `tools/mobile_graphics_profile.py` 的 SITES 逐字一致（其 unicorn
  验证覆盖语义）。
- KASPECT 的 D3 语义与 D2R 不同：D2R 是"宽高比上限"（19/9 下限+柱边距），D3 是镜头
  直接输入（Perspective cot(vfov/2)/aspect）——`thread.c` 加 D3 分支：取掌机比例本身。
- 位点表为空时（旧包）行为完全不变（原常量仍编译在蹦床后的原指令里？不——蹦床 LDR
  键页，键页值由 loader 写 `g_keyres[i]`；宿主总写 16:9 原值 → Mac 行为不变）。
- iOS：`front_game_res()` 适配分支 = 高 720、宽 = 720×屏幕比例；布局 fit 天然铺满。
  可用性 = `mobile-graphics.json` 的 `runtime_aspect`（pack 检测 main.params.tsv 有数据行）。

## 任务 ②：HUD 布局移位（调研完成，实施待排）

**发现：D3 的 UI 是 H2O 数据驱动布局，`.ui` 文件在 CPK 里。**

- 证据：ExeFS 有 `HUD_main`、`H2OLayout:`、`ConsoleHUD_main.LayoutRoot.hp_bar_template`
  等字符串；`ClientCommon.cpk` 里有 397 个 `.ui`（`UI\ConsoleHUD.ui` 60KB、
  `ConsoleHUD_SinglePlayerFrame.ui`、`ConsoleMinimap.ui`、`ConsoleGameHUDMisc.ui` 等）。
- 运行时节点路径可直接读：`ConsoleHUD_main.LayoutRoot.hp_bar_avenger`（复仇者血条）、
  `LayoutRoot.PlayerSlots.Player1`（多人血条槽）、`hp_bar_bounty.progressbar` 等；
  锚点语义字符串 `Bottom`、`Stretch` 出现在节点属性中。
- **文件格式**：`deadbeef` 魔数 + 0x20 头 + 表结构。0x4=0x1e0（头大小）、0x10 疑似解压后
  大小（230979 > 文件 60544 → 数据压缩）、0x28 处起分块（chunk 头 24B：8B 哈希 + 大小 +
  疑似类型/压缩标志，0xd8=0x15118+0x14、0xf0=0x15130+0x49 两组），字符串池在文件尾部。
  zlib/deflate 不中——疑似 Oodle 或自研 LZ。**完全逆向 = 数天级**（分块解压 + 节点树
  序列化 + 重压缩 + 哈希重算）。
- 抽包脚本已可用：`_scratch/dump_ui.py`（StrictReader 遍历 CPK 条目）。

### 候选实施路线（按工作量）

1. **运行时内存补丁（推荐）**：H2O 布局加载后是内存节点树，宿主在布局加载返回处改
   目标节点（hp_bar/minimap/hotbar）的锚点/位置。需要逆向：H2O 节点内存结构（属性表）+
   布局加载完成点。工作量中等；风险低（不碰文件校验）。
2. **文件级重写**：逆向 .ui 压缩块格式 + 重算哈希，pack 产出改过的 .ui，HLE fs 对
   `Update/CPKs` 或读 .ui 的路径做重定向（app 内置补丁 CPK）。工作量大；最干净。
3. **屏幕尺寸全局欺骗（D2R dm_uiscreen 思路）**：改"屏幕宽高全局"骗 H2O 重排——但
   D3 的 UI 投影直接吃渲染尺寸（mobile_graphics_profile 已验证），没有独立 UI 尺寸全局
   的证据；0x264f0/0x264f4 是 UI 投影宽高（随渲染走），欺骗空间小。不推荐。

### 需要移动的元素（H2O 节点线索）

| 现位置 | 目标 | 节点线索 |
|---|---|---|
| 血球+经验条（左下） | 左上 | `hp_bar_template*`、`ConsoleHUD_main.LayoutRoot` |
| 技能条 hotbar（右下） | 右上 | `hotbar_1/2/3` 字符串 |
| 小地图（右下） | 右上 | `ConsoleMinimap.ui`、`minimap_dialog*` |
| 多人血条槽 | 随主条 | `LayoutRoot.PlayerSlots.Player1` |

注意：主机版 HUD（ConsoleHUD*）与 PC 版（GameHUD*.ui）并存，Switch 加载 Console 系。
触控布局可参考 `ConsoleControllerLayout_NX64.ui`（NX=Switch 手柄图例）。

## 任务 ③：技能释放（结论：链路已通，无额外逆向）

- 通路：`DmGamepad.m`（触摸 UI，两种布局 2D/3D 已有）→ `dm_input_set(buttons, lx, ly,
  rx, ry)` → `hle_hid.c:32` → 游戏。虚拟手柄已能操作游戏（真机截图证实）。
- **D3 是手柄驱动游戏**：技能 = 肩键/ABXY 绑定技能槽（游戏内按键设置可查），虚拟按键
  直接合成手柄键即可——与 d2r-mobile 不同（D2R 是鼠标驱动，需要触摸→光标全套）。
- 拾取/交互：世界光标写入（路线 B，`D3触控适配逆向调查记录.md` 已完成逆向：
  `0x89d960→0x8a0360→0x9a0370` 光标节点 xyz）+ A 键合成（已有）。
- 剩余工作是**布局编排**：游戏 HUD 移上角（任务②）后，下半屏留给虚拟手柄（技能键
  放拇指区、摇杆移动、点物品=光标+点击）。

## 下一步排序

1. 真机验证参数槽适配模式（iPad 原生比例渲染）
2. H2O 节点内存结构逆向（任务②路线 1）：找布局加载完成点 → 节点树 dump → 改锚点
3. 触控路线 B 实施：世界光标写入 + 触摸→光标映射（拾取物品）
4. 虚拟手柄 D3 专用布局（技能键标语音、摇杆/按键分区）
