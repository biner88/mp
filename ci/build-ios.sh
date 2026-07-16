#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/build-ios"
deps_root="$build/deps"
artifact="$root/artifact-ios"
version=v0.7.0
archive="libmpv-xcframeworks_${version}_ios-universal-video-default.tar.gz"
url="https://github.com/media-kit/libmpv-darwin-build/releases/download/${version}/${archive}"
download_cache="${DARWIN_DOWNLOAD_CACHE:-$build}"
tarball="$download_cache/$archive"

rm -rf "$build" "$artifact"
mkdir -p "$deps_root/xcf" "$artifact" "$download_cache"
[ -s "$tarball" ] || curl -fL --retry 3 "$url" -o "$tarball"
tar -xzf "$tarball" --strip-components=1 -C "$deps_root/xcf"

stage_deps() {
    local slice=$1 deps=$2 xcf name binary lower subdir source
    mkdir -p "$deps/lib/pkgconfig" "$deps/include"
    for xcf in "$deps_root/xcf"/*.xcframework; do
        name="$(basename "$xcf" .xcframework)"
        binary="$(find "$xcf/$slice" -maxdepth 3 -type f -name "$name" -print -quit 2>/dev/null || true)"
        [ -n "$binary" ] || continue
        lower="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
        cp "$binary" "$deps/lib/lib${lower}.dylib"
        cat >"$deps/lib/pkgconfig/lib${lower}.pc" <<EOF
prefix=$deps
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: lib${lower}
Description: media-kit iOS dependency
Version: 999
Libs: -L\${libdir} -l${lower}
Cflags: -I\${includedir}
EOF
    done
    for subdir in libavcodec libavfilter libavformat libavutil libswresample libswscale ass; do
        source="$(brew --prefix)/include/$subdir"
        [ -d "$source" ] || continue
        mkdir -p "$deps/include/$subdir"
        cp "$source"/*.h "$deps/include/$subdir/"
    done
    cp -RL "$(brew --prefix libplacebo)/include/libplacebo" "$deps/include/"
    # This media-kit profile has no libplacebo renderer, but mpv checks its version.
    cat >"$deps/lib/pkgconfig/libplacebo.pc" <<EOF
prefix=$deps
includedir=\${prefix}/include
Name: libplacebo
Description: configure-only stub
Version: 7.360.1
Libs:
Cflags: -I\${includedir}
EOF
}

stage_deps ios-arm64 "$deps_root/device"
stage_deps ios-arm64_x86_64-simulator "$deps_root/simulator"

build_mpv() {
    local name=$1 sdk_name=$2 arch=$3 cpu_family=$4 target=$5 deps=$6
    local sdk cross
    sdk="$(xcrun --sdk "$sdk_name" --show-sdk-path)"
    cross="$build/$name.ini"
    cat >"$cross" <<EOF
[binaries]
c = '$(xcrun -f clang)'
cpp = '$(xcrun -f clang++)'
objc = '$(xcrun -f clang)'
objcpp = '$(xcrun -f clang++)'
ar = '$(xcrun -f ar)'
ranlib = '$(xcrun -f ranlib)'
strip = '$(xcrun -f strip)'
pkg-config = 'pkg-config'

[built-in options]
c_args = ['-target', '$target', '-arch', '$arch', '-isysroot', '$sdk', '-I$deps/include']
c_link_args = ['-target', '$target', '-arch', '$arch', '-isysroot', '$sdk', '-L$deps/lib']
cpp_args = ['-target', '$target', '-arch', '$arch', '-isysroot', '$sdk', '-I$deps/include']
cpp_link_args = ['-target', '$target', '-arch', '$arch', '-isysroot', '$sdk', '-L$deps/lib']
objc_args = ['-target', '$target', '-arch', '$arch', '-isysroot', '$sdk', '-I$deps/include']
objc_link_args = ['-target', '$target', '-arch', '$arch', '-isysroot', '$sdk', '-L$deps/lib']
objcpp_args = ['-target', '$target', '-arch', '$arch', '-isysroot', '$sdk', '-I$deps/include']
objcpp_link_args = ['-target', '$target', '-arch', '$arch', '-isysroot', '$sdk', '-L$deps/lib']

[host_machine]
system = 'darwin'
cpu_family = '$cpu_family'
cpu = '$arch'
endian = 'little'

[properties]
needs_exe_wrapper = true
pkg_config_libdir = '$deps/lib/pkgconfig'
EOF
    PKG_CONFIG_PATH="$deps/lib/pkgconfig" meson setup "$build/$name" \
        --cross-file="$cross" --buildtype=release \
    -Ddefault_library=shared -Dlibmpv=true \
    -Dcplayer=false -Dtests=false -Dgpl=false \
    -Dcplugins=disabled -Dlua=disabled -Djavascript=disabled \
    -Dlibarchive=disabled -Dlibbluray=disabled -Ddvdnav=disabled \
    -Dcdda=disabled -Ddvbin=disabled -Drubberband=disabled \
    -Dsdl2-gamepad=disabled -Dsdl2-video=disabled -Dzimg=disabled \
    -Dvapoursynth=disabled -Dcoreaudio=disabled -Davfoundation=disabled \
    -Daudiounit=enabled -Dcocoa=disabled -Dgl-cocoa=disabled \
    -Dgl=disabled -Dvulkan=disabled -Dmacos-cocoa-cb=disabled \
    -Dmacos-media-player=disabled -Dmacos-touchbar=disabled \
    -Dios-gl=disabled -Dvideotoolbox-gl=disabled \
    -Dlibcurl=disabled -Dx11=disabled -Dx11-clipboard=disabled \
    -Diconv=disabled -Dlcms2=disabled -Duchardet=disabled \
    -Dlibavdevice=disabled -Djack=disabled -Dpipewire=disabled \
    -Dpulse=disabled -Dalsa=disabled -Doss-audio=disabled \
    -Dsndio=disabled -Dopenal=disabled -Dopensles=disabled \
    -Daaudio=disabled -Dwasapi=disabled
    meson compile -C "$build/$name" mpv
    strip -x "$build/$name/libmpv.dylib"
}

meson_backup="$build/meson.build"
cp "$root/meson.build" "$meson_backup"
restore_meson() { cp "$meson_backup" "$root/meson.build"; }
trap restore_meson EXIT
sed -i.bak -E "s/version: '[^']+'/version: '>= 1.0'/g" "$root/meson.build"

build_mpv device iphoneos arm64 aarch64 arm64-apple-ios12.0 "$deps_root/device"
build_mpv simulator-arm64 iphonesimulator arm64 aarch64 arm64-apple-ios12.0-simulator "$deps_root/simulator"
build_mpv simulator-x86_64 iphonesimulator x86_64 x86_64 x86_64-apple-ios12.0-simulator "$deps_root/simulator"
mkdir -p "$build/simulator"
lipo -create "$build/simulator-arm64/libmpv.dylib" \
    "$build/simulator-x86_64/libmpv.dylib" \
    -output "$build/simulator/libmpv.dylib"

xcodebuild -create-xcframework \
    -library "$build/device/libmpv.dylib" -headers "$root/include/mpv" \
    -library "$build/simulator/libmpv.dylib" -headers "$root/include/mpv" \
    -output "$artifact/Mpv.xcframework"
# upload-artifact skips dylib symlinks, so store both names as regular files.
for pair in "ios-arm64:$build/device/libmpv.2.dylib" \
            "ios-arm64_x86_64-simulator:$build/simulator/libmpv.dylib"; do
    slice="${pair%%:*}"
    source="${pair#*:}"
    dir="$artifact/Mpv.xcframework/$slice"
    rm -f "$dir/libmpv.dylib" "$dir/libmpv.2.dylib"
    cp -L "$source" "$dir/libmpv.2.dylib"
    cp "$dir/libmpv.2.dylib" "$dir/libmpv.dylib"
done
for xcf in "$deps_root/xcf"/*.xcframework; do
    [ "$(basename "$xcf")" = Mpv.xcframework ] || cp -R "$xcf" "$artifact/"
done
file "$build/device/libmpv.dylib" "$build/simulator/libmpv.dylib"
test "$(lipo -archs "$build/simulator/libmpv.dylib")" = "x86_64 arm64" \
    -o "$(lipo -archs "$build/simulator/libmpv.dylib")" = "arm64 x86_64"
