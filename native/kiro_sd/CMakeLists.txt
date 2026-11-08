# Kiro image engine: libkiro_sd (shared) = stable-diffusion.cpp + its own ggml, linked statically.
#
# Built as a standalone CMake project so it never clashes with llama.cpp's ggml targets:
#   - Android: android/app/src/main/cpp/CMakeLists.txt builds it with ExternalProject (same NDK
#     toolchain) and copies libkiro_sd.so next to libkiro_llm.so.
#   - Windows/Linux desktop: cmake -S native/kiro_sd -B build/kiro_sd && cmake --build build/kiro_sd
#     (add -DKIRO_SD_VULKAN=ON for GPU), then bundle kiro_sd.dll / libkiro_sd.so with the app.
# Every ggml/sd symbol is hidden; only the kiro_sd_* C API (and the JNI entry points) are exported.
cmake_minimum_required(VERSION 3.22)
project(kiro_sd C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(KIRO_SD_TAG "master-1056-9234ad8" CACHE STRING "stable-diffusion.cpp release tag")
set(KIRO_SD_COMMIT "9234ad822a376a4724638467736118ed61d68ee9")
option(KIRO_SD_JNI "Build the Android JNI bridge" ${ANDROID})
option(KIRO_SD_VULKAN "Use ggml's Vulkan backend (desktop)" OFF)
option(KIRO_SD_HOST_TEST "Build the host test executable" OFF)

# stable-diffusion.cpp / ggml options: static, CPU, no OpenMP (Android NDK has no shared
# libomp by default), no image/video file I/O extras.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(SD_BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(SD_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(SD_WEBP OFF CACHE BOOL "" FORCE)
set(SD_WEBM OFF CACHE BOOL "" FORCE)
set(SD_VULKAN ${KIRO_SD_VULKAN} CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_LLAMAFILE OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "" FORCE)
set(GGML_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(GGML_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
if(ANDROID)
    # armv8.2-a + dotprod + fp16: every phone with enough RAM for Stable Diffusion has these
    # (the app only offers image generation when /proc/cpuinfo reports asimddp).
    set(GGML_CPU_ARM_ARCH "armv8.2-a+dotprod+fp16" CACHE STRING "" FORCE)
endif()

if(DEFINED ENV{KIRO_SD_SRC} AND EXISTS "$ENV{KIRO_SD_SRC}/CMakeLists.txt")
    set(KIRO_SD_DIR "$ENV{KIRO_SD_SRC}")
elseif(KIRO_SD_SRC AND EXISTS "${KIRO_SD_SRC}/CMakeLists.txt")
    set(KIRO_SD_DIR "${KIRO_SD_SRC}")
else()
    include(FetchContent)
    FetchContent_Declare(sdcpp
        GIT_REPOSITORY https://github.com/leejet/stable-diffusion.cpp.git
        GIT_TAG ${KIRO_SD_COMMIT}
        GIT_SUBMODULES ggml
        GIT_SHALLOW FALSE)
    FetchContent_GetProperties(sdcpp)
    if(NOT sdcpp_POPULATED)
        FetchContent_Populate(sdcpp)
    endif()
    set(KIRO_SD_DIR "${sdcpp_SOURCE_DIR}")
endif()
message(STATUS "kiro_sd: stable-diffusion.cpp from ${KIRO_SD_DIR}")

add_subdirectory("${KIRO_SD_DIR}" sdcpp_build EXCLUDE_FROM_ALL)

add_library(kiro_sd SHARED kiro_sd.cpp)
if(KIRO_SD_JNI)
    target_sources(kiro_sd PRIVATE kiro_sd_jni.cpp)
endif()
target_link_libraries(kiro_sd PRIVATE stable-diffusion)
target_include_directories(kiro_sd PRIVATE "${KIRO_SD_DIR}/include" "${KIRO_SD_DIR}/thirdparty")
set_target_properties(kiro_sd PROPERTIES C_VISIBILITY_PRESET hidden CXX_VISIBILITY_PRESET hidden VISIBILITY_INLINES_HIDDEN ON)
target_compile_options(kiro_sd PRIVATE -O3 -ffunction-sections -fdata-sections)
if(NOT MSVC)
    target_link_options(kiro_sd PRIVATE -Wl,--gc-sections)
    if(NOT APPLE)
        target_link_options(kiro_sd PRIVATE -Wl,--exclude-libs,ALL)
    endif()
endif()
if(ANDROID)
    target_link_libraries(kiro_sd PRIVATE android log)
    target_link_options(kiro_sd PRIVATE -Wl,-z,max-page-size=16384)
endif()

if(KIRO_SD_HOST_TEST)
    add_executable(kiro_sd_host_test host_test.cpp)
    target_link_libraries(kiro_sd_host_test PRIVATE kiro_sd)
endif()
