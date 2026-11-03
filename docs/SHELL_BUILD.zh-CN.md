# 壳构建与本地做包（无需 Xcode 出安装包）

English summary: `tools/shell_build.py` (CI, needs Xcode but no game files) builds the unsigned
game-content-free shell; `tools/dr3_pack.py` (your machine, needs your game files but no
Xcode/Mac) fills it with your rewritten game program and shader sources; you then sign the
result with a sideloading tool. Shaders are compiled on device at first launch and cached.

## 原理

壳 = 编译好的宿主与 iOS 前端、**不含任何游戏内容**的未签名安装包（构建原料，不能直接装）。
缺的东西列在壳内 `dm/shell_manifest.txt`，版本指纹在 `dm/shell_info.txt`。四个部分：

1. **模块映像**：壳的可执行文件里没有游戏程序。`dr3_pack.py` 用 `patch_nso.py` 改写你的
   `main`/`sdk`，经 `tools/guest_dylib.py` 写成一个只装段的动态库
   `Frameworks/Guest.framework/Guest`（节名与内嵌做法相同）。装载器经
   `dm_set_game_image_header`（nxnative 内建接口）从这个动态库取节
   （`platform/ios/Sources/main.m` 的 `DM_SHELL` 分支负责加载并交出映像头）。
2. **着色器**：壳里没有着色器库。`dr3_pack.py` 按「没有苹果编译器」模式跑出库链
   (`tools/nometal_run.py`)，「库文件」里放的是翻译出的 MSL 源码；壳的图形层
   （`patches/shell.patch` 的 `DM_SHELL` 分支）发现库不是编好的（无 MTLB 头）就在设备上现编，
   系统缓存后第二次启动起不再编。实测同类机制（d2r-mobile）：冷启动平均约 80 ms 一个着色器。
3. **图形表与资源清单**：`c1_full.tsv`（着色器构建产物）、`mobile-graphics.json`（画像证明）、
   `private-assets.json`（你的 RomFS/DLC 清单，App 启动时按它核对文件齐不齐）。
4. **占位表**：`shader_map.tsv` 等随仓库的占位表直接留在壳里（它们不是游戏衍生内容）。

## 出壳（CI，也可在 Mac 本地跑）

GitHub Actions：`.github/workflows/shell-build.yml`（手动触发或推 `shell-v*` 标签出 Release）。
本地（Mac + Xcode 26+，不需要游戏文件）：

```sh
make bootstrap                                  # 克隆并打补丁 nxnative
python3 tools/shell_build.py --out work/shell   # 产出 work/shell/DR3Mobile-shell-build-input.zip
```

产物：`DR3Mobile-shell-build-input.zip`（未签名）+ `shell_manifest.txt`。

## 做包（你自己的电脑：Windows / Linux / Mac 都行）

前置：Python 3.12+（`pip install -r requirements.txt`）、.NET SDK、spirv-cross、
已跑过 `tools/dr3.py bootstrap`，以及你自己的游戏文件
（Switch 版 2.7.7.92380 的 Update 目录：`ExeFS/{main,sdk}` + `RomFS/…`）。

```sh
python3 tools/dr3_pack.py DR3Mobile-shell-build-input.zip <Update 目录> DR3Mobile.ipa
```

慢的两步：改写等价验证（Unicorn，`--skip-verify` 可跳但建议保留）与全部着色器翻译。
成功后 `DR3Mobile.ipa` 用 Sideloadly / AltStore 签名装机；首次启动每个着色器现编，
会停在「正在准备着色器」一段时间，属正常。

## 与正常构建（`tools/build_ios.py`）的差异

| | 正常构建 | 壳构建 |
|---|---|---|
| 模块映像 | `gen_embed.py` 嵌进可执行文件 | `guest_dylib.py` 出 `Frameworks/Guest.framework`，运行时 `dlopen` |
| 着色器 | Mac 上用 iphoneos SDK 预编成 metallib | 源码进包，设备上现编（`DM_SHELL` 分支） |
| 宽屏画像 | 双映像嵌入，启动可选 | **不支持**（Guest v1 只带一份 `main`；`startup_selection=false`） |
| 图标 | 游戏图标 | 自绘占位图标 |
| 游戏文件 | 必需 | 出壳不需要；做包时必需 |

## 约束

壳与其构建产物不含、也不得含任何游戏内容（CI 的 `source-check` 与壳构建里的自检都会查）。
`dr3_pack.py` 的产物含游戏内容，只自用、不分发。版本强校验：壳的 `BUILD`/`PATCH`/`CHAIN`
指纹与你的仓库、游戏文件对不上会当场拒绝，不能绕过。
