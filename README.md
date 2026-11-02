# devshell-collection

一组 Nix flake 开发环境：**一个源码库一个 devShell**，所有环境共用同一份 `flake.lock`。
目标是 不用容器，也不用改宿主系统。

## 包含的环境

| devShell | 源码库 | 说明 | 文档 |
|---|---|---|---|
| `.#default` / `.#openwrt` | OpenWrt buildroot | 宿主编译环境（bubblewrap FHS）。`prereq` → `tools` → `toolchain` → 全量 `make` 已验证跑通并产出镜像 | [openwrt.md](docs/openwrt.md) |
| `.#openwrt-bare` | 同上 | 不带 FHS 的轻量版，支持 `--command` | [openwrt.md](docs/openwrt.md) |
| `.#openwrt-gcc-latest` | 同上 | 同上，换成 nixpkgs 当前的 gcc | [openwrt.md](docs/openwrt.md) |
| `.#cross-aarch64` | 任意 | nixpkgs 的 aarch64+musl 交叉工具链 + qemu，脱离 buildroot 用 | [cross-aarch64.md](docs/cross-aarch64.md) |
| `.#pyins-el7` | 单个 Python 应用 | PyInstaller onefile，产物要求 glibc ≤ 2.17（CentOS/RHEL 7） | [见下](#单文件打包pyinstaller-onefile) |
| `.#cxx` | 任意 C/C++ 项目 | 干净的头文件环境 + clangd 编译数据库（`gen-cdb`），与路径无关 | [见下](#cc-项目clangd) |

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

## C/C++ 项目（clangd）

`lib/cxx-clangd.nix` 是给普通 C/C++ 项目用的模板，`.#cxx` 是它的实例。它与具体路径无关：
**`APP_DIR` 默认就是「进入 shell 时的当前目录」**，所以直接在你项目里 `nix develop` 即可；
要指向别处再显式设 `APP_DIR`。

除了 gcc/make/pkg-config/bear/clang-tools 和项目要链接的库，它专门处理编辑器里 clangd 的
老问题 —— 这些都不是 `nix develop` 会替你做的：

- **清掉外层泄漏的 `CPATH` / `CPLUS_INCLUDE_PATH` / `C_INCLUDE_PATH`**：`nix develop` 只覆盖
  derivation 里定义过的变量，外层导出的会原样传进来。一旦它们指向另一个 C++ 标准库
  （比如 libc++），`<set>` 拉进来的 `<cctype>` 就会报
  "tried including <ctype.h> but didn't find libc++'s <ctype.h>"。
- **`LC_ALL=C.UTF-8`**：clangd 靠解析 `g++ -v` 的输出找系统头，中文 locale 会让它找不到
  标记（"start marker not found"）。
- **`gen-cdb`**：全量重编一遍（`make -C src -B -j$(nproc)`，传自己的 `-j` 可覆盖），
  用 bear 记录每条实际执行的编译命令，在源码树根生成 `compile_commands.json` —— clangd 的
  编译数据库（C/C++ 混编只能靠 CDB，`compile_flags.txt` 做不到按文件区分语言）。
  带 `-B` 是必须的：make 无事可做时一条编译命令都记录不到，CDB 会只剩链接那一条。
  生成后还会把 `g++ -v` 里的系统头目录展开成 `-isystem` 写进每条命令 —— 这样 clangd
  **不需要** `--query-driver`、也不受编辑器进程 locale 影响。
  同时补一份 `.clangd`（已有则不动），把 `*.h` 按 C++ 解析 —— 否则 clangd 会拿最近的
  CDB 条目推断语言，抓到 `cJSON.c` 这种 C 条目，头文件里的 `<set>` 就找不到。

**目标是 el9（glibc 2.34）的部署产物**，所以编译器和库都来自 `nixpkgs-el9`
（`nixos-22.05`：gcc 11.3、glibc 2.34、`libevent 2.1.12`、`libsodium 1.0.18`、
`libjwt 1.13.1`、`rabbitmq-c 0.11.0`），链接参数里固定了
`--dynamic-linker=/lib64/ld-linux-x86-64.so.2`，否则 PT_INTERP 会指向 nix store 里的 ld。
工具（clangd/bear/jq）仍取自 `nixos-unstable`，新 clangd 才认 `.clangd` 的 `If` 条件。

产物的符号上限是 **GLIBC_2.34**，NEEDED 是 `libevent-2.1.so.7` / `libjwt.so.1` /
`librabbitmq.so.4` / `libsodium.so.23` —— 正好都是 el9 上能装到的那几个版本。
换目标系统时改 `nixpkgs-el9` 这个 input 和 `dynamicLinker` 参数。

默认还带了 `extraCFlags = "-O0"`：nixpkgs 的 stdenv 会往 `NIX_CFLAGS_COMPILE` 里塞
`-O2 -fPIC -fstack-protector-strong`，而这类项目的 Makefile 通常只写 `-g`（等于 `-O0`）。
不压回去的话，产物比在 el9 上用 `gcc` 直接编的大 60% 以上（**全是 -O2 带来的调试信息**，
代码段反而更小），运行行为也和一线上编译的不一致。这个参数是通用的，别的项目
想要 `-O2` / `-g3` / `-gz` 都从这里传。

用法：

```bash
cd ~/work/some-cpp-project          # APP_DIR 默认取当前目录
nix develop ~/Projects/devshell-collection#cxx
make -C src -j8                     # 构建目录由 buildSubdir 决定（默认 src）
gen-cdb                             # 生成/更新 compile_commands.json 和 .clangd
```

换个项目时不用改 flake：`cd` 过去再 `nix develop …#cxx` 就行；构建目录不是 `src` 的
项目，在 `flake.nix` 里传 `buildSubdir`（或另建一个实例）。

CDB 里已经带了系统头路径，所以编辑器侧不配 `--query-driver` 也能用。想更稳（比如项目
还没跑过 `gen-cdb`）可以再加一层：`--query-driver=**` 让 clangd 自己去问 `g++`，同时
保证 clangd 进程的 locale 是 C（它靠解析 `g++ -v` 的英文输出提取系统头，中文 locale 下
gcc 打印「使用内建 specs。」就会失败，日志里是 `start marker not found`）—— 或者直接从
这个 shell 里启动 nvim，shellHook 已经设好 `LC_ALL` 并清掉了 `CPATH` 那几个变量。

## 约定

- 路径类变量统一用 `*_DIR`（`OPENWRT_DIR`、`PYINS_EL7_DIR`…），都有默认值，可被环境变量覆盖。
- 所有环境共用一份 `flake.lock`：`nix flake update` 一次全动，避免不同环境跑在不同 nixpkgs 上。
- 环境细节放 `lib/`（`openwrt.nix`、`python-onefile.nix`、`cxx-clangd.nix`），
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
