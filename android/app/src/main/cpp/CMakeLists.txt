cmake_minimum_required(VERSION 3.22.1)

project(kiro_llm C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ---------------------------------------------------------------------------
# llama.cpp, built from source at a pinned release tag.
# CI may pre-clone the same tag and point KIRO_LLAMA_SRC at it (cache friendly);
# otherwise CMake fetches the tag itself. Nothing is vendored in the repository.
# ---------------------------------------------------------------------------
set(KIRO_LLAMA_TAG "b12191")  # commit e95426f16982054c379ca7bdc8186996dd22f0fe

# ccache: ggml enables it for the whole build when found on PATH (GGML_CCACHE, default ON).

# llama.cpp / ggml options: shared libs + one CPU backend per ARM feature level,
# picked at runtime (dotprod, i8mm, SVE...) so old and new SoCs both run fast.
set(BUILD_SHARED_LIBS ON CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL ON CACHE BOOL "" FORCE)
# KIRO_CPU_ALL_VARIANTS=OFF is only for host-side testing of the bridge (single CPU backend).
option(KIRO_CPU_ALL_VARIANTS "Build every ARM CPU backend variant" ON)
set(GGML_CPU_ALL_VARIANTS ${KIRO_CPU_ALL_VARIANTS} CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_LLAMAFILE OFF CACHE BOOL "" FORCE)
set(GGML_CPU_KLEIDIAI OFF CACHE BOOL "" FORCE)
set(LLAMA_OPENSSL OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_HTML OFF CACHE BOOL "" FORCE)
set(LLAMA_ALL_WARNINGS OFF CACHE BOOL "" FORCE)

if(DEFINED ENV{KIRO_LLAMA_SRC} AND EXISTS "$ENV{KIRO_LLAMA_SRC}/CMakeLists.txt")
    set(KIRO_LLAMA_DIR "$ENV{KIRO_LLAMA_SRC}")
    message(STATUS "kiro: using llama.cpp from KIRO_LLAMA_SRC=${KIRO_LLAMA_DIR}")
    add_subdirectory("${KIRO_LLAMA_DIR}" llama_build)
else()
    include(FetchContent)
    FetchContent_Declare(
        llama_cpp
        GIT_REPOSITORY https://github.com/ggml-org/llama.cpp.git
        GIT_TAG        ${KIRO_LLAMA_TAG}
        GIT_SHALLOW    TRUE
        GIT_PROGRESS   TRUE
    )
    FetchContent_MakeAvailable(llama_cpp)
    set(KIRO_LLAMA_DIR "${llama_cpp_SOURCE_DIR}")
endif()

add_library(kiro_llm SHARED
    kiro_engine.cpp
    kiro_jni.cpp
)

target_include_directories(kiro_llm PRIVATE
    "${KIRO_LLAMA_DIR}/include"
    "${KIRO_LLAMA_DIR}/ggml/include"
)

target_compile_options(kiro_llm PRIVATE -O3 -fvisibility=hidden -ffunction-sections -fdata-sections)
target_link_options(kiro_llm PRIVATE -Wl,--gc-sections)

target_link_libraries(kiro_llm llama ggml)
if(ANDROID)
    target_link_libraries(kiro_llm android log)
    target_link_options(kiro_llm PRIVATE -Wl,--exclude-libs,ALL)
endif()

# The CPU backends are MODULE libraries loaded with dlopen() at runtime, so nothing links
# against them. Build them with kiro_llm and copy every runtime library next to
# libkiro_llm.so (the directory the Android Gradle Plugin packages), because llama.cpp
# writes its own outputs to ${CMAKE_BINARY_DIR}/bin.
set(KIRO_RUNTIME_LIBS llama ggml ggml-base)
foreach(variant android_armv8.0_1 android_armv8.2_1 android_armv8.2_2 android_armv8.6_1
                android_armv9.0_1 android_armv9.2_1 android_armv9.2_2)
    list(APPEND KIRO_RUNTIME_LIBS ggml-cpu-${variant})
endforeach()
list(APPEND KIRO_RUNTIME_LIBS ggml-cpu)
foreach(lib ${KIRO_RUNTIME_LIBS})
    if(TARGET ${lib})
        add_dependencies(kiro_llm ${lib})
        add_custom_command(TARGET kiro_llm POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different $<TARGET_FILE:${lib}> $<TARGET_FILE_DIR:kiro_llm>/
            VERBATIM)
    endif()
endforeach()

# ---------------------------------------------------------------------------
# libkiro_sd.so: stable-diffusion.cpp image engine (native/kiro_sd), built as a separate CMake
# project (ExternalProject) so its own ggml never clashes with llama.cpp's ggml targets.
# CI builds it once in a cached step and drops it in src/main/jniLibs/<abi>/; when that
# prebuilt file is present, Gradle packages it as is and this step is skipped.
# KIRO_SD_JOBS limits parallel compile jobs (some sd.cpp sources need >3 GB RAM each).
# ---------------------------------------------------------------------------
option(KIRO_BUILD_SD "Build libkiro_sd.so (stable-diffusion.cpp)" ON)
set(KIRO_SD_PREBUILT "${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libkiro_sd.so")
if(ANDROID AND KIRO_BUILD_SD AND NOT EXISTS "${KIRO_SD_PREBUILT}")
    include(ExternalProject)
    if(DEFINED ENV{KIRO_SD_JOBS})
        set(KIRO_SD_JOBS "$ENV{KIRO_SD_JOBS}")
    else()
        set(KIRO_SD_JOBS 2)
    endif()
    set(KIRO_SD_BIN "${CMAKE_BINARY_DIR}/kiro_sd")
    ExternalProject_Add(kiro_sd_ext
        SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../native/kiro_sd"
        BINARY_DIR "${KIRO_SD_BIN}"
        CMAKE_ARGS
            -DCMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE}
            -DANDROID_ABI=${ANDROID_ABI}
            -DANDROID_PLATFORM=${ANDROID_PLATFORM}
            -DANDROID_STL=c++_shared
            -DCMAKE_BUILD_TYPE=Release
            -DCMAKE_MAKE_PROGRAM=${CMAKE_MAKE_PROGRAM}
        BUILD_COMMAND ${CMAKE_COMMAND} --build <BINARY_DIR> --target kiro_sd -j ${KIRO_SD_JOBS}
        INSTALL_COMMAND ""
        BUILD_BYPRODUCTS "${KIRO_SD_BIN}/libkiro_sd.so")
    add_dependencies(kiro_llm kiro_sd_ext)
    add_custom_command(TARGET kiro_llm POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "${KIRO_SD_BIN}/libkiro_sd.so" $<TARGET_FILE_DIR:kiro_llm>/
        VERBATIM)
endif()
