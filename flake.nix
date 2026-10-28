{
  description = "A collection of Nix dev shells, one per source tree";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
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
