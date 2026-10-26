# flake-owrt

在 NixOS 上**原生**编译 OpenWrt buildroot（不需要 Docker 容器）。
目标平台：`mediatek/filogic`，`aarch64_cortex-a53` + musl，工具链由 buildroot 自建。

> 现状：**宿主环境已就绪**（OpenWrt 的 `make prereq` 全部 41 项检查通过），
> 但还没在真实源码树上跑过完整的 `tools/` → `toolchain/` → 全量编译。
> 第一次真正开跑大概率还会缺东西，见文末「下一步」。

## 为什么必须是 FHS 环境

OpenWrt buildroot 硬依赖一批固定路径，NixOS 上根本没有：

| buildroot 依赖 | NixOS 现状 | 解法 |
|---|---|---|
| `/bin/sh`、`/usr/bin/env`（大量 `#!/bin/sh` 脚本） | 不存在 | bubblewrap 拼 FHS |
| `/usr/include`、`/usr/lib`（configure 探测、`-lncurses`） | 不存在 | 同上 + `NIX_CFLAGS_COMPILE` |
| `-Wl,-Bstatic -lz`（host tools 链接） | nixpkgs zlib 默认无 `libz.a` | 额外装 `zlib.static` |
| 命令名 `awk`/`python`/`egrep` | 包名对不上 | 补软链 wrapper |

所以 `devShells.default` 用的是 `buildFHSEnv`，不是普通 `mkShell`。

## 用法

```bash
cd ~/Projects/flake-owrt
nix develop            # 进入交互式 FHS 环境
```

进去以后：

```bash
cd $OPENWRT_DIR
make defconfig
make -j$(nproc) V=s
```

脚本 / CI 里要非交互执行，用包装器（`.env` 不透传 `--command`）：

```bash
nix run .#shell -- -c 'cd ~/work/openwrt-src && make prereq'
```

其它 shell：

```bash
nix develop .#bare          # 无 FHS 的轻量环境，支持 --command
nix develop .#cross-aarch64 # aarch64+musl 交叉工具链 + qemu（只用于验证产物，别拿来编 OpenWrt）
nix develop .#gcc-latest    # 用 nixpkgs 最新 gcc（16.x），默认是 gcc13
```

## ⚠️ 从 Docker 方案迁移过来，必须先清掉宿主构建产物

Docker 里（Ubuntu）编出来的 `staging_dir/host`、`staging_dir/toolchain` 都是
**动态链接 Ubuntu glibc 的 ELF**，在 FHS 里跑不起来（`/lib/x86_64-linux-gnu` 不存在）。
所以第一次用这个环境前必须重来：

```bash
cd ~/work/openwrt-src
rm -rf staging_dir build_dir bin tmp          # dl/ 保留，省下载
make defconfig
```

否则会看到莫名其妙的 `No such file or directory`（其实是动态链接器找不到）。

## 环境里有什么

依赖清单以 OpenWrt 自己的 `include/prereq-build.mk` 为准（比 Dockerfile 的 apt 列表更权威），
再对照 `owrt22/Dockerfile` 补齐：

| 类别 | 包 |
|---|---|
| 编译器 | `gcc13`（默认）/ `gcc`（可选），`binutils` |
| 构建系统 | `gnumake` `bison` `flex` `cmake` `ninja` `pkg-config` |
| 必需 GNU 工具 | `bashInteractive` `coreutils` `findutils` `gnugrep` `gawk` `gnused` `gnutar` `patch` `diffutils` `which` `util-linux`(getopt) `file` `bc`(内核 timeconst) |
| 压缩/归档 | `gzip` `bzip2` `xz` `zstd` `unzip` `cpio` `rsync` |
| 网络 | `wget` `curl` `cacert` `git` `subversion` |
| 语言 | `perl`（含 Thread::Queue 等 core 模块）`python3` + setuptools（补回 distutils） |
| 库 | `ncurses`(menuconfig) `openssl` `zlib` + `zlib.static` `elfutils` |
| 其它 | `gettext` `swig` `tzdata` `glibcLocales` |

**gcc 版本为什么默认 13**：GCC 14 起 `-Werror=implicit-function-declaration` 变成默认错误，
OpenWrt 23.05 里那批老 configure 探测脚本很容易直接挂。用 `.#gcc-latest` 可以试新的。

## 和 Mic92 那份 nix-shell 配方的关系

