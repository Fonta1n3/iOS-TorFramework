#!/usr/bin/env sh
set -e # abort if any command fails

MIN_IOS_VERSION="10.0"
PROJ_ROOT=${PWD}
BUILD_ROOT=${PROJ_ROOT}/build
OUTPUT_DIR=${BUILD_ROOT}/fat
LOG_FILE=/dev/null

build_init()
{
  LIB_NAME=$1
  PLATFORM=$2
  ARCH=$3
  TARGET=$4
  HOST=$5
  SDK=$6
  BITCODE=$7
  VERSION=$8
  SDK_PATH=`xcrun -sdk ${SDK} --show-sdk-path`
  PREFIX=${BUILD_ROOT}/${PLATFORM}-${ARCH}/${LIB_NAME}

  export CFLAGS="-O3 -arch ${ARCH} -isysroot ${SDK_PATH} ${BITCODE} ${VERSION} -target ${TARGET} -Wno-overriding-t-option"
  export CXXFLAGS="-O3 -arch ${ARCH} -isysroot ${SDK_PATH} ${BITCODE} ${VERSION} -target ${TARGET} -Wno-overriding-t-option"
  export LDFLAGS="-arch ${ARCH} ${BITCODE}"
  export CC="$(xcrun --sdk ${SDK} -f clang) -arch ${ARCH} -isysroot ${SDK_PATH}"
  export CXX="$(xcrun --sdk ${SDK} -f clang++) -arch ${ARCH} -isysroot ${SDK_PATH}"
  export LIBTOOL=`which glibtool`
  export LIBTOOLIZE=`which glibtoolize`
}

build_xz()
{
  build_init liblzma $@

  pushd Tor/xz

  if [[ ! -f ./configure ]]; then
      LIBTOOLIZE=glibtoolize
      ./autogen.sh
  fi

  make distclean 2>/dev/null ||:
  rm -rf "${PREFIX}/"

  ./configure \
    --disable-shared \
    --enable-static \
    --disable-doc \
    --disable-scripts \
    --disable-xz \
    --disable-xzdec \
    --disable-lzmadec \
    --disable-lzmainfo \
    --disable-lzma-links \
    --prefix="${PREFIX}" \
    cross_compiling="yes" \
    ac_cv_func_clock_gettime="no"
  make -j$(sysctl hw.ncpu | awk '{print $2}')
  make install
  make distclean

  popd
}

build_openssl()
{
  build_init openssl $@

  pushd Tor/openssl

  make distclean 2>/dev/null ||:
  rm -rf "${PREFIX}/"

  if [[ "${ARCH}" == "i386" ]]; then
    ./Configure \
      no-shared \
      no-asm \
      --prefix="${PREFIX}" \
      darwin-i386-cc
  elif [[ "${ARCH}" == "x86_64" ]]; then
    ./Configure \
      no-shared \
      no-asm \
      enable-ec_nistp_64_gcc_128 \
      --prefix="${PREFIX}" \
      darwin64-x86_64-cc
  elif [[ "${ARCH}" == "arm64" ]]; then
    ./Configure \
      no-shared \
      no-async \
      zlib-dynamic \
      enable-ec_nistp_64_gcc_128 \
      --prefix="${PREFIX}" \
      ios64-cross
  else
    ./Configure \
      no-shared \
      no-async \
      zlib-dynamic \
      --prefix="${PREFIX}" \
      ios-cross
  fi
  make depend
  make -j$(sysctl hw.ncpu | awk '{print $2}') build_libs
  make install_dev
  make distclean

  popd
}

build_libevent()
{
  build_init libevent $@

  pushd Tor/libevent

  if [[ ! -f ./configure ]]; then
      LIBTOOLIZE=glibtoolize
      ./autogen.sh
  fi

  make distclean 2>/dev/null ||:
  rm -rf "${PREFIX}/"

  # We need XPC to build libevent, so copy it from the OSX SDK into a temporary directory
  XPC_INCLUDE_DIR="${PREFIX}/libevent-xpc"
  mkdir -p "${XPC_INCLUDE_DIR}/xpc"
  cp -f "$(xcrun --sdk macosx --show-sdk-path)/usr/include/xpc/base.h" "${XPC_INCLUDE_DIR}/xpc"

  export CFLAGS+=" -I\"${PREFIX}\" -I\"${PROJ_ROOT}/Tor/openssl/include\" -I\"${XPC_INCLUDE_DIR}\""
  export LDFLAGS+=" -L${PREFIX}"

  ./configure \
    --disable-shared \
    --enable-static \
    --enable-gcc-hardening \
    --prefix="${PREFIX}" \
    cross_compiling="yes" \
    ac_cv_func_clock_gettime="no"
  make -j$(sysctl hw.ncpu | awk '{print $2}')
  make install

  popd
}

