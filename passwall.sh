#!/bin/sh
set -eu

LOCKDIR="/tmp/passwall-install.lock"
GH_API="https://api.github.com/repos/Openwrt-Passwall/openwrt-passwall/releases/latest"
SF_BASE="https://sourceforge.net/projects/openwrt-passwall-build/files"
TMPFILES=""

register_tmp() {
    TMPFILES="$TMPFILES $1"
}

cleanup() {
    rmdir "$LOCKDIR" 2>/dev/null || true
    for f in $TMPFILES; do
        rm -f "$f" 2>/dev/null || true
    done
}

trap cleanup EXIT INT TERM

log() {
    printf '%s\n' "==> $*"
}

warn() {
    printf '%s\n' "[WARN] $*" >&2
}

die() {
    printf '%s\n' "[ERROR] $*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

refresh_luci() {
    rm -rf /tmp/luci-* /tmp/.luci* /tmp/etc/config/ucitrack /var/run/luci-indexcache 2>/dev/null || true
    if [ -x /etc/init.d/rpcd ]; then
        /etc/init.d/rpcd restart >/dev/null 2>&1 || warn "rpcd 重启失败"
    fi
}

download_file() {
    url="$1"
    output="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --connect-timeout 15 "$url" -o "$output" && return 0
        warn "curl 下载失败（将尝试跳过证书验证重试）: $url"
        curl -kfsSL --retry 2 --connect-timeout 15 "$url" -o "$output" && return 0
    fi

    if command -v wget >/dev/null 2>&1; then
        wget -qO "$output" "$url" && return 0
        warn "wget 下载失败（将尝试跳过证书验证重试）: $url"
        wget --no-check-certificate -qO "$output" "$url" && return 0
    fi

    return 1
}

fetch_text() {
    url="$1"
    tmp="$(mktemp /tmp/passwall-page.XXXXXX)"
    register_tmp "$tmp"
    download_file "$url" "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    cat "$tmp"
    rm -f "$tmp"
}

find_pkg_link() {
    page="$1"
    pkg="$2"
    link="$(printf '%s' "$page" | grep -o 'href="/projects/openwrt-passwall-build/files/[^"]*'"${pkg}"'_[^"]*\.ipk[^"]*"' | sed 's|^href="||;s|"$||' | head -n1)"
    if [ -z "$link" ]; then
        warn "在 SourceForge 页面中未找到包: $pkg"
        return 1
    fi
    printf '%s\n' "$link"
}

download_pkg_from_dir() {
    pkg="$1"
    dir="$2"
    sf_dir_url="${SF_BASE}/${PACKAGE_DIR}/${dir}/"
    page="$(fetch_text "$sf_dir_url")" || {
        warn "无法获取目录页: $sf_dir_url"
        return 1
    }
    link="$(find_pkg_link "$page" "$pkg")" || return 1

    case "$link" in
        */stats/timeline)
            link="${link%/stats/timeline}"
            ;;
    esac

    filename="$(basename "$link")"
    output="/tmp/$filename"
    register_tmp "$output"
    download_url="https://sourceforge.net${link}/download"

    log "下载: $filename" >&2
    download_file "$download_url" "$output" || {
        warn "下载失败: $download_url"
        return 1
    }
    [ -s "$output" ] || {
        warn "下载文件为空: $output"
        return 1
    }
    printf '%s\n' "$output"
}

if ! mkdir "$LOCKDIR" 2>/dev/null; then
    die "已有另一个 PassWall 任务正在运行"
fi

if command -v opkg >/dev/null 2>&1; then
    PKG_MGR="opkg"
elif command -v apk >/dev/null 2>&1; then
    die "当前环境包管理器为 apk（OpenWrt 25.12+），PassWall 安装脚本尚未适配。\n  请使用 OpenWrt 25.11 或更早版本，或等待脚本更新。"
else
    die "未检测到 opkg 或 apk，当前系统暂不支持"
fi

need_cmd opkg
need_cmd sed
need_cmd grep
need_cmd basename
need_cmd mktemp

[ -f /etc/openwrt_release ] || die "未检测到 /etc/openwrt_release"
# shellcheck disable=SC1091
. /etc/openwrt_release

ARCH="${DISTRIB_ARCH:-}"
REL_RAW="${DISTRIB_RELEASE:-}"
TARGET_NAME="${DISTRIB_TARGET:-}"
[ -n "$ARCH" ] || die "无法识别系统架构"
[ -n "$REL_RAW" ] || die "无法识别系统版本"

normalize_release_for_passwall() {
    case "$1" in
        25.[0-9]*|24.[0-9]*) printf '24.10' ;;
        23.05|23.05.[0-9]*) printf '23.05' ;;
        22.03|22.03.[0-9]*) printf '22.03' ;;
        *SNAPSHOT*) printf 'snapshots' ;;
        *) printf '' ;;
    esac
}

SUPPORTED_RELEASE="$(normalize_release_for_passwall "$REL_RAW")"
[ -n "$SUPPORTED_RELEASE" ] || die "当前系统版本 ${REL_RAW} 暂未适配 PassWall 安装脚本。建议使用 OpenWrt/iStoreOS/ImmortalWrt 22.03、23.05、24.10 系，或反馈 issue 补充适配。"

