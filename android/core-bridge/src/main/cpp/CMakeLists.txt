cmake_minimum_required(VERSION 3.22.1)
project(tessera_core_jni LANGUAGES CXX)

add_library(tessera_core_jni SHARED tessera_core_jni.cpp)

target_compile_features(tessera_core_jni PRIVATE cxx_std_17)
target_compile_options(tessera_core_jni PRIVATE -Wall -Wextra -Werror)
target_link_libraries(tessera_core_jni PRIVATE dl)
