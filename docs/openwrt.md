# OpenWrt buildroot（NixOS 原生）

在 NixOS 上**原生**编译 OpenWrt buildroot：用 bubblewrap 拼一个 FHS 运行环境，
不需要 Docker 容器，也不用改动宿主系统。

- 已验证版本：OpenWrt 23.05，目标 `mediatek/filogic`（`aarch64_cortex-a53` + musl）。
  `make prereq`、`make tools/compile`、`make toolchain/compile` 和全量 `make` 都能在这个环境里跑完并产出镜像。
- 目标工具链由 buildroot 自建（`aarch64-openwrt-linux-musl-gcc`），本环境只负责**宿主**编译环境。

## 快速开始

```bash
nix develop .#openwrt     # 等价于 nix develop
```

源码树默认在 `$HOME/work/openwrt-src`，进入环境前用 `OPENWRT_DIR` 可以覆盖。进去以后：

```bash
cd "$OPENWRT_DIR"
make defconfig
make -j"$(nproc)" V=s
```

脚本 / CI 里要非交互执行，用包装器（FHS 的 devShell 不透传 `--command`）：

```bash
nix run .#shell -- -c 'cd "$OPENWRT_DIR" && make prereq'
```

## 有哪些 shell

| 入口 | 说明 |
|---|---|
| `nix develop .#openwrt`（= `.#default`） | 交互式主环境：`buildFHSEnv` + gcc13，编 buildroot 用它 |
| `nix develop .#openwrt-gcc-latest` | 同上，换成 nixpkgs 当前的 gcc，用来试新版本 |
| `nix develop .#openwrt-bare` | 不带 FHS 的轻量环境，支持 `--command`，只适合跑不依赖 `/bin/sh` 的东西（perl/gcc/python 探测、脚本 lint） |
| `nix develop .#cross-aarch64` | nixpkgs 的 aarch64+musl 交叉工具链 + qemu，仅用于脱离 buildroot 快速验证代码能否为 aarch64 编过 |
| `nix run .#shell -- -c '…'` | 非交互入口（`packages.shell`），CI 用 |

## 和 direnv 的关系

**FHS 环境不能交给 direnv / nix-direnv。** 原因是 `devShells.openwrt` 的 shellHook 本身就是
`exec bwrap` 起一个交互 shell：direnv 在计算环境时会执行 shellHook，于是它永远等不到返回
（终端上表现为反复输出 `direnv: (…) is taking a while to execute`）；而 bwrap 里新起的 bash
继承了 `DIRENV_*`，prompt 一到又重新加载同一个 `.envrc`，一路自我嵌套，最后内核/ bwrap 拒绝：

```
bwrap: Creating new namespace failed: nesting depth or /proc/sys/user/max_*_namespaces exceeded (ENOSPC)
```

修复办法：

1. 本仓库**不带** `.envrc`，也不要把 `.envrc` 指向 `.#openwrt`。

2. 进构建环境：自己 `cd` 到源码树，再用 `nix develop` 指到本仓库
   （当前目录就在 flake 仓库里时写 `.#openwrt` 也一样）：

   ```bash
   cd ~/work/openwrt-src
   nix develop ~/Projects/devshell-collection#openwrt
   ```

3. 已经套娃了（`echo $SHLVL` 很大、`pgrep -c bwrap` 很多）：

   ```bash
   pkill -u "$USER" -f 'bwrap .*openwrt-buildroot'   # 收掉所有 FHS 终端
   # 然后重开终端；确认 pgrep -c bwrap 归零
   ```

   `user.max_user_namespaces` 一般不是瓶颈（Fedora 默认 25 万+），真正卡住的是嵌套层级和
   这些没退出的 bwrap 实例。

## 为什么必须是 FHS 环境

OpenWrt buildroot 硬依赖一批固定路径，NixOS 上默认没有：

