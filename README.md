# devshell-collection

一组 Nix flake 开发环境：**一个源码库一个 devShell**，所有环境共用同一份 `flake.lock`。
目标是在 NixOS 上开发 / 编译那些「假设自己跑在标准 FHS 或特定工具链里」的老项目 ——
不用容器，也不用改宿主系统。

## 包含的环境

| devShell | 源码库 | 说明 | 文档 |
|---|---|---|---|
| `.#default` / `.#openwrt` | OpenWrt buildroot | 宿主编译环境（bubblewrap FHS）。`prereq` → `tools` → `toolchain` → 全量 `make` 已验证跑通并产出镜像 | [openwrt.md](docs/openwrt.md) |
| `.#openwrt-bare` | 同上 | 不带 FHS 的轻量版，支持 `--command` | [openwrt.md](docs/openwrt.md) |
| `.#openwrt-gcc-latest` | 同上 | 同上，换成 nixpkgs 当前的 gcc | [openwrt.md](docs/openwrt.md) |
| `.#cross-aarch64` | 任意 | nixpkgs 的 aarch64+musl 交叉工具链 + qemu，脱离 buildroot 用 | [cross-aarch64.md](docs/cross-aarch64.md) |

## 用法

```bash
git clone git@github.com:handy-sun/devshell-collection.git
cd devshell-collection
nix flake show                 # 看看有哪些环境
nix develop .#openwrt          # 进入主环境（等价于 nix develop）
```

每个源码库可以放一个 `.envrc`，进目录自动加载对应环境 —— 不用复制 flake，也不会多出一份 lock：

```bash
# ~/work/openwrt-src/.envrc —— direnv 只拿工具，构建仍走 nix develop .#openwrt
use flake ~/Projects/devshell-collection#openwrt-bare
```

## 约定

- 路径类变量统一用 `*_DIR`（例如 `OPENWRT_DIR`），都有默认值，可被环境变量覆盖。
- 所有环境共用一份 `flake.lock`：`nix flake update` 一次全动，避免不同环境跑在不同 nixpkgs 上。
- 环境细节放 `lib/`（`openwrt.nix`），`flake.nix` 只负责拼装和传参数。
- 新增一个环境：用现成模板（或在 `lib/` 里加一个）→ 在 `flake.nix` 的 `devShells` 里挂上 →
  在 `docs/` 补一页 → 更新上面那张表。

## 维护

```bash
nix flake update    # 升级 nixpkgs（FHS 环境会重编）
nix flake check     # 求值检查
nix fmt             # nixfmt
```
