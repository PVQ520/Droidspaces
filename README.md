# Droidspaces RootFS Builder — aarch64 Minimal + Base

为 [Droidspaces](https://github.com/ravindu644/Droidspaces-OSS) 构建 aarch64 rootfs 压缩包，
由 GitHub Actions 云端编译并发布为 Release，同时自动重生成 `rootfs.json`。

只保留 **4 个发行版 × 2 个档位 = 10 个模板**，全部 aarch64。

## 模板

| 模板 | 发行版 | init | 档位 |
|---|---|---|---|
| `Alpine-Minimal` | Alpine 3.23 | OpenRC | 最小可用 |
| `Alpine-base` | Alpine 3.23 | OpenRC | + 开发工具 + Docker |
| `Arch-Minimal-Kernel-5.10-and-up` | Arch Linux | systemd | 最小可用 |
| `Arch-base-Kernel-5.10-and-up` | Arch Linux | systemd | + 开发工具 + Docker |
| `Debian-13-Minimal` | Debian 13 (trixie) | systemd | 最小可用 |
| `Debian-13-base` | Debian 13 (trixie) | systemd | + 开发工具 + Docker |
| `Ubuntu-24.04-Minimal` | Ubuntu 24.04 LTS | systemd | 最小可用 |
| `Ubuntu-24.04-base` | Ubuntu 24.04 LTS | systemd | + 开发工具 + Docker |
| `Ubuntu-26.04-Minimal` | Ubuntu 26.04 LTS | systemd | 最小可用 |
| `Ubuntu-26.04-base` | Ubuntu 26.04 LTS | systemd | + 开发工具 + Docker |

**Minimal** = 能启动、能联网、有包管理器和 SSH 服务端。
**Base** = Minimal + 编译工具链（build-essential / base-devel）+ Python + Docker + 常用系统工具。

> Ubuntu 22.04 模板已移除，换成 26.04 LTS。

## 目录

```
archs.json                         架构 → docker platform + CI runner
build.sh                           构建单个模板（本地用）
templates/aarch64/<Name>.Dockerfile
scripts/generate_rootfs_json.py    从 release 生成 rootfs.json（--lint 只校验标签）
scripts/lint-templates.sh          本地静态检查（标签/续行/heredoc/COPY 源）
scripts/audit-packages.py          包名核验（对官方仓库索引，四个包管理器生态）
scripts/cleanup_old_assets.py      清理旧 release / tag / workflow run
rootfs.json                        自动生成，勿手改
```

## 云端编译

推送到 `main`、每周日定时、或手动 `workflow_dispatch` 触发。
`.github/workflows/build-rootfs-releases.yml` 会：

1. `--lint` 校验所有模板的 `droidspaces.*` 标签
2. 扫描 `templates/<arch>/*.Dockerfile` 生成构建矩阵（并行）
3. 每个模板在 `ubuntu-24.04-arm` 上原生构建（无 QEMU 模拟开销）
4. 汇总成一个 release
5. 重生成并提交 `rootfs.json`

`rootfs.json` 的提交被 `paths-ignore` 排除，不会触发第二次构建。

首次发布前 `rootfs.json` 是空数组 `[]`，release 成功后会自动填充。

仓库名不写在任何脚本里：`GITHUB_REPOSITORY`（CI 自动提供）→ 本地 `git remote origin` → 报错。
所以仓库叫什么、放哪个账号、以后改名，都不用改代码。

手动只更新 JSON（不重新编译）：Actions → Run workflow → 勾 `update_json_only`。

## 本地构建与自检

需要 docker + buildx、jq、xz。非 aarch64 主机会自动注册 QEMU。

```sh
./build.sh -a aarch64 -i Debian-13-Minimal
./scripts/lint-templates.sh                      # 静态检查，不需要 docker
python3 scripts/generate_rootfs_json.py --lint    # 标签校验
```

包名核验（防"包不存在导致云端构建失败"，见下）：

```sh
# Ubuntu 26.04
curl -sO http://ports.ubuntu.com/ubuntu-ports/dists/resolute/main/binary-arm64/Packages.gz
gzip -dc Packages.gz | sed -n 's/^Package: //p' | sort -u > /tmp/names
./scripts/audit-packages.py --apt /tmp/names '' 'ubuntu:26'
```

## 首次上传到自己的 GitHub

先在网页上建一个**空仓库**（不要加 README / .gitignore / license），然后：

```bash
cd Droidspaces
git init -b main
git add -A
git commit -m "aarch64 Minimal/Base: 10 templates"
git remote add origin https://github.com/<你的账号>/<仓库名>.git
git push -u origin main
```

推送成功即触发第一次构建，约 20–40 分钟后 release 里会出现 10 个 tar.xz。

用 token 而不是密码推送（推荐）：

1. GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)
2. Generate new token，勾 `repo` 和 `workflow`
3. 推送时把 token 当密码：`git push https://<账号>:<token>@github.com/<账号>/<仓库名>.git main`

Actions 需要的权限已经写在 workflow 里（`permissions: contents: write`），
用默认的 `GITHUB_TOKEN` 即可，不用额外配 secret。

## 加模板 / 加发行版