| buildroot 的假设 | NixOS 现状 | 这里的解法 |
|---|---|---|
| `/bin/sh`、`/usr/bin/env`（大量 `#!/bin/sh` 脚本） | 不存在 | `buildFHSEnv`（bubblewrap）拼出 FHS |
| `/usr/include`、`/usr/lib`（configure 探测、`-lncurses`） | 不存在 | 同上，`NIX_CFLAGS_COMPILE` / `NIX_LDFLAGS` 指向 `/usr` |
| `-Wl,-Bstatic -lz`（host tools 静态链接 zlib） | nixpkgs 的 zlib 默认没有 `libz.a` | 额外装 `zlib.static` |
| 直接调用 `awk` / `python` / `egrep` | 包名与命令名对不上 | 补 wrapper（`gawk`、`python3`、`grep -E`） |
| `pkg-config --exists zlib` 找不到 | FHS 只把 `/usr/lib/pkgconfig` 放进搜索路径 | `PKG_CONFIG_PATH` 再补 `/usr/share/pkgconfig` |

## 环境里有什么

依赖清单以 OpenWrt 自己的 `include/prereq-build.mk` 为准（它才是权威清单），
再参考常见发行版的构建依赖补齐宿主工具：

| 类别 | 包 |
|---|---|
| 编译器 | `gcc13`（默认）/ `gcc`（`.#openwrt-gcc-latest`）、`binutils` |
| 构建系统 | `gnumake` `bison` `flex` `cmake` `ninja` `pkg-config` |
| 必需 GNU 工具 | `bashInteractive` `coreutils` `findutils` `gnugrep` `gawk` `gnused` `gnutar` `patch` `diffutils` `which` `util-linux`（getopt）`file` `bc` |
| 压缩归档 | `gzip` `bzip2` `xz` `zstd` `unzip` `cpio` `rsync` |
| 网络 | `wget` `curl` `cacert` `git` `subversion` |
| 语言 | `perl`（`Thread::Queue` 等均为 core 模块）、`python3` + setuptools（补回 distutils） |
| 库 | `ncurses`（menuconfig）、`openssl`、`zlib` + `zlib.static`、`elfutils` |
| 其它 | `gettext` `swig` `tzdata` `glibcLocales` |

**为什么默认 gcc13**：GCC 14 起 `-Werror=implicit-function-declaration` 默认开启，
OpenWrt 23.05 里那批老 configure 探测脚本很容易直接编译失败；想试新版本用 `.#openwrt-gcc-latest`。

**为什么 host tools 加 `-Wno-error`**：新 glibc/gcc 对 2023 年的代码更严格，而 buildroot 的
host tools 大多自带 `-Werror`。例如 `tools/elfutils` 0.189 的 `libcpu/riscv_disasm.c`：glibc 2.38
起 `_GNU_SOURCE` 也会打开 C23 语义，`bsearch` 变成 const-generic 宏，对 const 数组查询时返回
`const void *`，于是 `initialization discards 'const' qualifier` 被 `-Werror` 顶成错误。环境在
`NIX_CFLAGS_COMPILE` 末尾追加 `-Wno-error`：警告照旧打印，只是不再中断编译；目标端不受影响，
那是 buildroot 自建的工具链在编，不经过 nix 的 cc-wrapper。

## 交叉编译怎么处理

关键点：**buildroot 自己造交叉工具链**（`toolchain/` 阶段从源码编 binutils/gcc，产出
`aarch64-openwrt-linux-musl-gcc 12.3.0`）。所以宿主只需要一个能用的 x86_64 gcc，**不要**把
nix 的交叉编译器塞进去，否则会污染 buildroot 的 `CONFIG_*` 探测结果。

`.#cross-aarch64` 是另一件事：在 buildroot 之外快速验证「这段代码能不能为 aarch64+musl 编过」，
或者用 `qemu-aarch64` 跑产物：

```bash
nix develop .#cross-aarch64
aarch64-unknown-linux-musl-g++ -std=c++11 -c foo.cpp -o foo.o
qemu-aarch64 -L "$(dirname "$(aarch64-unknown-linux-musl-g++ -print-file-name=libc.so)")" ./app
```

