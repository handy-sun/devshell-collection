# C/C++ 项目开发环境：见 README「C/C++ 项目（clangd）」。
{ lib }:
{
  pkgs,
  name,
  # 指向项目目录的环境变量，默认 APP_DIR；未设置时用进入 shell 时的当前目录
  dirEnv ? "APP_DIR",
  # 构建目录（相对项目根），gen-cdb 在这里跑 make
  buildSubdir ? "src",
  # 编译器（要匹配目标机的版本时传对应的 gcc）
  gcc ? pkgs.gcc,
  # 目标机的动态加载器路径；设了就写进链接参数，产物不再指向 nix store 的 ld
  dynamicLinker ? null,
  extraPackages ? [ ],
  # 追加到 NIX_CFLAGS_COMPILE 的编译参数，例如 "-O0"（nix 默认注入 -O2）
  extraCFlags ? "",
  extraShellHook ? "",
}:
let
  genCdb = pkgs.writeShellScriptBin "gen-cdb" ''
    set -euo pipefail
    dir="$(${pkgs.coreutils}/bin/printenv ${dirEnv} || true)"
    if [ -z "$dir" ]; then
      echo "请先设置 ${dirEnv}" >&2
      exit 1
    fi
    cd "$dir"
    if [ ! -e "$dir/.clangd" ]; then
      printf '%s\n' 'CompileFlags:' '  Add: [-xc++]' 'If:' '  PathMatch: .*[.]h' > "$dir/.clangd"
    fi
    # -B 全量重编，bear 才能记录到每条编译命令；默认全核并行，传自己的 -j 会覆盖它
    ${pkgs.bear}/bin/bear --append -- ${pkgs.gnumake}/bin/make -C ${buildSubdir} -B \
      -j"$(${pkgs.coreutils}/bin/nproc)" "$@"

    # 把编译器真实的系统头目录展开成 -isystem 写进 CDB。这样 clangd 不需要
    # --query-driver，也不受编辑器进程 locale 影响（它靠解析 g++ -v 拿系统头，
    # 中文 locale 下会失败）；这里在本地 C locale 下解析一次就够了。
    incs=$(LC_ALL=C ${gcc}/bin/g++ -v -E -x c++ /dev/null 2>&1 \
      | ${pkgs.gnused}/bin/sed -n '/^#include <...> search starts here:/,/^End of search list./p' \
      | ${pkgs.gnused}/bin/sed '1d;$d;s/^ //;s/ (.*//' \
      | ${pkgs.jq}/bin/jq -R -s 'split("\n") | map(select(length > 0))')
    ${pkgs.jq}/bin/jq --argjson incs "$incs" '
      [ .[] | if (.arguments | index("-isystem")) then .
              else .arguments += (($incs | map(["-isystem", .]) | add) // []) end ]' \
      "$dir/compile_commands.json" > "$dir/.compile_commands.json.tmp" \
      && mv "$dir/.compile_commands.json.tmp" "$dir/compile_commands.json"

    echo "compile_commands.json: $(${pkgs.jq}/bin/jq length "$dir/compile_commands.json") 条"
  '';
in
pkgs.mkShell {
  name = "${name}";

  packages = [
    gcc
    pkgs.gnumake
    pkgs.pkg-config
    pkgs.bear
    pkgs.clang-tools
    pkgs.jq
    genCdb
  ] ++ extraPackages;

  shellHook = ''
    if [ -z "$(${pkgs.coreutils}/bin/printenv ${dirEnv} || true)" ]; then
      export ${dirEnv}="$PWD"
    fi

    unset CPATH CPLUS_INCLUDE_PATH C_INCLUDE_PATH
    export LC_ALL=C.UTF-8

    ${lib.optionalString (extraCFlags != "") ''
      export NIX_CFLAGS_COMPILE="''${NIX_CFLAGS_COMPILE:-} ${extraCFlags}"
    ''}
    ${lib.optionalString (dynamicLinker != null) ''
      export NIX_LDFLAGS="''${NIX_LDFLAGS:-} --dynamic-linker=${dynamicLinker}"
    ''}

    echo "${name} | gcc $(gcc -dumpversion) | $(clangd --version 2>/dev/null | head -1)"
    echo "项目目录：$(${pkgs.coreutils}/bin/printenv ${dirEnv})"
    echo "工具：gen-cdb 全量重编一遍，把每个源文件的实际编译命令写进"
    echo "       compile_commands.json（clangd 的编译数据库），并生成 .clangd"
    ${extraShellHook}
  '';
}