开工时对照了 [Mic92 的 OpenWrt nix-shell 配方](https://gist.github.com/Mic92/200f9811f218058ae66b0946f781ec33)
（以及它自己指向的维护版 [nix-community/nix-environments](https://github.com/nix-community/nix-environments/tree/master/envs/openwrt)），
下面几条在 FHS 方案里同样成立，已经采纳：

| 配方里的写法 | 为什么这里也要 |
|---|---|
| `hardeningDisable = "all"` | nix 的 cc-wrapper 会往每次编译里加 `-D_FORTIFY_SOURCE`、`-fstack-protector-strong` 之类；buildroot 里的老 configure 探测配上 `-Werror` 很容易直接挂。FHS 里用 `NIX_HARDENING_ENABLE=` 达到同样效果 |
| `FAKEROOTDONTTRYCHOWN=1` | bwrap 的 user namespace 里 `chown` 返回的是 `EINVAL` 而不是 `EPERM`，buildroot 的 fakeroot（tools/fakeroot 1.29）在 `package/install` 那一步会带着错误退出 |
| `bc` | 内核的 `timeconst.bc` 生成 `timeconst.h` 时要调 `bc`；buildroot 自己的 `tools/bc` 要等 tools 阶段编完才有 |
| `python3` + setuptools | 对应 owrt22 容器里的 `python3-distutils` + `python3-setuptools`；Python 3.12 起 distutils 已不在标准库 |

没照抄的：

- `NIX_LDFLAGS = "-lncurses"`、`zlibStatic`：FHS 的 `/usr/lib` 本来就在链接搜索路径里，
  静态 zlib 用 `zlib.static` 输出（nixpkgs 早把 `zlibStatic` 并回 `zlib`）。
- `perlPackages.ThreadQueue` / `ExtUtilsMakeMaker`：这两个在 nixpkgs 的 `perl` 里已经是 core 模块。
- LEDE 时代的 `asciidoc` `fastjar` `intltool` `jikespg` `cdrkit` `ruby` `sdcc`：
  `mediatek/filogic` 这个目标用不上，真需要再加。
- 配方是把依赖塞进 `nix-shell` 的 `stdenv`；这里必须走 `buildFHSEnv`，原因见上面「为什么必须是 FHS 环境」。

## 已验证

在 FHS 里逐条跑了 `prereq-build.mk` 的检查：**41 项全过**，包括

- `gcc`/`g++` 版本与可用性、`ncurses.h + -lncurses`
- `argp.h` `fts.h` `obstack.h` `libintl.h`
- GNU tar/find/bash/xargs/patch/diff/cp/seq/awk/grep/egrep/install
- `getopt --long`、`realpath`、`stat`、`file`、`which`
- perl 的 `Data::Dumper` `FindBin` `File::Copy` `File::Compare` `Thread::Queue`
- `python3 >= 3.6`（3.12+ 无 distutils，prereq 自动跳过该项）
- `umask 022`
- `pkg-config --modversion {zlib,openssl,libelf}`
- `-Wl,-Bstatic -lz` 静态链接
- `curl`/`wget` 走 HTTPS、`git ls-remote` 走 https

## 交叉编译怎么处理

关键认知：**buildroot 自己造交叉工具链**（`toolchain/` 阶段从源码编 binutils/gcc，
产出 `aarch64-openwrt-linux-musl-gcc 12.3.0`）。所以我们只需要提供一个能用的
**宿主** x86_64 gcc，**不能**把 nix 的 aarch64 交叉编译器塞进去，否则会污染
`CONFIG_*` 探测结果。

`.#cross-aarch64` 那个 shell 是另一个用途：在 buildroot 之外快速验证
「这段代码能不能为 aarch64+musl 编过」，或者用 `qemu-aarch64` 跑编出来的 `en`：

```bash
nix develop .#cross-aarch64
aarch64-unknown-linux-musl-g++ -std=c++11 -c foo.cpp -o foo.o
qemu-aarch64 -L $(dirname $(aarch64-unknown-linux-musl-g++ -print-file-name=libc.so)) ./en
```

## 下一步（预期会暴雷的地方）

按这个顺序试，出问题逐个补：

1. `make prereq` —— 应该全绿（已验证过等价检查）
2. `make tools/compile -j$(nproc) V=s` —— **第一个雷区**。buildroot 的 `tools/`
   会自己编一堆 host 工具（m4/bison/flex/pkgconf/patch/tar...），它们的 configure
   脚本假设标准 FHS，可能报「找不到 `/usr/bin/xxx`」或链接失败
3. `make toolchain/compile -j$(nproc) V=s` —— 编 gcc/binutils，耗时最长，
   可能因宿主 gcc 太新/太旧、或 `--with-native-system-header-dir` 相关而失败
4. `make -j$(nproc) V=s` —— 全量

常见症状与对策：

| 症状 | 多半是 |
|---|---|
| `No such file or directory` 但文件明明在 | ELF 动态链接器路径不对（旧的 Ubuntu 产物，见上文清理） |
| configure 报 `cannot run C compiled programs` | 交叉编进了 buildroot，或 `CC` 被环境覆盖 |
| `undefined reference to ...` 且是 host 库 | 缺静态库，参考 `zlib.static` 的做法补 |
| `make: /usr/bin/env: No such file or directory` | 某个脚本没走 FHS，检查是否在环境外执行 |
| `error: initialization discards 'const' qualifier [-Werror=discarded-qualifiers]` 这类**新警告被 `-Werror` 顶成错误** | 2026 年的 glibc/gcc 对 2023 年的代码更严格。**实际踩过的**：`tools/elfutils` 0.189 的 `libcpu/riscv_disasm.c` —— glibc 2.38 起 `_GNU_SOURCE` 也打开 C23 语义，`bsearch` 成了 const-generic 宏，对 const 数组查询时返回 `const void *`。环境里已经在 `NIX_CFLAGS_COMPILE` 末尾补了 `-Wno-error`（只影响用 nix gcc 编的 host tools，buildroot 自建工具链编的目标代码不受影响），警告照旧打印 |

## 维护

```bash
nix flake update          # 升级 nixpkgs（会重编 FHS 环境）
nix flake check           # 求值检查
nix fmt                   # nixfmt
```
