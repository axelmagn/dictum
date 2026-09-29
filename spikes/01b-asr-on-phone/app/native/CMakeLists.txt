cmake_minimum_required(VERSION 3.10)
project(dictum_whisper C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(BUILD_SHARED_LIBS ON CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)

set(WHISPER_CPP_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../whisper.cpp)

add_subdirectory(${WHISPER_CPP_DIR} ${CMAKE_CURRENT_BINARY_DIR}/whisper.cpp EXCLUDE_FROM_ALL)

add_library(dictum_whisper SHARED
    shim.c
)

target_include_directories(dictum_whisper PRIVATE
    ${WHISPER_CPP_DIR}/include
    ${WHISPER_CPP_DIR}/ggml/include
)

target_link_libraries(dictum_whisper PRIVATE
    whisper
    log
)
