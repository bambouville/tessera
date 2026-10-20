#include <jni.h>
#include <poll.h>
#include <errno.h>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

#include "MoshCABI.h"

namespace {

constexpr jlong kNoDeadline = INT64_MAX;

struct NativeClient {
  JavaVM* vm = nullptr;
  jobject callback_target = nullptr;
  jmethodID output_method = nullptr;
  tessera_mosh_client* client = nullptr;
  // Ordinary JNI entrypoints are serialized in Kotlin. This recursive lock is
  // still needed for a supported callback-time close, which re-enters JNI on
  // the same thread while start/tick/repaint is active.
  std::recursive_mutex mutex;
  size_t active_operations = 0;
  bool destroy_requested = false;
};

void secure_clear(std::string& value) {
  volatile char* bytes = value.empty() ? nullptr : value.data();
  for (size_t index = 0; index < value.size(); ++index) bytes[index] = 0;
  value.clear();
  value.shrink_to_fit();
}

JNIEnv* environment_for(JavaVM* vm, bool* needs_detach) {
  *needs_detach = false;
  JNIEnv* env = nullptr;
  const jint existing = vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6);
  if (existing == JNI_OK) return env;
  if (existing != JNI_EDETACHED || vm->AttachCurrentThread(&env, nullptr) != JNI_OK) return nullptr;
  *needs_detach = true;
  return env;
}

void output_callback(const uint8_t* bytes, size_t length, void* context) {
  auto* native = static_cast<NativeClient*>(context);
  if (native == nullptr || bytes == nullptr || length == 0 || length > INT32_MAX) return;
  bool needs_detach = false;
  JNIEnv* env = environment_for(native->vm, &needs_detach);
  if (env == nullptr) return;
  jbyteArray copy = env->NewByteArray(static_cast<jsize>(length));
  if (copy != nullptr) {
    env->SetByteArrayRegion(copy, 0, static_cast<jsize>(length), reinterpret_cast<const jbyte*>(bytes));
    env->CallVoidMethod(native->callback_target, native->output_method, copy);
    env->DeleteLocalRef(copy);
  }
  // The callback is best-effort. Java exceptions must not cross the C ABI or
  // poison the native Mosh event loop.
  if (env->ExceptionCheck()) env->ExceptionClear();
  if (needs_detach) native->vm->DetachCurrentThread();
}

NativeClient* get(jlong handle) {
  if (handle == 0) throw std::invalid_argument("native Mosh handle is closed");
  return reinterpret_cast<NativeClient*>(static_cast<intptr_t>(handle));
}

void throw_java(JNIEnv* env, const char* message) {
  jclass type = env->FindClass("java/lang/IllegalStateException");
  if (type != nullptr) env->ThrowNew(type, message == nullptr ? "native Mosh failure" : message);
}

void throw_result(JNIEnv* env, tessera_mosh_result result, NativeClient* native) {
  if (result == TESSERA_MOSH_OK) return;
  std::string detail;
  if (native != nullptr && native->client != nullptr) {
    size_t required = 0;
    if (tessera_mosh_client_copy_last_error(native->client, nullptr, 0, &required) == TESSERA_MOSH_BUFFER_TOO_SMALL
        && required > 1 && required <= TESSERA_MOSH_C_ABI_MAX_ERROR_BYTES) {
      std::vector<char> buffer(required);
      if (tessera_mosh_client_copy_last_error(native->client, buffer.data(), buffer.size(), &required) == TESSERA_MOSH_OK) {
        detail.assign(buffer.data());
      }
    }
  }
  if (detail.empty()) detail = "native Mosh operation failed";
  throw_java(env, detail.c_str());
}

void dispose_native_client(JNIEnv* env, NativeClient* native) {
  if (native == nullptr) return;
  if (native->callback_target != nullptr) env->DeleteGlobalRef(native->callback_target);
  delete native;
}

