#!/usr/bin/env bash
set -euo pipefail

# ---- helpers ----
log() { echo "$@" >&2; }
die() { log "ERROR: $*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "command not found: $1"
}

# Build a minimal OpenCV xcframework for Stitcher (pure C++, no CvVideoCamera/CaptureDelegate).
#
# Why:
# - OpenCV's iOS camera wrappers (CvVideoCamera/CvPhotoCamera/...) are Objective-C classes.
# - Other prebuilt SDKs may embed the same classes.
# - Linking OpenCV2.framework (or a build that includes cap_ios.mm) can cause duplicate ObjC classes at runtime.
#
# This script builds OpenCV as static libraries and packages them into an xcframework via:
#   xcodebuild -create-xcframework -library ... -headers ...
#
# Output:
#   KKGimbal/ThirdParty/OpenCVStitching/OpenCVStitching.xcframework
#
# Requirements (local machine):
# - Xcode + command line tools
# - CMake >= 3.20
# - Python3
# - Ninja (optional, recommended)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${ROOT_DIR}/Dependencies/OpenCV"
BUILD_DIR="${ROOT_DIR}/.build-opencv"

OPENCV_VERSION="${OPENCV_VERSION:-4.10.0}"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-15.0}"
OPENCV_ZIP="opencv-${OPENCV_VERSION}.zip"
OPENCV_URL="https://github.com/opencv/opencv/archive/refs/tags/${OPENCV_VERSION}.zip"

require_cmd xcodebuild
require_cmd curl
require_cmd unzip
require_cmd cmake
require_cmd xcrun
require_cmd libtool

log "[OpenCVStitching] root: ${ROOT_DIR}"
log "[OpenCVStitching] version: ${OPENCV_VERSION}"
log "[OpenCVStitching] iOS deployment target: ${IOS_DEPLOYMENT_TARGET}"
log "[OpenCVStitching] out: ${OUT_DIR}"
log "[OpenCVStitching] build: ${BUILD_DIR}"

mkdir -p "${BUILD_DIR}"
mkdir -p "${OUT_DIR}"

SRC_DIR="${BUILD_DIR}/opencv-${OPENCV_VERSION}"
if [[ ! -d "${SRC_DIR}" ]]; then
  log "[OpenCVStitching] downloading ${OPENCV_URL}"
  curl -L "${OPENCV_URL}" -o "${BUILD_DIR}/${OPENCV_ZIP}"
  log "[OpenCVStitching] extracting ${OPENCV_ZIP}"
  unzip -q "${BUILD_DIR}/${OPENCV_ZIP}" -d "${BUILD_DIR}"
fi

# The physical-object tracker also uses DNN to run the bundled NanoTrack ONNX models.
BUILD_LIST="core,imgproc,imgcodecs,calib3d,features2d,flann,photo,stitching,dnn"

COMMON_CMAKE_FLAGS=(
  "-DCMAKE_BUILD_TYPE=Release"
  "-DBUILD_SHARED_LIBS=OFF"
  "-DBUILD_opencv_world=ON"
  "-DBUILD_LIST=${BUILD_LIST}"
  "-DBUILD_TESTS=OFF"
  "-DBUILD_PERF_TESTS=OFF"
  "-DBUILD_EXAMPLES=OFF"
  "-DBUILD_DOCS=OFF"
  "-DBUILD_JAVA=OFF"
  "-DBUILD_OBJC=OFF"
  "-DBUILD_opencv_apps=OFF"
  "-DBUILD_opencv_highgui=OFF"
  "-DBUILD_opencv_videoio=OFF"
  "-DWITH_AVFOUNDATION=OFF"
  "-DWITH_QT=OFF"
  "-DWITH_OPENEXR=OFF"
  "-DWITH_ITT=OFF"
  "-DWITH_FFMPEG=OFF"
  "-DWITH_GSTREAMER=OFF"
  "-DWITH_V4L=OFF"
  "-DWITH_MSMF=OFF"
  "-DOPENCV_ENABLE_NONFREE=OFF"
  "-DOPENCV_GENERATE_PKGCONFIG=OFF"
)

