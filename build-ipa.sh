#!/usr/bin/env bash
#
# build-ipa.sh — 命令行编译 Folium 未签名 .ipa(侧载用)
# ─────────────────────────────────────────────────────────────────────────────
# 这是在 macOS 26 + Xcode 26 上实测趟通的可复现配方。它会自动处理本仓库特有的
# 几个坑(每个坑都在对应步骤注释说明):
#
#   1) 缺依赖包 AntiqueKit —— 本仓库不是用 submodule,而是用相对路径 ../AntiqueKit
#      引用一个外部 SwiftPM 包(提供 ColourKit/FontKit/SettingsKit 等模块)。
#      `git clone --recursive` 拉不到它,必须单独克隆到 Folium 同级目录。
#
#   2) 代理黑洞 —— 某些代理(fake-ip / TUN 模式)对 GitHub「连得上、传不动」,xcodebuild 内部
#      用的 libgit2 在 "Resolve Package Graph" 阶段会卡死。git 命令行走代理是通的,
#      所以用 git CLI 建本地裸镜像,再用 git insteadOf 把远程依赖重定向到本地。
#
#   3) iOS 模拟器运行时 —— Xcode 26 的 actool 编译 App Icon.icon(Icon Composer
#      液态玻璃图标)时要用模拟器运行时渲染图标,否则报
#      "No available simulator runtimes"。装运行时后通常需要重启 Mac 才会注册到
#      `simctl list runtimes`(actool 用的接口)。
#
#   4) 不走 Archive —— Archive/分发会剥掉 get-task-allow,而模拟器 JIT 靠它。
#      所以这里只 build 再手动打 Payload zip;侧载时 AltStore/SideStore 用开发证书
#      重签会自动带上 get-task-allow → JIT 可用。
#
# 用法:
#   ./build-ipa.sh
#
# 可选环境变量:
#   FOLIUM_SKIP_MIRROR=1   跳过本地镜像/insteadOf(网络直连 GitHub 没问题时用)
#   FOLIUM_FORCE=1         模拟器运行时缺失时仍强行编译(大概率在 actool 失败)
#   FOLIUM_BUNDLE_ID=xxx   覆盖 Bundle Identifier(避免与已装的同 ID 冲突)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ---- 路径与常量 ----
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$PROJECT_DIR/Folium.xcodeproj"
TARGET="Folium"
CONFIG="Release"
OUT_DIR="$PROJECT_DIR/build"
ANTIQUEKIT_DIR="$(cd "$PROJECT_DIR/.." && pwd)/AntiqueKit"
ANTIQUEKIT_URL="https://github.com/jarrodnorwell/AntiqueKit.git"
MIRROR_ROOT="${FOLIUM_MIRROR_ROOT:-$HOME/.cache/folium-spm}"
RESOLVED="$PROJECT/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

log()  { printf '\033[1;34m▶ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ---- 1) 前置:完整 Xcode + 许可 ----
log "检查 Xcode 工具链..."
DEVDIR="$(xcode-select -p 2>/dev/null || true)"
case "$DEVDIR" in
  ""|*CommandLineTools*)
    die "当前不是完整 Xcode($DEVDIR)。装好 Xcode 后执行:
       sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" ;;
esac
xcodebuild -version >/dev/null 2>&1 \
  || die "xcodebuild 不可用(许可未接受?执行:sudo xcodebuild -license accept)"

# ---- 2) 依赖包 AntiqueKit(../AntiqueKit,非 submodule)----
if [ -f "$ANTIQUEKIT_DIR/Package.swift" ]; then
  log "AntiqueKit 已就位:$ANTIQUEKIT_DIR"
else
  log "缺少依赖包 AntiqueKit,克隆到 $ANTIQUEKIT_DIR ..."
  git clone "$ANTIQUEKIT_URL" "$ANTIQUEKIT_DIR" \
    || die "克隆 AntiqueKit 失败,请检查网络/代理"
fi

# ---- 3) iOS 模拟器运行时(actool 渲染 Icon Composer 图标必需)----
if xcrun simctl list runtimes 2>/dev/null | grep -qiE "iOS [0-9]"; then
  log "iOS 模拟器运行时已注册"
