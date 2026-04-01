#!/bin/bash
set -euo pipefail

# Build FFmpeg static libraries for iOS and tvOS, merge into a single xcframework.
#
# Usage: ./scripts/build-ffmpeg.sh
#
# Prerequisites:
#   - Xcode command-line tools installed
#   - Internet connection (downloads FFmpeg source)
#
# Output: FFmpegKit/Frameworks/FFmpeg.xcframework

FFMPEG_VERSION="7.1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
WORK_DIR="$PROJECT_ROOT/.ffmpeg-build"
OUTPUT_DIR="$PROJECT_ROOT/apple/FFmpegKit/Frameworks"

LIBRARIES=(libavformat libavcodec libavutil libswresample)

log() { echo "==> $*"; }

download_source() {
    local tarball="ffmpeg-${FFMPEG_VERSION}.tar.xz"
    local url="https://ffmpeg.org/releases/${tarball}"

    if [ -d "$WORK_DIR/ffmpeg-${FFMPEG_VERSION}" ]; then
        log "Source already exists, skipping download"
        return
    fi

    mkdir -p "$WORK_DIR"
    log "Downloading FFmpeg ${FFMPEG_VERSION}..."
    curl -L -o "$WORK_DIR/$tarball" "$url"
    log "Extracting..."
    tar xf "$WORK_DIR/$tarball" -C "$WORK_DIR"
    rm "$WORK_DIR/$tarball"
}

build_platform() {
    local name="$1"
    local sdk="$2"
    local arch="$3"
    local min_ver_flag="$4"

    local src_dir="$WORK_DIR/ffmpeg-${FFMPEG_VERSION}"
    local build_dir="$WORK_DIR/build-${name}"
    local prefix="$WORK_DIR/install-${name}"

    if [ -d "$prefix/lib" ]; then
        log "[$name] Already built, skipping"
        return
    fi

    local sysroot
    sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
    local cc
    cc="$(xcrun --sdk "$sdk" -f clang)"

    local extra_cflags="-arch ${arch} ${min_ver_flag} -isysroot ${sysroot}"
    local extra_ldflags="-arch ${arch} ${min_ver_flag} -isysroot ${sysroot}"

    log "[$name] Configuring (sdk=$sdk, arch=$arch)..."
    mkdir -p "$build_dir"
    cd "$build_dir"

    "$src_dir/configure" \
        --prefix="$prefix" \
        --enable-cross-compile \
        --target-os=darwin \
        --arch="$arch" \
        --cc="$cc" \
        --sysroot="$sysroot" \
        --extra-cflags="$extra_cflags" \
        --extra-ldflags="$extra_ldflags" \
        \
        --enable-static \
        --disable-shared \
        --enable-pic \
        \
        --disable-programs \
        --disable-doc \
        --disable-debug \
        --disable-autodetect \
        \
        --disable-avdevice \
        --disable-swscale \
        --disable-postproc \
        --disable-avfilter \
        \
        --enable-network \
        --enable-securetransport \
        --enable-protocol=file,http,https,tcp,tls,httpproxy \
        \
        --disable-encoders \
        --enable-encoder=aac \
        \
        --disable-decoders \
        --enable-decoder=aac \
        --enable-decoder=ac3 \
        --enable-decoder=eac3 \
        --enable-decoder=dca \
        --enable-decoder=truehd \
        --enable-decoder=flac \
        --enable-decoder=opus \
        --enable-decoder=vorbis \
        --enable-decoder=mp3 \
        --enable-decoder=pcm_s16le \
        --enable-decoder=pcm_s24le \
        --enable-decoder=pcm_s32le \
        --enable-decoder=pcm_f32le \
        --enable-decoder=subrip \
        --enable-decoder=ass \
        --enable-decoder=webvtt \
        \
        --disable-demuxers \
        --enable-demuxer=matroska \
        --enable-demuxer=mov \
        --enable-demuxer=mpegts \
        --enable-demuxer=hls \
        --enable-demuxer=avi \
        --enable-demuxer=webm_dash_manifest \
        --enable-demuxer=ogg \
        --enable-demuxer=flac \
        --enable-demuxer=srt \
        --enable-demuxer=ass \
        --enable-demuxer=webvtt \
        \
        --disable-muxers \
        --enable-muxer=hls \
        --enable-muxer=mpegts \
        --enable-muxer=webvtt \
        \
        --disable-parsers \
        --enable-parser=h264 \
        --enable-parser=hevc \
        --enable-parser=aac \
        --enable-parser=ac3 \
        --enable-parser=dca \
        --enable-parser=flac \
        --enable-parser=opus \
        --enable-parser=vorbis \
        --enable-parser=mpegaudio \
        \
        --disable-bsfs \
        --enable-bsf=extract_extradata \
        --enable-bsf=h264_mp4toannexb \
        --enable-bsf=hevc_mp4toannexb \
        --enable-bsf=aac_adtstoasc \
        --enable-bsf=dts2pts \
        \
        --disable-filters \
        --disable-devices \
        --disable-hwaccels \
        --enable-asm \
        --enable-neon \
        2>&1 | tail -5

    log "[$name] Building..."
    make -j"$(sysctl -n hw.ncpu)" 2>&1 | tail -3

    log "[$name] Installing..."
    make install 2>&1 | tail -3

    cd "$PROJECT_ROOT"
}

