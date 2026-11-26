#!/bin/sh
# envup — 一条命令装好 Linux 开发环境
#
# 纯 POSIX sh（dash / busybox ash / bash 均可），单文件，无外部依赖。
#
#   curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/envup.sh | sh
#   curl -fsSL ... | sh -s -- install node python
#   sh envup.sh doctor
#
# 设计原则：
#   1. 只做加法：不删包、不覆盖用户配置，换源前备份、失败回滚。
#   2. 幂等：已安装的包跳过，可反复执行。
#   3. 可审计：--dry-run 只打印将要执行的命令。
#   4. 不越权：非 root 且无 sudo 时明确报错，不静默失败。
set -u

ENVUP_VERSION="1.0.0"
PROG="envup"

# ────────────────────────────── 全局状态 ──────────────────────────────
DRY_RUN=0
ASSUME_YES=0
USE_MIRROR=0          # 0=不动软件源  1=探测并换
NO_COLOR_FORCED=0
VERBOSE=0
INSTALLED_ITEMS=""    # 本次实际处理的 item

# 颜色变量必须在任何输出前先定义：set -u 下参数解析阶段就可能调 err()
C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''

# ────────────────────────────── 终端能力 ──────────────────────────────
init_color() {
    if [ "$NO_COLOR_FORCED" = 1 ] || [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
        C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
    else
        C_RESET=$(printf '\033[0m'); C_BOLD=$(printf '\033[1m')
        C_DIM=$(printf '\033[2m');   C_RED=$(printf '\033[31m')
        C_GREEN=$(printf '\033[32m'); C_YELLOW=$(printf '\033[33m')
        C_BLUE=$(printf '\033[34m')
    fi
}

# ────────────────────────────── 交互通道 ──────────────────────────────
# curl | sh 时 stdin 是脚本流本身，直接 read 会读到脚本剩余内容。
# 这里统一从 fd 3 读：优先继承真 tty，其次打开 /dev/tty；都不行则走非交互默认值。
INTERACTIVE=0
init_input() {
    if [ -t 0 ]; then
        exec 3<&0
        INTERACTIVE=1
    elif ( : </dev/tty ) 2>/dev/null; then
        exec 3</dev/tty
        INTERACTIVE=1
    fi
}

# ────────────────────────────── 输出 ──────────────────────────────
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }
hr()   { printf '%s%s%s\n' "$C_DIM" "────────────────────────────────────────────" "$C_RESET"; }
hint() { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

# ────────────────────────────── 日志 ──────────────────────────────
STATE_DIR=""
init_log() {
    STATE_DIR="${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/envup"
    LOG_FILE="$STATE_DIR/envup.log"
    mkdir -p "$STATE_DIR" 2>/dev/null || { LOG_FILE=/dev/null; return 0; }
    # 超过 256KB 截尾，避免长期使用无限增长
    if [ -f "$LOG_FILE" ]; then
        sz=$(wc -c <"$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$sz" -gt 262144 ] 2>/dev/null; then
            tail -c 65536 "$LOG_FILE" >"$LOG_FILE.tmp" 2>/dev/null &&
                mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null
        fi
    fi
    log "==== $PROG $ENVUP_VERSION 启动 | args: $* | uid: $(id -u 2>/dev/null)"
}
log() {
    [ -n "${LOG_FILE:-}" ] || return 0
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$*" >>"$LOG_FILE" 2>/dev/null ||:
}

# 执行命令的唯一出口：dry-run / 日志 / 错误处理都收在这里
run() {
    log "exec: $*"
    if [ "$DRY_RUN" = 1 ]; then
        printf '  %s+ %s%s\n' "$C_DIM" "$*" "$C_RESET"
        return 0
    fi
    if [ "$VERBOSE" = 1 ]; then
        "$@"
    else
        "$@" >>"${LOG_FILE:-/dev/null}" 2>&1
    fi
}

# 需要特权的命令
SUDO=""
IS_ROOT=0
NO_PRIV=0
detect_priv() {
    if [ "$(id -u 2>/dev/null || echo 1000)" = 0 ]; then
        IS_ROOT=1
    elif command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        NO_PRIV=1
    fi
}
as_root() {
    if [ "$IS_ROOT" = 1 ]; then
        run "$@"
    elif [ -n "$SUDO" ]; then
        # shellcheck disable=SC2086  # $SUDO 故意不加引号：空值时应整体消失
        run $SUDO "$@"
    else
        err "需要 root 或 sudo 权限：$*"
        return 1
    fi
}

# ────────────────────────────── 系统探测 ──────────────────────────────
PM=""        # apk | apt | dnf | yum | pacman | zypper
PM_FAMILY="" # 便于给镜像用
DISTRO_ID=""
DISTRO_VER=""
DISTRO_CODENAME=""
ARCH=""

detect_os() {
    ARCH=$(uname -m 2>/dev/null || echo unknown)
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_VER="${VERSION_ID:-}"
        DISTRO_CODENAME="${VERSION_CODENAME:-}"
        DISTRO_NAME="${PRETTY_NAME:-${NAME:-$DISTRO_ID}}"
    else
        DISTRO_ID=$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')
        DISTRO_NAME="$DISTRO_ID"
    fi
}

detect_pm() {
    if command -v apk >/dev/null 2>&1; then
        PM=apk; PM_FAMILY=alpine
    elif command -v apt-get >/dev/null 2>&1; then
        PM=apt; PM_FAMILY=debian
    elif command -v dnf >/dev/null 2>&1; then
        PM=dnf; PM_FAMILY=redhat
    elif command -v yum >/dev/null 2>&1; then
        PM=yum; PM_FAMILY=redhat
    elif command -v pacman >/dev/null 2>&1; then
        PM=pacman; PM_FAMILY=arch
    elif command -v zypper >/dev/null 2>&1; then
        PM=zypper; PM_FAMILY=suse
    else
        PM=""
    fi
}

# ────────────────────────── 包管理器原语 ──────────────────────────
pm_update() {
    case "$PM" in
        apk)    as_root apk update ;;
        apt)    as_root env DEBIAN_FRONTEND=noninteractive apt-get update -y ;;
        dnf)    as_root dnf -q makecache -y ;;
        yum)    as_root yum -q makecache -y ;;
        pacman) as_root pacman -Sy --noconfirm ;;
        zypper) as_root zypper --non-interactive --quiet refresh ;;
        *)      return 1 ;;
    esac
}