else
  warn "未检测到已注册的 iOS 模拟器运行时(simctl list runtimes 为空)。"
  warn "Xcode 26 的 actool 编译 App Icon.icon 需要它,否则会报 'No available simulator runtimes'。"
  warn "修复:"
  warn "    xcodebuild -downloadPlatform iOS     # 下载 iOS 模拟器运行时(约 8.5GB)"
  warn "    然后【重启 Mac】让 CoreSimulator 注册该运行时"
  [ "${FOLIUM_FORCE:-0}" = "1" ] || die "装好并重启后重跑;或设 FOLIUM_FORCE=1 强行继续。"
  warn "FOLIUM_FORCE=1 已设,继续(actool 很可能失败)..."
fi

# ---- 4) 代理黑洞规避:远程 SPM 依赖 → 本地 git 镜像 + insteadOf ----
declare -a CLEAN_KEYS=()
cleanup() {
  if [ "${#CLEAN_KEYS[@]}" -gt 0 ]; then
    for k in "${CLEAN_KEYS[@]}"; do
      git config --global --unset-all "$k" 2>/dev/null || true
    done
  fi
}
trap cleanup EXIT

if [ "${FOLIUM_SKIP_MIRROR:-0}" != "1" ] && [ -f "$RESOLVED" ]; then
  mkdir -p "$MIRROR_ROOT"
  while IFS= read -r url; do
    [ -z "$url" ] && continue
    name="$(basename "$url" .git)"
    mirror="$MIRROR_ROOT/$name.git"
    if [ -d "$mirror" ]; then
      log "复用本地镜像:$name"
    else
      log "建立本地镜像(git CLI 走代理):$name"
      git clone --mirror "$url" "$mirror" \
        || { warn "镜像 $name 失败,跳过(将直连,可能卡住)"; continue; }
    fi
    # 先清掉任何已有的、把同一 url 重定向走的旧 insteadOf,避免冲突
    while IFS= read -r oldkey; do
      [ -n "$oldkey" ] && git config --global --unset-all "$oldkey" 2>/dev/null || true
    done < <(git config --global --get-regexp 'url\..*\.insteadof' 2>/dev/null \
               | awk -v u="$url" '$2==u {print $1}')
    git config --global --add "url.$mirror.insteadOf" "$url"
    CLEAN_KEYS+=("url.$mirror.insteadOf")
  done < <(grep -oE '"location" : "[^"]+"' "$RESOLVED" \
             | sed -E 's/.*"location" : "([^"]+)".*/\1/' | sort -u)
fi

# ---- 5) 编译(未签名,真机,Release)----
# 用 -target(非 -scheme)绕开 destination 资格检查;SYMROOT 指定输出位置。
# 清空代理环境变量,避免 xcodebuild/libgit2 继承后又走代理黑洞。
log "编译 $TARGET ($CONFIG, iphoneos)... 首次约数分钟(含 C++ 核心)"
BID_ARGS=()
[ -n "${FOLIUM_BUNDLE_ID:-}" ] && BID_ARGS=(PRODUCT_BUNDLE_IDENTIFIER="$FOLIUM_BUNDLE_ID")
rm -rf "$OUT_DIR"
# 注:${arr[@]+"${arr[@]}"} 是 bash 3.2(macOS 自带)下 set -u 安全展开空数组的写法
env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy \
  xcodebuild \
    -project "$PROJECT" \
    -target "$TARGET" \
    -configuration "$CONFIG" \
    -sdk iphoneos \
    CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=NO \
    SYMROOT="$OUT_DIR" \
    ${BID_ARGS[@]+"${BID_ARGS[@]}"} \
    build

APP="$OUT_DIR/$CONFIG-iphoneos/$TARGET.app"
[ -d "$APP" ] || die "未找到产物 $APP —— 编译可能失败,请看上面的日志。"

# ---- 6) 打包未签名 .ipa(Payload/ → zip → .ipa)----
log "打包 .ipa ..."
STAGE="$OUT_DIR/ipa-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
IPA="$OUT_DIR/$TARGET.ipa"
rm -f "$IPA"
( cd "$STAGE" && zip -qry "$IPA" Payload )
rm -rf "$STAGE"

log "完成 ✅"
echo "  未签名 IPA:$IPA"
echo "  大小:$(du -h "$IPA" | cut -f1)"
echo "  → 用 AltStore / SideStore 安装。侧载会用开发证书重签,自动带上 get-task-allow → JIT 可用。"
