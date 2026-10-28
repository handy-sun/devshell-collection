# `.#cross-aarch64`

nixpkgs 的 aarch64+musl 交叉工具链 + qemu，**和 buildroot 无关**。

用途：快速回答"这段 C/C++ 本身能不能为目标平台编过"——新写的代码片段、第三方库的可移植性、
要不要加某个头文件。**不要**用它编 OpenWrt 的包：buildroot 会用自己的工具链重编，ABI 和默认
参数都不一样，这里编过不代表固件里能编过（反过来也一样）。

```bash
nix develop .#cross-aarch64
echo "$CROSS_COMPILE"        # 前缀，例如 aarch64-unknown-linux-musl-
aarch64-unknown-linux-musl-g++ -std=c++11 -c foo.cpp -o foo.o
qemu-aarch64 -L "$(dirname "$(aarch64-unknown-linux-musl-g++ -print-file-name=libc.so)")" ./app
```

换目标平台：改 `flake.nix` 里 `mkCrossAarch64` 的参数 —— `target`（`pkgsCross` 的属性名，
如 `mips64el-multilib-linux-musl`）和 `qemuArch`（qemu-user 的可执行名，如 `mips64el`）。

`qemu` 让这个环境的闭包比较大（第一次要现编）。只想要编译器、不打算跑产物的话，
把 `flake.nix` 里的 `withQemu = false` 关掉即可。