pm_install() {
    [ $# -gt 0 ] || return 0
    case "$PM" in
        apk)    as_root apk add --no-cache "$@" ;;
        apt)    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" ;;
        dnf)    as_root dnf install -y "$@" ;;
        yum)    as_root yum install -y "$@" ;;
        pacman) as_root pacman -S --noconfirm --needed "$@" ;;
        zypper) as_root zypper --non-interactive install "$@" ;;
        *)      return 1 ;;
    esac
}

# 包是否已安装
pm_installed() {
    case "$PM" in
        apk)    apk info -e "$1" >/dev/null 2>&1 ;;
        apt)    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed' ;;
        dnf|yum|zypper) rpm -q "$1" >/dev/null 2>&1 ;;
        pacman) pacman -Q "$1" >/dev/null 2>&1 ;;
        *)      return 1 ;;
    esac
}

# 包在源里是否可获取（注意：apk 的 search 无论命中与否都返回 0，只能看输出）
pm_available() {
    case "$PM" in
        apk)    [ -n "$(apk search -e -x "$1" 2>/dev/null)" ] ;;
        apt)    [ -n "$(apt-cache policy "$1" 2>/dev/null | sed -n 's/^  Candidate: //p')" ] &&
                    ! apt-cache policy "$1" 2>/dev/null | grep -q 'Candidate: (none)' ;;
        dnf)    dnf -q list --available "$1" >/dev/null 2>&1 ;;
        yum)    yum -q list available "$1" >/dev/null 2>&1 ;;
        pacman) pacman -Si "$1" >/dev/null 2>&1 ;;
        zypper) zypper --non-interactive --quiet info "$1" >/dev/null 2>&1 ;;
        *)      return 1 ;;
    esac
}

