cmake_minimum_required(VERSION 3.22.1)
project(tessera_mosh_jni LANGUAGES CXX)

# The app packages this only when -Ptessera.enableMoshNative=true. The
# reviewed OpenSSL 3.5.7 prefix is produced by the existing Android Mosh gate;
# it is deliberately not substituted with a host or SDK crypto library.
set(TESSERA_ANDROID_OPENSSL_ROOT "" CACHE PATH "Reviewed Android OpenSSL prefix")
if(NOT EXISTS "${TESSERA_ANDROID_OPENSSL_ROOT}/include/openssl/evp.h")
  message(FATAL_ERROR "Set TESSERA_ANDROID_OPENSSL_ROOT to the reviewed Android OpenSSL 3.5.7 prefix")
endif()

set(MOSH_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../../../../Packages/MoshBridge")
set(MOSH_VENDOR "${MOSH_ROOT}/Vendor")
set(MOSH_GENERATED "${MOSH_ROOT}/Sources/MoshCore/generated")

set(PROTOBUF_SOURCES
  ${MOSH_VENDOR}/protobuf/src/google/protobuf/any_lite.cc
  ${MOSH_VENDOR}/protobuf/src/google/protobuf/arena.cc
  ${MOSH_VENDOR}/protobuf/src/google/protobuf/arenastring.cc
  ${MOSH_VENDOR}/protobuf/src/google/protobuf/arenaz_sampler.cc
  ${MOSH_VENDOR}/protobuf/src/google/protobuf/extension_set.cc
  ${MOSH_VENDOR}/protobuf/src/google/protobuf/generated_enum_util.cc
  ${MOSH_VENDOR}/protobuf/src/google/protobuf/generated_message_tctable_lite.cc
  ${MOSH_VENDOR}/protobuf/src/google/protobuf/generated_message_util.cc
  ${MOSH_VENDOR}/protobuf/src/google/protobuf/implicit_weak_message.cc
  ${MOSH_VENDOR}/protobuf/src/google/protobuf/inlined_string_field.cc
  ${MOSH_VENDOR}/protobuf/src/google/protobuf/io/coded_stream.cc
  ${MOSH_VENDOR}/protobuf/src/google/protobuf/io/io_win32.cc
  ${MOSH_VENDOR}/protobuf/src/google/protobuf/io/strtod.cc
  ${MOSH_VENDOR}/protobuf/src/google/protobuf/io/zero_copy_stream.cc
  ${MOSH_VENDOR}/protobuf/src/google/protobuf/io/zero_copy_stream_impl.cc
  ${MOSH_VENDOR}/protobuf/src/google/protobuf/io/zero_copy_stream_impl_lite.cc
  ${MOSH_VENDOR}/protobuf/src/google/protobuf/map.cc
  ${MOSH_VENDOR}/protobuf/src/google/protobuf/message_lite.cc
  ${MOSH_VENDOR}/protobuf/src/google/protobuf/parse_context.cc
  ${MOSH_VENDOR}/protobuf/src/google/protobuf/repeated_field.cc
  ${MOSH_VENDOR}/protobuf/src/google/protobuf/repeated_ptr_field.cc
  ${MOSH_VENDOR}/protobuf/src/google/protobuf/stubs/bytestream.cc
  ${MOSH_VENDOR}/protobuf/src/google/protobuf/stubs/common.cc
  ${MOSH_VENDOR}/protobuf/src/google/protobuf/stubs/int128.cc
  ${MOSH_VENDOR}/protobuf/src/google/protobuf/stubs/status.cc
  ${MOSH_VENDOR}/protobuf/src/google/protobuf/stubs/statusor.cc
  ${MOSH_VENDOR}/protobuf/src/google/protobuf/stubs/stringpiece.cc
  ${MOSH_VENDOR}/protobuf/src/google/protobuf/stubs/stringprintf.cc
  ${MOSH_VENDOR}/protobuf/src/google/protobuf/stubs/structurally_valid.cc
  ${MOSH_VENDOR}/protobuf/src/google/protobuf/stubs/strutil.cc
  ${MOSH_VENDOR}/protobuf/src/google/protobuf/stubs/time.cc
  ${MOSH_VENDOR}/protobuf/src/google/protobuf/wire_format_lite.cc)
set(MOSH_SOURCES
  ${MOSH_VENDOR}/mosh/src/crypto/base64.cc
  ${MOSH_VENDOR}/mosh/src/crypto/crypto.cc
  ${MOSH_VENDOR}/mosh/src/crypto/ocb_internal.cc
  ${MOSH_VENDOR}/mosh/src/frontend/terminaloverlay.cc
  ${MOSH_VENDOR}/mosh/src/network/compressor.cc
  ${MOSH_VENDOR}/mosh/src/network/network.cc
  ${MOSH_VENDOR}/mosh/src/network/transportfragment.cc
  ${MOSH_VENDOR}/mosh/src/statesync/completeterminal.cc
  ${MOSH_VENDOR}/mosh/src/statesync/user.cc
  ${MOSH_VENDOR}/mosh/src/terminal/parser.cc
  ${MOSH_VENDOR}/mosh/src/terminal/parseraction.cc
  ${MOSH_VENDOR}/mosh/src/terminal/parserstate.cc
  ${MOSH_VENDOR}/mosh/src/terminal/terminal.cc
  ${MOSH_VENDOR}/mosh/src/terminal/terminaldispatcher.cc
  ${MOSH_VENDOR}/mosh/src/terminal/terminaldisplay.cc
  ${MOSH_VENDOR}/mosh/src/terminal/terminalframebuffer.cc
  ${MOSH_VENDOR}/mosh/src/terminal/terminalfunctions.cc
  ${MOSH_VENDOR}/mosh/src/terminal/terminaluserinput.cc
  ${MOSH_VENDOR}/mosh/src/util/timestamp.cc
  ${MOSH_ROOT}/Sources/MoshCore/MoshClient.cc
  ${MOSH_ROOT}/Sources/MoshCore/TerminalDisplayInit.cc
  ${MOSH_ROOT}/Sources/MoshCore/TransportInstantiation.cc
  ${MOSH_ROOT}/Sources/MoshCore/generated/hostinput.pb.cc
  ${MOSH_ROOT}/Sources/MoshCore/generated/transportinstruction.pb.cc
  ${MOSH_ROOT}/Sources/MoshCore/generated/userinput.pb.cc
  ${MOSH_ROOT}/Sources/MoshCABI/MoshCABI.cc)

add_library(tessera_mosh_jni SHARED tessera_mosh_jni.cpp ${PROTOBUF_SOURCES} ${MOSH_SOURCES})
target_compile_features(tessera_mosh_jni PRIVATE cxx_std_17)
target_compile_options(tessera_mosh_jni PRIVATE -fexceptions -frtti -Wno-everything)
target_compile_definitions(tessera_mosh_jni PRIVATE HAVE_CONFIG_H HAVE_PTHREAD=1 GOOGLE_PROTOBUF_NO_GENERIC_SERVICES=1 GOOGLE_PROTOBUF_NO_RDTSC=1)
target_include_directories(tessera_mosh_jni PRIVATE
  ${MOSH_ROOT}/Sources/MoshCABI/include ${MOSH_ROOT}/Sources/MoshCore/include ${MOSH_ROOT}/Sources/MoshCore
  ${MOSH_GENERATED} ${MOSH_VENDOR}/MoshConfig ${MOSH_VENDOR}/protobuf/src
  ${MOSH_VENDOR}/mosh/src ${MOSH_VENDOR}/mosh/src/crypto ${MOSH_VENDOR}/mosh/src/frontend
  ${MOSH_VENDOR}/mosh/src/network ${MOSH_VENDOR}/mosh/src/statesync ${MOSH_VENDOR}/mosh/src/terminal ${MOSH_VENDOR}/mosh/src/util
  ${TESSERA_ANDROID_OPENSSL_ROOT}/include)
find_library(LOG_LIB log)
find_library(Z_LIB z)
target_link_libraries(tessera_mosh_jni PRIVATE ${TESSERA_ANDROID_OPENSSL_ROOT}/lib/libcrypto.a ${Z_LIB} ${LOG_LIB})
