# 出包流程（CI → 本机 repack → ipa）

> 适用：改动了 `third_party/nxnative`（宿主）或 iOS 壳代码后，从 CI 产物在本机打出可装机 ipa。
> 配套文档：`BUILD.md`（游戏文件怎么导出）、`SHELL_BUILD.zh-CN.md`（壳构建是什么）、`GAME_FILES.md`（红线：游戏资源与密钥不入库）。

## 0. 约定

- **CI 绿 = 直接出包**（本项目的既定工作流）。
- 出包口径：`--skip-verify`（占位宽屏画像、普通 16:9 启动）；完整验证口径见 §4 坑 6。
- 产物命名建议：`DR3Mobile-<分支/主题>-<MMDD>-<N>.ipa`；坏包改名加 `-BAD-<原因>` 留档。
- 装机：Sideloadly / AltStore 自签安装；首次启动停在「正在准备着色器缓存」属正常（设备上现编）。

## 1. 一次性前置

| 项 | 要求 |
|---|------|
| Python ≥3.12 + 依赖 | `pip install -r requirements.txt`（pillow numpy lz4 capstone unicorn fonttools） |
| .NET SDK | 着色器翻译工具（dmsh_xlate）编译用 |
| spirv-cross | **必须在 PATH**（预检硬性要求；装好后确认 `spirv-cross --version` 可跑） |
| gh CLI | 已登录（触发 CI、下载 artifact） |
| bootstrap | `python3 tools/dr3.py bootstrap` 跑过一次（生成 `work/` 工作缓存与改写产物） |
| 游戏源目录 | 你自己的 Switch 2.7.7.92380 Update 导出目录（内含 `ExeFS/{main,sdk}` 与 `RomFS/`；导出方法见 `BUILD.md`）。**不区分本体/更新叠加时以 Update 最终态为准** |

## 2. 全流程（8 步）

### 步骤 1 · 补丁重出（改动了 third_party/nxnative 之后必做）

nxnative 目录被 `.gitignore`，它的改动进 CI 的**唯一载体**是 `patches/nxnative.patch`。

```bash
cd third_party/nxnative          # HEAD 必须仍是净基线（单提交 pinned snapshot）
git add -A && git reset -q -- dm/games dm/verify
git diff --cached > ../../patches/nxnative.patch
git reset -q                     # 恢复工作区原状（nxnative 本身不提交）
```

**文件集规则**（多退少补都是事故）：
- 排除 `dm/games/<TITLE>*/`：CI 由 `tools/dr3.py` 从本仓库 `config/<TITLE>/game.tsv` 注入游戏档案，本地这份是 bootstrap 运行产物（`-rmv` 后缀目录是重命名残渣）；
- 排除 `dm/verify/`：`patch_nso.py` 不依赖它；
- 其余全部进（**含未跟踪新文件**）：`git add -A` 就是为此。

### 步骤 2 · 补丁三重验证

```bash
# ① 净树 apply：把 third_party/nxnative-s9579030.zip 解到全新空目录，dry-run + apply
patch -p1 --dry-run -s -i patches/nxnative.patch && patch -p1 -s -i patches/nxnative.patch
# ② 逐字节比对：补丁涉及的每个文件（diff 头 +++ b/ 行）与 nxnative 工作区同名文件 sha256 相等
# ③ 提交后复验：git show HEAD:patches/nxnative.patch 的 blob 再做一次 ①（防 CRLF 污染）
```

### 步骤 3 · 提交（仓库根）

```bash
git add patches/nxnative.patch <其余改动>
git commit -m "<域>: <一句话>——<要点分列>"
# Windows 用户：提交后用仓库 blob 覆写本地补丁文件，保证换行指纹与 CI 检出一致（见 §4 坑 4）
git show HEAD:patches/nxnative.patch > patches/nxnative.patch
git push origin <分支>
```

### 步骤 4 · 触发 CI（push 不会自动触发）

`shell-build.yml` 只认 `shell-build` 分支 / `workflow_dispatch` / `shell-v*` tag，其它分支推完必须手动点：

```bash
gh workflow run shell-build.yml --ref <分支>
sleep 5 && gh run list --workflow=shell-build.yml --limit 1     # 拿 run id
gh run watch <run_id> --exit-status --interval 20               # 退出码 0 = 绿
```