template <typename Operation>
void with_client(JNIEnv* env, jlong handle, Operation&& operation) {
  NativeClient* native = nullptr;
  bool dispose_after_operation = false;
  try {
    native = get(handle);
    std::lock_guard<std::recursive_mutex> lock(native->mutex);
    if (native->destroy_requested || native->client == nullptr) {
      throw std::invalid_argument("native Mosh handle is closed");
    }
    ++native->active_operations;
    throw_result(env, operation(native), native);
    --native->active_operations;
    dispose_after_operation = native->destroy_requested && native->active_operations == 0;
  } catch (const std::exception& exception) {
    if (native != nullptr) {
      std::lock_guard<std::recursive_mutex> lock(native->mutex);
      if (native->active_operations > 0) --native->active_operations;
      dispose_after_operation = native->destroy_requested && native->active_operations == 0;
    }
    throw_java(env, exception.what());
  }
  if (dispose_after_operation) dispose_native_client(env, native);
}

}  // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_com_bambouville_tessera_networking_mosh_JniMoshNativeClient_nativeCreate(
    JNIEnv* env, jobject receiver, jstring host, jint port, jbyteArray key) {
  if (host == nullptr || key == nullptr || port < 1 || port > 65535) {
    throw_java(env, "invalid native Mosh configuration");
    return 0;
  }
  const char* host_chars = env->GetStringUTFChars(host, nullptr);
  if (host_chars == nullptr) return 0;
  std::string host_copy(host_chars);
  env->ReleaseStringUTFChars(host, host_chars);
  const jsize key_length = env->GetArrayLength(key);
  if (key_length != 22) {
    throw_java(env, "invalid Mosh bootstrap key");
    return 0;
  }
  std::string key_copy(static_cast<size_t>(key_length), '\0');
  env->GetByteArrayRegion(key, 0, key_length, reinterpret_cast<jbyte*>(key_copy.data()));
  if (env->ExceptionCheck()) {
    secure_clear(key_copy);
    return 0;
  }

  auto native = std::make_unique<NativeClient>();
  if (env->GetJavaVM(&native->vm) != JNI_OK) {
    secure_clear(key_copy);
    throw_java(env, "could not obtain Java VM");
    return 0;
  }
  native->callback_target = env->NewGlobalRef(receiver);
  jclass clazz = env->GetObjectClass(receiver);
  native->output_method = clazz == nullptr ? nullptr : env->GetMethodID(clazz, "onNativeOutput", "([B)V");
  if (clazz != nullptr) env->DeleteLocalRef(clazz);
  if (native->callback_target == nullptr || native->output_method == nullptr) {
    if (native->callback_target != nullptr) env->DeleteGlobalRef(native->callback_target);
    secure_clear(key_copy);
    throw_java(env, "native Mosh output callback is unavailable");
    return 0;
  }

  tessera_mosh_client_config_v1 config{};
  config.abi_version = TESSERA_MOSH_C_ABI_VERSION;
  config.struct_size = sizeof(config);
  config.host = host_copy.c_str();
  config.port = static_cast<uint16_t>(port);
  config.base64_key = key_copy.c_str();
  config.output_callback = output_callback;
  config.output_context = native.get();
  const tessera_mosh_result result = tessera_mosh_client_create(&config, &native->client);
  secure_clear(key_copy);
  if (result != TESSERA_MOSH_OK || native->client == nullptr) {
    env->DeleteGlobalRef(native->callback_target);
    throw_java(env, "could not create native Mosh client");
    return 0;
  }
  return static_cast<jlong>(reinterpret_cast<intptr_t>(native.release()));
}

