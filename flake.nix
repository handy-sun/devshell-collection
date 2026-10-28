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

      # 环境模板：每个文件导出若干 "给一组 pkgs，还我一个 devShell" 的函数。
      # 新增环境时优先复用模板，别在 flake.nix 里直接写环境细节。
      openwrt = import ./lib/openwrt.nix { inherit lib; };
    in
    {
      devShells = forEachSystem (
        pkgs:
        let
          ow = openwrt.devShells pkgs;
        in
        {
          # 默认环境 = OpenWrt buildroot 宿主环境（FHS）
          default = ow.openwrt;
          openwrt = ow.openwrt;
          openwrt-gcc-latest = ow.openwrt-gcc-latest;
          openwrt-bare = ow.openwrt-bare;

          # 通用：脱离 buildroot 的 aarch64+musl 交叉工具链（+ qemu）
          cross-aarch64 = ow.cross-aarch64;

        }
      );

      packages = forEachSystem (pkgs: {
        # 给脚本 / CI 用：nix run .#shell -- -c '…'
        # （FHS 的 devShell .env 不透传 --command，这个包装器会把 "$@" 透传进 FHS）
        shell = openwrt.shell pkgs;
        default = openwrt.shell pkgs;
      });

      formatter = forEachSystem (pkgs: pkgs.nixfmt);
    };
}
