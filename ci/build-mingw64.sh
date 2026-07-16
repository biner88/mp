#!/bin/bash
set -e

prefix_dir=$PWD/mingw_prefix
mkdir -p "$prefix_dir"
ln -snf . "$prefix_dir/usr"
ln -snf . "$prefix_dir/local"

wget="wget -nc --progress=bar:force"
gitclone="git clone --depth=1 --recursive --shallow-submodules"

if [[ -z "$TARGET" || -z "$RUST_TARGET" ]]; then
    echo "Error: must set TARGET and RUST_TARGET" >&2
    exit 1
fi
ln -snf "/usr/$TARGET" "$prefix_dir/$TARGET"
if ! command -v pkg-config >/dev/null; then
    echo "Error: missing pkg-config" >&2
    exit 1
fi

# -posix is Ubuntu's variant with pthreads support
export CC=$TARGET-gcc-posix
export AS=$TARGET-gcc-posix
export CXX=$TARGET-g++-posix
export AR=$TARGET-ar
export NM=$TARGET-nm
export RANLIB=$TARGET-ranlib

export CFLAGS="-O3 -flto -pipe -Wall"
export LDFLAGS="-flto -fstack-protector-strong -static-libgcc -static-libstdc++"

. ./ci/build-common.sh

if [[ "$TARGET" == "i686-"* ]]; then
    export WINEPATH="`$CC -print-file-name=`;/usr/$TARGET/lib"
fi

# anything that uses pkg-config
export PKG_CONFIG_SYSROOT_DIR="$prefix_dir"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_SYSROOT_DIR/lib/pkgconfig"

# autotools(-like)
at_flags="--enable-static --disable-shared"

# meson
fam=x86_64
[[ "$TARGET" == "i686-"* ]] && fam=x86
cat >"$prefix_dir/crossfile" <<EOF
[built-in options]
buildtype = 'release'
wrap_mode = 'nodownload'
default_library = 'static'
prefer_static = true
b_lto = true
optimization = '3'
[binaries]
c = ['ccache', '${CC}']
cpp = ['ccache', '${CXX}']
rust = ['rustc', '--target', '${RUST_TARGET}']
ar = '${AR}'
nm = '${NM}'
strip = '${TARGET}-strip'
pkgconfig = 'pkg-config'
pkg-config = 'pkg-config'
windres = '${TARGET}-windres'
dlltool = '${TARGET}-dlltool'
nasm = 'nasm'
exe_wrapper = 'wine'
[host_machine]
system = 'windows'
cpu_family = '${fam}'
cpu = '${TARGET%%-*}'
endian = 'little'
EOF

# CMake
cmake_args=(
    -Wno-dev
    -GNinja
    -DCMAKE_SYSTEM_PROCESSOR="${fam}"
    -DCMAKE_SYSTEM_NAME=Windows
    -DCMAKE_FIND_ROOT_PATH="$PKG_CONFIG_SYSROOT_DIR"
    -DCMAKE_RC_COMPILER="${TARGET}-windres"
    -DCMAKE_ASM_COMPILER="$AS"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON
    -DBUILD_SHARED_LIBS=OFF
)

export CC="ccache $CC"
export CXX="ccache $CXX"

function builddir {
    [ -d "$1/builddir" ] && rm -rf "$1/builddir"
    mkdir -p "$1/builddir"
    pushd "$1/builddir"
}

function makeplusinstall {
    if [ -f build.ninja ]; then
        ninja
        DESTDIR="$prefix_dir" ninja install
    else
        make -j$(nproc)
        make DESTDIR="$prefix_dir" install
    fi
}

# $1: URL to download
# $2: directory name inside tar (optional)
function gettar {
    local fname="${1##*/}"
    local dname="$2"
    [ -z "$dname" ] && dname="${fname%.tar.*}"
    [ -d "$dname" ] && return 0
    local cachename="$(md5sum <<<"$1" | cut -d " " -f 1)"
    if [[ -n "$DOWNLOAD_CACHE" && -s "$DOWNLOAD_CACHE/$cachename" ]]; then
        cp -v "$DOWNLOAD_CACHE/$cachename" "$fname"
        cachename=
    else
        $wget "$1" -O "$fname"
    fi
    tar -xaf "$fname"
    if [ ! -d "$dname" ]; then
        echo "Error: expected $fname to extract to $dname but it was not created" >&2
        return 2
    fi
    if [[ -n "$DOWNLOAD_CACHE" && -n "$cachename" ]]; then
        # assume successful extraction means the file was fine
        mkdir -p "$DOWNLOAD_CACHE"
        cp -v "$fname" "$DOWNLOAD_CACHE/$cachename"
    fi
}

