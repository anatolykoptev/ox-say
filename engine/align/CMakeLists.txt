# ox-align against a whisper.cpp tree: only ggml is needed (the GGUF reader
# ships inside ggml). engine/build.sh passes WHISPER_SRC and the same ggml
# options as the other engine builds.
cmake_minimum_required(VERSION 3.14)
project(ox-align C CXX)

set(WHISPER_SRC "" CACHE PATH "whisper.cpp source tree")
if (NOT WHISPER_SRC)
    message(FATAL_ERROR "set -DWHISPER_SRC=<whisper.cpp tree>")
endif()

add_subdirectory(${WHISPER_SRC}/ggml whisper-ggml EXCLUDE_FROM_ALL)

add_executable(ox-align ox-align.cpp)
target_compile_features(ox-align PRIVATE cxx_std_17)
target_include_directories(ox-align PRIVATE ${WHISPER_SRC}/ggml/include)
target_link_libraries(ox-align PRIVATE ggml)
