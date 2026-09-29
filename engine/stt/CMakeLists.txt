# ox-stt against a whisper.cpp tree (whisper + parakeet libraries); engine/build.sh passes
# WHISPER_SRC and the same ggml options as the tts-server build.
cmake_minimum_required(VERSION 3.14)
project(ox-stt C CXX)

set(WHISPER_SRC "" CACHE PATH "whisper.cpp source tree")
if (NOT WHISPER_SRC)
    message(FATAL_ERROR "set -DWHISPER_SRC=<whisper.cpp tree>")
endif()

add_subdirectory(${WHISPER_SRC} whisper EXCLUDE_FROM_ALL)

add_executable(ox-stt ox-stt.cpp)
target_compile_features(ox-stt PRIVATE cxx_std_17)
target_link_libraries(ox-stt PRIVATE whisper parakeet)
