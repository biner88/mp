#!/usr/bin/env bash
set -euo pipefail

root=$PWD
prefix=$root/linux_prefix
sources=$root/linux_sources
builds=$root/linux_builds
mkdir -p "$prefix" "$sources" "$builds"

export CFLAGS="-O3 -fPIC -pipe"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-L$prefix/lib -static-libgcc -static-libstdc++"
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"

clone() {
    local repo=$1 dir=$2 ref=$3
    [ -d "$sources/$dir" ] || git clone --depth 1 --branch "$ref" --recursive "$repo" "$sources/$dir"
}

meson_build() {
    local source=$1 name=$2
    shift 2
    rm -rf "$builds/$name"
    meson setup "$builds/$name" "$source" --prefix="$prefix" --libdir=lib \
        --buildtype=release -Ddefault_library=static -Db_lto=false "$@"
    meson compile -C "$builds/$name"
    meson install -C "$builds/$name"
}

cmake_build() {
    local source=$1 name=$2
    shift 2
    rm -rf "$builds/$name"
    cmake -S "$source" -B "$builds/$name" -GNinja \
        -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DBUILD_SHARED_LIBS=OFF "$@"
    cmake --build "$builds/$name" -j"$(nproc)"
    cmake --install "$builds/$name"
}

if [ ! -f "$prefix/lib/libz.a" ]; then
    clone https://github.com/madler/zlib.git zlib v1.3.1
    cmake_build "$sources/zlib" zlib -DZLIB_BUILD_TESTING=OFF
fi

if [ ! -f "$prefix/lib/libmbedtls.a" ]; then
    clone https://github.com/Mbed-TLS/mbedtls.git mbedtls mbedtls-3.6.4
    cmake_build "$sources/mbedtls" mbedtls \
        -DENABLE_PROGRAMS=OFF -DENABLE_TESTING=OFF \
        -DUSE_SHARED_MBEDTLS_LIBRARY=OFF -DUSE_STATIC_MBEDTLS_LIBRARY=ON
fi

if [ ! -f "$prefix/lib/libdav1d.a" ]; then
    clone https://code.videolan.org/videolan/dav1d.git dav1d 1.5.1
    meson_build "$sources/dav1d" dav1d -Denable_tools=false -Denable_tests=false
fi

if [ ! -f "$prefix/lib/libavcodec.a" ]; then
    clone https://github.com/FFmpeg/FFmpeg.git ffmpeg n7.1.2
    rm -rf "$builds/ffmpeg"
    mkdir -p "$builds/ffmpeg"
    pushd "$builds/ffmpeg"
    "$sources/ffmpeg/configure" \
        --prefix="$prefix" --libdir="$prefix/lib" --incdir="$prefix/include" \
        --pkg-config-flags=--static --enable-static --disable-shared --enable-pic \
        --disable-gpl --enable-version3 --disable-doc --disable-programs \
        --disable-everything --enable-network \
        --enable-avutil --enable-avcodec --enable-avfilter --enable-avformat \
        --enable-swscale --enable-swresample --enable-libdav1d --enable-mbedtls \
        --enable-small --enable-bsfs --enable-hwaccels \
        --enable-decoder=flv,h263,h263i,h263p,h264,mpeg1video,mpeg2video,mpeg4,vp6,vp6a,vp6f,vp8,vp9,hevc,av1,libdav1d,theora,msmpeg4v1,msmpeg4v2,msmpeg4v3,mjpeg,wmv1,wmv2,wmv3 \
        --enable-decoder=aac,ac3,alac,als,ape,eac3,flac,mp1,mp2,mp3,opus,vorbis,wavpack,wmav1,wmav2,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le \
        --enable-decoder=ssa,ass,dvbsub,dvdsub,srt,subrip,text,webvtt,movtext,png,gif,bmp,tiff,webp \
        --enable-demuxer=concat,data,flv,hls,latm,live_flv,loas,m4v,mov,mpegps,mpegts,mpegvideo,hevc,rtsp,mjpeg,avi,av1,matroska,dash \
        --enable-demuxer=aac,ac3,aiff,ape,asf,au,flac,mp3,ogg,rm,tta,wav,wv,dsf,truehd,dts,ass,srt,webvtt \
        --enable-parser=h263,h264,hevc,mpeg4video,mpegvideo,aac,aac_latm,ac3,flac,mpegaudio,vorbis \
        --enable-filter=overlay,equalizer \
        --enable-protocol=async,cache,crypto,data,file,ftp,hls,http,httpproxy,https,pipe,rtmp,rtmps,rtp,subfile,tcp,tls \
        --enable-encoder=mjpeg,ljpeg,png
    make -j"$(nproc)"
    make install
    popd
