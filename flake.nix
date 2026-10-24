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

      # ------------------------------------------------------------------
      # 依赖清单
      #
      # 权威来源是 OpenWrt 自己的 include/prereq-build.mk（每一条都会在
      # `make prereq` 时检查），owrt22/Dockerfile 里的 apt 列表只是它的近似。
      # 下面按 prereq 的检查项逐条对应到 nixpkgs 包名。
      # ------------------------------------------------------------------
      openwrtHostPackages =
        pkgs: with pkgs; [
          # --- 编译器 / 构建系统 ---
          # 注意：这只用于编译 buildroot 自己的 host tools。
          # 目标工具链（aarch64-openwrt-linux-musl-gcc 12.3.0）由 buildroot
          # 在 toolchain/ 阶段从源码自建，绝不能用 nix 的交叉工具链替代。
          gcc # 含 g++，prereq 要求 >= 6
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
          perl # 需要 Data::Dumper / FindBin / File::Copy / File::Compare /
          # Thread::Queue —— 均为 core 模块，nixpkgs 的 perl 已自带
          python3 # 需 >= 3.6；3.12+ 无 distutils，prereq 会自动跳过该项
          ncurses # menuconfig 要 ncurses.h + -lncurses
          openssl # libssl-dev
          elfutils # libelf-dev
          # HOST_OS=Linux 时 buildroot 用 `-Wl,-Bstatic -lz -Wl,-Bdynamic`
          # 链接 host tools，必须提供静态 libz.a；nixpkgs 的 zlib 默认不带，
          # 所以把 static 输出单独装进来。
          zlib.static
          tzdata
          glibcLocales # 替代 Ubuntu 的 locale-gen en_US.UTF-8
        ];

      # buildroot 里有几处按硬编码命令名调用，nixpkgs 的包名对不上，补软链
      openwrtAliases =
        pkgs:
        let
          mkAlias = name: target: pkgs.runCommandLocal "openwrt-alias-${name}" { } ''
            mkdir -p $out/bin
            ln -s ${target} $out/bin/${name}
          '';
        in
        [
          (mkAlias "awk" "${pkgs.gawk}/bin/gawk")
          # scripts/checkpatch.pl 里直接调 `python <script>.py`
          (mkAlias "python" "${pkgs.python3}/bin/python3")
          # prereq 要 `egrep --version | grep GNU`（grep -E 的语义要保留）
          (pkgs.writeShellScriptBin "egrep" ''exec ${pkgs.gnugrep}/bin/grep -E "$@"'')
        ];

      allTargetPackages = pkgs: openwrtHostPackages pkgs ++ openwrtAliases pkgs;

      # ------------------------------------------------------------------
      # FHS 环境：OpenWrt buildroot 大量依赖 /bin/sh、/usr/bin/env、
      # /usr/include、/usr/lib 这些固定路径，NixOS 上只能靠 bubblewrap 拼一个。
      # ------------------------------------------------------------------
      fhs =
        pkgs:
        pkgs.buildFHSEnv {
          name = "openwrt-buildroot";

          targetPkgs = allTargetPackages;

          # 让 dev/bin 等输出也进 FHS（头文件、pkg-config 等）
          extraOutputsToInstall = [ "dev" ];

          runScript = "bash";

          # 该 profile 会在进入环境时被 source。
          profile = ''
            # buildroot 的 prereq 会检查 umask
            umask 022

            export LANG=en_US.UTF-8
            export LC_ALL=en_US.UTF-8
            export TZ=Asia/Shanghai

            # 源码树位置：对外暴露一个变量，方便脚本里用
            export OPENWRT_DIR="''${OPENWRT_DIR:-$HOME/ztemp-changes/openwrt-src}"

            # 防止宿主环境的编译参数泄漏进 buildroot。
            # 注意：NIX_CFLAGS_COMPILE / NIX_LDFLAGS 不能 unset——FHS 靠它们
            # 把 /usr/include 和 /usr/lib 加进搜索路径。
            unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
            unset CC CXX HOSTCC HOSTCXX
            unset ARCH CROSS_COMPILE
            unset PKG_CONFIG_PATH || true
            export PKG_CONFIG_PATH=/usr/lib/pkgconfig

            echo "OpenWrt buildroot 环境（gcc $(gcc -dumpversion), $(bash --version | head -1)）"
            echo "源码树：$OPENWRT_DIR"
            echo "常用：cd \$OPENWRT_DIR && make defconfig && make -j\$(nproc) V=s"
          '';
        };
    in
    {
      devShells = forEachSystem (
        system: pkgs: {
          # 交互式主环境：nix develop
          default = (fhs pkgs).env;

          # 没有 FHS 的轻量环境，支持 `nix develop .#bare --command ...`
          # 只适合跑不需要 /bin/sh 的东西（perl/gcc/python 检查、脚本 lint）
          bare = pkgs.mkShell {
            packages = allTargetPackages pkgs;
            shellHook = ''
              umask 022
              export LANG=en_US.UTF-8
              export LC_ALL=en_US.UTF-8
              export TZ=Asia/Shanghai
              export OPENWRT_DIR="''${OPENWRT_DIR:-$HOME/ztemp-changes/openwrt-src}"
            '';
          };

          # 交叉工具链单独一个 shell：只用于在 buildroot 之外快速验证
          # 「这段 C/C++ 能不能为 aarch64+musl 编过」，或者跑 qemu 验证产物。
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
                echo "aarch64 musl 交叉工具链：$(${cross.stdenv.cc.targetPrefix}cc --version | head -1)"
                echo "跑产物：qemu-aarch64 -L ${cross.stdenv.cc.libc}/lib ./your-binary"
              '';
            };
        }
      );

      packages = forEachSystem (system: pkgs: {
        # 给脚本/CI 用：nix run .#shell -- -c 'make prereq'
        # （devShell 的 .env 不支持 --command，这个包装器会把参数透传进 FHS）
        shell = fhs pkgs;
        default = self.packages.${system}.shell;
      });

      formatter = forEachSystem (system: pkgs: pkgs.nixfmt-rfc-style);
    };
}
