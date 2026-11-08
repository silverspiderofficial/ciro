#!/usr/bin/env bash
# Builds a small, static FFmpeg command-line binary (with libx264) for Kiro's video renderer.
#
#   tool/ffmpeg/build_ffmpeg.sh android <out-dir>   # needs ANDROID_NDK_HOME (NDK r27+), host x86_64 or arm64 Linux
#   tool/ffmpeg/build_ffmpeg.sh linux   <out-dir>   # native Linux build (desktop + local verification)
#
# Windows: the same configure flags work under MSYS2/MinGW (target-os=mingw32); see README.
#
# Only the components the renderer uses are enabled (see lib/studio/video/ffmpeg_command.dart and
# lib/studio/editor/editor_command.dart; transpose/hflip/vflip let FFmpeg auto-rotate phone videos):
# PNG/JPEG stills, WAV narration, MP3/Ogg-Vorbis/AAC music, Ken Burns (scale+crop), xfade
# transitions, PNG overlays (animated text + burned-in subtitles), H.264 + AAC in MP4.
# Text is rendered by Flutter into PNGs, so no freetype/harfbuzz/libass is needed and Persian
# shaping is exactly what the app shows on screen.
#
# Licence note: libx264 is GPL-2.0+, so this FFmpeg build is GPL (--enable-gpl).
set -euo pipefail

TARGET="${1:?target: android|linux}"
OUT="$(mkdir -p "${2:?out dir}" && cd "$2" && pwd)"

FFMPEG_VERSION="8.1.3"
FFMPEG_SHA256="${FFMPEG_SHA256:-7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3}"
X264_COMMIT="b35605ace3ddf7c1a5d67a2eb553f034aef41d55"   # x264 'stable' branch head, 2026-11-08
API=26
JOBS="$(nproc 2>/dev/null || echo 4)"

WORK="${KIRO_FFMPEG_WORK:-$(pwd)/.ffmpeg-build}"
mkdir -p "$WORK"
cd "$WORK"
PREFIX="$WORK/prefix-$TARGET"

# ---- sources (pinned) ----
if [ ! -d "ffmpeg-$FFMPEG_VERSION" ]; then
  curl -fsSL -o "ffmpeg-$FFMPEG_VERSION.tar.xz" "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
  if [ -n "$FFMPEG_SHA256" ]; then
    echo "$FFMPEG_SHA256  ffmpeg-$FFMPEG_VERSION.tar.xz" | sha256sum -c -
  fi
  tar xf "ffmpeg-$FFMPEG_VERSION.tar.xz"
fi
if [ ! -d x264 ]; then
  git init -q x264
  git -C x264 remote add origin https://code.videolan.org/videolan/x264.git
  git -C x264 fetch -q --depth 1 origin "$X264_COMMIT"
  git -C x264 checkout -q FETCH_HEAD
fi
test "$(git -C x264 rev-parse HEAD)" = "$X264_COMMIT"

# ---- toolchain ----
COMMON_FF=()
X264_HOST=()
case "$TARGET" in
  android)
    NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
    [ -d "$NDK" ] || { echo "ANDROID_NDK_HOME not set" >&2; exit 1; }
    HOST_TAG="linux-x86_64"
    [ -d "$NDK/toolchains/llvm/prebuilt/$HOST_TAG" ] || HOST_TAG="$(ls "$NDK/toolchains/llvm/prebuilt" | head -1)"
    TC="$NDK/toolchains/llvm/prebuilt/$HOST_TAG"
    SYSROOT="$TC/sysroot"
    export CC="$TC/bin/aarch64-linux-android$API-clang"
    export CXX="$TC/bin/aarch64-linux-android$API-clang++"
    export AR="$TC/bin/llvm-ar" RANLIB="$TC/bin/llvm-ranlib" STRIP="$TC/bin/llvm-strip" NM="$TC/bin/llvm-nm"
    # 16 KB page alignment (Android 15+ devices).
    LDFLAGS_EXTRA="-Wl,-z,max-page-size=16384"
    X264_HOST=(--host=aarch64-linux-android --cross-prefix="$TC/bin/llvm-" --sysroot="$SYSROOT")
    COMMON_FF=(
      --enable-cross-compile --target-os=android --arch=aarch64 --cpu=armv8-a
      --cc="$CC" --cxx="$CXX" --ar="$AR" --ranlib="$RANLIB" --strip="$STRIP" --nm="$NM"
      --sysroot="$SYSROOT" --enable-pic
    )
    ;;
  linux)
    export CC="${CC:-cc}" CXX="${CXX:-c++}"
    LDFLAGS_EXTRA=""
    ;;
  *) echo "unknown target $TARGET" >&2; exit 1 ;;