# ────────────────────────── 包名映射 ──────────────────────────
# 每个 item 对应一组候选包名（按优先级）。取第一个"源里可用"的装，
# 避免 alpine 的 openjdk21-jdk / debian 的 openjdk-21-jdk-headless 这类差异散落在调用处。
item_candidates() {
    case "$PM:$1" in
        # —— 基础工具 ——
        *:base)      echo "bash curl git ripgrep ca-certificates" ;;

        # —— 运行时 ——
        apk:node)    echo "nodejs npm" ;;
        apt:node)    echo "nodejs npm" ;;
        dnf:node|yum:node|zypper:node|pacman:node) echo "nodejs npm" ;;

        apk:python)  echo "python3 py3-pip py3-virtualenv python3-dev" ;;
        apt:python)  echo "python3 python3-pip python3-venv python3-dev" ;;
        dnf:python|yum:python) echo "python3 python3-pip python3-devel" ;;
        zypper:python) echo "python3 python3-pip python3-devel" ;;
        pacman:python) echo "python python-pip" ;;

        # Java：候选按新到旧，装源里最新的那个
        apk:java)    echo "openjdk21-jdk openjdk17-jdk openjdk11-jdk" ;;
        apt:java)    echo "openjdk-21-jdk-headless openjdk-17-jdk-headless openjdk-11-jdk-headless" ;;
        dnf:java|yum:java) echo "java-21-openjdk-headless java-17-openjdk-headless java-11-openjdk-headless" ;;
        zypper:java) echo "java-21-openjdk java-17-openjdk" ;;
        pacman:java) echo "jdk21-openjdk jdk17-openjdk jdk-openjdk" ;;

        apk:go)      echo "go" ;;
        apt:go)      echo "golang-go" ;;
        dnf:go|yum:go) echo "golang" ;;
        zypper:go)   echo "go" ;;
        pacman:go)   echo "go" ;;

        apk:rust)    echo "rust cargo" ;;
        apt:rust)    echo "rustc cargo" ;;
        dnf:rust|yum:rust) echo "rust cargo" ;;
        zypper:rust) echo "rust cargo" ;;
        pacman:rust) echo "rust" ;;

        apk:php)     echo "php83 php82 php84" ;;
        apt:php)     echo "php-cli" ;;
        dnf:php|yum:php) echo "php-cli" ;;
        zypper:php)  echo "php" ;;
        pacman:php)  echo "php" ;;

        apk:ruby)    echo "ruby" ;;
        apt:ruby)    echo "ruby ruby-dev" ;;
        dnf:ruby|yum:ruby) echo "ruby ruby-devel" ;;
        zypper:ruby) echo "ruby ruby-devel" ;;
        pacman:ruby) echo "ruby" ;;

        # —— 编译工具链 ——
        apk:build)   echo "build-base make cmake" ;;
        apt:build)   echo "build-essential make cmake pkg-config" ;;
        dnf:build|yum:build) echo "gcc gcc-c++ make cmake" ;;
        zypper:build) echo "gcc gcc-c++ make cmake" ;;
        pacman:build) echo "base-devel cmake" ;;

        *) return 1 ;;
    esac
}

# 主包选定后必装的附加包（与主版本强相关，但不是并列候选）
item_extras() {
    case "$PM:$1" in
        # alpine 的 composer 需要对应版本的 phar 扩展才能跑
        apk:php) echo "$2-phar composer" ;;
        apt:php|dnf:php|yum:php|zypper:php|pacman:php) echo "composer" ;;
        *) : ;;
    esac
}

# 把 item 解析成具体包名：含多候选的（java/php）取首个可用主版本，再拼上附加包
resolve_item() {
    _cands=$(item_candidates "$1") || return 1
    [ -n "$_cands" ] || return 1

    # 单包直接返回
    case "$_cands" in
        *" "*) : ;;   # 多包，继续挑
        *)
            _out=$_cands
            _ex=$(item_extras "$1" "$_cands")
            [ -n "$_ex" ] && _out="$_cands $_ex"
            echo "$_out"
            return 0
            ;;
    esac

    # java/php 的候选是"多选一的主版本"，其余 item 的候选是"必装并列包"
    case "$1" in
        java|php)
            for _c in $_cands; do
                if pm_available "$_c"; then
                    _out=$_c
                    _ex=$(item_extras "$1" "$_c")
                    [ -n "$_ex" ] && _out="$_c $_ex"
                    echo "$_out"
                    return 0
                fi
            done
            # 都探测不到就交给包管理器，让它自己报错，信息更准确
            _c=$(echo "$_cands" | awk '{print $1}')
            _out=$_c
            _ex=$(item_extras "$1" "$_c")
            [ -n "$_ex" ] && _out="$_c $_ex"
            echo "$_out"
            return 0
            ;;
        *) echo "$_cands"; return 0 ;;
    esac
}

# ────────────────────────── 镜像源 ──────────────────────────
MIRROR=""
mirror_candidates() {
    case "$PM_FAMILY" in
        alpine) echo "mirrors.tuna.tsinghua.edu.cn mirrors.ustc.edu.cn mirrors.huaweicloud.com mirrors.cloud.tencent.com mirrors.aliyun.com" ;;
        debian) echo "mirrors.tuna.tsinghua.edu.cn mirrors.ustc.edu.cn mirrors.huaweicloud.com mirrors.cloud.tencent.com mirrors.aliyun.com" ;;
        redhat) echo "mirrors.tuna.tsinghua.edu.cn mirrors.ustc.edu.cn mirrors.huaweicloud.com mirrors.aliyun.com" ;;
        arch)   echo "mirrors.tuna.tsinghua.edu.cn mirrors.ustc.edu.cn mirrors.huaweicloud.com" ;;
        suse)   echo "mirrors.tuna.tsinghua.edu.cn mirrors.ustc.edu.cn" ;;
        *)      return 1 ;;
    esac
}

