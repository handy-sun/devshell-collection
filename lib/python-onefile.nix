{ lib }:
{
  pkgs,
  name,
  # 指向源码树的环境变量名，例如 PYINS_EL7_DIR
  dirEnv,
  # 默认路径（相对 $HOME）
  defaultDir,
  # python-build-standalone 的版本，会交给 `uv python install`
  python ? "3.12",
  # PyInstaller 版本，和下面 deps 一起 pin 住，保证可复现
  pyinstaller ? "6.22.3",
  # 运行期依赖，pip 写法： [ "fastapi==0.110.3" "uvicorn==0.29.0" ]
  deps ? [ ],
  # 产物路径（相对源码树）。留空则取 dist/ 下最新的文件
  artifact ? "",
  # 允许的最高 GLIBC 符号版本
  glibcBaseline ? "2.17",
  # 在源码树根目录执行的构建命令。单个脚本路径会用 bash 显式调用
  # （非 FHS 环境里没有 /usr/bin/env，带 `#!/usr/bin/env bash` 的脚本不能直接执行）；
  # 想跑完整命令行时直接传字符串，例如 "make dist"。
  buildCommand ? "./build.sh",
  extraPackages ? [ ],
}:
let
  depsLine = lib.concatStringsSep " " (map (d: "\"${d}\"") deps);
  artifactHint = if artifact == "" then "dist/ 下最新的文件" else artifact;
  buildRunner =
    if lib.hasInfix " " buildCommand then buildCommand else "${pkgs.bash}/bin/bash ${buildCommand}";
  c = {
    printenv = "${pkgs.coreutils}/bin/printenv";
    sort = "${pkgs.coreutils}/bin/sort";
    tail = "${pkgs.coreutils}/bin/tail";
    printf = "${pkgs.coreutils}/bin/printf";
    grep = "${pkgs.gnugrep}/bin/grep";
    objdump = "${pkgs.binutils}/bin/objdump";
    mkdir = "${pkgs.coreutils}/bin/mkdir";
    du = "${pkgs.coreutils}/bin/du";
    find = "${pkgs.findutils}/bin/find";
    cut = "${pkgs.coreutils}/bin/cut";
  };

  build = pkgs.writeShellScriptBin "${name}-build" ''
    set -euo pipefail

    src="$(${c.printenv} ${dirEnv} || true)"
    if [ -z "$src" ]; then
      echo "请先设置 ${dirEnv}（例如 export ${dirEnv}=$HOME/${defaultDir}）" >&2
      exit 1
    fi
    cd "$src"

    cache="''${XDG_CACHE_HOME:-$HOME/.cache}/devshell-collection/${name}"
    venv="$cache/venv"
    ${c.mkdir} -p "$cache"

    echo ">>> Python ${python}（python-build-standalone，glibc ${glibcBaseline} 基线）"
    uv python install --no-bin ${python}

    if [ ! -x "$venv/bin/python" ]; then
      uv venv --python ${python} "$venv"
    fi

    echo ">>> 安装构建依赖（pyinstaller==${pyinstaller} ${depsLine}）"
    uv pip install --quiet --python "$venv/bin/python" "pyinstaller==${pyinstaller}" ${depsLine}

    echo ">>> 构建：${buildCommand}"
    PATH="$venv/bin:$PATH" ${buildRunner}

    if [ -n "${artifact}" ]; then
      bin="$src/${artifact}"
    else
      bin=$(${c.find} "$src/dist" -maxdepth 1 -type f -printf '%T@ %p\n' 2>/dev/null \
        | ${c.sort} -n | ${c.tail} -1 | ${c.cut} -d' ' -f2-)
    fi
    if [ -z "$bin" ] || [ ! -f "$bin" ]; then
      echo "构建没有产出可用的二进制（期望 ${artifactHint}）" >&2
      exit 1
    fi

    max=$(${c.objdump} -T "$bin" | ${c.grep} -o 'GLIBC_[0-9.]*' | ${c.sort} -uV | ${c.tail} -1)
    limit="GLIBC_${glibcBaseline}"
    highest=$(${c.printf} '%s\n%s\n' "$max" "$limit" | ${c.sort} -uV | ${c.tail} -1)
    if [ "$highest" != "$limit" ]; then
      echo "✗ $bin 需要 $max，超过目标基线 $limit" >&2
      exit 1
    fi
    echo "✓ $bin 最高要求 $max（目标基线 $limit），大小 $(${c.du} -h "$bin" | cut -f1)"
  '';
in
pkgs.mkShell {
  name = "${name}-onefile";

  packages = [
    build
    pkgs.uv
    pkgs.git # 构建脚本通常要 git describe 生成版本号
    pkgs.binutils # objdump 校验 GLIBC 基线
  ] ++ extraPackages;

  shellHook = ''
    if [ -z "$(${c.printenv} ${dirEnv} || true)" ]; then
      export ${dirEnv}="$HOME/${defaultDir}"
    fi
    echo "${name} | PyInstaller onefile（Python ${python}，目标 glibc ${glibcBaseline}）"
    echo "源码树：$(${c.printenv} ${dirEnv})"
    echo "构建： ${name}-build    → ${artifactHint}"
  '';
}