产物：`DR3Mobile-shell-build-input` artifact（无签名、不含游戏内容的壳构建原料）。

### 步骤 5 · 下载 artifact（每次新目录）

```bash
gh run download <run_id> -D <你的产物暂存目录>
```

### 步骤 6 · 出包

```bash
python3 tools/dr3_pack.py \
  <暂存目录>/DR3Mobile-shell-build-input/DR3Mobile-shell-build-input.zip \
  <你的游戏源目录> \
  <输出.ipa> \
  --icon <自备图标.png> --skip-verify
```

- `game_dir` = 游戏源目录（步骤 1 表）；**绝不能传本仓库的 `work/game`**（那是工具自己的工作目录）；
- 缓存全走约 40s；若补丁改了 main 改写相关内容会重跑改写+验证，需数分钟；
- 日志「链版本重写 … → …」是装配期正常步骤（把壳里的链版本常量改成本机真实口径），不是报错。

### 步骤 7 · 产物验证（装机前必做）

宿主代码在 **App 主二进制**（`Payload/<App>.app/<App>`），不在 Guest.framework（那里是客体镜像 main+sdk）：

```bash
python3 - <<'EOF'
import zipfile
ipa = zipfile.ZipFile("<输出.ipa>")
data = ipa.read("Payload/DR3Mobile.app/DR3Mobile")
for k in (b"<本轮新增的特征串1>", b"<特征串2>"):   # 例如新增功能的日志串/文件名/键名
    n = data.count(k); print(k, "->", n); assert n > 0
print("PASS")
EOF
```

有条件时与上一版 ipa 对比（旧包应 0 命中）。

### 步骤 8 · 交付记录

把真机验收清单随包记入项目文档；坏包改名留档不删。

## 3. 产物结构速查

| 路径（ipa 内） | 内容 |
|---|---|
| `Payload/DR3Mobile.app/DR3Mobile` | **宿主二进制**（dm/hle 全部逻辑；产物验证在这里做） |
| `Payload/DR3Mobile.app/Frameworks/Guest.framework/Guest` | 客体镜像（改写后的 main+sdk） |
| `.../skin/`、`.../skin/skills/` | 皮肤与技能图标备料 |
| `.../dm/*.tsv` | 改写元数据表（gates/cuts/obs…） |

## 4. 坑速查表（现象 → 原因 → 修法）

| # | 现象 | 原因 | 修法 |
|---|------|------|------|
| 1 | 补丁缺文件 / CI 净树找不到文件 | 未跟踪文件不进 `git diff` | 重出时 `git add -A` 后 `diff --cached` |
| 2 | 补丁混入 games/verify 等多余文件 | 本地 bootstrap 运行产物混入 | 重出时显式 `git reset -- dm/games dm/verify` |
| 3 | 预检「缺 spirv-cross」 | 不在 PATH | 安装并确认 `spirv-cross --version` |
| 4 | 预检「壳出的时代与本地 patch 不同」 | Windows 工作区补丁 CRLF ≠ 仓库 blob LF | 提交后 `git show HEAD:patches/nxnative.patch > patches/nxnative.patch`；**每次重出补丁后例行做** |
| 5 | `copyfile SameFileError: work/game/ExeFS/main` | game_dir 传成了工具自己的工作目录 | 传你自己的游戏源目录 |
| 6 | `D3 graphics requires successful exact-profile rewrite verification` | 完整模式要求全量 `work/verification.json`（Unicorn 等价验证产物） | 定案口径：出包带 `--skip-verify`；要切完整模式先删旧 verification.json 让等价验证重跑 |
| 7 | 在 Guest.framework 搜宿主字符串 0 命中 | 搜错文件 | 宿主代码在 App 主二进制 |
| 8 | nxnative HEAD 不是净基线 | 有人往 nxnative 仓库提交过业务改动 | 以 pinned zip 重建净基线再重出补丁 |

## 5. 红线

- 游戏文件、密钥、XCI/NCA 解包产物**永不入库**（`GAME_FILES.md`）；出包只在本机读它们。
- 打出的 ipa 含游戏内容，仅自用，不分发。
