#!/bin/bash
#
# build_ipa.sh - 一键出真机 .ipa(默认开发签名,上传蒲公英用)
#
# 用法:
#   ./CustomPatches/build_ipa.sh              # 开发签名(development)
#   ./CustomPatches/build_ipa.sh ad-hoc       # ad-hoc(仍限已注册设备)
#   ./CustomPatches/build_ipa.sh app-store    # App Store / TestFlight 上传包
#   ./CustomPatches/build_ipa.sh enterprise   # 企业签名(需企业账号)
#
# 前置条件:
#   1) 已在 Xcode 登录团队对应的 Apple ID(用于自动签名申请描述文件)
#   2) LoopConfigOverride.xcconfig 里已设 LOOP_DEVELOPMENT_TEAM
#   3) 开发/ad-hoc 签名的包只能装在描述文件里已注册的设备上
#
# 产物: build/Loop-<版本>-b<build号>-<method>.ipa  (build/ 已被 .gitignore 忽略)
# archive 与临时文件放在 /tmp,跑完自动清理,不污染仓库。
#
# 注: Xcode 16+ 起 method 的 "development" 已更名为 "debugging"、"ad-hoc" 更名为
#     "release-testing";当前(Xcode 26)旧名仍可用,只是有一条 deprecated 提示。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

METHOD="${1:-development}"
WORKSPACE="LoopWorkspace.xcworkspace"
SCHEME="LoopWorkspace"
OUTPUT_DIR="$ROOT/build"
STAMP="$$"
ARCHIVE_PATH="/tmp/LoopWorkspace-${STAMP}.xcarchive"
EXPORT_TMP="/tmp/LoopExport-${STAMP}"
EXPORT_OPTS="/tmp/ExportOptions-${STAMP}.plist"

cleanup() { rm -rf "$ARCHIVE_PATH" "$EXPORT_TMP" "$EXPORT_OPTS" "/tmp/prof-${STAMP}"; }
trap cleanup EXIT

# ---- 取 Team ID ----
TEAM="$(grep -E '^[[:space:]]*LOOP_DEVELOPMENT_TEAM' LoopConfigOverride.xcconfig 2>/dev/null | tail -1 | sed -E 's/.*=[[:space:]]*//' | tr -d '[:space:]')"
if [ -z "$TEAM" ]; then
    echo "错误: 在 LoopConfigOverride.xcconfig 里找不到 LOOP_DEVELOPMENT_TEAM，无法签名。"
    exit 1
fi
echo "==> Team ID: $TEAM   导出方式: $METHOD"

# ---- 生成 ExportOptions.plist ----
cat > "$EXPORT_OPTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>${METHOD}</string>
    <key>teamID</key><string>${TEAM}</string>
    <key>signingStyle</key><string>automatic</string>
    <key>compileBitcode</key><false/>
    <key>stripSwiftSymbols</key><true/>
    <key>destination</key><string>export</string>
</dict>
</plist>
PLIST

# ---- 1/2 archive(Release + 真机 + 自动签名)----
echo "==> [1/2] Archiving (Release, generic/iOS)... 这一步较久,请耐心等待"
rm -rf "$ARCHIVE_PATH"
xcodebuild -workspace "$WORKSPACE" -scheme "$SCHEME" -configuration Release \
    -archivePath "$ARCHIVE_PATH" -destination 'generic/platform=iOS' \
    -skipMacroValidation -allowProvisioningUpdates archive

# ---- 2/2 导出 .ipa ----
echo "==> [2/2] Exporting .ipa ..."
rm -rf "$EXPORT_TMP"
xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_TMP" -exportOptionsPlist "$EXPORT_OPTS" \
    -allowProvisioningUpdates

# ---- 命名 + 拷贝 ----
APP_PLIST="$ARCHIVE_PATH/Products/Applications/Loop.app/Info.plist"
VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST" 2>/dev/null || echo 'x')"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PLIST" 2>/dev/null || echo '0')"
SRC_IPA="$(ls "$EXPORT_TMP"/*.ipa 2>/dev/null | head -1)"
if [ -z "${SRC_IPA:-}" ]; then echo "错误: 导出目录没有 .ipa"; exit 1; fi
mkdir -p "$OUTPUT_DIR"

# 文件名带日期和超级项目 commit 短哈希。
# 版本号(3.15.2 b58)在合并上游后往往不变,只用它命名会导致同名覆盖、
# 丢掉上一个包无法对比(例如上游 bump 子模块使体积从 39.7MB 涨到 50MB 那次)。
DATE_TAG="$(date '+%Y%m%d')"
GIT_SHA="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo 'nogit')"
# 超级项目自身有未提交的跟踪文件改动时标记 dirty。
# 用 --ignore-submodules=all 排除子模块:补丁机制下子模块工作区常态是脏的(restore.sh
# 应用补丁所致),不应据此判定构建不可复现。
if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no --ignore-submodules=all 2>/dev/null)" ]; then
    GIT_SHA="${GIT_SHA}-dirty"
fi

DEST_IPA="$OUTPUT_DIR/Loop-${VER}-b${BUILD}-${DATE_TAG}-${GIT_SHA}-${METHOD}.ipa"
cp "$SRC_IPA" "$DEST_IPA"

# ---- 签名/设备摘要 ----
mkdir -p "/tmp/prof-${STAMP}"
unzip -o -j "$DEST_IPA" "Payload/Loop.app/embedded.mobileprovision" -d "/tmp/prof-${STAMP}" >/dev/null 2>&1 || true
PROF_XML="/tmp/prof-${STAMP}/prof.xml"
security cms -D -i "/tmp/prof-${STAMP}/embedded.mobileprovision" > "$PROF_XML" 2>/dev/null || true
EXPIRY="$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$PROF_XML" 2>/dev/null || echo '?')"
DEVCOUNT="$(/usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$PROF_XML" 2>/dev/null | grep -cE '^[[:space:]]+[0-9A-Fa-f]' || true)"
[ -z "$DEVCOUNT" ] && DEVCOUNT="0"

GIT_BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
IPA_SIZE="$(du -h "$DEST_IPA" 2>/dev/null | cut -f1 | tr -d ' ')"

echo ""
echo "========================================================"
echo "完成 ✅  $DEST_IPA"
echo "  版本: $VER (build $BUILD)    体积: $IPA_SIZE"
echo "  来源: $GIT_BRANCH @ $GIT_SHA"
echo "  导出: $METHOD    描述文件到期: $EXPIRY"
if [ "$METHOD" = "development" ] || [ "$METHOD" = "ad-hoc" ]; then
    echo "  已注册设备: $DEVCOUNT 台 (仅这些设备能安装)"
fi
echo "  上传蒲公英: 直接把该 .ipa 拖到 pgyer.com 即可"
echo "========================================================"