丢一个 `templates/aarch64/<Name>.Dockerfile` 进去即可，CI 自动发现，`--lint` 校验标签。

Dockerfile 最后必须是 `export` 阶段并带元数据标签：

```dockerfile
FROM scratch AS export
LABEL droidspaces.name="Debian 13 - Custom" \
      droidspaces.distro="Debian" \
      droidspaces.description="一句话说明。" \
      droidspaces.author="Droidspaces developers"
COPY --from=customizer / /
```

`name` / `distro` / `description` 必填，`author` 默认 `Droidspaces developers`。
其余 `droidspaces.<key>` 会作为 `<key>` 原样进入 `rootfs.json`。
构建上下文是仓库根目录，所以 `COPY scripts/...` 在任何模板里都可用。

## SSH

所有模板都装了 SSH **服务端**，但**默认不随机启动**，且 root 密码为空 —— 直接开 sshd 会被拒登。

进容器先设密码：

```sh
passwd root
```

再按 init 启动：

```sh
# Debian / Ubuntu / Arch (systemd)
systemctl enable --now ssh     # Ubuntu/Debian 服务名是 ssh
systemctl enable --now sshd    # Arch 服务名是 sshd

# Alpine (OpenRC)
rc-update add sshd default && rc-service sshd start
```

`PermitRootLogin` 已设为 `yes`、`PasswordAuthentication` 已开启。
纯内网/自用没问题；若容器会暴露到不可信网络，建议改密钥并关闭密码登录。

## 精简了什么（相对上游模板）

按自用 Lite 版的手法，保留 SSH，不加 FTP：

- **删掉 bspwm 桌面主题资源** —— 上游 `scripts/bspwm/` 占 17 MB（壁纸、Nerd 字体、Catppuccin GTK 主题），只有两个 bspwm 模板引用，随模板一起删除。仓库从 17.4 MB 降到约 140 KB。
- **去掉 qemu-user-static + binfmt 注册服务** —— 上游 Minimal 装 qemu 再做一轮 purge/reinstall，纯为跨架构执行准备；aarch64 容器不需要，删掉少约 100 MB 并去掉一个开机服务。
- **只构建 aarch64** —— `archs.json` 只留 aarch64，删除 armhf / x86 / x86_64 模板目录。
- **包集瘦身** —— 去掉 `dialog`、`file`、`net-tools`、`dnsutils`、重复的 `git`/`sudo`；Alpine 上 busybox 已提供的 `coreutils`/`findutils`/`grep`/`sed`/`gawk` 不再单独装。
- **文档与缓存** —— 清 `/usr/share/man`、`/usr/share/doc`、`/usr/share/info`、`/tmp`。
- **Debian 用 main 仓库** —— 收回原先只为 `hfsprogs` 开启的 contrib/non-free。
- **去掉过时文件系统工具** —— `jfsutils`、`hfsprogs`、`reiserfsprogs`、`nilfs-tools`、`udftools` 在 Android 上无实用（且 `reiserfsprogs` 在 Ubuntu 24.04/26.04 已不存在）；保留 `f2fs-tools`、`exfatprogs`、`ntfs-3g`、`btrfs-progs`、`xfsprogs`、`dosfstools`、`cryptsetup`。

## 修掉的上游 bug（都会让云端构建失败）

逐个用官方仓库索引核验过，不是猜的：

1. **`Debian-13-base` 用了 `docker-cli`** —— 名字对，但它属于 Docker 官方 apt 源而非 Debian 仓库，直接 `apt-get install` 装不到。改为 `docker.io` + `docker-compose`（Debian 没有 `docker-compose-v2`，那是 Ubuntu 的包名）。
2. **`Alpine-base` 用了 `clang`** —— Alpine 3.23 没有无版本号的 `clang` 包，也没有提供者。改为 `clang21`。
3. **Ubuntu base 用了 `reiserfsprogs`** —— 24.04 与 26.04 仓库均已移除。已删。
4. **`Debian-13-Minimal` 有一处 `\ \` 断行损坏**（反斜杠后多一个空格），会让 `apt-get` 那层语法错误。已修。
5. **`Ubuntu-24.04-base` 的 `xdg-user-dirs-update`** 在容器里通常不存在，整层 RUN 会失败。已删除该行。
6. **上游 release 步骤把 `rootfs.json` 提交回 `main`**，而触发器是 `push: branches:[main]`，会导致每次发布再触发一次全量重建。已加 `paths-ignore`。

### 一个不能动的依赖

`Ubuntu-24.04-base` 里的 `ppa:zhangsongcui3371/fastfetch` **必须保留**。
`fastfetch` 只在 Ubuntu 26.04+ 进入官方仓库，24.04 没有；删掉这个 PPA 会让
`apt-get install fastfetch` 找不到包，整个 base 构建中断。26.04 的模板不需要 PPA。

## 桌面模板与桌面用户

本仓库不含桌面模板。如需 XFCE / bspwm 版本，参考上游
[Droidspaces-rootfs-builder](https://github.com/Droidspaces/Droidspaces-rootfs-builder)。

Android 网络组（`aid_inet` / `aid_net_raw` / `aid_net_admin`）、
iptables-legacy 切换、`net_mode` 网络模式限制等兼容性修复全部保留。
