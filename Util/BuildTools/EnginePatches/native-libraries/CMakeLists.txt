cmake_minimum_required(VERSION 3.16)
project(CarlaMacEngineLibraries LANGUAGES C CXX)
enable_language(OBJCXX)

if(NOT DEFINED ENGINE_ROOT)
  message(FATAL_ERROR "ENGINE_ROOT is required")
endif()
set(CMAKE_CXX_STANDARD 14)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(THIRD_PARTY "${ENGINE_ROOT}/Engine/Source/ThirdParty")

set(MTLPP_ROOT "${THIRD_PARTY}/mtlpp/mtlpp-master-7efad47")
file(GLOB MTLPP_SOURCES "${MTLPP_ROOT}/src/*.mm" "${MTLPP_ROOT}/src/*.cpp")
list(REMOVE_ITEM MTLPP_SOURCES "${MTLPP_ROOT}/src/command_encoder.mm")
add_library(mtlpp STATIC ${MTLPP_SOURCES})
target_include_directories(mtlpp PRIVATE "${MTLPP_ROOT}/src" "${MTLPP_ROOT}/interpose")
target_compile_definitions(mtlpp PRIVATE MTLPP_CONFIG_USE_SDK_AVAILABILITY=1)
target_compile_options(mtlpp PRIVATE -frtti -fno-objc-arc)
set_target_properties(mtlpp PROPERTIES OBJCXX_STANDARD 14)

file(GLOB VHACD_SOURCES "${THIRD_PARTY}/VHACD/src/*.cpp")
add_library(VHACD_LIB STATIC ${VHACD_SOURCES})
target_include_directories(VHACD_LIB PRIVATE "${THIRD_PARTY}/VHACD/inc" "${THIRD_PARTY}/VHACD/public")

add_library(nvtristrip STATIC
  "${THIRD_PARTY}/nvTriStrip/nvTriStrip-1.0.0/Src/NvTriStrip.cpp"
  "${THIRD_PARTY}/nvTriStrip/nvTriStrip-1.0.0/Src/NvTriStripObjects.cpp")
add_library(ForsythTriOptimizer STATIC "${THIRD_PARTY}/ForsythTriOO/Src/forsythtriangleorderoptimizer.cpp")
add_library(SPIRV-Reflect STATIC "${THIRD_PARTY}/SPIRV-Reflect/SPIRV-Reflect/spirv_reflect.c")

set(KISS_ROOT "${THIRD_PARTY}/Kiss_FFT/kiss_fft129")
add_library(KissFFT STATIC "${KISS_ROOT}/kiss_fft.c" "${KISS_ROOT}/tools/kfc.c"
  "${KISS_ROOT}/tools/kiss_fftnd.c" "${KISS_ROOT}/tools/kiss_fftndr.c" "${KISS_ROOT}/tools/kiss_fftr.c")
target_include_directories(KissFFT PRIVATE "${KISS_ROOT}" "${KISS_ROOT}/tools")

set(MCPP_ROOT "${THIRD_PARTY}/MCPP/mcpp-2.7.2")
set(MCPP_SOURCE "${CMAKE_CURRENT_BINARY_DIR}/mcpp-source")
file(GLOB MCPP_INPUTS "${MCPP_ROOT}/src/*" "${MCPP_ROOT}/config/*"
  "${MCPP_ROOT}/inc/*" "${MCPP_ROOT}/configure" "${MCPP_ROOT}/Makefile.in")
file(GLOB_RECURSE MCPP_MAKEFILES "${MCPP_ROOT}/*/Makefile.in")
list(APPEND MCPP_INPUTS ${MCPP_MAKEFILES})
foreach(INPUT_FILE IN LISTS MCPP_INPUTS)
  if(IS_DIRECTORY "${INPUT_FILE}")
    continue()
  endif()
  file(RELATIVE_PATH RELATIVE_FILE "${MCPP_ROOT}" "${INPUT_FILE}")
  file(READ "${INPUT_FILE}" CONTENT)
  string(REPLACE "\r\n" "\n" CONTENT "${CONTENT}")
  set(OUTPUT_FILE "${MCPP_SOURCE}/${RELATIVE_FILE}")
  set(OLD_CONTENT "")
  if(EXISTS "${OUTPUT_FILE}")
    file(READ "${OUTPUT_FILE}" OLD_CONTENT)
  endif()
  if(NOT CONTENT STREQUAL OLD_CONTENT)
    file(WRITE "${OUTPUT_FILE}" "${CONTENT}")
  endif()
endforeach()
include(ExternalProject)
ExternalProject_Add(mcpp_native
  SOURCE_DIR "${MCPP_SOURCE}"
  BINARY_DIR "${CMAKE_CURRENT_BINARY_DIR}/mcpp-build"
  DOWNLOAD_COMMAND ""
  CONFIGURE_COMMAND "${CMAKE_COMMAND}" -E env "CC=${CMAKE_C_COMPILER}"
    "CFLAGS=-arch arm64 -isysroot ${CMAKE_OSX_SYSROOT} -mmacosx-version-min=${CMAKE_OSX_DEPLOYMENT_TARGET} -O2 -fPIC -std=gnu99 -Wno-error=implicit-function-declaration"
    /bin/bash <SOURCE_DIR>/configure --srcdir=<SOURCE_DIR>
    --enable-mcpplib --disable-shared --build=arm-apple-darwin --host=arm-apple-darwin
  BUILD_COMMAND ""
  INSTALL_COMMAND ""
  BUILD_BYPRODUCTS "${CMAKE_CURRENT_BINARY_DIR}/mcpp-build/src/config.h")
add_library(mcpp STATIC "${MCPP_SOURCE}/src/main.c" "${MCPP_SOURCE}/src/directive.c"
  "${MCPP_SOURCE}/src/eval.c" "${MCPP_SOURCE}/src/expand.c" "${MCPP_SOURCE}/src/mbchar.c"
  "${MCPP_SOURCE}/src/support.c" "${MCPP_SOURCE}/src/system.c")
add_dependencies(mcpp mcpp_native)
target_include_directories(mcpp PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/mcpp-build/src")
target_compile_definitions(mcpp PRIVATE HAVE_CONFIG_H=1)
target_compile_options(mcpp PRIVATE -Wno-error=implicit-function-declaration)
set_target_properties(mcpp PROPERTIES C_STANDARD 99 C_EXTENSIONS ON)
