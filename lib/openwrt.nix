# OpenWrt buildroot 的宿主编译环境（buildFHSEnv + bubblewrap）。
#
# 这里只放"模板"，具体挂哪几个 devShell 由 flake.nix 决定：
#   mkFhsEnv        buildFHSEnv 本体，可以包装成 nix run 入口，也能取 .env 当 devShell
#   mkDevShell      同上的 .env 版本（devShells 用这个）
#   mkBare          无 FHS 的轻量 mkShell
#   mkCrossAarch64  nixpkgs 的交叉工具链 + qemu（与 buildroot 无关）
#
# 为什么必须用 FHS、各项取舍见 docs/openwrt.md。
{ lib }:
let
  # OpenWrt 有些 host 脚本还在用老式 setup.py / distutils（对应发行版里的
  # python3-distutils + python3-setuptools）。Python 3.12 起 distutils 已经
  # 不在标准库里，只能靠 setuptools 提供的垫片补回来。
  pythonFor = pkgs: pkgs.python3.withPackages (ps: [ ps.setuptools ]);

  # ------------------------------------------------------------------
  # 依赖清单
  #
  # 权威来源是 OpenWrt 自己的 include/prereq-build.mk（每条都会在
  # `make prereq` 时检查），发行版文档里的依赖列表通常只是它的近似。
  # 下面按 prereq 的检查项逐条对应到 nixpkgs 包名。
  # ------------------------------------------------------------------
  hostPackages =
    pkgs: with pkgs; [
      # --- 构建系统（编译器单独传，见 mkFhsEnv）---
      # 注意：主机编译器只用来编 buildroot 自己的 host tools。
      # 目标工具链（aarch64-openwrt-linux-musl-gcc）由 buildroot 在 toolchain/
      # 阶段从源码自建，绝不能用 nix 的交叉工具链替代。
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
      glibcLocales # 替代发行版的 locale-gen en_US.UTF-8
    ];

  # buildroot 里有几处按硬编码命令名调用，nixpkgs 的包名对不上，补软链
  aliases =
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
      (pkgs.writeShellScriptBin "egrep" ''exec ${pkgs.gnugrep}/bin/grep -E "$"'')
    ];

  # 固定的环境变量与提示：FHS 和 bare 两个 shell 共用
  commonExports = ''
    umask 022

    # fakeroot（buildroot 的 tools/fakeroot）在 bwrap 的 user namespace 里
    # 做 chown 拿到的是 EINVAL、不是它期待的 EPERM，package/install 打包那一步
    # 会带着错误直接退出。fakeroot 认这个开关（官方 man page 都没写）。
    export FAKEROOTDONTTRYCHOWN=1

    # 别让 nix 的编译器 wrapper 往 buildroot 的编译里塞加固标志
    export NIX_HARDENING_ENABLE=

    # 新 glibc/gcc 对几年前的旧代码会报一堆当年没有的警告，而 buildroot 的
    # host tools 大多自带 -Werror，一撞就编不过。典型：tools/elfutils 的
    # libcpu/riscv_disasm.c —— glibc 2.38 起 _GNU_SOURCE 也会打开 C23 语义，
    # bsearch 变成 const-generic 宏，拿 const 数组查询时返回 const void *，
    # 那句 "initialization discards 'const' qualifier" 就被 -Werror 顶成错误。
    # 这里让 nix 的 cc-wrapper 在命令行末尾补 -Wno-error：警告照旧打印，只是
    # 不再中断编译。目标端不受影响——那是 buildroot 自建的工具链在编。
    export NIX_CFLAGS_COMPILE="''${NIX_CFLAGS_COMPILE} -Wno-error"

    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8
    export TZ=Asia/Shanghai

    # 源码树位置（也可以用 OPENWRT_DIR 覆盖）
    export OPENWRT_DIR="''${OPENWRT_DIR:-$HOME/work/openwrt-src}"
  '';