function build_one() {
  local platform="$1"   # iphoneos / iphonesimulator
  local archs="$2"      # e.g. arm64 or "arm64;x86_64"
  local processor="$3"  # arm64 / x86_64
  local build_subdir="${BUILD_DIR}/build-${platform}"
  local install_dir="${BUILD_DIR}/install-${platform}"

  rm -rf "${build_subdir}" "${install_dir}"
  mkdir -p "${build_subdir}" "${install_dir}"

  log "[OpenCVStitching] configure ${platform} archs=${archs}"
  cmake -S "${SRC_DIR}" -B "${build_subdir}" \
    -GXcode \
    "-DCMAKE_SYSTEM_NAME=iOS" \
    "-DCMAKE_OSX_SYSROOT=${platform}" \
    "-DCMAKE_OSX_ARCHITECTURES=${archs}" \
    "-DCMAKE_OSX_DEPLOYMENT_TARGET=${IOS_DEPLOYMENT_TARGET}" \
    "-DCMAKE_SYSTEM_PROCESSOR=${processor}" \
    "-DCMAKE_C_COMPILER=$(xcrun -f clang)" \
    "-DCMAKE_CXX_COMPILER=$(xcrun -f clang++)" \
    "-DCMAKE_INSTALL_PREFIX=${install_dir}" \
    "${COMMON_CMAKE_FLAGS[@]}" >&2

  log "[OpenCVStitching] build+install ${platform}"
  cmake --build "${build_subdir}" --config Release --target install >&2

  # IMPORTANT: Only print the install dir to stdout (so command substitution works).
  printf "%s" "${install_dir}"
}

# Xcode 新版本在 Apple Silicon 上经常不再支持 x86_64 simulator（或会导致 CMake 找不到可用编译器）。
# 默认只构建 arm64 simulator。如需额外 x86_64，可设置 INCLUDE_SIM_X86_64=1。
SIM_ARCHS="arm64"
SIM_PROCESSOR="arm64"
if [[ "${INCLUDE_SIM_X86_64:-0}" == "1" ]]; then
  SIM_ARCHS="arm64;x86_64"
  SIM_PROCESSOR="arm64"
fi

IOS_INSTALL_DIR="$(build_one iphoneos arm64 arm64)"
SIM_INSTALL_DIR="$(build_one iphonesimulator "${SIM_ARCHS}" "${SIM_PROCESSOR}")"

IOS_LIB="${IOS_INSTALL_DIR}/lib/libopencv_world.a"
SIM_LIB="${SIM_INSTALL_DIR}/lib/libopencv_world.a"
HDR_DIR="${IOS_INSTALL_DIR}/include"

if [[ ! -f "${IOS_LIB}" ]]; then
  die "missing ${IOS_LIB}"
fi
if [[ ! -f "${SIM_LIB}" ]]; then
  die "missing ${SIM_LIB}"
fi
if [[ ! -d "${HDR_DIR}" ]]; then
  die "missing headers at ${HDR_DIR}"
fi

function merge_with_thirdparty() {
  local install_dir="$1"
  local platform="$2"
  local world_lib="${install_dir}/lib/libopencv_world.a"
  local thirdparty_dir="${install_dir}/lib/opencv4/3rdparty"
  local merged_dir="${BUILD_DIR}/merged-${platform}"
  local merged_lib="${merged_dir}/libopencv_world.a"
  local thirdparty_libs=("${thirdparty_dir}"/*.a)

  if [[ ! -f "${thirdparty_libs[0]}" ]]; then
    die "missing OpenCV third-party libraries at ${thirdparty_dir}"
  fi

  # opencv_world 仍引用静态构建产生的 jpeg/png/webp/zlib 符号。
  # 必须打进同一个 archive，否则移除 OpenCV Pod 后下游链接会缺符号。
  log "[OpenCVStitching] merge ${platform} world + third-party archives"
  rm -rf "${merged_dir}"
  mkdir -p "${merged_dir}"
  libtool -static -o "${merged_lib}" "${world_lib}" "${thirdparty_libs[@]}" >&2
  printf "%s" "${merged_lib}"
}

IOS_MERGED_LIB="$(merge_with_thirdparty "${IOS_INSTALL_DIR}" iphoneos)"
SIM_MERGED_LIB="$(merge_with_thirdparty "${SIM_INSTALL_DIR}" iphonesimulator)"

XC_OUT="${OUT_DIR}/OpenCVStitching.xcframework"
rm -rf "${XC_OUT}"

log "[OpenCVStitching] create xcframework"
xcodebuild -create-xcframework \
  -library "${IOS_MERGED_LIB}" -headers "${HDR_DIR}" \
  -library "${SIM_MERGED_LIB}" -headers "${HDR_DIR}" \
  -output "${XC_OUT}"

log "[OpenCVStitching] done: ${XC_OUT}"
log "Add this xcframework to your host target; see docs/INTEGRATION.md."




