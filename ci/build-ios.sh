#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/build-ios"
deps="$build/deps"
artifact="$root/artifact-ios"
version=v0.7.0
archive="libmpv-xcframeworks_${version}_ios-universal-video-default.tar.gz"
url="https://github.com/media-kit/libmpv-darwin-build/releases/download/${version}/${archive}"
download_cache="${DARWIN_DOWNLOAD_CACHE:-$build}"
tarball="$download_cache/$archive"

rm -rf "$build" "$artifact"
mkdir -p "$deps/xcf" "$deps/lib/pkgconfig" "$deps/include" "$artifact" "$download_cache"
[ -s "$tarball" ] || curl -fL --retry 3 "$url" -o "$tarball"
tar -xzf "$tarball" --strip-components=1 -C "$deps/xcf"

for xcf in "$deps/xcf"/*.xcframework; do
    name="$(basename "$xcf" .xcframework)"
    binary="$(find "$xcf/ios-arm64" -maxdepth 3 -type f -name "$name" -print -quit 2>/dev/null || true)"
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
    source="/opt/homebrew/include/$subdir"
    [ -d "$source" ] || continue
    mkdir -p "$deps/include/$subdir"
    cp "$source"/*.h "$deps/include/$subdir/"
done
cp -RL "$(brew --prefix libplacebo)/include/libplacebo" "$deps/include/"

# The media-kit iOS profile does not compile a libplacebo renderer, but mpv's
# configure step still checks its version.
cat >"$deps/lib/pkgconfig/libplacebo.pc" <<EOF
prefix=$deps
includedir=\${prefix}/include
Name: libplacebo
Description: configure-only stub
Version: 7.360.1
Libs:
Cflags: -I\${includedir}
EOF

sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
cross="$build/ios.ini"
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
c_args = ['-arch', 'arm64', '-isysroot', '$sdk', '-miphoneos-version-min=12.0', '-I$deps/include']
c_link_args = ['-arch', 'arm64', '-isysroot', '$sdk', '-miphoneos-version-min=12.0', '-L$deps/lib']
cpp_args = ['-arch', 'arm64', '-isysroot', '$sdk', '-miphoneos-version-min=12.0', '-I$deps/include']
cpp_link_args = ['-arch', 'arm64', '-isysroot', '$sdk', '-miphoneos-version-min=12.0', '-L$deps/lib']
objc_args = ['-arch', 'arm64', '-isysroot', '$sdk', '-miphoneos-version-min=12.0', '-I$deps/include']
objc_link_args = ['-arch', 'arm64', '-isysroot', '$sdk', '-miphoneos-version-min=12.0', '-L$deps/lib']
objcpp_args = ['-arch', 'arm64', '-isysroot', '$sdk', '-miphoneos-version-min=12.0', '-I$deps/include']
objcpp_link_args = ['-arch', 'arm64', '-isysroot', '$sdk', '-miphoneos-version-min=12.0', '-L$deps/lib']

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[properties]
needs_exe_wrapper = true
pkg_config_libdir = '$deps/lib/pkgconfig'
EOF

meson_backup="$build/meson.build"
cp "$root/meson.build" "$meson_backup"
restore_meson() { cp "$meson_backup" "$root/meson.build"; }
trap restore_meson EXIT
sed -i.bak -E "s/version: '[^']+'/version: '>= 1.0'/g" "$root/meson.build"

export PKG_CONFIG_PATH="$deps/lib/pkgconfig"
meson setup "$build/mpv" --cross-file="$cross" --buildtype=release \
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
meson compile -C "$build/mpv" mpv
strip -x "$build/mpv/libmpv.dylib"

xcodebuild -create-xcframework \
    -library "$build/mpv/libmpv.dylib" -headers "$root/include/mpv" \
    -output "$artifact/Mpv.xcframework"
for xcf in "$deps/xcf"/*.xcframework; do
    [ "$(basename "$xcf")" = Mpv.xcframework ] || cp -R "$xcf" "$artifact/"
done
file "$build/mpv/libmpv.dylib"