# 探测用的 URL：要能代表"该镜像真的能提供这个发行版的包索引"
probe_url() {
    case "$PM_FAMILY" in
        alpine) echo "http://$1/alpine/${ALPINE_BRANCH:-v3.21}/main/$ARCH/APKINDEX.tar.gz" ;;
        debian) echo "http://$1/${DEB_PATH:-debian}/dists/${DEB_SUITE:-stable}/Release" ;;
        redhat) echo "http://$1/rocky/${DISTRO_VER:-9}/BaseOS/$ARCH/os/repodata/repomd.xml" ;;
        arch)   echo "http://$1/archlinux/core/os/$ARCH/core.db" ;;
        suse)   echo "http://$1/opensuse/distribution/leap/${DISTRO_VER:-15.6}/repo/oss/repodata/repomd.xml" ;;
        *)      return 1 ;;
    esac
}

http_head_ok() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSI -m 8 -o /dev/null "$1" 2>/dev/null && return 0
        # 部分镜像不支持 HEAD，退化为 Range GET
        code=$(curl -fsS -m 8 -r 0-0 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || echo 000)
        [ "$code" = 200 ] || [ "$code" = 206 ]
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 8 --spider "$1" 2>/dev/null
    else
        return 1
    fi
}

compute_distro_meta() {
    case "$PM_FAMILY" in
        alpine)
            # 分支优先从现有源里读，兼容用户导入的不同 Alpine 版本
            ALPINE_BRANCH=""
            if [ -r /etc/apk/repositories ]; then
                ALPINE_BRANCH=$(sed -n 's#.*alpine/\([^/]*\)/.*#\1#p' /etc/apk/repositories 2>/dev/null | head -1)
            fi
            if [ -z "$ALPINE_BRANCH" ] && [ -n "$DISTRO_VER" ]; then
                ALPINE_BRANCH="v$(echo "$DISTRO_VER" | cut -d. -f1-2)"
            fi
            [ -n "$ALPINE_BRANCH" ] || ALPINE_BRANCH="v3.21"
            ;;
        debian)
            case "$DISTRO_ID" in
                ubuntu|linuxmint|pop) DEB_PATH=ubuntu ;;
                *) DEB_PATH=debian ;;
            esac
            DEB_SUITE="${DISTRO_CODENAME:-stable}"
            [ -n "$DEB_SUITE" ] || DEB_SUITE=stable
            ;;
    esac
}

pick_mirror() {
    _list=$(mirror_candidates) || return 1
    for _m in $_list; do
        _u=$(probe_url "$_m") || continue
        if http_head_ok "$_u"; then
            MIRROR=$_m
            return 0
        fi
    done
    return 1
}

BACKUP_DIR=""
backup_sources() {
    BACKUP_DIR="$STATE_DIR/sources-backup-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo 0)"
    mkdir -p "$BACKUP_DIR" 2>/dev/null || return 1
    case "$PM" in
        apk)  [ -f /etc/apk/repositories ] && cp -a /etc/apk/repositories "$BACKUP_DIR/" 2>/dev/null ;;
        apt)  [ -f /etc/apt/sources.list ] && cp -a /etc/apt/sources.list "$BACKUP_DIR/" 2>/dev/null
              [ -d /etc/apt/sources.list.d ] && cp -a /etc/apt/sources.list.d "$BACKUP_DIR/" 2>/dev/null ;;
        dnf|yum) [ -d /etc/yum.repos.d ] && cp -a /etc/yum.repos.d "$BACKUP_DIR/" 2>/dev/null ;;
        pacman) [ -f /etc/pacman.d/mirrorlist ] && cp -a /etc/pacman.d/mirrorlist "$BACKUP_DIR/" 2>/dev/null ;;
    esac
    return 0
}

restore_sources() {
    [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ] || return 0
    warn "回滚软件源配置：$BACKUP_DIR"
    case "$PM" in
        apk)  [ -f "$BACKUP_DIR/repositories" ] && as_root cp -a "$BACKUP_DIR/repositories" /etc/apk/repositories ;;
        apt)  [ -f "$BACKUP_DIR/sources.list" ] && as_root cp -a "$BACKUP_DIR/sources.list" /etc/apt/sources.list
              as_root rm -f /etc/apt/sources.list.d/envup-mirror.sources ;;
        dnf|yum) [ -d "$BACKUP_DIR/yum.repos.d" ] && as_root cp -a "$BACKUP_DIR/yum.repos.d/." /etc/yum.repos.d/ ;;
        pacman) [ -f "$BACKUP_DIR/mirrorlist" ] && as_root cp -a "$BACKUP_DIR/mirrorlist" /etc/pacman.d/mirrorlist ;;
    esac
}

