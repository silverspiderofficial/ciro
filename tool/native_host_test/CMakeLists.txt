# Host build of the engine test:
#   git clone --depth 1 -b b12191 https://github.com/ggml-org/llama.cpp.git /tmp/llama.cpp
#   cmake -S tool/native_host_test -B build/host_test -DLLAMA_SRC=/tmp/llama.cpp
#   cmake --build build/host_test -j && build/host_test/kiro_engine_test model.gguf
cmake_minimum_required(VERSION 3.22)
project(kiro_engine_host_test C CXX)
set(CMAKE_CXX_STANDARD 17)
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP OFF CACHE BOOL "" FORCE)
set(LLAMA_OPENSSL OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
add_subdirectory(${LLAMA_SRC} llama_build)
set(ENGINE_DIR ${CMAKE_CURRENT_LIST_DIR}/../../android/app/src/main/cpp)
add_executable(kiro_engine_test engine_test.cpp ${ENGINE_DIR}/kiro_engine.cpp)
target_include_directories(kiro_engine_test PRIVATE ${ENGINE_DIR})
target_link_libraries(kiro_engine_test PRIVATE llama ggml)
