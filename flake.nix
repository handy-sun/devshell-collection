{
  description = "A collection of Nix dev shells, one per source tree";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  # 只为 gcc11（11.5.0）：nixos-unstable 已经把 gcc11 移除了
  inputs.nixpkgs-gcc11.url = "github:NixOS/nixpkgs/nixos-25.05";
  # 目标机是 el9（glibc 2.34）：这个 nixpkgs 的 glibc 正好 2.34，用来编译部署产物
  inputs.nixpkgs-el9.url = "github:NixOS/nixpkgs/nixos-22.05";

  outputs =
    { self, nixpkgs, nixpkgs-gcc11, nixpkgs-el9 }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forEachSystem = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # 环境模板：只提供 "给一组 pkgs + 参数 → devShell" 的函数。
      # 具体参数（gcc 版本、目标三元组…）在下面的 devShells 里显式写清楚。
      openwrt = import ./lib/openwrt.nix { inherit lib; };
      mkPythonOnefile = import ./lib/python-onefile.nix { inherit lib; };
      mkCxxClangd = import ./lib/cxx-clangd.nix { inherit lib; };
      gcc11For = system: nixpkgs-gcc11.legacyPackages.${system}.gcc11;
      el9For = system: nixpkgs-el9.legacyPackages.${system};
    in
    {
      devShells = forEachSystem (
        pkgs:
        {
          # OpenWrt buildroot 宿主环境（FHS）。
          # default 是 openwrt 的别名，让 `nix develop` 和老脚本继续可用。
          default = openwrt.mkDevShell { inherit pkgs; };
          openwrt = openwrt.mkDevShell { inherit pkgs; };
          openwrt-gcc-latest = openwrt.mkDevShell {
            inherit pkgs;
            gcc = pkgs.gcc;
            suffix = "-gcc-latest";
          };
          openwrt-bare = openwrt.mkBare { inherit pkgs; };

          # 脱离 buildroot 的 nixpkgs 交叉工具链（换目标就改 target / qemuArch）
          cross-aarch64 = openwrt.mkCrossAarch64 {
            inherit pkgs;
            target = "aarch64-multiplatform-musl";
            qemuArch = "aarch64";
          };

          # PyInstaller 单文件，产物要能在 CentOS/RHEL 7（glibc 2.17）上跑。
          # Python 用 python-build-standalone 的 3.12（按 glibc 2.17 基线编译），
          # 构建后会自动校验产物的 GLIBC 符号版本。
          # 用 PYINS_EL7_DIR 指到具体项目（见 README「单文件打包」）。
          pyins-el7 = mkPythonOnefile {
            inherit pkgs;
            name = "pyins-el7";
            dirEnv = "PYINS_EL7_DIR";
            defaultDir = "work/pyins-el7";
            python = "3.12";
            pyinstaller = "6.22.3";
            deps = [
              "fastapi==0.110.3"
              "uvicorn==0.29.0"
            ];
            glibcBaseline = "2.17";
          };

          # C/C++ 项目（APP_DIR 默认 = 进入 shell 时的当前目录）
          # 工具用新版（clangd 要 ≥16 才认 .clangd 的 If），编译器/库用 el9 那套
          # （glibc 2.34 + gcc 11.3），产物才能在 el9 容器里跑。
          cxx = mkCxxClangd {
            inherit pkgs;
            name = "cxx";
            gcc = (el9For pkgs.stdenv.system).gcc11;
            # nix stdenv 默认注入 -O2，而项目的 Makefile 只写了 -g（-O0）；
            # 不压回去产物会大 60%（全是调试信息），行为也和 el9 上编出来的不一致
            extraCFlags = "-O0";
            dynamicLinker = "/lib64/ld-linux-x86-64.so.2";
            extraPackages = with (el9For pkgs.stdenv.system); [
              libevent
              libjwt
              rabbitmq-c
              libsodium
            ];
          };
        }
      );

      packages = forEachSystem (pkgs: {
        # 给脚本 / CI 用：nix run .#shell -- -c '…'
        # （FHS 的 devShell .env 不透传 --command，这个包装器会把 "$@" 透传进 FHS）
        shell = openwrt.mkFhsEnv { inherit pkgs; };
        default = openwrt.mkFhsEnv { inherit pkgs; };
      });

      formatter = forEachSystem (pkgs: pkgs.nixfmt);
    };
}