apply_mirror() {
    [ -n "$MIRROR" ] || return 0
    # dry-run 不能有副作用：不建备份目录、不写源文件，只报告将要做什么
    if [ "$DRY_RUN" = 1 ]; then
        printf '  %s+ 换源 %s → %s（会先备份原配置）%s\n' "$C_DIM" "$PM" "$MIRROR" "$C_RESET"
        return 0
    fi
    backup_sources || { warn "备份软件源失败，跳过换源"; return 0; }

    case "$PM" in
        apk)
            # minirootfs 无 ca-certificates，用 http；apk 本身对索引与包做签名校验
            if [ "$DRY_RUN" = 1 ]; then
                printf '  %s+ 写入 /etc/apk/repositories → %s/alpine/%s%s\n' "$C_DIM" "$MIRROR" "$ALPINE_BRANCH" "$C_RESET"
            else
                printf 'http://%s/alpine/%s/main\nhttp://%s/alpine/%s/community\n' \
                    "$MIRROR" "$ALPINE_BRANCH" "$MIRROR" "$ALPINE_BRANCH" >/tmp/envup-repos.$$ &&
                    as_root cp /tmp/envup-repos.$$ /etc/apk/repositories
                rm -f /tmp/envup-repos.$$
            fi
            ;;
        apt)
            if [ "$DRY_RUN" = 1 ]; then
                printf '  %s+ 写入 /etc/apt/sources.list.d/envup-mirror.sources → %s%s\n' "$C_DIM" "$MIRROR" "$C_RESET"
            else
                {
                    printf 'Types: deb\n'
                    printf 'URIs: http://%s/%s\n' "$MIRROR" "$DEB_PATH"
                    printf 'Suites: %s %s-updates %s-security\n' "$DEB_SUITE" "$DEB_SUITE" "$DEB_SUITE"
                    printf 'Components: main contrib non-free non-free-firmware\n'
                } >/tmp/envup-src.$$ &&
                    as_root cp /tmp/envup-src.$$ /etc/apt/sources.list.d/envup-mirror.sources
                rm -f /tmp/envup-src.$$
            fi
            ;;
        pacman)
            if [ "$DRY_RUN" = 1 ]; then
                printf '  %s+ 重写 /etc/pacman.d/mirrorlist → %s%s\n' "$C_DIM" "$MIRROR" "$C_RESET"
            else
                # $repo / $arch 是 pacman 的变量，必须原样保留不展开
                # shellcheck disable=SC2016
                printf 'Server = http://%s/archlinux/$repo/os/$arch\n' "$MIRROR" >/tmp/envup-ml.$$
                as_root cp /tmp/envup-ml.$$ /etc/pacman.d/mirrorlist
                rm -f /tmp/envup-ml.$$
            fi
            ;;
        dnf|yum|zypper)
            warn "$PM 暂不支持自动换源，使用系统默认源"
            return 0
            ;;
    esac
    ok "软件源 → $MIRROR（原配置备份在 $BACKUP_DIR）"
}

# ────────────────────────── 档案（profile）──────────────────────────
# 每个档案 = 若干 item 的组合
PROFILES="base node python java go rust php ruby build common full"

profile_items() {
    case "$1" in
        base)   echo "base" ;;
        node)   echo "base node" ;;
        python) echo "base python" ;;
        java)   echo "base java" ;;
        go)     echo "base go" ;;
        rust)   echo "base rust" ;;
        php)    echo "base php" ;;
        ruby)   echo "base ruby" ;;
        build)  echo "base build" ;;
        common) echo "base node python" ;;
        full)   echo "base node python java go rust php ruby build" ;;
        *)      return 1 ;;
    esac
}

profile_desc() {
    case "$1" in
        base)   echo "基础工具（bash curl git ripgrep ca-certificates）" ;;
        node)   echo "Node.js + npm" ;;
        python) echo "Python 3 + pip + venv" ;;
        java)   echo "JDK（自动选源里最新的 LTS 主版本）" ;;
        go)     echo "Go" ;;
        rust)   echo "Rust + cargo" ;;
        php)    echo "PHP + Composer" ;;
        ruby)   echo "Ruby" ;;
        build)  echo "编译工具链（gcc/make/cmake）" ;;
        common) echo "常用组合：Node.js + Python 3" ;;
        full)   echo "全套：所有运行时 + 编译工具链" ;;
        *)      echo "$1" ;;
    esac
}