merge_and_create_xcframework() {
    log "Merging libraries and creating xcframework..."

    local platforms=("ios-arm64" "ios-sim-arm64" "tvos-arm64" "tvos-sim-arm64")

    # Merge static libraries per platform
    for name in "${platforms[@]}"; do
        local prefix="$WORK_DIR/install-${name}"
        local merged="$prefix/lib/libffmpeg.a"

        if [ -f "$merged" ]; then
            continue
        fi

        local libs=()
        for lib in "${LIBRARIES[@]}"; do
            if [ -f "$prefix/lib/${lib}.a" ]; then
                libs+=("$prefix/lib/${lib}.a")
            fi
        done

        log "  [$name] Merging ${#libs[@]} libraries..."
        libtool -static -o "$merged" "${libs[@]}" 2>/dev/null
    done

    # Create xcframework
    local xcf_path="$OUTPUT_DIR/FFmpeg.xcframework"
    rm -rf "$xcf_path"
    mkdir -p "$OUTPUT_DIR"

    local xcf_args=()
    for name in "${platforms[@]}"; do
        local prefix="$WORK_DIR/install-${name}"
        if [ -f "$prefix/lib/libffmpeg.a" ]; then
            xcf_args+=(-library "$prefix/lib/libffmpeg.a" -headers "$prefix/include")
        fi
    done

    log "  Creating FFmpeg.xcframework..."
    xcodebuild -create-xcframework "${xcf_args[@]}" -output "$xcf_path"

    # Add module.modulemap to each platform so Swift can import the C headers
    for dir in "$xcf_path"/*/Headers; do
        cat > "$dir/module.modulemap" << 'MODULEMAP'
module FFmpeg {
    header "libavformat/avformat.h"
    header "libavformat/avio.h"
    header "libavcodec/avcodec.h"
    header "libavcodec/codec_desc.h"
    header "libavutil/avutil.h"
    header "libavutil/dict.h"
    header "libavutil/pixdesc.h"
    header "libavutil/channel_layout.h"
    header "libavutil/opt.h"
    header "libavutil/error.h"
    header "libavutil/mathematics.h"
    header "libavutil/rational.h"
    header "libswresample/swresample.h"
    link "z"
    link "bz2"
    link "iconv"
    export *
}
MODULEMAP
    done
    log "  Added module.modulemap to all platforms"
}

# ---------- main ----------

log "FFmpeg build for iOS/tvOS"
log "Version: ${FFMPEG_VERSION}"
log "Output: ${OUTPUT_DIR}"
echo ""

download_source

build_platform "ios-arm64"      "iphoneos"         "arm64" "-miphoneos-version-min=17.0"
build_platform "ios-sim-arm64"  "iphonesimulator"  "arm64" "-mios-simulator-version-min=17.0"
build_platform "tvos-arm64"     "appletvos"        "arm64" "-mappletvos-version-min=17.0"
build_platform "tvos-sim-arm64" "appletvsimulator"  "arm64" "-mappletvsimulator-version-min=17.0"

merge_and_create_xcframework

log "Done! xcframework is at: $OUTPUT_DIR/FFmpeg.xcframework"
ls -la "$OUTPUT_DIR"

log "To clean up build files: rm -rf $WORK_DIR"
