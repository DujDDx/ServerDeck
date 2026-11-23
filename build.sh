#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

BUILD="$ROOT/build"
DIST="$ROOT/dist"
APP="$DIST/ServerDeck.app"
SDK="$(xcrun --show-sdk-path)"
TARGET="arm64-apple-macos14.0"

if [ -z "${CODESIGN_IDENTITY:-}" ]; then
    CODESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)"
fi
IDENTITY="${CODESIGN_IDENTITY:--}"

build_icon() {
    echo "==> 生成图标"
    mkdir -p "$BUILD/AppIcon.iconset"
    xcrun swift "$ROOT/tools/make_icon.swift" "$BUILD/icon_1024.png" >/dev/null

    local set="$BUILD/AppIcon.iconset"
    local sizes=(16 32 64 128 256 512 1024)
    for s in "${sizes[@]}"; do
        sips -z "$s" "$s" "$BUILD/icon_1024.png" --out "$set/icon_${s}.png" >/dev/null
    done
    cp "$set/icon_16.png"   "$set/icon_16x16.png"
    cp "$set/icon_32.png"   "$set/icon_16x16@2x.png"
    cp "$set/icon_32.png"   "$set/icon_32x32.png"
    cp "$set/icon_64.png"   "$set/icon_32x32@2x.png"
    cp "$set/icon_128.png"  "$set/icon_128x128.png"
    cp "$set/icon_256.png"  "$set/icon_128x128@2x.png"
    cp "$set/icon_256.png"  "$set/icon_256x256.png"
    cp "$set/icon_512.png"  "$set/icon_256x256@2x.png"
    cp "$set/icon_512.png"  "$set/icon_512x512.png"
    cp "$set/icon_1024.png" "$set/icon_512x512@2x.png"
    iconutil -c icns "$set" -o "$BUILD/AppIcon.icns"
}

build() {
    rm -rf "$BUILD" "$DIST"
    mkdir -p "$BUILD" "$DIST"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

    build_icon

    echo "==> 编译主程序"
    xcrun swiftc -O -swift-version 5 -target "$TARGET" -sdk "$SDK" -parse-as-library \
        -module-name ServerDeck \
        Shared/*.swift App/*.swift App/Views/*.swift \
        -o "$BUILD/ServerDeck"

    echo "==> 组装 .app"
    cp "$BUILD/ServerDeck" "$APP/Contents/MacOS/ServerDeck"
    cp Resources/AppInfo.plist "$APP/Contents/Info.plist"
    cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    printf 'APPL????' > "$APP/Contents/PkgInfo"

    xattr -cr "$APP" 2>/dev/null || true

    echo "==> 签名（$IDENTITY）"
    codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
    codesign --verify --deep --strict "$APP"
    echo "==> 完成：$APP"
}

build_release() {
    rm -rf "$BUILD" "$DIST"
    mkdir -p "$BUILD" "$DIST"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

    build_icon

    echo "==> 编译通用架构（arm64 + x86_64）"
    for arch in arm64 x86_64; do
        xcrun swiftc -O -swift-version 5 -target "${arch}-apple-macos14.0" -sdk "$SDK" -parse-as-library \
            -module-name ServerDeck \
            Shared/*.swift App/*.swift App/Views/*.swift \
            -o "$BUILD/ServerDeck-$arch"
    done
    lipo -create -output "$BUILD/ServerDeck" \
        "$BUILD/ServerDeck-arm64" "$BUILD/ServerDeck-x86_64"

    echo "==> 组装 .app"
    cp "$BUILD/ServerDeck" "$APP/Contents/MacOS/ServerDeck"
    cp Resources/AppInfo.plist "$APP/Contents/Info.plist"
    cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    printf 'APPL????' > "$APP/Contents/PkgInfo"
    xattr -cr "$APP" 2>/dev/null || true

    echo "==> ad-hoc 签名"
    codesign --force --timestamp=none --sign - "$APP"
    codesign --verify --strict "$APP"

    local version
    version="$(plutil -extract CFBundleShortVersionString raw Resources/AppInfo.plist)"
    local zip="$DIST/ServerDeck-${version}-macos.zip"
    ditto -c -k --keepParent "$APP" "$zip"
    echo "==> Release 产物：$zip"
    lipo -info "$APP/Contents/MacOS/ServerDeck"
}

install_app() {
    # 旧版本可能注册过小组件扩展，先尽力注销。
    pluginkit -r "/Applications/ServerDeck.app/Contents/PlugIns/ServerDeckWidget.appex" 2>/dev/null || true

    pkill -x ServerDeck 2>/dev/null || true
    sleep 0.3
    rm -rf "/Applications/ServerDeck.app"
    ditto "$APP" "/Applications/ServerDeck.app"
    xattr -cr "/Applications/ServerDeck.app" 2>/dev/null || true

    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    "$LSREGISTER" -f "/Applications/ServerDeck.app" 2>/dev/null || true

    echo "==> 已安装到 /Applications/ServerDeck.app"
    open "/Applications/ServerDeck.app"
}

case "${1:-build}" in
    build)   build ;;
    release) build_release ;;
    install) build; install_app ;;
    run)     build; open "$APP" ;;
    clean)   rm -rf "$BUILD" "$DIST"; echo "已清理" ;;
    *)       echo "用法: $0 [build|release|install|run|clean]"; exit 1 ;;
esac