# ────────────────────────── 校验 ──────────────────────────
verify_item() {
    case "$1" in
        node)   _c=node;    _a="--version" ;;
        python) _c=python3; _a="--version" ;;
        java)   _c=java;    _a="-version" ;;
        go)     _c=go;      _a="version" ;;
        rust)   _c=rustc;   _a="--version" ;;
        php)    _c=php;     _a="--version" ;;
        ruby)   _c=ruby;    _a="--version" ;;
        base)   _c=git;     _a="--version" ;;
        build)  _c='make';  _a='--version' ;;
        *)      return 0 ;;
    esac
    if command -v "$_c" >/dev/null 2>&1; then
        # java -version 走 stderr
        _v=$("$_c" "$_a" 2>&1 | head -1)
        printf '  %s·%s %-8s %s\n' "$C_DIM" "$C_RESET" "$1" "$_v"
    else
        printf '  %s·%s %-8s %s（未生效，可能需要重开终端）%s\n' "$C_DIM" "$C_RESET" "$1" "$C_YELLOW" "$C_RESET"
    fi
}

# ────────────────────────── 安装主流程 ──────────────────────────
collect_items() {
    # 合并多个档案的 item，去重保序
    for _p in "$@"; do
        _items=$(profile_items "$_p") || die "未知档案：$_p（可用：$PROFILES）"
        for _i in $_items; do
            case " $COLLECTED " in
                *" $_i "*) : ;;
                *) COLLECTED="$COLLECTED $_i" ;;
            esac
        done
    done
    COLLECTED=${COLLECTED# }
}

confirm() {
    [ "$ASSUME_YES" = 1 ] && return 0
    [ "$INTERACTIVE" = 1 ] || return 0
    printf '确认执行？[Y/n] ' >&2
    _a=""
    IFS= read -r _a <&3 || _a=""
    case "$_a" in
        n|N|no|NO) return 1 ;;
        *) return 0 ;;
    esac
}