fi

if [ ! -f "$prefix/lib/libfreetype.a" ]; then
    clone https://gitlab.freedesktop.org/freetype/freetype.git freetype VER-2-14-3
    meson_build "$sources/freetype" freetype
fi

if [ ! -f "$prefix/lib/libfribidi.a" ]; then
    clone https://github.com/fribidi/fribidi.git fribidi v1.0.16
    meson_build "$sources/fribidi" fribidi -Ddocs=false -Dtests=false
fi

if [ ! -f "$prefix/lib/libharfbuzz.a" ]; then
    clone https://github.com/harfbuzz/harfbuzz.git harfbuzz 14.2.0
    meson_build "$sources/harfbuzz" harfbuzz \
        -Dtests=disabled -Dutilities=disabled -Ddocs=disabled \
        -Dsubset=disabled -Dvector=disabled -Dgpu=disabled -Dgpu_demo=disabled
fi

if [ ! -f "$prefix/lib/libass.a" ]; then
    clone https://github.com/libass/libass.git libass 0.17.4
    meson_build "$sources/libass" libass -Dfontconfig=disabled
fi

if [ ! -f "$prefix/lib/libplacebo.a" ]; then
    clone https://code.videolan.org/videolan/libplacebo.git libplacebo v7.360.1
    meson_build "$sources/libplacebo" libplacebo \
        -Dvulkan=disabled -Dopengl=enabled -Dglslang=disabled \
        -Dshaderc=disabled -Dlcms=disabled -Ddovi=disabled -Dlibdovi=disabled \
        -Ddemos=false -Dtests=false -Dbench=false -Dfuzz=false \
        -Dunwind=disabled -Dxxhash=disabled
fi

if [ ! -f "$prefix/lib/libasound.a" ]; then
    clone https://github.com/alsa-project/alsa-lib.git alsa-lib v1.2.14
    pushd "$sources/alsa-lib"
    autoreconf -fi
    popd
    rm -rf "$builds/alsa-lib"
    mkdir -p "$builds/alsa-lib"
    pushd "$builds/alsa-lib"
    "$sources/alsa-lib/configure" --prefix="$prefix" --libdir="$prefix/lib" \
        --enable-static --disable-shared --disable-python
    make -j"$(nproc)"
    make install
    popd
fi

rm -rf linux_build
meson setup linux_build --buildtype=release \
    -Ddefault_library=shared -Dprefer_static=true \
    -Dlibmpv=true -Dcplayer=false -Dtests=false -Dgpl=false \
    -Dcplugins=disabled -Dlua=disabled -Djavascript=disabled \
    -Dlibarchive=disabled -Dlibbluray=disabled -Ddvdnav=disabled \
    -Dcdda=disabled -Ddvbin=disabled -Drubberband=disabled \
    -Dzimg=disabled -Dvapoursynth=disabled -Dsubrandr=disabled \
    -Dsdl2-gamepad=disabled -Dsdl2-video=disabled -Dsdl2-audio=disabled \
    -Diconv=disabled -Dlcms2=disabled -Duchardet=disabled \
    -Dlibavdevice=disabled -Dlibcurl=disabled -Djpeg=disabled \
    -Djack=disabled -Dopenal=disabled -Doss-audio=disabled -Dsndio=disabled \
    -Dpipewire=disabled -Dpulse=disabled -Dalsa=enabled \
    -Dx11=disabled -Dx11-clipboard=disabled -Dwayland=disabled \
    -Ddrm=disabled -Dgbm=disabled -Degl=disabled -Dplain-gl=enabled \
    -Dvulkan=disabled -Dvaapi=disabled -Dvdpau=disabled \
    -Dcaca=disabled -Dsixel=disabled -Dshaderc=disabled -Dspirv-cross=disabled
meson compile -C linux_build mpv
strip --strip-unneeded linux_build/libmpv.so

needed="$(readelf -d linux_build/libmpv.so | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p')"
unexpected="$(printf '%s\n' "$needed" | grep -Ev '^lib(c|m|pthread|dl|rt|resolv|util)\.so(\..*)?$' || true)"
if [ -n "$unexpected" ]; then
    printf 'Non-system shared dependencies remain:\n%s\n' "$unexpected" >&2
    exit 1
fi
printf 'Dynamic dependencies:\n%s\n' "$needed"