## 排错

| 症状 | 多半是 |
|---|---|
| configure 报 `cannot run C compiled programs` | 交叉编译器混进了 buildroot，或 `CC` 被宿主环境覆盖 |
| `undefined reference to …` 且是 host 库 | 缺静态库，参照 `zlib.static` 的做法补 |
| `make: /usr/bin/env: No such file or directory` | 某条命令没在 FHS 环境里执行 |
| `… discards 'const' qualifier [-Werror=…]` 这类「新警告变错误」 | 新工具链对老代码更严格；环境已统一降级 `-Wno-error`，若仍失败说明是真正的错误 |
| `staging_dir/host` 里的程序报 `No such file or directory` 但文件明明存在 | 那是别的发行版编出来的产物，动态链接器路径不匹配，用当前环境重新编 |

## 与已有方案的关系

对照过 [Mic92 的 OpenWrt nix-shell 配方](https://gist.github.com/Mic92/200f9811f218058ae66b0946f781ec33)
（以及它的维护版 [nix-community/nix-environments](https://github.com/nix-community/nix-environments/tree/master/envs/openwrt)）。
下面几条在 FHS 方案里同样成立，已采纳：

- `hardeningDisable = "all"` —— 这里用 `NIX_HARDENING_ENABLE=` 达到同样效果，避免 nix 的 cc-wrapper
  往 buildroot 的编译里加 `-D_FORTIFY_SOURCE`、`-fstack-protector-strong`。
- `FAKEROOTDONTTRYCHOWN=1` —— bwrap 的 user namespace 里 `chown` 返回 `EINVAL` 而非 `EPERM`，
  不设的话 buildroot 的 fakeroot 在 `package/install` 阶段会带着错误退出。
- `bc` —— 内核的 `timeconst.bc` 生成 `timeconst.h` 时要调它。
- `python3` + setuptools —— 补回 Python 3.12 起被移出标准库的 distutils。

没照抄的部分：`NIX_LDFLAGS = "-lncurses"` 和 `zlibStatic`（FHS 的 `/usr/lib` 本来就在链接搜索路径里，
静态 zlib 用 `zlib.static` 输出）、`perlPackages.ThreadQueue` / `ExtUtilsMakeMaker`（在 nixpkgs 的
perl 里已经是 core 模块）。那份配方把依赖塞进 `nix-shell` 的 `stdenv`，而 buildroot 需要固定的
`/bin/sh` 等路径，所以这里必须走 `buildFHSEnv`。

## 参数（`lib/openwrt.nix`）

环境由模板生成，`flake.nix` 里只写参数。常用几个：

| 模板 | 参数 | 说明 |
|---|---|---|
| `mkFhsEnv` | `gcc` | 宿主编译器，默认 `pkgs.gcc13`；GCC 14+ 会把隐式函数声明当错误 |
| | `suffix` | 环境名后缀，多个 FHS 环境共存时用来区分 |
| | `extraPackages` | 额外宿主工具（项目自己需要的） |
| | `extraProfile` | 追加到 `/etc/profile` 末尾的内容 |
| `mkDevShell` | 同 `mkFhsEnv` | 直接产出 `.env`，给 `devShells` 用 |
| `mkBare` | `gcc`、`extraPackages` | 无 FHS 的轻量版本 |
| `mkCrossAarch64` | `target`、`qemuArch`、`withQemu` | 换目标平台时改这两个（`pkgsCross` 属性名 / qemu-user 可执行名） |

例如想再加一个"用 gcc12 编 OpenWrt"的环境：

```nix
openwrt-gcc12 = openwrt.mkDevShell { inherit pkgs; gcc = pkgs.gcc12; suffix = "-gcc12"; };
```

## 维护

```bash
nix flake update    # 升级 nixpkgs（会重编 FHS 环境）
nix flake check     # 求值检查
nix fmt             # nixfmt
```