do_install() {
    [ $# -gt 0 ] || die "缺档案参数。可用：$PROFILES"

    [ -n "$PM" ] || die "未识别的包管理器（支持 apk / apt-get / dnf / yum / pacman / zypper）"
    if [ "$DRY_RUN" = 0 ] && [ "$NO_PRIV" = 1 ]; then
        die "需要 root 或 sudo 才能安装系统包"
    fi

    compute_distro_meta
    COLLECTED=""
    collect_items "$@"

    # ── 计划 ──
    say ""
    printf '%s安装计划%s  %s%s · %s · %s%s\n' \
        "$C_BOLD" "$C_RESET" "$DISTRO_NAME" "$C_DIM" "$PM" "$ARCH" "$C_RESET"
    hr
    PLAN_PKGS=""
    for _i in $COLLECTED; do
        _pkgs=$(resolve_item "$_i") || { warn "跳过未知项：$_i"; continue; }
        printf '  %-8s → %s%s%s\n' "$_i" "$C_DIM" "$_pkgs" "$C_RESET"
        for _p in $_pkgs; do
            case " $PLAN_PKGS " in
                *" $_p "*) : ;;
                *) PLAN_PKGS="$PLAN_PKGS $_p" ;;
            esac
        done
        INSTALLED_ITEMS="$INSTALLED_ITEMS $_i"
    done
    PLAN_PKGS=${PLAN_PKGS# }
    [ -n "$PLAN_PKGS" ] || die "没有可解析的安装项"
    hr

    # ── 已装过滤 ──
    TODO_PKGS=""
    SKIPPED=""
    for _p in $PLAN_PKGS; do
        if pm_installed "$_p"; then
            SKIPPED="$SKIPPED $_p"
        else
            TODO_PKGS="$TODO_PKGS $_p"
        fi
    done
    TODO_PKGS=${TODO_PKGS# }
    if [ -n "$SKIPPED" ]; then
        printf '%s已安装，跳过：%s%s\n' "$C_DIM" "${SKIPPED# }" "$C_RESET"
    fi

    if [ -z "$TODO_PKGS" ]; then
        ok "目标环境已就绪，无需安装"
        say ""
        for _i in $INSTALLED_ITEMS; do verify_item "$_i"; done
        return 0
    fi

    printf '待安装：%s%s%s\n' "$C_BOLD" "$TODO_PKGS" "$C_RESET"
    say ""
    confirm || { warn "已取消"; return 2; }

    # ── 换源（显式开启才动）──
    if [ "$USE_MIRROR" = 1 ]; then
        if pick_mirror; then
            ok "探测到可用镜像：$MIRROR"
            apply_mirror
        else
            warn "镜像探测失败，使用系统默认源"
        fi
    fi

    # ── 更新索引 + 安装 ──
    say ""
    hint "更新软件包索引…"
    if ! pm_update; then
        warn "索引更新失败"
        [ "$USE_MIRROR" = 1 ] && restore_sources
        [ "$DRY_RUN" = 1 ] || return 1
    fi

    hint "开始安装（可能需要几分钟）…"
    # shellcheck disable=SC2086  # 包名列表故意不加引号以做分词
    if ! pm_install $TODO_PKGS; then
        err "安装失败"
        say ""
        hint "排查建议："
        hint "  1. 加 --mirror 换国内源重试"
        hint "  2. 加 -v 查看完整输出"
        hint "  3. 日志：${LOG_FILE:-不可用}"
        [ "$USE_MIRROR" = 1 ] && restore_sources
        return 1
    fi

    # ── 结果 ──
    say ""
    hr
    ok "安装完成"
    for _i in $INSTALLED_ITEMS; do verify_item "$_i"; done
    hr
    hint "日志：${LOG_FILE:-不可用}"
    return 0
}

# ────────────────────────── doctor ──────────────────────────
do_doctor() {
    say ""
    printf '%s%senvup doctor%s  v%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET" "$ENVUP_VERSION"
    hr

    printf '%-14s %s\n' "系统" "${DISTRO_NAME:-未知}"
    printf '%-14s %s (%s)\n' "内核" "$(uname -r 2>/dev/null || echo '?')" "${ARCH:-?}"
    printf '%-14s %s\n' "包管理器" "${PM:-未识别}"
    if [ "$IS_ROOT" = 1 ]; then
        _priv=root
    elif [ -n "$SUDO" ]; then
        _priv="sudo 可用"
    else
        _priv="无 root/sudo"
    fi
    printf '%-14s %s\n' "权限" "$_priv"
    printf '%-14s %s\n' "交互" "$( [ "$INTERACTIVE" = 1 ] && echo 可用 || echo 不可用（将用默认值）)"

    _avail=$(df -Pk / 2>/dev/null | awk 'NR==2 {print int($4/1024)}')
    if [ -n "$_avail" ]; then
        if [ "$_avail" -lt 500 ] 2>/dev/null; then
            printf '%-14s %s MB %s(偏低)%s\n' "磁盘可用" "$_avail" "$C_YELLOW" "$C_RESET"
        else
            printf '%-14s %s MB\n' "磁盘可用" "$_avail"
        fi
    fi

    say ""
    printf '%s网络%s\n' "$C_BOLD" "$C_RESET"
    if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
        if http_head_ok "http://mirrors.tuna.tsinghua.edu.cn/" 2>/dev/null ||
           http_head_ok "https://mirrors.tuna.tsinghua.edu.cn/" 2>/dev/null; then
            printf '  %s✓%s 镜像站可达\n' "$C_GREEN" "$C_RESET"
        else
            printf '  %s!%s 镜像站不可达（可能需要代理）\n' "$C_YELLOW" "$C_RESET"
        fi
    else
        printf '  %s!%s 无 curl/wget，无法探测\n' "$C_YELLOW" "$C_RESET"
    fi

    say ""
    printf '%s已装运行时%s\n' "$C_BOLD" "$C_RESET"
    _any=0
    for _pair in "node:node --version" "python3:python3 --version" "java:java -version" \
                 "go:go version" "rustc:rustc --version" "php:php --version" \
                 "ruby:ruby --version" "git:git --version" "rg:rg --version"; do
        _cmd=${_pair%%:*}
        _args=${_pair#*:}
        if command -v "$_cmd" >/dev/null 2>&1; then
            # shellcheck disable=SC2086
            _v=$($_args 2>&1 | head -1)
            printf '  %s✓%s %-8s %s\n' "$C_GREEN" "$C_RESET" "$_cmd" "$_v"
            _any=1
        fi
    done
    [ "$_any" = 1 ] || printf '  %s（无）%s\n' "$C_DIM" "$C_RESET"
    hr
}

# ────────────────────────── list ──────────────────────────
do_list() {
    say ""
    printf '%s可用档案%s（%s）\n' "$C_BOLD" "$C_RESET" "$PM"
    hr
    for _p in $PROFILES; do
        printf '  %s%-8s%s %s\n' "$C_GREEN" "$_p" "$C_RESET" "$(profile_desc "$_p")"
    done
    hr
    hint "用法：envup install <档案...>   例：envup install common"
    hint "      envup install node python --mirror --yes"
}

# ────────────────────────── 交互菜单 ──────────────────────────
do_menu() {
    say ""
    printf '%s%senvup%s %s— 选择要安装的环境%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET" "$C_DIM" "$C_RESET"
    hr
    _i=1
    for _p in $PROFILES; do
        printf '  %s%2d.%s %-8s %s\n' "$C_GREEN" "$_i" "$C_RESET" "$_p" "$(profile_desc "$_p")"
        _i=$((_i + 1))
    done
    printf '  %s%2d.%s 查看环境自检\n' "$C_GREEN" "$_i" "$C_RESET"
    _i=$((_i + 1))
    printf '  %s%2d.%s 退出\n' "$C_DIM" "$_i" "$C_RESET"
    hr
    printf '请选择（可多选，空格分隔）: ' >&2
    _sel=""
    IFS= read -r _sel <&3 || { say ""; return 0; }
    [ -n "$_sel" ] || return 0

    _chosen=""
    for _n in $_sel; do
        case "$_n" in
            *[!0-9]*) warn "忽略非数字输入：$_n"; continue ;;
        esac
        _idx=1
        for _p in $PROFILES; do
            if [ "$_n" = "$_idx" ]; then _chosen="$_chosen $_p"; fi
            _idx=$((_idx + 1))
        done
        if [ "$_n" = "$_idx" ]; then do_doctor; return 0; fi
        _idx=$((_idx + 1))
        if [ "$_n" = "$_idx" ]; then return 0; fi
    done
    [ -n "$_chosen" ] || { warn "未选中任何档案"; return 0; }
    # shellcheck disable=SC2086
    do_install $_chosen
}

# ────────────────────────── 帮助 ──────────────────────────
usage() {
    cat <<EOF
${C_BOLD}envup${C_RESET} v$ENVUP_VERSION — 一条命令装好 Linux 开发环境

${C_BOLD}用法${C_RESET}
  envup                      交互菜单
  envup install <档案...>    安装（必需）
  envup doctor               环境自检
  envup list                 列出可用档案
  envup --help               显示帮助

${C_BOLD}选项${C_RESET}
  --yes, -y        跳过确认
  --mirror         自动探测并切换到国内镜像源（会先备份原配置）
  --dry-run        只打印将要执行的命令，不做任何修改
  --no-color       禁用颜色
  --verbose, -v    显示命令输出（默认写入日志）
  --version        显示版本

${C_BOLD}档案${C_RESET}
$(for _p in $PROFILES; do printf '  %-8s %s\n' "$_p" "$(profile_desc "$_p")"; done)

${C_BOLD}例${C_RESET}
  curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/envup.sh | sh
  curl -fsSL ... | sh -s -- install common --mirror
  sh envup.sh install node python java --mirror --yes
  sh envup.sh doctor

${C_BOLD}说明${C_RESET}
  · 幂等：已安装的包会跳过，可反复执行
  · 不越权：非 root 且无 sudo 时直接报错，不会静默失败
  · 不擅改软件源：仅 ${C_BOLD}--mirror${C_RESET} 时切换，失败自动回滚
  · 日志：\${XDG_STATE_HOME:-~/.local/state}/envup/envup.log
EOF
}

# ────────────────────────── 入口 ──────────────────────────
main() {
    _cmd=""
    _args=""
    for _a in "$@"; do
        case "$_a" in
            --dry-run)   DRY_RUN=1 ;;
            --yes|-y)    ASSUME_YES=1 ;;
            --mirror)    USE_MIRROR=1 ;;
            --no-color)  NO_COLOR_FORCED=1 ;;
            --verbose|-v) VERBOSE=1 ;;
            --version)   say "$PROG $ENVUP_VERSION"; exit 0 ;;
            --help|-h)   _cmd=help ;;
            -*)          err "未知选项：$_a"; say ""; usage; exit 2 ;;
            *)
                if [ -z "$_cmd" ] && { [ "$_a" = install ] || [ "$_a" = doctor ] ||
                                       [ "$_a" = list ] || [ "$_a" = help ] ||
                                       [ "$_a" = menu ]; }; then
                    _cmd=$_a
                else
                    _args="$_args $_a"
                fi
                ;;
        esac
    done

    init_input
    init_color
    init_log "$@"
    detect_os
    detect_pm
    detect_priv

    [ "$NO_PRIV" = 1 ] && [ "$DRY_RUN" = 0 ] && [ "$_cmd" = install ] &&
        die "需要 root 或 sudo 才能安装系统包（可用 --dry-run 预览）"

    case "${_cmd:-menu}" in
        install)
            # shellcheck disable=SC2086
            do_install $_args
            ;;
        doctor) do_doctor ;;
        list)   do_list ;;
        help)   usage ;;
        menu)
            if [ "$INTERACTIVE" = 1 ]; then
                do_menu
            else
                # curl | sh 且无 tty：不能交互，给出明确指引
                say ""
                err "当前没有可交互的终端（stdin 不是 tty）"
                hint "请指定要安装的档案，例如："
                hint "  curl -fsSL <URL> | sh -s -- install common"
                hint "  curl -fsSL <URL> | sh -s -- install node python"
                say ""
                do_list
                exit 2
            fi
            ;;
    esac
}

main "$@"