case "$SUPPORTED_RELEASE" in
    snapshots)
        PACKAGE_DIR="snapshots/packages/$ARCH"
        ;;
    *)
        PACKAGE_DIR="releases/packages-$SUPPORTED_RELEASE/$ARCH"
        ;;
esac

log "System release: $REL_RAW"
log "Arch: $ARCH"
[ -n "$TARGET_NAME" ] && log "Target: $TARGET_NAME"
log "Package dir: $PACKAGE_DIR"
if [ "$SUPPORTED_RELEASE" != "$REL_RAW" ]; then
    warn "当前系统版本 ${REL_RAW} 将按兼容目录 ${SUPPORTED_RELEASE} 匹配 PassWall 软件源。"
fi

GH_LATEST="$(fetch_text "$GH_API" 2>/dev/null | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1 || true)"
[ -n "$GH_LATEST" ] && log "GitHub latest release: $GH_LATEST"

OLD_VER="$(opkg status luci-app-passwall 2>/dev/null | sed -n 's/^Version: //p' | head -n1 || true)"
log "当前已安装版本: ${OLD_VER:-not installed}"
log "按接近手动 IPK 的方式安装 / 更新 PassWall"

install_lyaml_fallback() {
    case "$SUPPORTED_RELEASE" in
        24.10)
            dep_path="releases/${REL_RAW}/packages/${ARCH}/packages"
            ;;
        *)
            return 1
            ;;
    esac

    for mirror in \
        "https://downloads.openwrt.org" \
        "https://mirrors.tuna.tsinghua.edu.cn/openwrt" \
        "https://mirrors.ustc.edu.cn/openwrt" \
        "https://mirrors.aliyun.com/openwrt" \
        "https://mirrors.cernet.edu.cn/openwrt"
    do
        dep_base="${mirror}/${dep_path}"
        log "软件源安装 lyaml 失败，尝试从 ${dep_base} 直接下载依赖 IPK"
        dir_page="$(fetch_text "${dep_base}/")" || {
            warn "无法获取依赖目录: ${dep_base}/"
            continue
        }

        libyaml_name="$(printf '%s' "$dir_page" | grep -o "libyaml_[^\"'<>]*_${ARCH}\.ipk" | head -n1)"
        lyaml_name="$(printf '%s' "$dir_page" | grep -o "lyaml_[^\"'<>]*_${ARCH}\.ipk" | head -n1)"
        [ -n "$libyaml_name" ] || {
            warn "未找到 libyaml IPK（架构: $ARCH）"
            continue
        }
        [ -n "$lyaml_name" ] || {
            warn "未找到 lyaml IPK（架构: $ARCH）"
            continue
        }

        libyaml_ipk="/tmp/$libyaml_name"
        lyaml_ipk="/tmp/$lyaml_name"
        register_tmp "$libyaml_ipk"
        register_tmp "$lyaml_ipk"

        log "下载依赖: $libyaml_name"
        download_file "${dep_base}/${libyaml_name}" "$libyaml_ipk" || continue
        log "下载依赖: $lyaml_name"
        download_file "${dep_base}/${lyaml_name}" "$lyaml_ipk" || continue

        opkg install "$libyaml_ipk" "$lyaml_ipk" && return 0
    done

    return 1
}

if ! opkg list-installed lyaml 2>/dev/null | grep -q '^lyaml -'; then
    log "安装依赖: lyaml"
    opkg update || warn "opkg update 失败，将继续尝试安装已缓存的软件源依赖"
    opkg install lyaml || install_lyaml_fallback || die "安装依赖 lyaml 失败。请检查系统软件源是否启用 packages 源，或手动执行: opkg update && opkg install lyaml"
fi

MAIN_IPK="$(download_pkg_from_dir luci-app-passwall passwall_luci)" || die "下载 luci-app-passwall 失败，请检查当前系统版本/架构是否存在对应构建，或稍后重试。"
LANG_IPK="$(download_pkg_from_dir luci-i18n-passwall-zh-cn passwall_luci)" || die "下载 luci-i18n-passwall-zh-cn 失败，请稍后重试。"

if ! opkg install "$MAIN_IPK" "$LANG_IPK"; then
    cat >&2 <<EOF
[ERROR] PassWall 安装失败。
可能原因：
1. 当前固件版本与 PassWall 预编译包不匹配
2. 当前架构缺少对应依赖包，或软件源中没有兼容构建
3. 第三方固件重写了软件源，导致依赖解析异常

建议排查：
- 确认系统版本优先使用 22.03 / 23.05 / 24.10 系
- 执行 opkg update 后重试
- 检查 /etc/opkg/customfeeds.conf 是否存在异常或重复源
- 如为 iStoreOS 24.10 / 非标准固件，可优先使用 OpenClash，PassWall 兼容性取决于上游构建
EOF
    exit 1
fi

NEW_VER="$(opkg status luci-app-passwall 2>/dev/null | sed -n 's/^Version: //p' | head -n1 || true)"
log "安装后版本: ${NEW_VER:-unknown}"

refresh_luci
warn "默认不主动修改 /etc/config/passwall；如界面初次显示异常，可手动刷新页面或重新登录 LuCI"
warn "如界面初次显示为英文，请刷新页面，中文语言包会自动生效"
log "PassWall 处理完成"