build_tor()
{
  build_init tor $@

  pushd Tor/tor

  if [[ ! -f ./configure ]]; then
      ./autogen.sh --add-missing
  fi
  make distclean 2>/dev/null ||:
  rm -rf "${PREFIX}/"

  # Disable PT_DENY_ATTACH because it is private API.
  PSEUDO_SYS_INCLUDE_DIR="${PREFIX}/tor-sys"
  mkdir -p "${PSEUDO_SYS_INCLUDE_DIR}/sys"
  touch "${PSEUDO_SYS_INCLUDE_DIR}/sys/ptrace.h"

  export CPPFLAGS+=" \
    -I${PROJ_ROOT}/Tor/tor/core \
    -I${PROJ_ROOT}/Tor/openssl/include \
    -I${PREFIX} \
    -I${PROJ_ROOT}/Tor/libevent/include \
    -I${BUILD_ROOT}/${ARCH}/libevent \
    -I${BUILD_ROOT}/${ARCH}/libevent/include \
    -I${BUILD_ROOT}/${ARCH}/liblzma \
    -I${BUILD_ROOT}/${ARCH}/liblzma/include \
    -I${PSEUDO_SYS_INCLUDE_DIR} \
    "
  export LDFLAGS+=" -lz"

  ./configure \
    --enable-restart-debugging \
    --enable-silent-rules \
    --enable-pic \
    --disable-module-dirauth \
    --disable-tool-name-check \
    --disable-unittests \
    --enable-static-openssl \
    --enable-static-libevent \
    --disable-asciidoc \
    --disable-system-torrc \
    --disable-linker-hardening \
    --disable-dependency-tracking \
    --disable-manpage \
    --disable-html-manual \
    --prefix="${PREFIX}" \
    --with-libevent-dir="${BUILD_ROOT}/${PLATFORM}-${ARCH}/libevent" \
    --with-openssl-dir="${BUILD_ROOT}/${PLATFORM}-${ARCH}/openssl" \
    --with-zlib-dir="${BUILD_ROOT}/${PLATFORM}-${ARCH}/liblzma" \
    --enable-lzma \
    --enable-zstd=no \
    cross_compiling="yes" \
    ac_cv_func__NSGetEnviron="no" \
    ac_cv_func_clock_gettime="no" \
    ac_cv_func_getentropy="no"

  declare -a LIBS=$(make show-libs)
  echo "LIBRARIES: ${LIBS[@]}"

  # There seems to be a race condition with the above configure and the later cp.
  # Just sleep a little so the correct file is copied and delete the old one before.
  sleep 2s
  rm -f src/lib/cc/orconfig.h
  cp orconfig.h "src/lib/cc/"

  make -j$(sysctl hw.ncpu | awk '{print $2}')

  cp micro-revision.i "${PREFIX}/micro-revision.i"

  for LIB in ${LIBS[@]}
  do
      cp $LIB "${PREFIX}/$(basename $LIB)"
  done

  make clean

  popd
}

