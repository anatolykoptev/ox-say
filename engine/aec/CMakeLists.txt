# ox-aec against a webrtc-audio-processing tree: the upstream is built by
# engine/build.sh with meson into one merged static archive (the
# libwebrtc-audio-processing-N component archives plus the abseil subproject's),
# whose path comes in as WEBRTC_APM_LIB. Include roots are the source tree
# (headers as <webrtc/...> and <api/...>) and the abseil subproject checkout.
cmake_minimum_required(VERSION 3.14)
project(ox-aec C CXX)

set(WEBRTC_APM_SRC "" CACHE PATH "webrtc-audio-processing source tree")
set(WEBRTC_APM_LIB "" CACHE FILEPATH "merged static webrtc-audio-processing archive")
if (NOT WEBRTC_APM_SRC OR NOT WEBRTC_APM_LIB)
    message(FATAL_ERROR "set -DWEBRTC_APM_SRC=<tree> -DWEBRTC_APM_LIB=<merged .a>")
endif()

file(GLOB ABSL_INC LIST_DIRECTORIES true "${WEBRTC_APM_SRC}/subprojects/abseil-cpp-*")

add_executable(ox-aec ox-aec.cpp)
target_compile_features(ox-aec PRIVATE cxx_std_17)
target_include_directories(ox-aec PRIVATE ${WEBRTC_APM_SRC} ${WEBRTC_APM_SRC}/webrtc ${ABSL_INC})
target_link_libraries(ox-aec PRIVATE ${WEBRTC_APM_LIB} "-framework CoreFoundation")

# standalone: lag.h (windowed cross-correlation lag estimation) has no
# webrtc-audio-processing deps, so this also builds on any host with a C++17
# compiler (the CI gate compiles it directly)
add_executable(lag-test lag_test.cpp)
target_compile_features(lag-test PRIVATE cxx_std_17)
