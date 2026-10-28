# devshell-collection

一组 Nix flake 开发环境：**一个源码库一个 devShell**，所有环境共用同一份 `flake.lock`。
目标是在 NixOS 上开发 / 编译那些「假设自己跑在标准 FHS 或特定工具链里」的老项目 ——
不用容器，也不用改宿主系统。

## 包含的环境

| devShell | 源码库 | 说明 | 文档 |
|---|---|---|---|
| `.#default` / `.#openwrt` | OpenWrt buildroot | 宿主编译环境（bubblewrap FHS）。`prereq` → `tools` → `toolchain` → 全量 `make` 已验证跑通并产出镜像 | [openwrt.md](docs/openwrt.md) |
| `.#openwrt-bare` | 同上 | 不带 FHS 的轻量版，支持 `--command` | [openwrt.md](docs/openwrt.md) |
| `.#openwrt-gcc-latest` | 同上 | 同上，换成 nixpkgs 当前的 gcc | [openwrt.md](docs/openwrt.md) |
| `.#cross-aarch64` | 任意 | nixpkgs 的 aarch64+musl 交叉工具链 + qemu，脱离 buildroot 用 | [cross-aarch64.md](docs/cross-aarch64.md) |
| `.#pyins-el7` | 单个 Python 应用 | PyInstaller onefile，产物要求 glibc ≤ 2.17（CentOS/RHEL 7） | [见下](#单文件打包pyinstaller-onefile) |

## 用法

```bash
git clone git@github.com:handy-sun/devshell-collection.git
cd devshell-collection
nix flake show                 # 看看有哪些环境
nix develop .#openwrt          # 进入主环境（等价于 nix develop）
```

**FHS 类的环境不能交给 direnv**（`.#openwrt` 这一族）：nix-direnv 要执行 devShell 的
shellHook，而它的 shellHook 是 `exec bwrap` 起一个交互 shell —— direnv 永远等不到返回，
新 shell 又继承 `DIRENV_*` 重新加载，最后一路嵌套到
`bwrap: Creating new namespace failed: nesting depth ... (ENOSPC)`。
所以**本仓库不带 `.envrc`**。进构建环境的方式是：自己 `cd` 到源码树，再
用 `nix develop` 指到本仓库（不需要先 cd 进本仓库）：

```bash
cd ~/work/openwrt-src
nix develop ~/Projects/devshell-collection#openwrt
```

其它环境（`mkShell` 类，例如 `.#pyins-el7`）可以用 direnv：在源码库目录放
`.envrc`，进目录自动加载、离开自动还原：

```bash
# ~/work/some-app/.envrc
export PYINS_EL7_DIR="$PWD"
use flake /home/qi/Projects/devshell-collection#pyins-el7
```

## 单文件打包（PyInstaller onefile）

有些环境要产出**一个文件**发给很老的机器（例如 CentOS/RHEL 7，glibc 2.17）。
PyInstaller 的 `--onefile` 产物不是静态二进制，它动态链接构建机的 glibc —— 在
NixOS（glibc 2.4x）上直接用 nixpkgs 的 Python 编，产物会要求 `GLIBC_2.28+`，到目标机上
就是 `version 'GLIBC_2.28' not found`。

`lib/python-onefile.nix` 因此这么做：

- 解释器用 **python-build-standalone**（`uv python install`；它的 `x86_64-unknown-linux-gnu`
  构建按 glibc 2.17 基线编译），PyInstaller 自带的 bootloader 也是同一 manylinux 基线；
- venv 放在源码树外（`~/.cache/devshell-collection/<name>`），不污染仓库；
- 构建走项目自己的脚本，venv 在 `PATH` 上；
- 构建后检查产物最高的 `GLIBC_x.y` 符号版本，超过 `glibcBaseline` 直接失败 ——
  以后换 Python 或依赖时会在这里暴露，而不是等目标机报错。

用法（`.#pyins-el7` 是这个模板的一个实例）：

```bash
export PYINS_EL7_DIR=~/work/some-app     # 指到具体项目
nix develop .#pyins-el7
pyins-el7-build                          # 产物：$PYINS_EL7_DIR/dist/ 下最新的文件
```

基线参考：CentOS/RHEL 7 → `2.17`，8 → `2.28`，9 → `2.34`。

## 约定

- 路径类变量统一用 `*_DIR`（`OPENWRT_DIR`、`PYINS_EL7_DIR`…），都有默认值，可被环境变量覆盖。
- 所有环境共用一份 `flake.lock`：`nix flake update` 一次全动，避免不同环境跑在不同 nixpkgs 上。
- 环境细节放 `lib/`（`openwrt.nix`、`python-onefile.nix`），
  `flake.nix` 只负责拼装和传参数。
- `lib/python-onefile.nix` 是给「PyInstaller 单文件 + 老 glibc 目标」用的模板：解释器走
  python-build-standalone（按目标 glibc 基线编译），构建后自动校验产物的 GLIBC 符号版本，
  超出基线就失败。
- 新增一个环境：用现成模板（或在 `lib/` 里加一个）→ 在 `flake.nix` 的 `devShells` 里挂上 →
  在 `docs/` 补一页 → 更新上面那张表。

## 维护

```bash
nix flake update    # 升级 nixpkgs（FHS 环境会重编）
nix flake check     # 求值检查
nix fmt             # nixfmt
```