build_deps()
(
  IOS_ARM64_PARAMS=("ios" "arm64" "aarch64-apple-ios" "arm-apple-darwin" "iphoneos" "-fembed-bitcode" "-mios-version-min=${MIN_IOS_VERSION}")
  MAC_CATALYST_X86_64_PARAMS=("mac-catalyst" "x86_64" "x86_64-apple-ios13.0-macabi" "x86_64-apple-darwin" "macosx" "-fembed-bitcode" "-mios-version-min=${MIN_IOS_VERSION}") # This is the build that runs under Catalyst
  IOS_SIMULATOR_X86_64_PARAMS=("ios-simulator" "x86_64" "x86_64-apple-ios" "x86_64-apple-darwin" "iphonesimulator" "-fembed-bitcode-marker" "-mios-simulator-version-min=${MIN_IOS_VERSION}")
  # IOS_ARMV7_PARAMS=("ios" "armv7" "armv7-apple-ios" "arm-apple-darwin" "iphoneos" "-fembed-bitcode" "-mios-version-min=${MIN_IOS_VERSION}")
  # IOS_SIMULATOR_I386_PARAMS=("ios-simulator" "i386" "i386-apple-ios" "i386-apple-darwin" "iphonesimulator" "-fembed-bitcode-marker" "-mios-simulator-version-min=${MIN_IOS_VERSION}")

  build_xz ${IOS_ARM64_PARAMS[@]}
  build_xz ${MAC_CATALYST_X86_64_PARAMS[@]}
  build_xz ${IOS_SIMULATOR_X86_64_PARAMS[@]}
  # build_xz ${IOS_ARMV7_PARAMS[@]}
  # build_xz ${IOS_SIMULATOR_I386_PARAMS[@]}

  build_openssl ${IOS_ARM64_PARAMS[@]}
  build_openssl ${MAC_CATALYST_X86_64_PARAMS[@]}
  build_openssl ${IOS_SIMULATOR_X86_64_PARAMS[@]}
  # # build_openssl ${IOS_ARMV7_PARAMS[@]}
  # # build_openssl ${IOS_SIMULATOR_I386_PARAMS[@]}
  #
  build_libevent ${IOS_ARM64_PARAMS[@]}
  build_libevent ${MAC_CATALYST_X86_64_PARAMS[@]}
  build_libevent ${IOS_SIMULATOR_X86_64_PARAMS[@]}
  # # build_libevent ${IOS_ARMV7_PARAMS[@]}
  # # build_libevent ${IOS_SIMULATOR_I386_PARAMS[@]}
  #
  build_tor ${IOS_ARM64_PARAMS[@]}
  build_tor ${MAC_CATALYST_X86_64_PARAMS[@]}
  build_tor ${IOS_SIMULATOR_X86_64_PARAMS[@]}
  # # build_tor ${IOS_ARMV7_PARAMS[@]}
  # # build_tor ${IOS_SIMULATOR_I386_PARAMS[@]}
)

build_framework()
{
  # https://stackoverflow.com/questions/56978529/using-xcodebuild-to-do-a-command-line-builds-for-catalyst-uikit-for-mac
  XC_ARCH=$1
  XC_BUILD_DIR_NAME=$2
  XC_SDK=$3
  XC_CATALYST=$4

  XC_PROJECT=Tor.xcodeproj
  XC_SCHEME=Tor-iOS
  XC_BUILD_DIR=${BUILD_ROOT}/${XC_BUILD_DIR_NAME}
  XC_ARCHIVE_PATH=${XC_BUILD_DIR}/Tor.xcarchive
  rm -rf ${ARCHIVE_PATH}
  xcodebuild clean archive \
    -project ${XC_PROJECT} \
    -scheme ${XC_SCHEME} \
    -archivePath ${XC_ARCHIVE_PATH} \
    -sdk ${XC_SDK} \
    ONLY_ACTIVE_ARCH=YES \
    ARCHS=${XC_ARCH} \
    SKIP_INSTALL=NO \
    BUILD_LIBRARIES_FOR_DISTRIBUTION=YES \
    SUPPORTS_MACCATALYST=${XC_CATALYST} \
    IPHONEOS_DEPLOYMENT_TARGET=10.0 \
    OTHER_LDFLAGS="\
      -L${XC_BUILD_DIR}/liblzma/lib \
      -L${XC_BUILD_DIR}/openssl/lib \
      -L${XC_BUILD_DIR}/libevent/lib \
      -L${XC_BUILD_DIR}/tor \
      "
}

build_frameworks()
{
  build_framework arm64 ios-arm64 iphoneos NO
  build_framework x86_64 mac-catalyst-x86_64 macosx YES
  build_framework x86_64 ios-simulator-x86_64 iphonesimulator NO

  # build_framework armv7 ios-armv7 iphoneos NO
  # build_framework i386 ios-simulator-i386 iphonesimulator NO
}

build_xcframework()
{
  xcodebuild -create-xcframework \
  -framework ${BUILD_ROOT}/ios-arm64/Tor.xcarchive/Products/@rpath/Tor.framework \
  -framework ${BUILD_ROOT}/mac-catalyst-x86_64/Tor.xcarchive/Products/@rpath/Tor.framework \
  -framework ${BUILD_ROOT}/ios-simulator-x86_64/Tor.xcarchive/Products/@rpath/Tor.framework \
  -output ${BUILD_ROOT}/Tor.xcframework

  # xcodebuild -create-xcframework \
  # -framework ${BUILD_ROOT}/mac-catalyst-x86_64/Tor.xcarchive/Products/@rpath/Tor.framework \
  # -output ${BUILD_ROOT}/Tor.xcframework

  # -framework ${BUILD_ROOT}/ios-simulator-i386/Tor.xcarchive/Products/@rpath/Tor.framework \
  # -framework ${BUILD_ROOT}/ios-armv7/Tor.xcarchive/Products/@rpath/Tor.framework \
}

build_deps
build_frameworks
build_xcframework