in
rec {
  inherit hostPackages aliases;

  # 通用 FHS 环境。
  #   gcc             宿主编译器，默认 gcc13（GCC 14+ 会把隐式函数声明当错误）
  #   suffix          名字后缀，多个环境共存时用来区分
  #   extraPackages   额外依赖（项目自己需要的宿主导工具）
  #   extraProfile    追加到 /etc/profile 末尾的内容
  mkFhsEnv =
    {
      pkgs,
      gcc ? pkgs.gcc13,
      suffix ? "",
      extraPackages ? [ ],
      extraProfile ? "",
    }:
    pkgs.buildFHSEnv {
      name = "openwrt-buildroot${suffix}";

      targetPkgs = pkgs: hostPackages pkgs ++ aliases pkgs ++ extraPackages ++ [ gcc ];

      # 让 dev 输出也进 FHS（头文件、pkg-config、.so 链接）
      extraOutputsToInstall = [ "dev" ];

      # 关掉 nix cc-wrapper 的 hardening 注入（-D_FORTIFY_SOURCE、
      # -fstack-protector-strong 等）。buildroot 自己决定优化和加固参数，
      # 宿主再偷偷塞一份只会让老代码在 -Werror 下挂掉。
      hardeningDisable = [ "all" ];

      runScript = "bash";

      # 进入环境时被 source
      profile = ''
        ${commonExports}

        # 防止宿主环境的编译参数泄漏进 buildroot。
        # 注意：NIX_CFLAGS_COMPILE / NIX_LDFLAGS 不能 unset——FHS 正是靠
        # 它们把 /usr/include 和 /usr/lib 加进搜索路径（见 nixpkgs 的
        # buildFHSEnv 生成的 /etc/profile）。
        unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
        unset CC CXX HOSTCC HOSTCXX
        unset ARCH CROSS_COMPILE
        # FHS 的 /etc/profile 只把 /usr/lib/pkgconfig 放进搜索路径，但 zlib 之类的
        # .pc 装在 /usr/share/pkgconfig，所以两个都要给，否则 pkg-config --exists
        # zlib 会失败。
        export PKG_CONFIG_PATH=/usr/lib/pkgconfig:/usr/share/pkgconfig

        echo "OpenWrt buildroot 环境 | gcc $(gcc -dumpversion) | $(bash --version | head -1)"
        echo "源码树：$OPENWRT_DIR"
        echo "常用：cd \$OPENWRT_DIR && make defconfig && make -j\$(nproc) V=s"
        ${extraProfile}
      '';
    };

  # 直接当 devShell 用（devShells 需要的是 .env 而不是 FHS 本体）
  mkDevShell = args: (mkFhsEnv args).env;

  # 无 FHS 的轻量环境：支持 `nix develop .#openwrt-bare --command ...`，
  # 只适合跑不需要 /bin/sh 的东西（perl/gcc/python 探测、脚本 lint）。
  mkBare =
    {
      pkgs,
      gcc ? pkgs.gcc13,
      extraPackages ? [ ],
    }:
    pkgs.mkShell {
      packages = hostPackages pkgs ++ aliases pkgs ++ extraPackages ++ [ gcc ];
      # 见 mkFhsEnv：不让 nix 的加固标志混进 buildroot 的编译参数
      hardeningDisable = [ "all" ];
      shellHook = ''
        ${commonExports}
        echo "bare 环境（没有 FHS）：只能跑不依赖 /bin/sh 的东西"
      '';
    };

  # nixpkgs 的交叉工具链 + qemu：脱离 buildroot 快速验证代码能不能为目标平台编过。
  #   target     pkgsCross 里的属性名
  #   qemuArch   qemu-user 的可执行文件名
  mkCrossAarch64 =
    {
      pkgs,
      target ? "aarch64-multiplatform-musl",
      qemuArch ? "aarch64",
      withQemu ? true,
    }:
    let
      cross = pkgs.pkgsCross.${target};
      prefix = cross.stdenv.cc.targetPrefix;
    in
    pkgs.mkShell {
      packages = [ cross.stdenv.cc cross.binutils pkgs.file ] ++ lib.optionals withQemu [ pkgs.qemu ];
      shellHook = ''
        export CROSS_COMPILE="${prefix}"
        echo "交叉工具链：${prefix}cc（$(${prefix}cc --version | head -1)）"
        ${lib.optionalString withQemu ''
          echo "跑产物：qemu-${qemuArch} -L ${cross.stdenv.cc.libc}/lib ./your-binary"
        ''}
      '';
    };
}