esac

# ---- x264 (static) ----
if [ ! -f "$PREFIX/lib/libx264.a" ]; then
  rm -rf "x264-build-$TARGET" && cp -r x264 "x264-build-$TARGET"
  (
    cd "x264-build-$TARGET"
    ./configure --prefix="$PREFIX" --enable-static --enable-pic --disable-cli \
      --disable-opencl --disable-lavf --disable-swscale --disable-ffms --disable-gpac --disable-lsmash \
      --bit-depth=8 --chroma-format=420 "${X264_HOST[@]}" --extra-ldflags="$LDFLAGS_EXTRA"
    make -j"$JOBS"
    make install
  )
fi

# ---- FFmpeg ----
rm -rf "ffmpeg-build-$TARGET" && mkdir "ffmpeg-build-$TARGET"
cd "ffmpeg-build-$TARGET"
PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" \
"../ffmpeg-$FFMPEG_VERSION/configure" \
  "${COMMON_FF[@]}" \
  --prefix="$PREFIX" \
  --pkg-config=pkg-config --pkg-config-flags=--static \
  --extra-cflags="-I$PREFIX/include -O2" \
  --extra-ldflags="-L$PREFIX/lib $LDFLAGS_EXTRA" \
  --extra-libs="-lm" \
  --enable-gpl --enable-version3 \
  --disable-everything --disable-autodetect \
  --disable-doc --disable-debug --disable-network --disable-ffplay --disable-ffprobe \
  --disable-shared --enable-static \
  --enable-ffmpeg --enable-avcodec --enable-avformat --enable-avfilter --enable-swscale --enable-swresample \
  --enable-zlib --enable-libx264 \
  --enable-protocol=file,pipe \
  --enable-demuxer=image2,png_pipe,jpeg_pipe,webp_pipe,wav,mp3,ogg,mov,aac,concat,matroska,flac \
  --enable-decoder=png,mjpeg,webp,pcm_s16le,pcm_s24le,pcm_f32le,mp3,mp3float,vorbis,aac,h264,hevc,mpeg4,vp8,vp9,opus,flac \
  --enable-parser=png,mjpeg,webp,mpegaudio,vorbis,aac,h264,hevc,mpeg4video,vp8,vp9,opus,flac \
  --enable-encoder=libx264,aac,png \
  --enable-muxer=mp4,mov,image2,null \
  --enable-filter=scale,zoompan,crop,pad,format,fps,setsar,setpts,trim,null,copy,split,overlay,xfade,fade,concat,loop,color,colorchannelmixer,boxblur,eq,transpose,hflip,vflip \
  --enable-filter=atrim,asetpts,amix,volume,afade,apad,aresample,aformat,anull,adelay,aloop,anullsrc,acompressor,alimiter,asplit,sidechaincompress,atempo
make -j"$JOBS"
cp ffmpeg "$OUT/ffmpeg"
"${STRIP:-strip}" "$OUT/ffmpeg" || true
echo "built $OUT/ffmpeg ($(du -h "$OUT/ffmpeg" | cut -f1))"
