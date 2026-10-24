{
  description = "OpenWrt buildroot 交叉编译环境（NixOS 原生，不用容器）";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forEachSystem = f: nixpkgs.lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});

      # OpenWrt 有些 host 脚本还在用老式 setup.py / distutils（owrt22 容器里
      # 对应的就是 python3-distutils + python3-setuptools）。Python 3.12 起
      # distutils 已经不在标准库里，只能靠 setuptools 提供的垫片补回来。
      pythonFor = pkgs: pkgs.python3.withPackages (ps: [ ps.setuptools ]);

      # ------------------------------------------------------------------
      # 依赖清单
      #
      # 权威来源是 OpenWrt 自己的 include/prereq-build.mk（每条都会在
      # `make prereq` 时检查），owrt22/Dockerfile 里的 apt 列表只是它的近似。
      # 下面按 prereq 的检查项逐条对应到 nixpkgs 包名。
      # ------------------------------------------------------------------
      openwrtHostPackages =
        pkgs: with pkgs; [
          # --- 构建系统（编译器单独传，见 mkFhsEnv）---
          # 注意：主机编译器只用来编 buildroot 自己的 host tools。
          # 目标工具链（aarch64-openwrt-linux-musl-gcc 12.3.0）由 buildroot
          # 在 toolchain/ 阶段从源码自建，绝不能用 nix 的交叉工具链替代。
          binutils
          gnumake
          bison
          flex
          cmake
          ninja
          pkg-config

          # --- prereq-build.mk 显式检查的 GNU 工具 ---
          bashInteractive # bash --version | grep GNU
          coreutils # cp --help / seq / install / realpath / stat
          findutils # find --version、xargs -r
          gnugrep # grep / egrep
          gawk # awk（包内只有 gawk，awk 由下面的 alias 补）
          gnused
          gnutar # tar --version | grep GNU
          patch # patch --version | grep FSF
          diffutils # diff --version | grep GNU
          which # which which
          util-linux # getopt --long
          # 内核的 timeconst.bc 生成 timeconst.h 时要调 bc；
          # buildroot 自己的 tools/bc 得等 tools 阶段编完才有。
          bc
          file
          unzip
          gzip
          bzip2
          xz
          zstd
          cpio
          rsync
          wget
          curl
          cacert
          git
          gettext # msgfmt
          subversion # 部分 feed 走 svn://
          swig # OpenWrt 文档列出的依赖
          perl # 需 Data::Dumper / FindBin / File::Copy / File::Compare /
          # Thread::Queue —— 均为 core 模块，nixpkgs 的 perl 已自带
          (pythonFor pkgs) # 需 >= 3.6；带 setuptools，distutils 靠它垫
          ncurses # menuconfig 要 ncurses.h + -lncurses
          openssl # libssl-dev
          elfutils # libelf-dev
          # HOST_OS=Linux 时 buildroot 用 `-Wl,-Bstatic -lz -Wl,-Bdynamic`
          # 链接 host tools，必须提供静态 libz.a；nixpkgs 的 zlib 默认不带，
          # 所以把 static 输出单独装进来。dev 输出（zlib.pc）也要，
          # 否则 pkg-config --exists zlib 会失败。
          zlib
          zlib.static
          tzdata
          glibcLocales # 替代 Ubuntu 的 locale-gen en_US.UTF-8
        ];

      # buildroot 里有几处按硬编码命令名调用，nixpkgs 的包名对不上，补软链
      openwrtAliases =
        pkgs:
        let
          mkAlias =
            name: target:
            pkgs.runCommandLocal "openwrt-alias-${name}" { } ''
              mkdir -p $out/bin
              ln -s ${target} $out/bin/${name}
            '';
        in
        [
          (mkAlias "awk" "${pkgs.gawk}/bin/gawk")
          # scripts/checkpatch.pl 里直接调 `python <script>.py`
          (mkAlias "python" "${pythonFor pkgs}/bin/python3")
          # prereq 要 `egrep --version | grep GNU`，语义还得是 grep -E
          (pkgs.writeShellScriptBin "egrep" ''exec ${pkgs.gnugrep}/bin/grep -E "$@"'')
        ];

      # ------------------------------------------------------------------
      # FHS 环境：OpenWrt buildroot 大量依赖 /bin/sh、/usr/bin/env、
      # /usr/include、/usr/lib 这些固定路径，NixOS 上只能靠 bubblewrap 拼一个。
      # ------------------------------------------------------------------
      mkFhsEnv =
        {
          pkgs,
          gcc,
          suffix ? "",
        }:
        pkgs.buildFHSEnv {
          name = "openwrt-buildroot${suffix}";

          targetPkgs = pkgs: openwrtHostPackages pkgs ++ openwrtAliases pkgs ++ [ gcc ];

          # 让 dev 输出也进 FHS（头文件、pkg-config、.so 链接）
          extraOutputsToInstall = [ "dev" ];

          # 关掉 nix cc-wrapper 的 hardening 注入（-D_FORTIFY_SOURCE、
          # -fstack-protector-strong 等）。buildroot 自己决定优化和加固参数，
          # 宿主再偷偷塞一份只会让老代码在 -Werror 下挂掉。
          hardeningDisable = [ "all" ];

          runScript = "bash";

          # 进入环境时被 source
          profile = ''
            # buildroot 的 prereq 会检查 umask
            umask 022

            # fakeroot（buildroot 的 tools/fakeroot 1.29）在 bwrap 的 user
            # namespace 里做 chown 拿到的是 EINVAL、不是它期待的 EPERM，
            # package/install 打包那一步会带着错误直接退出。fakeroot 认这个
            # 开关（官方 man page 都没写）。
            export FAKEROOTDONTTRYCHOWN=1

            # 同上：别让 nix 的编译器 wrapper 往 buildroot 的编译里塞加固标志
            export NIX_HARDENING_ENABLE=

            # 2026 年的 glibc/gcc 对 2023 年的老代码会报一堆当年没有的警告，
            # 而 buildroot 的 host tools 大多自带 -Werror，一撞就编不过。
            # 典型：tools/elfutils 0.189 的 libcpu/riscv_disasm.c —— glibc 2.38
            # 起 _GNU_SOURCE 也会打开 C23 语义，bsearch 变成 const-generic 宏，
            # 拿 const 数组查询时返回 const void *，那句
            # "initialization discards 'const' qualifier" 就被 -Werror 顶成错误。
            # 这里让 nix 的 cc-wrapper 在命令行末尾补 -Wno-error：警告照旧打印，
            # 只是不再中断编译。目标端不受影响——那是 buildroot 自建的工具链在编，
            # 根本不经过 nix 的 wrapper。
            export NIX_CFLAGS_COMPILE="''${NIX_CFLAGS_COMPILE} -Wno-error"

            export LANG=en_US.UTF-8
            export LC_ALL=en_US.UTF-8
            export TZ=Asia/Shanghai

            # 源码树位置
            export OPENWRT_DIR="''${OPENWRT_DIR:-$HOME/ztemp-changes/openwrt-src}"

            # 防止宿主环境的编译参数泄漏进 buildroot。
            # 注意：NIX_CFLAGS_COMPILE / NIX_LDFLAGS 不能 unset——FHS 正是靠
            # 它们把 /usr/include 和 /usr/lib 加进搜索路径（见 nixpkgs 的
            # buildFHSEnv 生成的 /etc/profile）。
            unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
            unset CC CXX HOSTCC HOSTCXX
            unset ARCH CROSS_COMPILE
            # 注意：FHS 的 /etc/profile 只把 /usr/lib/pkgconfig 放进搜索路径，
            # 但 zlib 之类的 .pc 装在 /usr/share/pkgconfig（默认路径里），
            # 所以这里两个都要给，否则 pkg-config --exists zlib 会失败。
            export PKG_CONFIG_PATH=/usr/lib/pkgconfig:/usr/share/pkgconfig

            echo "OpenWrt buildroot 环境 | gcc $(gcc -dumpversion) | $(bash --version | head -1)"
            echo "源码树：$OPENWRT_DIR"
            echo "常用：cd \$OPENWRT_DIR && make defconfig && make -j\$(nproc) V=s"
          '';
        };

      # gcc 版本选择：
      #   GCC 14 起 -Werror=implicit-function-declaration 变成默认错误，
      #   OpenWrt 23.05 里那批老 configure 探测脚本很容易直接挂。
      #   所以默认用 gcc13（比 Ubuntu 22.04 的 11 新一点，但没踩 14+ 的坑）。
      defaultGcc = pkgs: pkgs.gcc13;
    in
    {
      devShells = forEachSystem (
        system: pkgs: {
          # 交互式主环境：nix develop
          # 注意：FHS 的 .env 不支持 `nix develop --command`（shellHook 会
          # exec 成交互 shell，命令被吞掉）。脚本化调用请用：
          #   nix run .#shell -- -c 'make prereq'
          default =
            (mkFhsEnv {
              inherit pkgs;
              gcc = defaultGcc pkgs;
            }).env;

          # 想用 nixpkgs 最新的 gcc（当前 16.x）时用这个
          gcc-latest =
            (mkFhsEnv {
              inherit pkgs;
              gcc = pkgs.gcc;
              suffix = "-gcc-latest";
            }).env;

          # 没有 FHS 的轻量环境，支持 `nix develop .#bare --command ...`
          # 只适合跑不需要 /bin/sh 的东西（perl/gcc/python 检查、脚本 lint）
          bare = pkgs.mkShell {
            packages = openwrtHostPackages pkgs ++ openwrtAliases pkgs ++ [ (defaultGcc pkgs) ];
            # 见 mkFhsEnv：不让 nix 的加固标志混进 buildroot 的编译参数
            hardeningDisable = [ "all" ];
            shellHook = ''
              umask 022
              export FAKEROOTDONTTRYCHOWN=1
              export LANG=en_US.UTF-8
              export LC_ALL=en_US.UTF-8
              export TZ=Asia/Shanghai
              export OPENWRT_DIR="''${OPENWRT_DIR:-$HOME/ztemp-changes/openwrt-src}"
            '';
          };

          # 交叉工具链单独一个 shell：只用于在 buildroot 之外快速验证
          # 「这段 C/C++ 能不能为 aarch64+musl 编过」，以及用 qemu 跑产物。
          # 千万不要用它去编 OpenWrt——buildroot 必须用自建工具链。
          cross-aarch64 =
            let
              cross = pkgs.pkgsCross.aarch64-multiplatform-musl;
            in
            pkgs.mkShell {
              packages = [
                cross.stdenv.cc
                cross.binutils
                pkgs.qemu
                pkgs.file
              ];
              shellHook = ''
                export CROSS_COMPILE=aarch64-unknown-linux-musl-
                echo "aarch64 musl: $(${cross.stdenv.cc.targetPrefix}cc --version | head -1)"
                echo "跑产物：qemu-aarch64 -L ${cross.stdenv.cc.libc}/lib ./your-binary"
              '';
            };
        }
      );

      packages = forEachSystem (
        system: pkgs:
        let
          fhs = mkFhsEnv {
            inherit pkgs;
            gcc = defaultGcc pkgs;
          };
        in
        {
          # 给脚本/CI 用：nix run .#shell -- -c 'make prereq'
          # （devShell 的 .env 不透传参数，这个包装器会把 "$@" 透传进 FHS）
          shell = fhs;
          default = fhs;
        }
      );

      formatter = forEachSystem (system: pkgs: pkgs.nixfmt);
    };
}