extern "C" JNIEXPORT void JNICALL
Java_com_bambouville_tessera_networking_mosh_JniMoshNativeClient_nativeStart(JNIEnv* env, jobject, jlong handle) {
  with_client(env, handle, [](NativeClient* native) { return tessera_mosh_client_start(native->client); });
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_bambouville_tessera_networking_mosh_JniMoshNativeClient_nativeTick(JNIEnv* env, jobject, jlong handle) {
  jlong deadline = kNoDeadline;
  with_client(env, handle, [&](NativeClient* native) {
    uint64_t wait = TESSERA_MOSH_C_ABI_NO_DEADLINE;
    const tessera_mosh_result result = tessera_mosh_client_tick(native->client, &wait);
    if (result == TESSERA_MOSH_OK) deadline = wait > static_cast<uint64_t>(INT64_MAX) ? kNoDeadline : static_cast<jlong>(wait);
    return result;
  });
  return deadline;
}

extern "C" JNIEXPORT void JNICALL
Java_com_bambouville_tessera_networking_mosh_JniMoshNativeClient_nativeInject(JNIEnv* env, jobject, jlong handle, jbyteArray bytes) {
  if (bytes == nullptr) { throw_java(env, "input bytes are required"); return; }
  const jsize length = env->GetArrayLength(bytes);
  std::vector<uint8_t> copy(static_cast<size_t>(std::max(length, 0)));
  if (length > 0) env->GetByteArrayRegion(bytes, 0, length, reinterpret_cast<jbyte*>(copy.data()));
  if (env->ExceptionCheck()) return;
  with_client(env, handle, [&](NativeClient* native) {
    return tessera_mosh_client_inject_bytes(native->client, copy.data(), copy.size());
  });
}

extern "C" JNIEXPORT void JNICALL
Java_com_bambouville_tessera_networking_mosh_JniMoshNativeClient_nativeResize(JNIEnv* env, jobject, jlong handle, jint columns, jint rows) {
  with_client(env, handle, [&](NativeClient* native) {
    return tessera_mosh_client_resize(native->client, columns, rows);
  });
}

extern "C" JNIEXPORT void JNICALL
Java_com_bambouville_tessera_networking_mosh_JniMoshNativeClient_nativeForceFullRepaint(JNIEnv* env, jobject, jlong handle) {
  with_client(env, handle, [](NativeClient* native) { return tessera_mosh_client_force_full_repaint(native->client); });
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_bambouville_tessera_networking_mosh_JniMoshNativeClient_nativeBeginFullRepaintFence(JNIEnv* env, jobject, jlong handle) {
  uint64_t token = 0;
  with_client(env, handle, [&](NativeClient* native) {
    return tessera_mosh_client_begin_full_repaint_fence(native->client, &token);
  });
  if (token > static_cast<uint64_t>(INT64_MAX)) {
    throw_java(env, "Mosh repaint fence sequence exhausted");
    return 0;
  }
  return static_cast<jlong>(token);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_bambouville_tessera_networking_mosh_JniMoshNativeClient_nativeFullRepaintFenceReady(JNIEnv* env, jobject, jlong handle, jlong token) {
  if (token <= 0) return JNI_FALSE;
  int32_t ready = 0;
  with_client(env, handle, [&](NativeClient* native) {
    return tessera_mosh_client_is_full_repaint_fence_ready(native->client, static_cast<uint64_t>(token), &ready);
  });
  return ready == 0 ? JNI_FALSE : JNI_TRUE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_bambouville_tessera_networking_mosh_JniMoshNativeClient_nativeConnected(JNIEnv* env, jobject, jlong handle) {
  jint value = JNI_FALSE;
  with_client(env, handle, [&](NativeClient* native) {
    int32_t output = 0;
    const tessera_mosh_result result = tessera_mosh_client_is_connected(native->client, &output);
    value = output == 0 ? JNI_FALSE : JNI_TRUE;
    return result;
  });
  return value;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_bambouville_tessera_networking_mosh_JniMoshNativeClient_nativeTransportReachable(JNIEnv* env, jobject, jlong handle) {
  jint value = JNI_FALSE;
  with_client(env, handle, [&](NativeClient* native) {
    int32_t output = 0;
    const tessera_mosh_result result = tessera_mosh_client_is_transport_reachable(native->client, &output);
    value = output == 0 ? JNI_FALSE : JNI_TRUE;
    return result;
  });
  return value;
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_bambouville_tessera_networking_mosh_JniMoshNativeClient_nativeServerContactAgeMilliseconds(JNIEnv* env, jobject, jlong handle) {
  jlong value = 0;
  with_client(env, handle, [&](NativeClient* native) {
    uint64_t output = 0;
    const tessera_mosh_result result = tessera_mosh_client_server_contact_age_ms(native->client, &output);
    value = static_cast<jlong>(std::min(output, static_cast<uint64_t>(INT64_MAX)));
    return result;
  });
  return value;
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_bambouville_tessera_networking_mosh_JniMoshNativeClient_nativeReplyAgeMilliseconds(JNIEnv* env, jobject, jlong handle) {
  jlong value = 0;
  with_client(env, handle, [&](NativeClient* native) {
    uint64_t output = 0;
    const tessera_mosh_result result = tessera_mosh_client_reply_age_ms(native->client, &output);
    value = static_cast<jlong>(std::min(output, static_cast<uint64_t>(INT64_MAX)));
    return result;
  });
  return value;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_bambouville_tessera_networking_mosh_JniMoshNativeClient_nativeShutdownComplete(JNIEnv* env, jobject, jlong handle) {
  jint value = JNI_FALSE;
  with_client(env, handle, [&](NativeClient* native) {
    int32_t output = 0;
    const tessera_mosh_result result = tessera_mosh_client_is_shutdown_complete(native->client, &output);
    value = output == 0 ? JNI_FALSE : JNI_TRUE;
    return result;
  });
  return value;
}

extern "C" JNIEXPORT jintArray JNICALL
Java_com_bambouville_tessera_networking_mosh_JniMoshNativeClient_nativeSocketFds(JNIEnv* env, jobject, jlong handle) {
  std::vector<int32_t> fds(8);
  size_t count = 0;
  with_client(env, handle, [&](NativeClient* native) {
    tessera_mosh_result result = tessera_mosh_client_copy_socket_fds(native->client, fds.data(), fds.size(), &count);
    if (result == TESSERA_MOSH_BUFFER_TOO_SMALL && count > fds.size() && count <= 256) {
      fds.resize(count);
      result = tessera_mosh_client_copy_socket_fds(native->client, fds.data(), fds.size(), &count);
    }
    return result;
  });
  if (env->ExceptionCheck()) return nullptr;
  if (count > fds.size()) count = fds.size();
  jintArray output = env->NewIntArray(static_cast<jsize>(count));
  if (output == nullptr) return nullptr;
  if (count > 0) env->SetIntArrayRegion(output, 0, static_cast<jsize>(count), reinterpret_cast<const jint*>(fds.data()));
  return output;
}

// Blocks until one of `fds` is readable, `timeout_millis` elapses, or the
// wait is interrupted. Deliberately takes no client handle and no lock: the
// pump waits here for most of a session's lifetime, and a wait that held the
// native mutex would stall every keystroke (`inject`) and resize behind it.
// Returns >0 when at least one descriptor is readable, 0 on timeout, -1 when
// a descriptor was invalid or the poll failed (the caller falls back to a
// timed sleep so a stale descriptor cannot spin), -2 on EINTR.
extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_networking_mosh_JniMoshNativeClient_nativePollReadable(
    JNIEnv* env, jobject, jintArray fds, jint timeout_millis) {
  if (fds == nullptr) return -1;
  const jsize length = env->GetArrayLength(fds);
  if (length <= 0 || length > 256) return -1;
  std::vector<jint> raw(static_cast<size_t>(length));
  env->GetIntArrayRegion(fds, 0, length, raw.data());
  if (env->ExceptionCheck()) return -1;
  std::vector<struct pollfd> entries(static_cast<size_t>(length));
  for (jsize index = 0; index < length; ++index) {
    entries[static_cast<size_t>(index)].fd = raw[static_cast<size_t>(index)];
    entries[static_cast<size_t>(index)].events = POLLIN;
    entries[static_cast<size_t>(index)].revents = 0;
  }
  const int timeout = timeout_millis < 0 ? -1 : timeout_millis;
  const int ready = ::poll(entries.data(), static_cast<nfds_t>(entries.size()), timeout);
  if (ready < 0) return errno == EINTR ? -2 : -1;
  if (ready == 0) return 0;
  bool readable = false;
  for (const struct pollfd& entry : entries) {
    if (entry.revents & POLLNVAL) return -1;
    if (entry.revents & (POLLIN | POLLERR | POLLHUP)) readable = true;
  }
  return readable ? ready : -1;
}

extern "C" JNIEXPORT void JNICALL
Java_com_bambouville_tessera_networking_mosh_JniMoshNativeClient_nativeDestroy(JNIEnv* env, jobject, jlong handle) {
  NativeClient* native = reinterpret_cast<NativeClient*>(static_cast<intptr_t>(handle));
  if (native == nullptr) return;
  tessera_mosh_client* client = nullptr;
  bool dispose_now = false;
  {
    std::lock_guard<std::recursive_mutex> lock(native->mutex);
    if (native->destroy_requested) return;
    native->destroy_requested = true;
    client = native->client;
    native->client = nullptr;
    // The Mosh C ABI defers callback-time destruction until its enclosing
    // operation returns. Retain our callback context on the same schedule.
    if (client != nullptr) tessera_mosh_client_destroy(client);
    dispose_now = native->active_operations == 0;
  }
  if (dispose_now) dispose_native_client(env, native);
}