function build_if_missing {
    local name=${1//-/_}
    local mark_var=_${name}_mark
    local mark_file=$prefix_dir/${!mark_var}
    [ -e "$mark_file" ] && return 0
    echo "::group::Building $1"
    _$name
    echo "::endgroup::"
    if [ ! -e "$mark_file" ]; then
        echo "Error: Build of $1 completed but $mark_file was not created" >&2
        return 2
    fi
}


## mpv's dependencies

_iconv () {
    local ver=1.19
    gettar "https://ftpmirror.gnu.org/gnu/libiconv/libiconv-${ver}.tar.gz"
    builddir libiconv-${ver}
    ../configure --host=$TARGET $at_flags
    makeplusinstall
    popd
}
_iconv_mark=lib/libiconv.a

_zlib_ng () {
    local ver=2.3.3
    gettar "https://github.com/zlib-ng/zlib-ng/archive/refs/tags/${ver}.tar.gz" zlib-ng-${ver}
    builddir zlib-ng-${ver}
    cmake .. "${cmake_args[@]}" \
        -DZLIB_COMPAT=ON -DBUILD_TESTING=OFF
    makeplusinstall
    popd
}
_zlib_ng_mark=lib/libz.a

_dav1d () {
    [ -d dav1d ] || $gitclone https://code.videolan.org/videolan/dav1d.git
    builddir dav1d
    meson setup .. --cross-file "$prefix_dir/crossfile" \
        -Denable_{tools,tests}=false
    makeplusinstall
    popd
}
_dav1d_mark=lib/libdav1d.a

_lcms2 () {
    [ -d lcms2 ] || $gitclone https://github.com/mm2/Little-CMS.git lcms2
    builddir lcms2
    meson setup .. --cross-file "$prefix_dir/crossfile" \
        -Dtests=disabled -D{utils,versionedlibs}=false
    makeplusinstall
    popd
}
_lcms2_mark=lib/liblcms2.a

_amf_headers () {
    local ver=1.5.2
    gettar "https://github.com/GPUOpen-LibrariesAndSDKs/AMF/releases/download/v${ver}/AMF-headers-v${ver}.tar.gz" amf-headers-v${ver}
    pushd amf-headers-v${ver}
    mkdir -p "$prefix_dir/include"
    cp -r AMF "$prefix_dir/include/"
    popd
}
_amf_headers_mark=include/AMF/core/Version.h

_ffmpeg () {
    [ -d ffmpeg ] || $gitclone https://github.com/FFmpeg/FFmpeg.git ffmpeg
    builddir ffmpeg
    local args=(
        --pkg-config=pkg-config --pkg-config-flags=--static
        --target-os=mingw32 --disable-gpl --enable-version3
        --enable-cross-compile --cross-prefix=$TARGET- --arch=${TARGET%%-*}
        --cc="$CC" --cxx="$CXX" $at_flags
        --disable-everything --disable-{doc,programs,vulkan,iconv}
        --enable-{avutil,avcodec,avfilter,avformat,avdevice,swscale,swresample}
        --enable-{small,network,hwaccels,bsfs,lto}
        --enable-libdav1d
        --enable-decoder=flv,h263,h263i,h263p,h264,mpeg1video,mpeg2video,mpeg4,vp6,vp6a,vp6f,vp8,vp9,hevc,av1,libdav1d,theora,msmpeg4v1,msmpeg4v2,msmpeg4v3,mjpeg,wmv1,wmv2,wmv3
        --enable-decoder=aac,ac3,alac,als,ape,atrac1,atrac3,atrac3al,atrac3p,atrac3pal,eac3,flac,gsm,gsm_ms,mp1,mp2,mp3,mpc7,mpc8,opus,ra_144,ra_288,ralf,shorten,tak,tta,vorbis,wavpack,wmalossless,wmapro,wmav1,wmav2,wmavoice,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le,dsd_lsbf,dsd_msbf,dca
        --enable-decoder=ssa,ass,dvbsub,dvdsub,srt,stl,subrip,subviewer,subviewer1,text,vplayer,webvtt,movtext
        --enable-decoder=ljpeg,jpegls,jpeg2000,png,gif,bmp,tiff,webp
        --enable-demuxer=concat,data,flv,hls,latm,live_flv,loas,m4v,mov,mpegps,mpegts,mpegvideo,hevc,rtsp,mjpeg,avi,av1,matroska,dash,webm_dash_manifest
        --enable-demuxer=aac,ac3,aiff,ape,asf,au,flac,mp3,mpc,mpc8,ogg,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le,rm,shorten,tak,tta,wav,wv,xwma,dsf,truehd,dts,dtshd
        --enable-demuxer=ass,srt,stl,webvtt,subviewer,subviewer1,vplayer
        --enable-parser=h263,h264,hevc,mpeg4video,mpegvideo,aac,aac_latm,ac3,cook,flac,gsm,mpegaudio,tak,vorbis,dca
        --enable-filter=overlay,equalizer
        --enable-protocol=async,cache,crypto,data,ffrtmphttp,file,ftp,hls,http,httpproxy,https,pipe,rtmp,rtmps,rtmpt,rtmpts,rtp,subfile,tcp,tls,srt
        --enable-encoder=mjpeg,ljpeg,jpegls,jpeg2000,png
    )
    ../configure "${args[@]}"
    makeplusinstall
    popd
}
_ffmpeg_mark=lib/libavcodec.a

_shaderc () {
    if [ ! -d shaderc ]; then
        $gitclone https://github.com/google/shaderc.git
        (cd shaderc && ./utils/git-sync-deps)
    fi
    builddir shaderc
    cmake .. "${cmake_args[@]}" \
        -DBUILD_SHARED_LIBS=OFF -DSHADERC_SKIP_TESTS=ON \
        -DSHADERC_SKIP_EXECUTABLES=ON
    makeplusinstall
    popd
}
_shaderc_mark=lib/libshaderc.a

_spirv_cross () {
    [ -d SPIRV-Cross ] || $gitclone https://github.com/KhronosGroup/SPIRV-Cross
    builddir SPIRV-Cross
    cmake .. "${cmake_args[@]}" \
        -DSPIRV_CROSS_SHARED=OFF -DSPIRV_CROSS_CLI=OFF -DSPIRV_CROSS_STATIC=ON
    makeplusinstall
    popd
    sed 's/-lspirv-cross-c$/-lspirv-cross-c -lspirv-cross-cpp -lspirv-cross-reflect -lspirv-cross-msl -lspirv-cross-hlsl -lspirv-cross-glsl -lspirv-cross-core/' \
        "$prefix_dir/lib/pkgconfig/spirv-cross-c.pc" \
        >"$prefix_dir/lib/pkgconfig/spirv-cross-c-shared.pc"
    sed -i "s|^Libs:.*|& $($TARGET-g++-posix -print-file-name=libstdc++.a)|" \
        "$prefix_dir/lib/pkgconfig/spirv-cross-c-shared.pc"
}
_spirv_cross_mark=lib/libspirv-cross-c.a

_nv_headers () {
    [ -d nv-codec-headers ] || $gitclone https://github.com/FFmpeg/nv-codec-headers
    pushd nv-codec-headers
    makeplusinstall
    popd
}
_nv_headers_mark=include/ffnvcodec/dynlink_loader.h

_vulkan_headers () {
    [ -d Vulkan-Headers ] || $gitclone https://github.com/KhronosGroup/Vulkan-Headers
    builddir Vulkan-Headers
    cmake .. "${cmake_args[@]}"
    makeplusinstall
    popd
}
_vulkan_headers_mark=include/vulkan/vulkan.h

_vulkan_loader () {
    [ -d Vulkan-Loader ] || $gitclone https://github.com/KhronosGroup/Vulkan-Loader
    builddir Vulkan-Loader
    cmake .. "${cmake_args[@]}" -DBUILD_SHARED_LIBS=ON -DUSE_GAS=ON
    makeplusinstall
    popd
}
_vulkan_loader_mark=lib/libvulkan-1.dll.a

_libplacebo () {
    [ -d libplacebo ] || $gitclone https://code.videolan.org/videolan/libplacebo.git
    builddir libplacebo
    meson setup .. --cross-file "$prefix_dir/crossfile" \
        -Ddemos=false -D{opengl,d3d11,lcms}=enabled
    makeplusinstall
    popd
}
_libplacebo_mark=lib/libplacebo.a

_freetype () {
    local ver=2.14.3
    gettar "https://download.savannah.gnu.org/releases/freetype/freetype-${ver}.tar.xz"
    builddir freetype-${ver}
    meson setup .. --cross-file "$prefix_dir/crossfile"
    makeplusinstall
    popd
}
_freetype_mark=lib/libfreetype.a

_fribidi () {
    local ver=1.0.16
    gettar "https://github.com/fribidi/fribidi/releases/download/v${ver}/fribidi-${ver}.tar.xz"
    builddir fribidi-${ver}
    meson setup .. --cross-file "$prefix_dir/crossfile" \
        -D{tests,docs}=false
    makeplusinstall
    popd
}
_fribidi_mark=lib/libfribidi.a

_harfbuzz () {
    local ver=14.2.0
    gettar "https://github.com/harfbuzz/harfbuzz/releases/download/${ver}/harfbuzz-${ver}.tar.xz"
    builddir harfbuzz-${ver}
    meson setup .. --cross-file "$prefix_dir/crossfile" \
        -D{tests,utilities,gpu,gpu_demo,vector,subset,docs}=disabled
    makeplusinstall
    popd
}
_harfbuzz_mark=lib/libharfbuzz.a

_libass () {
    [ -d libass ] || $gitclone https://github.com/libass/libass.git
    builddir libass
    meson setup .. --cross-file "$prefix_dir/crossfile"
    makeplusinstall
    popd
}
_libass_mark=lib/libass.a

_luajit () {
    [ -d LuaJIT ] || $gitclone https://github.com/LuaJIT/LuaJIT.git
    pushd LuaJIT
    local hostcc="ccache cc"
    local flags=
    if [[ "$TARGET" == "i686-"* ]]; then
        hostcc="$hostcc -m32"
        flags=XCFLAGS=-DLUAJIT_NO_UNWIND
    fi
    make TARGET_SYS=Windows clean
    make TARGET_SYS=Windows HOST_CC="$hostcc" CROSS="ccache $TARGET-" \
        BUILDMODE=static $flags amalg
    make DESTDIR="$prefix_dir" INSTALL_DEP= FILE_T=luajit.exe install
    sed -i -e 's/-Wl,-E//g' -e 's/-ldl//g' \
        "$prefix_dir/lib/pkgconfig/luajit.pc"
    popd
}
_luajit_mark=lib/libluajit-5.1.a

_subrandr () {
    build_subrandr "$prefix_dir" --target "$RUST_TARGET" \
        --static-library true --shared-library false -- -- -L"$prefix_dir"/lib
}
_subrandr_mark=lib/libsubrandr.a

_curl () {
    local ver=8.20.0
    gettar "https://curl.se/download/curl-${ver}.tar.xz"
    builddir curl-${ver}
    cmake .. "${cmake_args[@]}" \
        -DCURL_{USE_SCHANNEL,ZLIB}=ON -DCURL_DISABLE_LDAP=ON -DCURL_USE_LIBPSL=OFF
    makeplusinstall
    popd
}
_curl_mark=lib/libcurl.a

for x in iconv zlib-ng shaderc spirv-cross amf-headers nv-headers dav1d lcms2; do
    build_if_missing $x
done
if [[ "$TARGET" != "i686-"* ]]; then
    build_if_missing vulkan-headers
    build_if_missing vulkan-loader
fi
for x in ffmpeg libplacebo freetype fribidi harfbuzz libass; do
    build_if_missing $x
done
if [[ "$TARGET" != "i686-"* ]]; then
    build_if_missing subrandr
fi

## mpv

if [ -z "$1" ]; then
    echo "Not building mpv."
    exit 0
fi

CFLAGS+=" -I'$prefix_dir/include'"
LDFLAGS+=" -L'$prefix_dir/lib'"
export CFLAGS LDFLAGS
build=mingw_build
rm -rf $build

mpv_args=(
    --cross-file "$prefix_dir/crossfile" $common_args
    --buildtype release
    -Dstrip=true
    -Ddefault_library=shared
    --force-fallback-for=mujs
    -Dmujs:werror=false
    -Dmujs:default_library=static
    -Dlua=disabled
    -Dgpl=false
    -Db_lto=true
    -Doptimization=3
    -Dopenal=disabled
    -D{amf,shaderc,spirv-cross,d3d11,javascript}=enabled
    -Dlibcurl=disabled
)
[[ "$1" == libmpv ]] && mpv_args+=( -Dcplayer=false -Dtests=false )
meson setup $build "${mpv_args[@]}"
if [[ "$1" == libmpv ]]; then
    meson compile -C $build mpv
else
    meson compile -C $build
fi

if [ "$2" = pack ]; then
    mkdir -p artifact/tmp
    echo "Copying:"
    cp -pv $build/mpv.com $build/mpv.exe etc/mpv-*.bat artifact/

    echo "Adding DLLs:"
    # grab everything we can get our hands on
    cp -p "$prefix_dir/bin/"*.dll artifact/tmp/
    shopt -s nullglob
    for file in /usr/lib/gcc/$TARGET/*-posix/*.dll /usr/$TARGET/lib/*.dll; do
        cp -p "$file" artifact/tmp/
    done
    # pick DLLs we need
    pushd artifact/tmp
    dlls=(
        # compiler runtime
        libgcc_*.dll lib{ssp,stdc++,winpthread}-[0-9]*.dll
        # ffmpeg
        av*.dll sw*.dll postproc-[0-9]*.dll
        # everything else
        subrandr-[0-9]*.dll lib{ass,freetype,fribidi,harfbuzz,iconv,placebo}-[0-9]*.dll
        lib{curl,shaderc_shared,spirv-cross-c-shared,dav1d,lcms2,zlib1}.dll
    )
    [[ -f vulkan-1.dll ]] && dlls+=(vulkan-1.dll)
    mv -v "${dlls[@]}" ..
    popd
    rm -rf artifact/tmp
fi
