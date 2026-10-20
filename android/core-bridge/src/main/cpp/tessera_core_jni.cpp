#include <jni.h>
#include <dlfcn.h>

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {

using CoreEventCallback = void (*)(const std::uint8_t*, std::size_t, void*);
using CoreRuntimeCreate = void* (*)(CoreEventCallback, void*);
using CoreRuntimeCall = std::int32_t (*)(void*, const std::uint8_t*, std::size_t);
using AgentRuntimeRegister = std::int32_t (*)(
    void*, const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t, std::size_t*
);
using CoreRuntimeDestroy = void (*)(void*);

constexpr std::size_t kCoreMaxPayloadBytes = 1024 * 1024;
constexpr std::size_t kAgentMaxPayloadBytes = kCoreMaxPayloadBytes;
constexpr std::size_t kAgentMarkdownMaxInputBytes = 128 * 1024;
constexpr std::size_t kAgentMarkdownMaxOutputBytes = 2 * 1024 * 1024;

struct RuntimeBridge {
    jlong token = 0;
    JavaVM* vm = nullptr;
    jobject listener = nullptr;
    jmethodID on_event = nullptr;
    void* core_runtime = nullptr;
    std::atomic_bool closing = false;
    std::mutex call_mutex;
    // tmux callbacks may synchronously re-enter submit/take from Kotlin.  A
    // recursive gate preserves that contract while active_calls defers a
    // re-entrant close until the outer Swift call has returned.
    std::recursive_mutex tmux_call_mutex;
    std::size_t tmux_active_calls = 0;
    bool tmux_destroy_pending = false;
    // Tmux authority lifecycle and show-edge reductions are serialised by
    // call_mutex, so one response buffer per handle is reused instead of a
    // zero-filled allocation per call. It is allocated uninitialised on
    // first use.
    std::unique_ptr<std::uint8_t[]> lifecycle_output;
    std::size_t lifecycle_output_capacity = 0;
};

std::mutex registry_mutex;
std::unordered_map<jlong, std::shared_ptr<RuntimeBridge>> runtimes;
std::unordered_map<jlong, std::shared_ptr<RuntimeBridge>> tmux_runtimes;
std::unordered_map<jlong, std::shared_ptr<RuntimeBridge>> tmux_authority_lifecycles;
std::unordered_map<jlong, std::shared_ptr<RuntimeBridge>> tmux_show_edges;
std::unordered_map<jlong, std::shared_ptr<RuntimeBridge>> cross_device_runtimes;
std::unordered_map<jlong, std::shared_ptr<RuntimeBridge>> agent_runtimes;
std::atomic<jlong> next_runtime_token = 1;
std::atomic<jlong> next_tmux_runtime_token = 1;
std::atomic<jlong> next_tmux_authority_lifecycle_token = 1;
std::atomic<jlong> next_tmux_show_edges_token = 1;
std::atomic<jlong> next_cross_device_runtime_token = 1;
std::atomic<jlong> next_agent_runtime_token = 1;

void throw_java(JNIEnv* env, const char* class_name, const char* message) {
    jclass exception_class = env->FindClass(class_name);
    if (exception_class != nullptr) {
        env->ThrowNew(exception_class, message);
    }
}

// JVM unit tests build this shim for the host and name the core's staged
// path (scripts/android/build-host-core.sh).
#ifndef TESSERA_CORE_LIBRARY_FILE
#define TESSERA_CORE_LIBRARY_FILE "libTesseraCoreAndroid.so"
#endif

void* core_library(JNIEnv* env) {
    static void* handle = dlopen(TESSERA_CORE_LIBRARY_FILE, RTLD_NOW | RTLD_LOCAL);
    if (handle == nullptr) {
        const char* error = dlerror();
        throw_java(
            env,
            "java/lang/UnsatisfiedLinkError",
            error != nullptr ? error : "Unable to load " TESSERA_CORE_LIBRARY_FILE
        );
    }
    return handle;
}

template <typename Function>
Function require_symbol(JNIEnv* env, const char* name) {
    void* handle = core_library(env);
    if (handle == nullptr) {
        return nullptr;
    }
    dlerror();
    void* symbol = dlsym(handle, name);
    const char* error = dlerror();
    if (symbol == nullptr || error != nullptr) {
        throw_java(
            env,
            "java/lang/UnsatisfiedLinkError",
            error != nullptr ? error : name
        );
        return nullptr;
    }
    return reinterpret_cast<Function>(symbol);
}

// Android's jni.h takes JNIEnv**; the JDK's, used by host JVM tests, void**.
jint attach_current_thread(JavaVM* vm, JNIEnv** env) {
#ifdef __ANDROID__
    return vm->AttachCurrentThread(env, nullptr);
#else
    return vm->AttachCurrentThread(reinterpret_cast<void**>(env), nullptr);
#endif
}

std::shared_ptr<RuntimeBridge> find_runtime(jlong token) {
    std::lock_guard<std::mutex> lock(registry_mutex);
    const auto iterator = runtimes.find(token);
    return iterator == runtimes.end() ? nullptr : iterator->second;
}

void deliver_event(const std::uint8_t* bytes, std::size_t count, void* context) {
    auto* raw_bridge = static_cast<RuntimeBridge*>(context);
    if (raw_bridge == nullptr) return;
    const auto bridge = find_runtime(raw_bridge->token);
    if (bridge == nullptr || bridge->closing.load()) return;

    JNIEnv* env = nullptr;
    bool attached = false;
    const jint environment_status = bridge->vm->GetEnv(
        reinterpret_cast<void**>(&env),
        JNI_VERSION_1_6
    );
    if (environment_status == JNI_EDETACHED) {
        if (attach_current_thread(bridge->vm, &env) != JNI_OK) return;
        attached = true;
    } else if (environment_status != JNI_OK) {
        return;
    }

    jobject listener = env->NewLocalRef(bridge->listener);
    if (listener != nullptr && bytes != nullptr) {
        jobject buffer = env->NewDirectByteBuffer(
            const_cast<std::uint8_t*>(bytes),
            static_cast<jlong>(count)
        );
        if (buffer != nullptr) {
            env->CallVoidMethod(listener, bridge->on_event, buffer);
            env->DeleteLocalRef(buffer);
        }
        env->DeleteLocalRef(listener);
    }
    // Exceptions cannot cross a Swift/C callback. Kotlin copies bytes and owns
    // application-level error handling before this borrowed callback returns.
    if (env->ExceptionCheck()) env->ExceptionClear();
    if (attached) bridge->vm->DetachCurrentThread();
}

std::shared_ptr<RuntimeBridge> find_tmux_runtime(jlong token) {
    std::lock_guard<std::mutex> lock(registry_mutex);
    const auto iterator = tmux_runtimes.find(token);
    return iterator == tmux_runtimes.end() ? nullptr : iterator->second;
}

// Must be called with tmux_call_mutex held and no active tmux ABI call.
void destroy_tmux_runtime_locked(JNIEnv* env, const std::shared_ptr<RuntimeBridge>& bridge) {
    if (bridge->core_runtime != nullptr) {
        using Destroy = void (*)(void*);
        const Destroy destroy = require_symbol<Destroy>(env, "tessera_tmux_runtime_destroy");
        if (destroy != nullptr) destroy(bridge->core_runtime);
        bridge->core_runtime = nullptr;
    }
    {
        std::lock_guard<std::mutex> lock(registry_mutex);
        tmux_runtimes.erase(bridge->token);
    }
    if (bridge->listener != nullptr) {
        env->DeleteGlobalRef(bridge->listener);
        bridge->listener = nullptr;
    }
    bridge->tmux_destroy_pending = false;
}

class TmuxRuntimeCallScope {
public:
    TmuxRuntimeCallScope(JNIEnv* env, std::shared_ptr<RuntimeBridge> bridge)
        : env_(env), bridge_(std::move(bridge)), lock_(bridge_->tmux_call_mutex) {
        if (!bridge_->closing.load() && bridge_->core_runtime != nullptr) {
            bridge_->tmux_active_calls += 1;
            entered_ = true;
        }
    }

    ~TmuxRuntimeCallScope() {
        if (!entered_) return;
        bridge_->tmux_active_calls -= 1;
        if (bridge_->tmux_active_calls == 0 && bridge_->tmux_destroy_pending) {
            destroy_tmux_runtime_locked(env_, bridge_);
        }
    }

    explicit operator bool() const { return entered_; }

private:
    JNIEnv* env_;
    std::shared_ptr<RuntimeBridge> bridge_;
    std::unique_lock<std::recursive_mutex> lock_;
    bool entered_ = false;
};

std::shared_ptr<RuntimeBridge> find_tmux_authority_lifecycle(jlong token) {
    std::lock_guard<std::mutex> lock(registry_mutex);
    const auto iterator = tmux_authority_lifecycles.find(token);
    return iterator == tmux_authority_lifecycles.end() ? nullptr : iterator->second;
}

// A stateful JSON reducer handle (the tmux authority lifecycle, the show-edge
// tracker): one bounded request in, one bounded response out of a buffer the
// caller provides.
struct BoundedJsonReducerSymbols {
    using Reduce = std::int32_t (*)(
        void*, const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t
    );
    Reduce reduce = nullptr;
    std::size_t maximum_payload_bytes = 0;
};

// These reducers run on every authority-carrying runtime event and every
// show-edge fact, so their two dlsym lookups and the size query are resolved
// once per process. Only a complete lookup is cached: a failure still raises
// UnsatisfiedLinkError on the call that observes it, and the next call
// retries.
const BoundedJsonReducerSymbols* bounded_json_reducer_symbols(
    JNIEnv* env,
    std::atomic<const BoundedJsonReducerSymbols*>& cached,
    const char* maximum_payload_bytes_name,
    const char* reduce_name
) {
    if (const auto* symbols = cached.load(std::memory_order_acquire)) return symbols;
    using MaximumPayloadBytes = std::size_t (*)();
    const MaximumPayloadBytes maximum_payload_bytes = require_symbol<MaximumPayloadBytes>(
        env, maximum_payload_bytes_name
    );
    if (maximum_payload_bytes == nullptr) return nullptr;
    const auto reduce = require_symbol<BoundedJsonReducerSymbols::Reduce>(env, reduce_name);
    if (reduce == nullptr) return nullptr;
    const std::size_t maximum = maximum_payload_bytes();
    if (maximum == 0) return nullptr;
    auto* fresh = new (std::nothrow) BoundedJsonReducerSymbols{reduce, maximum};
    if (fresh == nullptr) return nullptr;
    const BoundedJsonReducerSymbols* expected = nullptr;
    if (!cached.compare_exchange_strong(expected, fresh, std::memory_order_acq_rel)) {
        delete fresh;
        return expected;
    }
    return fresh;
}

const BoundedJsonReducerSymbols* tmux_authority_lifecycle_symbols(JNIEnv* env) {
    static std::atomic<const BoundedJsonReducerSymbols*> cached{nullptr};
    return bounded_json_reducer_symbols(
        env,
        cached,
        "tessera_tmux_authority_lifecycle_max_payload_bytes",
        "tessera_tmux_authority_lifecycle_reduce"
    );
}

std::shared_ptr<RuntimeBridge> find_tmux_show_edges(jlong token) {
    std::lock_guard<std::mutex> lock(registry_mutex);
    const auto iterator = tmux_show_edges.find(token);
    return iterator == tmux_show_edges.end() ? nullptr : iterator->second;
}

const BoundedJsonReducerSymbols* tmux_show_edges_symbols(JNIEnv* env) {
    static std::atomic<const BoundedJsonReducerSymbols*> cached{nullptr};
    return bounded_json_reducer_symbols(
        env,
        cached,
        "tessera_tmux_show_edges_max_payload_bytes",
        "tessera_tmux_show_edges_reduce"
    );
}

// One reduction through a handle's reused output buffer. The caller holds
// the bridge's call_mutex and has checked that it is not closing.
jbyteArray reduce_bounded_json(
    JNIEnv* env,
    RuntimeBridge& bridge,
    const BoundedJsonReducerSymbols* (*resolve_symbols)(JNIEnv*),
    jobject request,
    jint count
) {
    void* address = env->GetDirectBufferAddress(request);
    const jlong capacity = env->GetDirectBufferCapacity(request);
    if (address == nullptr || capacity < 0 || static_cast<jlong>(count) > capacity) return nullptr;
    const BoundedJsonReducerSymbols* symbols = resolve_symbols(env);
    if (symbols == nullptr) return nullptr;
    const std::size_t maximum = symbols->maximum_payload_bytes;
    if (static_cast<std::size_t>(count) > maximum) return nullptr;
    if (bridge.lifecycle_output_capacity < maximum) {
        bridge.lifecycle_output.reset(new (std::nothrow) std::uint8_t[maximum]);
        bridge.lifecycle_output_capacity = bridge.lifecycle_output ? maximum : 0;
        if (!bridge.lifecycle_output) return nullptr;
    }
    std::uint8_t* const output = bridge.lifecycle_output.get();
    const std::int32_t output_count = symbols->reduce(
        bridge.core_runtime,
        static_cast<const std::uint8_t*>(address),
        static_cast<std::size_t>(count),
        output,
        bridge.lifecycle_output_capacity
    );
    if (output_count <= 0 || static_cast<std::size_t>(output_count) > bridge.lifecycle_output_capacity) {
        return nullptr;
    }
    jbyteArray result = env->NewByteArray(output_count);
    if (result == nullptr) return nullptr;
    env->SetByteArrayRegion(
        result, 0, output_count, reinterpret_cast<const jbyte*>(output)
    );
    return result;
}

std::shared_ptr<RuntimeBridge> find_cross_device_runtime(jlong token) {
    std::lock_guard<std::mutex> lock(registry_mutex);
    const auto iterator = cross_device_runtimes.find(token);
    return iterator == cross_device_runtimes.end() ? nullptr : iterator->second;
}

std::shared_ptr<RuntimeBridge> find_agent_runtime(jlong token) {
    std::lock_guard<std::mutex> lock(registry_mutex);
    const auto iterator = agent_runtimes.find(token);
    return iterator == agent_runtimes.end() ? nullptr : iterator->second;
}

void deliver_tmux_event(const std::uint8_t* bytes, std::size_t count, void* context) {
    auto* raw_bridge = static_cast<RuntimeBridge*>(context);
    if (raw_bridge == nullptr) return;
    const auto bridge = find_tmux_runtime(raw_bridge->token);
    if (bridge == nullptr || bridge->closing.load()) return;
    JNIEnv* env = nullptr;
    bool attached = false;
    const jint status = bridge->vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6);
    if (status == JNI_EDETACHED) {
        if (attach_current_thread(bridge->vm, &env) != JNI_OK) return;
        attached = true;
    } else if (status != JNI_OK) return;
    jobject listener = env->NewLocalRef(bridge->listener);
    if (listener != nullptr && bytes != nullptr) {
        jobject buffer = env->NewDirectByteBuffer(
            const_cast<std::uint8_t*>(bytes), static_cast<jlong>(count)
        );
        if (buffer != nullptr) {
            env->CallVoidMethod(listener, bridge->on_event, buffer);
            env->DeleteLocalRef(buffer);
        }
        env->DeleteLocalRef(listener);
    }
    if (env->ExceptionCheck()) env->ExceptionClear();
    if (attached) bridge->vm->DetachCurrentThread();
}

void deliver_cross_device_event(const std::uint8_t* bytes, std::size_t count, void* context) {
    auto* raw_bridge = static_cast<RuntimeBridge*>(context);
    if (raw_bridge == nullptr) return;
    const auto bridge = find_cross_device_runtime(raw_bridge->token);
    if (bridge == nullptr || bridge->closing.load()) return;
    JNIEnv* env = nullptr;
    bool attached = false;
    const jint status = bridge->vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6);
    if (status == JNI_EDETACHED) {
        if (attach_current_thread(bridge->vm, &env) != JNI_OK) return;
        attached = true;
    } else if (status != JNI_OK) return;
    jobject listener = env->NewLocalRef(bridge->listener);
    if (listener != nullptr && bytes != nullptr) {
        jobject buffer = env->NewDirectByteBuffer(
            const_cast<std::uint8_t*>(bytes), static_cast<jlong>(count)
        );
        if (buffer != nullptr) {
            env->CallVoidMethod(listener, bridge->on_event, buffer);
            env->DeleteLocalRef(buffer);
        }
        env->DeleteLocalRef(listener);
    }
    if (env->ExceptionCheck()) env->ExceptionClear();
    if (attached) bridge->vm->DetachCurrentThread();
}

void deliver_agent_event(const std::uint8_t* bytes, std::size_t count, void* context) {
    // The Agent ABI can enqueue its terminal callback after destroy returns.
    // Pass the opaque registry token (never a RuntimeBridge address) so a late
    // callback cannot dereference freed bridge storage.
    const auto token = static_cast<jlong>(reinterpret_cast<std::uintptr_t>(context));
    if (token <= 0) return;
    const auto bridge = find_agent_runtime(token);
    if (bridge == nullptr || bridge->closing.load() || bytes == nullptr || count == 0 ||
        count > kAgentMaxPayloadBytes) return;
    JNIEnv* env = nullptr;
    bool attached = false;
    const jint status = bridge->vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6);
    if (status == JNI_EDETACHED) {
        if (attach_current_thread(bridge->vm, &env) != JNI_OK) return;
        attached = true;
    } else if (status != JNI_OK) return;
    jobject listener = env->NewLocalRef(bridge->listener);
    if (listener != nullptr) {
        jobject buffer = env->NewDirectByteBuffer(
            const_cast<std::uint8_t*>(bytes), static_cast<jlong>(count)
        );
        if (buffer != nullptr) {
            env->CallVoidMethod(listener, bridge->on_event, buffer);
            env->DeleteLocalRef(buffer);
        }
        env->DeleteLocalRef(listener);
    }
    if (env->ExceptionCheck()) env->ExceptionClear();
    if (attached) bridge->vm->DetachCurrentThread();
}

template <typename Function>
jint call_runtime(
    JNIEnv* env,
    jlong token,
    jobject payload,
    jint offset,
    jint count,
    const char* symbol_name
) {
    const auto bridge = find_runtime(token);
    if (bridge == nullptr || bridge->closing.load()) return -2;
    void* address = env->GetDirectBufferAddress(payload);
    const jlong capacity = env->GetDirectBufferCapacity(payload);
    if (address == nullptr || offset < 0 || count <= 0 ||
        static_cast<jlong>(offset) + count > capacity) {
        return -1;
    }
    const Function function = require_symbol<Function>(env, symbol_name);
    if (function == nullptr) return -1;
    const auto* bytes = static_cast<const std::uint8_t*>(address) + offset;
    return static_cast<jint>(function(bridge->core_runtime, bytes, count));
}

// Copy/feed buffers always use their base address and an explicit capacity.
// A null buffer with zero capacity is the ABI's size-query/no-output form.
bool program_status_output(JNIEnv* env, jobject output, jint capacity, std::uint8_t** bytes) {
    *bytes = nullptr;
    if (capacity < 0) return false;
    if (output == nullptr) return capacity == 0;
    *bytes = static_cast<std::uint8_t*>(env->GetDirectBufferAddress(output));
    return *bytes != nullptr && env->GetDirectBufferCapacity(output) >= capacity;
}

}  // namespace

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_abiVersion(
    JNIEnv* env,
    jobject /* receiver */
) {
    using Function = std::uint32_t (*)();
    const Function function = require_symbol<Function>(env, "tessera_core_abi_version");
    return function == nullptr ? 0 : static_cast<jint>(function());
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_maxPayloadBytes(
    JNIEnv* env,
    jobject /* receiver */
) {
    using Function = std::size_t (*)();
    const Function function =
        require_symbol<Function>(env, "tessera_core_abi_max_payload_bytes");
    return function == nullptr ? 0 : static_cast<jlong>(function());
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_createRuntime(
    JNIEnv* env,
    jobject /* receiver */,
    jobject event_sink
) {
    if (event_sink == nullptr) return 0;
    jclass sink_class = env->GetObjectClass(event_sink);
    if (sink_class == nullptr) return 0;
    jmethodID on_event = env->GetMethodID(
        sink_class,
        "onEvent",
        "(Ljava/nio/ByteBuffer;)V"
    );
    env->DeleteLocalRef(sink_class);
    if (on_event == nullptr) return 0;

    JavaVM* vm = nullptr;
    if (env->GetJavaVM(&vm) != JNI_OK) return 0;
    jobject listener = env->NewGlobalRef(event_sink);
    if (listener == nullptr) return 0;

    const auto bridge = std::make_shared<RuntimeBridge>();
    bridge->token = next_runtime_token.fetch_add(1);
    bridge->vm = vm;
    bridge->listener = listener;
    bridge->on_event = on_event;
    {
        std::lock_guard<std::mutex> lock(registry_mutex);
        runtimes.emplace(bridge->token, bridge);
    }

    const CoreRuntimeCreate create =
        require_symbol<CoreRuntimeCreate>(env, "tessera_core_runtime_create");
    if (create != nullptr) {
        bridge->core_runtime = create(deliver_event, bridge.get());
    }
    if (bridge->core_runtime == nullptr) {
        std::lock_guard<std::mutex> lock(registry_mutex);
        runtimes.erase(bridge->token);
        env->DeleteGlobalRef(listener);
        return 0;
    }
    return bridge->token;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_sendRuntime(
    JNIEnv* env,
    jobject /* receiver */,
    jlong handle,
    jobject payload,
    jint offset,
    jint count
) {
    return call_runtime<CoreRuntimeCall>(
        env,
        handle,
        payload,
        offset,
        count,
        "tessera_core_runtime_send"
    );
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_emitRuntime(
    JNIEnv* env,
    jobject /* receiver */,
    jlong handle,
    jobject payload,
    jint offset,
    jint count
) {
    return call_runtime<CoreRuntimeCall>(
        env,
        handle,
        payload,
        offset,
        count,
        "tessera_core_runtime_emit"
    );
}

extern "C" JNIEXPORT void JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_destroyRuntime(
    JNIEnv* env,
    jobject /* receiver */,
    jlong handle
) {
    const auto bridge = find_runtime(handle);
    if (bridge == nullptr) return;
    bool expected = false;
    if (!bridge->closing.compare_exchange_strong(expected, true)) return;

    const CoreRuntimeDestroy destroy =
        require_symbol<CoreRuntimeDestroy>(env, "tessera_core_runtime_destroy");
    if (destroy != nullptr) destroy(bridge->core_runtime);
    {
        std::lock_guard<std::mutex> lock(registry_mutex);
        runtimes.erase(handle);
    }
    if (bridge->listener != nullptr) {
        env->DeleteGlobalRef(bridge->listener);
        bridge->listener = nullptr;
    }
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_createTmuxRuntime(
    JNIEnv* env,
    jobject /* receiver */,
    jobject event_sink
) {
    if (event_sink == nullptr) return 0;
    jclass sink_class = env->GetObjectClass(event_sink);
    if (sink_class == nullptr) return 0;
    jmethodID on_event = env->GetMethodID(sink_class, "onEvent", "(Ljava/nio/ByteBuffer;)V");
    env->DeleteLocalRef(sink_class);
    if (on_event == nullptr) return 0;
    JavaVM* vm = nullptr;
    if (env->GetJavaVM(&vm) != JNI_OK) return 0;
    jobject listener = env->NewGlobalRef(event_sink);
    if (listener == nullptr) return 0;
    const auto bridge = std::make_shared<RuntimeBridge>();
    bridge->token = next_tmux_runtime_token.fetch_add(1);
    bridge->vm = vm;
    bridge->listener = listener;
    bridge->on_event = on_event;
    {
        std::lock_guard<std::mutex> lock(registry_mutex);
        tmux_runtimes.emplace(bridge->token, bridge);
    }
    using Create = void* (*)(CoreEventCallback, void*);
    const Create create = require_symbol<Create>(env, "tessera_tmux_runtime_create");
    if (create != nullptr) {
        bridge->core_runtime = create(
            deliver_tmux_event,
            bridge.get()
        );
    }
    if (bridge->core_runtime == nullptr) {
        std::lock_guard<std::mutex> lock(registry_mutex);
        tmux_runtimes.erase(bridge->token);
        env->DeleteGlobalRef(listener);
        return 0;
    }
    return bridge->token;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_feedTmuxRuntime(
    JNIEnv* env,
    jobject /* receiver */,
    jlong handle,
    jobject payload,
    jint offset,
    jint count
) {
    const auto bridge = find_tmux_runtime(handle);
    if (bridge == nullptr) return -2;
    TmuxRuntimeCallScope call(env, bridge);
    if (!call) return -2;
    void* address = env->GetDirectBufferAddress(payload);
    const jlong capacity = env->GetDirectBufferCapacity(payload);
    if (address == nullptr || offset < 0 || count <= 0 ||
        static_cast<jlong>(offset) + count > capacity) return -1;
    using Feed = std::int32_t (*)(void*, const std::uint8_t*, std::size_t);
    const Feed feed = require_symbol<Feed>(env, "tessera_tmux_runtime_feed");
    if (feed == nullptr) return -1;
    const auto* bytes = static_cast<const std::uint8_t*>(address) + offset;
    return static_cast<jint>(feed(bridge->core_runtime, bytes, count));
}

// tessera_tmux_runtime_feed at the attached authority session's clock: the
// session reduces the read's stamp edges itself.
extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_feedTmuxRuntimeAt(
    JNIEnv* env,
    jobject /* receiver */,
    jlong handle,
    jobject payload,
    jint offset,
    jint count,
    jlong now_millis
) {
    const auto bridge = find_tmux_runtime(handle);
    if (bridge == nullptr) return -2;
    TmuxRuntimeCallScope call(env, bridge);
    if (!call) return -2;
    void* address = env->GetDirectBufferAddress(payload);
    const jlong capacity = env->GetDirectBufferCapacity(payload);
    if (address == nullptr || offset < 0 || count <= 0 || now_millis < 0 ||
        static_cast<jlong>(offset) + count > capacity) return -1;
    using FeedAt = std::int32_t (*)(void*, const std::uint8_t*, std::size_t, std::int64_t);
    const FeedAt feed_at = require_symbol<FeedAt>(env, "tessera_tmux_runtime_feed_at");
    if (feed_at == nullptr) return -1;
    const auto* bytes = static_cast<const std::uint8_t*>(address) + offset;
    return static_cast<jint>(feed_at(bridge->core_runtime, bytes, count, static_cast<std::int64_t>(now_millis)));
}

// Deliver feedTmuxRuntimeAt's lost authority result again (it returned 1 and
// the session never adopted it): 0, -1 for nothing to deliver, -2 stale.
extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_redeliverTmuxRuntimeAuthorityResult(
    JNIEnv* env,
    jobject /* receiver */,
    jlong handle,
    jlong now_millis
) {
    const auto bridge = find_tmux_runtime(handle);
    if (bridge == nullptr) return -2;
    TmuxRuntimeCallScope call(env, bridge);
    if (!call) return -2;
    if (now_millis < 0) return -1;
    using Redeliver = std::int32_t (*)(void*, std::int64_t);
    const Redeliver redeliver = require_symbol<Redeliver>(env, "tessera_tmux_runtime_redeliver_authority_result");
    if (redeliver == nullptr) return -1;
    return static_cast<jint>(redeliver(bridge->core_runtime, static_cast<std::int64_t>(now_millis)));
}

// Attach the authority session lifecycle `session` (0 detaches) for
// feedTmuxRuntimeAt: 0, -1 for a session that is not live, -2 for a stale
// runtime. The lifecycle's call mutex is deliberately not held: a runtime
// callback already holds the runtime's lock while it reduces the session
// through that mutex. The core resolves the session handle itself and
// refuses one destroyed in between.
extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_attachTmuxRuntimeAuthoritySession(
    JNIEnv* env,
    jobject /* receiver */,
    jlong handle,
    jlong session
) {
    void* core_session = nullptr;
    if (session != 0) {
        const auto lifecycle = find_tmux_authority_lifecycle(session);
        if (lifecycle == nullptr || lifecycle->closing.load()) return -1;
        core_session = lifecycle->core_runtime;
    }
    const auto bridge = find_tmux_runtime(handle);
    if (bridge == nullptr) return -2;
    TmuxRuntimeCallScope call(env, bridge);
    if (!call) return -2;
    using Attach = std::int32_t (*)(void*, void*);
    const Attach attach = require_symbol<Attach>(env, "tessera_tmux_runtime_attach_authority_session");
    if (attach == nullptr) return -1;
    return static_cast<jint>(attach(bridge->core_runtime, core_session));
}

static jlong submit_tmux_runtime_command(
    JNIEnv* env,
    jlong handle,
    jobject command,
    jint count,
    const char* symbol
) {
    const auto bridge = find_tmux_runtime(handle);
    if (bridge == nullptr) return -2;
    TmuxRuntimeCallScope call(env, bridge);
    if (!call) return -2;
    void* address = env->GetDirectBufferAddress(command);
    const jlong capacity = env->GetDirectBufferCapacity(command);
    if (address == nullptr || count <= 0 || static_cast<std::size_t>(count) > kCoreMaxPayloadBytes ||
        count > capacity) return -1;
    using SendCommand = std::int64_t (*)(void*, const std::uint8_t*, std::size_t);
    const SendCommand send_command = require_symbol<SendCommand>(env, symbol);
    if (send_command == nullptr) return -1;
    return static_cast<jlong>(send_command(
        bridge->core_runtime,
        static_cast<const std::uint8_t*>(address),
        static_cast<std::size_t>(count)
    ));
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_sendTmuxRuntimeCommand(
    JNIEnv* env, jobject /* receiver */, jlong handle, jobject command, jint count
) {
    return submit_tmux_runtime_command(env, handle, command, count, "tessera_tmux_runtime_send_command");
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_queueTmuxRuntimeCommand(
    JNIEnv* env, jobject /* receiver */, jlong handle, jobject command, jint count
) {
    return submit_tmux_runtime_command(env, handle, command, count, "tessera_tmux_runtime_queue_command");
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_submitTmuxRenderFact(
    JNIEnv* env,
    jobject /* receiver */,
    jlong handle,
    jobject fact,
    jint count
) {
    const auto bridge = find_tmux_runtime(handle);
    if (bridge == nullptr) return -2;
    TmuxRuntimeCallScope call(env, bridge);
    if (!call) return -2;
    void* address = env->GetDirectBufferAddress(fact);
    const jlong capacity = env->GetDirectBufferCapacity(fact);
    if (address == nullptr || count <= 0 || static_cast<std::size_t>(count) > kCoreMaxPayloadBytes ||
        count > capacity) return -1;
    using SubmitFact = std::int32_t (*)(void*, const std::uint8_t*, std::size_t);
    const SubmitFact submit_fact = require_symbol<SubmitFact>(
        env, "tessera_tmux_runtime_submit_fact"
    );
    if (submit_fact == nullptr) return -1;
    return static_cast<jint>(submit_fact(
        bridge->core_runtime,
        static_cast<const std::uint8_t*>(address),
        static_cast<std::size_t>(count)
    ));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_takeTmuxRenderBytes(
    JNIEnv* env,
    jobject /* receiver */,
    jlong handle,
    jlong bytes_ref,
    jobject output,
    jint output_capacity
) {
    if (bytes_ref <= 0 || output_capacity < 0 ||
        static_cast<std::size_t>(output_capacity) > kCoreMaxPayloadBytes) return -1;
    const auto bridge = find_tmux_runtime(handle);
    if (bridge == nullptr) return -2;
    TmuxRuntimeCallScope call(env, bridge);
    if (!call) return -2;

    auto* output_bytes = static_cast<std::uint8_t*>(nullptr);
    if (output != nullptr) {
        void* address = env->GetDirectBufferAddress(output);
        const jlong direct_capacity = env->GetDirectBufferCapacity(output);
        if (address == nullptr || direct_capacity < output_capacity) return -1;
        output_bytes = static_cast<std::uint8_t*>(address);
    } else if (output_capacity != 0) {
        return -1;
    }

    using TakeBytes = std::int32_t (*)(void*, std::uint64_t, std::uint8_t*, std::size_t);
    const TakeBytes take_bytes = require_symbol<TakeBytes>(
        env, "tessera_tmux_runtime_take_render_bytes"
    );
    if (take_bytes == nullptr) return -1;
    return static_cast<jint>(take_bytes(
        bridge->core_runtime,
        static_cast<std::uint64_t>(bytes_ref),
        output_bytes,
        static_cast<std::size_t>(output_capacity)
    ));
}

// The same direct-buffer boundary as render facts/bytes. A short output is
// refused before mutation, so Kotlin can grow it and safely retry once.
extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_projectTmuxAuthorityReleasing(
    JNIEnv* env,
    jobject /* receiver */,
    jlong handle,
    jobject authority,
    jint authority_count,
    jobject output,
    jint output_capacity
) {
    const auto bridge = find_tmux_runtime(handle);
    if (bridge == nullptr) return -2;
    TmuxRuntimeCallScope call(env, bridge);
    if (!call) return -2;
    if (authority == nullptr || output == nullptr || output_capacity <= 0 ||
        static_cast<std::size_t>(output_capacity) > kCoreMaxPayloadBytes) return -1;
    const auto* authority_bytes = static_cast<const std::uint8_t*>(env->GetDirectBufferAddress(authority));
    auto* output_bytes = static_cast<std::uint8_t*>(env->GetDirectBufferAddress(output));
    if (authority_bytes == nullptr || output_bytes == nullptr || authority_count <= 0 ||
        authority_count > env->GetDirectBufferCapacity(authority) ||
        static_cast<std::size_t>(authority_count) > kCoreMaxPayloadBytes ||
        output_capacity > env->GetDirectBufferCapacity(output)) return -1;
    using Project = std::int32_t (*)(void*, const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t);
    const Project project = require_symbol<Project>(env, "tessera_tmux_runtime_project_authority_releasing");
    if (project == nullptr) return -1;
    return static_cast<jint>(project(
        bridge->core_runtime, authority_bytes, static_cast<std::size_t>(authority_count),
        output_bytes, static_cast<std::size_t>(output_capacity)
    ));
}

// The adapter-owned render-ledger switches as the header's
// TESSERA_TMUX_RENDER_LEDGER_* bits: 0, -1 for an undefined bit, -2 stale.
extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_setTmuxRenderLedgerOptions(
    JNIEnv* env,
    jobject /* receiver */,
    jlong handle,
    jint options
) {
    const auto bridge = find_tmux_runtime(handle);
    if (bridge == nullptr) return -2;
    TmuxRuntimeCallScope call(env, bridge);
    if (!call) return -2;
    using SetOptions = std::int32_t (*)(void*, std::uint32_t);
    const SetOptions set_options = require_symbol<SetOptions>(
        env, "tessera_tmux_runtime_set_render_ledger_options"
    );
    return set_options == nullptr ? -1 : static_cast<jint>(
        set_options(bridge->core_runtime, static_cast<std::uint32_t>(options))
    );
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_setTmuxProgramStatusEnabled(
    JNIEnv* env, jobject /* receiver */, jlong handle, jboolean enabled
) {
    const auto bridge = find_tmux_runtime(handle);
    if (bridge == nullptr) return -2;
    TmuxRuntimeCallScope call(env, bridge);
    if (!call) return -2;
    using SetEnabled = std::int32_t (*)(void*, std::int32_t);
    const SetEnabled set_enabled = require_symbol<SetEnabled>(env, "tessera_tmux_runtime_set_program_status_enabled");
    return set_enabled == nullptr ? -1 : static_cast<jint>(set_enabled(bridge->core_runtime, enabled ? 1 : 0));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_setTmuxSubscriptions(
    JNIEnv* env, jobject /* receiver */, jlong handle, jint feeds, jlong authority_owner_session_id
) {
    const auto bridge = find_tmux_runtime(handle);
    if (bridge == nullptr) return -2;
    TmuxRuntimeCallScope call(env, bridge);
    if (!call) return -2;
    using SetSubscriptions = std::int32_t (*)(void*, std::uint32_t, std::int64_t);
    const SetSubscriptions set_subscriptions = require_symbol<SetSubscriptions>(env, "tessera_tmux_runtime_set_subscriptions");
    return set_subscriptions == nullptr ? -1 : static_cast<jint>(set_subscriptions(
        bridge->core_runtime, static_cast<std::uint32_t>(feeds), static_cast<std::int64_t>(authority_owner_session_id)
    ));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_copyTmuxProgramStatus(
    JNIEnv* env, jobject /* receiver */, jlong handle, jobject output, jint output_capacity
) {
    const auto bridge = find_tmux_runtime(handle);
    if (bridge == nullptr) return -2;
    TmuxRuntimeCallScope call(env, bridge);
    if (!call) return -2;
    std::uint8_t* output_bytes = nullptr;
    if (!program_status_output(env, output, output_capacity, &output_bytes)) return -1;
    using Copy = std::int32_t (*)(void*, std::uint8_t*, std::size_t);
    const Copy copy = require_symbol<Copy>(env, "tessera_tmux_runtime_copy_program_status");
    return copy == nullptr ? -1 : static_cast<jint>(copy(
        bridge->core_runtime, output_bytes, static_cast<std::size_t>(output_capacity)
    ));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_acknowledgeTmuxProgramStatus(
    JNIEnv* env, jobject /* receiver */, jlong handle, jlong pane_id, jlong through
) {
    const auto bridge = find_tmux_runtime(handle);
    if (bridge == nullptr) return -2;
    TmuxRuntimeCallScope call(env, bridge);
    if (!call) return -2;
    using Acknowledge = std::int32_t (*)(void*, std::int64_t, std::uint64_t);
    const Acknowledge acknowledge = require_symbol<Acknowledge>(env, "tessera_tmux_runtime_acknowledge_program_status");
    return acknowledge == nullptr ? -1 : static_cast<jint>(acknowledge(
        bridge->core_runtime, static_cast<std::int64_t>(pane_id), static_cast<std::uint64_t>(through)
    ));
}

// Raw monitors are the C ABI's opaque registry tokens, carried directly as
// jlong. The core owns locking and stale-token checks, including close races.
extern "C" JNIEXPORT jlong JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_createProgramStatusMonitor(
    JNIEnv* env, jobject /* receiver */
) {
    using Create = void* (*)();
    const Create create = require_symbol<Create>(env, "tessera_program_status_monitor_create");
    return create == nullptr ? 0 : reinterpret_cast<jlong>(create());
}

extern "C" JNIEXPORT void JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_destroyProgramStatusMonitor(
    JNIEnv* env, jobject /* receiver */, jlong handle
) {
    if (handle == 0) return;
    using Destroy = void (*)(void*);
    const Destroy destroy = require_symbol<Destroy>(env, "tessera_program_status_monitor_destroy");
    if (destroy != nullptr) destroy(reinterpret_cast<void*>(handle));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_setProgramStatusMonitorEnabled(
    JNIEnv* env, jobject /* receiver */, jlong handle, jboolean enabled
) {
    if (handle == 0) return -2;
    using SetEnabled = std::int32_t (*)(void*, std::int32_t);
    const SetEnabled set_enabled = require_symbol<SetEnabled>(env, "tessera_program_status_monitor_set_enabled");
    return set_enabled == nullptr ? -1 : static_cast<jint>(set_enabled(reinterpret_cast<void*>(handle), enabled ? 1 : 0));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_feedProgramStatusMonitor(
    JNIEnv* env, jobject /* receiver */, jlong handle, jobject input, jint count,
    jobject reply, jint reply_capacity, jlongArray revision_out
) {
    if (handle == 0) return -2;
    if (count < 0 || static_cast<std::size_t>(count) > kCoreMaxPayloadBytes) return -1;
    const std::uint8_t* input_bytes = nullptr;
    if (input != nullptr) {
        input_bytes = static_cast<const std::uint8_t*>(env->GetDirectBufferAddress(input));
        if (input_bytes == nullptr || env->GetDirectBufferCapacity(input) < count) return -1;
    } else if (count != 0) {
        return -1;
    }
    std::uint8_t* reply_bytes = nullptr;
    if (!program_status_output(env, reply, reply_capacity, &reply_bytes)) return -1;
    if (revision_out != nullptr && env->GetArrayLength(revision_out) < 1) return -1;
    using Feed = std::int32_t (*)(
        void*, const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t, std::uint64_t*
    );
    const Feed feed = require_symbol<Feed>(env, "tessera_program_status_monitor_feed");
    if (feed == nullptr) return -1;
    std::uint64_t revision = 0;
    const auto result = feed(
        reinterpret_cast<void*>(handle), input_bytes, static_cast<std::size_t>(count),
        reply_bytes, static_cast<std::size_t>(reply_capacity), revision_out == nullptr ? nullptr : &revision
    );
    if (result >= 0 && revision_out != nullptr) {
        const jlong value = static_cast<jlong>(revision);
        env->SetLongArrayRegion(revision_out, 0, 1, &value);
    }
    return static_cast<jint>(result);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_copyProgramStatusMonitorSnapshot(
    JNIEnv* env, jobject /* receiver */, jlong handle, jobject output, jint output_capacity
) {
    if (handle == 0) return -2;
    std::uint8_t* output_bytes = nullptr;
    if (!program_status_output(env, output, output_capacity, &output_bytes)) return -1;
    using Copy = std::int32_t (*)(void*, std::uint8_t*, std::size_t);
    const Copy copy = require_symbol<Copy>(env, "tessera_program_status_monitor_copy_snapshot");
    return copy == nullptr ? -1 : static_cast<jint>(copy(
        reinterpret_cast<void*>(handle), output_bytes, static_cast<std::size_t>(output_capacity)
    ));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_acknowledgeProgramStatusMonitor(
    JNIEnv* env, jobject /* receiver */, jlong handle, jlong through
) {
    if (handle == 0) return -2;
    using Acknowledge = std::int32_t (*)(void*, std::uint64_t);
    const Acknowledge acknowledge = require_symbol<Acknowledge>(env, "tessera_program_status_monitor_acknowledge");
    return acknowledge == nullptr ? -1 : static_cast<jint>(acknowledge(
        reinterpret_cast<void*>(handle), static_cast<std::uint64_t>(through)
    ));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_noteProgramStatusMonitorTransportLost(
    JNIEnv* env, jobject /* receiver */, jlong handle
) {
    if (handle == 0) return -2;
    using NoteLost = std::int32_t (*)(void*);
    const NoteLost note_lost = require_symbol<NoteLost>(env, "tessera_program_status_monitor_note_transport_lost");
    return note_lost == nullptr ? -1 : static_cast<jint>(note_lost(reinterpret_cast<void*>(handle)));
}

// Usually re-entered from deliver_tmux_event's Kotlin listener, when the event
// decoder finds its held snapshot out of step: the recursive call gate admits
// it and the core queues the answer behind the callback in progress.
extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_resyncTmuxRuntimeSnapshot(
    JNIEnv* env,
    jobject /* receiver */,
    jlong handle
) {
    const auto bridge = find_tmux_runtime(handle);
    if (bridge == nullptr) return -2;
    TmuxRuntimeCallScope call(env, bridge);
    if (!call) return -2;
    using Resync = std::int32_t (*)(void*);
    const Resync resync = require_symbol<Resync>(env, "tessera_tmux_runtime_resync_snapshot");
    return resync == nullptr ? -1 : static_cast<jint>(resync(bridge->core_runtime));
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_createTmuxAuthorityLifecycleSeeded(
    JNIEnv* env,
    jobject /* receiver */,
    jlong initial_generation
) {
    using Create = void* (*)(std::int64_t);
    const Create create = require_symbol<Create>(
        env, "tessera_tmux_authority_lifecycle_create_seeded"
    );
    if (create == nullptr) return 0;
    const auto bridge = std::make_shared<RuntimeBridge>();
    bridge->token = next_tmux_authority_lifecycle_token.fetch_add(1);
    bridge->core_runtime = create(initial_generation);
    if (bridge->core_runtime == nullptr) return 0;
    {
        std::lock_guard<std::mutex> lock(registry_mutex);
        tmux_authority_lifecycles.emplace(bridge->token, bridge);
    }
    return bridge->token;
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_createTmuxAuthorityLifecycle(
    JNIEnv* env,
    jobject /* receiver */
) {
    using Create = void* (*)();
    const Create create = require_symbol<Create>(
        env, "tessera_tmux_authority_lifecycle_create"
    );
    if (create == nullptr) return 0;
    const auto bridge = std::make_shared<RuntimeBridge>();
    bridge->token = next_tmux_authority_lifecycle_token.fetch_add(1);
    bridge->core_runtime = create();
    if (bridge->core_runtime == nullptr) return 0;
    {
        std::lock_guard<std::mutex> lock(registry_mutex);
        tmux_authority_lifecycles.emplace(bridge->token, bridge);
    }
    return bridge->token;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_reduceTmuxAuthorityLifecycle(
    JNIEnv* env,
    jobject /* receiver */,
    jlong handle,
    jobject request,
    jint count
) {
    const auto bridge = find_tmux_authority_lifecycle(handle);
    if (bridge == nullptr || request == nullptr || count <= 0) {
        return nullptr;
    }
    std::lock_guard<std::mutex> call_lock(bridge->call_mutex);
    if (bridge->closing.load()) return nullptr;
    return reduce_bounded_json(env, *bridge, tmux_authority_lifecycle_symbols, request, count);
}

extern "C" JNIEXPORT void JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_destroyTmuxAuthorityLifecycle(
    JNIEnv* env,
    jobject /* receiver */,
    jlong handle
) {
    const auto bridge = find_tmux_authority_lifecycle(handle);
    if (bridge == nullptr) return;
    bool expected = false;
    if (!bridge->closing.compare_exchange_strong(expected, true)) return;
    std::lock_guard<std::mutex> call_lock(bridge->call_mutex);
    using Destroy = void (*)(void*);
    const Destroy destroy = require_symbol<Destroy>(
        env, "tessera_tmux_authority_lifecycle_destroy"
    );
    if (destroy != nullptr) destroy(bridge->core_runtime);
    std::lock_guard<std::mutex> lock(registry_mutex);
    tmux_authority_lifecycles.erase(handle);
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_createTmuxShowEdges(
    JNIEnv* env,
    jobject /* receiver */
) {
    using Create = void* (*)();
    const Create create = require_symbol<Create>(env, "tessera_tmux_show_edges_create");
    if (create == nullptr) return 0;
    const auto bridge = std::make_shared<RuntimeBridge>();
    bridge->token = next_tmux_show_edges_token.fetch_add(1);
    bridge->core_runtime = create();
    if (bridge->core_runtime == nullptr) return 0;
    {
        std::lock_guard<std::mutex> lock(registry_mutex);
        tmux_show_edges.emplace(bridge->token, bridge);
    }
    return bridge->token;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_reduceTmuxShowEdges(
    JNIEnv* env,
    jobject /* receiver */,
    jlong handle,
    jobject request,
    jint count
) {
    const auto bridge = find_tmux_show_edges(handle);
    if (bridge == nullptr || request == nullptr || count <= 0) {
        return nullptr;
    }
    std::lock_guard<std::mutex> call_lock(bridge->call_mutex);
    if (bridge->closing.load()) return nullptr;
    return reduce_bounded_json(env, *bridge, tmux_show_edges_symbols, request, count);
}

extern "C" JNIEXPORT void JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_destroyTmuxShowEdges(
    JNIEnv* env,
    jobject /* receiver */,
    jlong handle
) {
    const auto bridge = find_tmux_show_edges(handle);
    if (bridge == nullptr) return;
    bool expected = false;
    if (!bridge->closing.compare_exchange_strong(expected, true)) return;
    std::lock_guard<std::mutex> call_lock(bridge->call_mutex);
    using Destroy = void (*)(void*);
    const Destroy destroy = require_symbol<Destroy>(env, "tessera_tmux_show_edges_destroy");
    if (destroy != nullptr) destroy(bridge->core_runtime);
    std::lock_guard<std::mutex> lock(registry_mutex);
    tmux_show_edges.erase(handle);
}

namespace {

/*
 * Shared string contract for the remote-command builders: a first call with a
 * null buffer reports the exact byte count, so a command whose length depends
 * on the session name is never silently truncated by a fixed ceiling.
 */
template <typename Build>
jstring build_shared_command(JNIEnv* env, const char* what, Build build) {
    const std::int32_t required = build(nullptr, 0);
    if (required <= 0) {
        throw_java(env, "java/lang/IllegalArgumentException", what);
        return nullptr;
    }
    std::unique_ptr<std::uint8_t[]> output(new std::uint8_t[required + 1]);
    const std::int32_t written = build(output.get(), required);
    if (written != required) {
        throw_java(env, "java/lang/IllegalStateException", what);
        return nullptr;
    }
    // JNI's NewStringUTF accepts modified UTF-8: it corrupts ordinary UTF-8
    // NUL and does not accept four-byte scalar encodings (emoji). Core command
    // builders return ordinary UTF-8, so validate/decode it ourselves and use
    // NewString's UTF-16 code units instead.
    std::u16string utf16;
    utf16.reserve(static_cast<std::size_t>(required));
    for (std::size_t index = 0; index < static_cast<std::size_t>(required);) {
        const std::uint8_t first = output[index++];
        std::uint32_t scalar = 0;
        std::size_t continuation_count = 0;
        if (first <= 0x7f) {
            scalar = first;
        } else if (first >= 0xc2 && first <= 0xdf) {
            scalar = first & 0x1f; continuation_count = 1;
        } else if (first >= 0xe0 && first <= 0xef) {
            scalar = first & 0x0f; continuation_count = 2;
        } else if (first >= 0xf0 && first <= 0xf4) {
            scalar = first & 0x07; continuation_count = 3;
        } else {
            throw_java(env, "java/lang/IllegalStateException", "shared command returned invalid UTF-8");
            return nullptr;
        }
        if (index + continuation_count > static_cast<std::size_t>(required)) {
            throw_java(env, "java/lang/IllegalStateException", "shared command returned truncated UTF-8");
            return nullptr;
        }
        for (std::size_t offset = 0; offset < continuation_count; ++offset) {
            const std::uint8_t next = output[index++];
            if ((next & 0xc0) != 0x80) {
                throw_java(env, "java/lang/IllegalStateException", "shared command returned invalid UTF-8");
                return nullptr;
            }
            scalar = (scalar << 6) | (next & 0x3f);
        }
        const bool overlong = (continuation_count == 1 && scalar < 0x80) ||
            (continuation_count == 2 && scalar < 0x800) ||
            (continuation_count == 3 && scalar < 0x10000);
        if (overlong || (scalar >= 0xd800 && scalar <= 0xdfff) || scalar > 0x10ffff) {
            throw_java(env, "java/lang/IllegalStateException", "shared command returned invalid UTF-8");
            return nullptr;
        }
        if (scalar <= 0xffff) {
            utf16.push_back(static_cast<char16_t>(scalar));
        } else {
            scalar -= 0x10000;
            utf16.push_back(static_cast<char16_t>(0xd800 + (scalar >> 10)));
            utf16.push_back(static_cast<char16_t>(0xdc00 + (scalar & 0x3ff)));
        }
    }
    if (utf16.size() > static_cast<std::size_t>(std::numeric_limits<jsize>::max())) {
        throw_java(env, "java/lang/IllegalStateException", "shared command is too large");
        return nullptr;
    }
    return env->NewString(
        reinterpret_cast<const jchar*>(utf16.data()), static_cast<jsize>(utf16.size())
    );
}

/* Borrow a direct buffer that the caller is allowed to leave empty. */
bool borrow_optional_buffer(
    JNIEnv* env,
    jobject buffer,
    jint count,
    const std::uint8_t** out_bytes,
    std::size_t* out_count
) {
    if (buffer == nullptr || count <= 0) {
        *out_bytes = nullptr;
        *out_count = 0;
        return true;
    }
    void* address = env->GetDirectBufferAddress(buffer);
    if (address == nullptr || count > env->GetDirectBufferCapacity(buffer)) return false;
    *out_bytes = static_cast<const std::uint8_t*>(address);
    *out_count = static_cast<std::size_t>(count);
    return true;
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_tmuxAuthorityVisibleClientOption(
    JNIEnv* env,
    jobject /* receiver */,
    jobject device_id,
    jint device_id_count
) {
    const std::uint8_t* device_bytes = nullptr;
    std::size_t device_size = 0;
    if (!borrow_optional_buffer(env, device_id, device_id_count, &device_bytes, &device_size) ||
        device_bytes == nullptr) return nullptr;
    using Function = std::int32_t (*)(
        const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t
    );
    const Function function = require_symbol<Function>(
        env, "tessera_tmux_authority_visible_client_option"
    );
    if (function == nullptr) return nullptr;
    return build_shared_command(env, "shared authority visible-client option failed",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(device_bytes, device_size, output, capacity);
        });
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_tmuxAuthorityStampValue(
    JNIEnv* env,
    jobject /* receiver */,
    jobject device_id,
    jint device_id_count,
    jobject display_name,
    jint display_name_count,
    jlong generation
) {
    if (generation < 0) return nullptr;
    const std::uint8_t* device_bytes = nullptr;
    const std::uint8_t* display_bytes = nullptr;
    std::size_t device_size = 0;
    std::size_t display_size = 0;
    if (!borrow_optional_buffer(env, device_id, device_id_count, &device_bytes, &device_size) ||
        !borrow_optional_buffer(env, display_name, display_name_count, &display_bytes, &display_size) ||
        device_bytes == nullptr || display_bytes == nullptr) return nullptr;
    using Function = std::int32_t (*)(
        const std::uint8_t*, std::size_t,
        const std::uint8_t*, std::size_t,
        std::uint64_t,
        std::uint8_t*, std::size_t
    );
    const Function function = require_symbol<Function>(
        env, "tessera_tmux_authority_stamp_value"
    );
    if (function == nullptr) return nullptr;
    return build_shared_command(env, "shared authority stamp failed",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(
                device_bytes, device_size,
                display_bytes, display_size,
                static_cast<std::uint64_t>(generation),
                output, capacity
            );
        });
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_moshVisibleTmuxClientCommand(
    JNIEnv* env,
    jobject /* receiver */,
    jobject session_target,
    jint session_target_count,
    jobject grid_authority_device_id,
    jint grid_authority_device_id_count,
    jboolean ignores_size
) {
    const std::uint8_t* target_bytes = nullptr;
    const std::uint8_t* device_bytes = nullptr;
    std::size_t target_size = 0;
    std::size_t device_size = 0;
    if (!borrow_optional_buffer(env, session_target, session_target_count, &target_bytes, &target_size) ||
        !borrow_optional_buffer(
            env, grid_authority_device_id, grid_authority_device_id_count, &device_bytes, &device_size
        ) ||
        target_bytes == nullptr) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid mosh tmux session target");
        return nullptr;
    }
    using Function = std::int32_t (*)(
        const std::uint8_t*, std::size_t,
        const std::uint8_t*, std::size_t,
        std::int32_t,
        std::uint8_t*, std::size_t
    );
    const Function function = require_symbol<Function>(
        env, "tessera_tmux_mosh_visible_client_command"
    );
    if (function == nullptr) return nullptr;
    return build_shared_command(
        env,
        "shared mosh tmux client command failed",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(
                target_bytes, target_size,
                device_bytes, device_size,
                ignores_size ? 1 : 0,
                output, capacity
            );
        }
    );
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_moshTmuxViewSessionName(
    JNIEnv* env,
    jobject /* receiver */,
    jobject session_target,
    jint session_target_count
) {
    const std::uint8_t* target_bytes = nullptr;
    std::size_t target_size = 0;
    if (!borrow_optional_buffer(env, session_target, session_target_count, &target_bytes, &target_size) ||
        target_bytes == nullptr) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid tmux session target");
        return nullptr;
    }
    using Function = std::int32_t (*)(
        const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t
    );
    const Function function = require_symbol<Function>(
        env, "tessera_tmux_mosh_view_session_name"
    );
    if (function == nullptr) return nullptr;
    return build_shared_command(
        env,
        "shared mosh view session name failed",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(target_bytes, target_size, output, capacity);
        }
    );
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_moshTmuxControlChannelCommand(
    JNIEnv* env,
    jobject /* receiver */,
    jobject session_target,
    jint session_target_count,
    jboolean preserve_initial_geometry
) {
    const std::uint8_t* target_bytes = nullptr;
    std::size_t target_size = 0;
    if (!borrow_optional_buffer(env, session_target, session_target_count, &target_bytes, &target_size) ||
        target_bytes == nullptr) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid tmux session target");
        return nullptr;
    }
    using Function = std::int32_t (*)(
        const std::uint8_t*, std::size_t, std::int32_t, std::uint8_t*, std::size_t
    );
    const Function function = require_symbol<Function>(
        env, "tessera_tmux_mosh_control_channel_command"
    );
    if (function == nullptr) return nullptr;
    return build_shared_command(
        env,
        "shared mosh control-channel tmux command failed",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(
                target_bytes, target_size,
                preserve_initial_geometry ? 1 : 0,
                output, capacity
            );
        }
    );
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_controlModeTmuxSessionCommand(
    JNIEnv* env,
    jobject /* receiver */,
    jobject session_target,
    jint session_target_count,
    jboolean preserve_initial_geometry
) {
    const std::uint8_t* target_bytes = nullptr;
    std::size_t target_size = 0;
    if (!borrow_optional_buffer(env, session_target, session_target_count, &target_bytes, &target_size) ||
        target_bytes == nullptr) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid tmux session target");
        return nullptr;
    }
    using Function = std::int32_t (*)(
        const std::uint8_t*, std::size_t, std::int32_t, std::uint8_t*, std::size_t
    );
    const Function function = require_symbol<Function>(
        env, "tessera_tmux_control_mode_session_command"
    );
    if (function == nullptr) return nullptr;
    return build_shared_command(
        env,
        "shared control-mode tmux command failed",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(
                target_bytes, target_size,
                preserve_initial_geometry ? 1 : 0,
                output, capacity
            );
        }
    );
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_tmuxHydrationCommands(
    JNIEnv* env,
    jobject /* receiver */
) {
    using Function = std::int32_t (*)(std::uint8_t*, std::size_t);
    const Function function = require_symbol<Function>(env, "tessera_tmux_hydration_commands");
    if (function == nullptr) return nullptr;
    return build_shared_command(
        env,
        "shared tmux hydration commands failed",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(output, capacity);
        }
    );
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_tmuxActivePaneCommand(
    JNIEnv* env,
    jobject /* receiver */,
    jint window_id
) {
    using Function = std::int32_t (*)(std::int32_t, std::uint8_t*, std::size_t);
    const Function function = require_symbol<Function>(env, "tessera_tmux_active_pane_command");
    if (function == nullptr) return nullptr;
    return build_shared_command(
        env,
        "shared tmux active-pane command failed",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(window_id, output, capacity);
        }
    );
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_tmuxSessionWindowTarget(
    JNIEnv* env,
    jobject /* receiver */,
    jint session_id,
    jint window_id,
    jint pane_id
) {
    using Function = std::int32_t (*)(
        std::int32_t, std::int32_t, std::int32_t, std::uint8_t*, std::size_t);
    const Function function = require_symbol<Function>(
        env, "tessera_tmux_session_window_target");
    if (function == nullptr) return nullptr;
    return build_shared_command(
        env,
        "shared tmux session window target rejected the ids",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(session_id, window_id, pane_id, output, capacity);
        }
    );
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_tmuxClientSizeReplayCommands(
    JNIEnv* env,
    jobject /* receiver */,
    jint columns,
    jint rows,
    jboolean side_channel,
    jboolean belongs_to_claim
) {
    using Function = std::int32_t (*)(
        std::int32_t, std::int32_t, std::int32_t, std::int32_t, std::uint8_t*, std::size_t);
    const Function function = require_symbol<Function>(
        env, "tessera_tmux_client_size_replay_commands");
    if (function == nullptr) return nullptr;
    return build_shared_command(
        env,
        "shared tmux client-size replay rejected the grid",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(
                columns, rows, side_channel ? 1 : 0, belongs_to_claim ? 1 : 0, output, capacity);
        }
    );
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_tmuxWindowSizeReplayCommands(
    JNIEnv* env,
    jobject /* receiver */,
    jint window_id,
    jint columns,
    jint rows
) {
    using Function = std::int32_t (*)(
        std::int32_t, std::int32_t, std::int32_t, std::uint8_t*, std::size_t);
    const Function function = require_symbol<Function>(
        env, "tessera_tmux_window_size_replay_commands");
    if (function == nullptr) return nullptr;
    return build_shared_command(
        env,
        "shared tmux window-size replay rejected the target or grid",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(window_id, columns, rows, output, capacity);
        }
    );
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_tmuxWindowSizeReplayDecision(
    JNIEnv* env,
    jobject /* receiver */,
    jint requested_columns,
    jint requested_rows,
    jint observed_columns,
    jint observed_rows,
    jint last_attempt_columns,
    jint last_attempt_rows
) {
    using Function = std::int32_t (*)(
        std::int32_t, std::int32_t, std::int32_t,
        std::int32_t, std::int32_t, std::int32_t);
    const Function function = require_symbol<Function>(
        env, "tessera_tmux_window_size_replay_decision");
    if (function == nullptr) return -1;
    return function(
        requested_columns, requested_rows, observed_columns, observed_rows,
        last_attempt_columns, last_attempt_rows);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_tmuxWindowSizeReplayConfirm(
    JNIEnv* env,
    jobject /* receiver */,
    jint window_id,
    jint columns,
    jint rows,
    jobject reply,
    jint reply_count
) {
    const std::uint8_t* bytes = nullptr;
    std::size_t count = 0;
    if (reply_count < 0 || reply_count > 256 ||
        (reply_count > 0 && reply == nullptr) ||
        !borrow_optional_buffer(env, reply, reply_count, &bytes, &count)) {
        return -1;
    }
    using Function = std::int32_t (*)(
        std::int32_t, std::int32_t, std::int32_t, const std::uint8_t*, std::size_t);
    const Function function = require_symbol<Function>(
        env, "tessera_tmux_window_size_replay_confirm");
    if (function == nullptr) return -1;
    return function(window_id, columns, rows, bytes, count);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_tmuxWindowSizeReplaySizeQuery(
    JNIEnv* env,
    jobject /* receiver */,
    jint window_id
) {
    using Function = std::int32_t (*)(std::int32_t, std::uint8_t*, std::size_t);
    const Function function = require_symbol<Function>(
        env, "tessera_tmux_window_size_replay_size_query");
    if (function == nullptr) return nullptr;
    return build_shared_command(
        env,
        "shared tmux window-size query rejected the target",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(window_id, output, capacity);
        }
    );
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_tmuxWindowSizeReplayReportedGeometry(
    JNIEnv* env,
    jobject /* receiver */,
    jint window_id,
    jobject reply,
    jint reply_count
) {
    const std::uint8_t* bytes = nullptr;
    std::size_t count = 0;
    if (reply_count < 0 || reply_count > 256 ||
        (reply_count > 0 && reply == nullptr) ||
        !borrow_optional_buffer(env, reply, reply_count, &bytes, &count)) {
        return -1;
    }
    using Function = std::int64_t (*)(std::int32_t, const std::uint8_t*, std::size_t);
    const Function function = require_symbol<Function>(
        env, "tessera_tmux_window_size_replay_reported_geometry");
    if (function == nullptr) return -1;
    return function(window_id, bytes, count);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_tmuxWindowSizeReplayProvesExclusiveOwnership(
    JNIEnv* env,
    jobject /* receiver */,
    jint window_id,
    jobject control_identity,
    jint control_identity_count,
    jobject visible_identity,
    jint visible_identity_count,
    jobject inventory,
    jint inventory_count
) {
    const std::uint8_t* control_bytes = nullptr;
    const std::uint8_t* visible_bytes = nullptr;
    const std::uint8_t* inventory_bytes = nullptr;
    std::size_t control_count = 0;
    std::size_t visible_count = 0;
    std::size_t inventory_size = 0;
    if (window_id < 0 || control_identity_count < 0 || control_identity_count > 256 ||
        visible_identity_count < 0 || visible_identity_count > 256 ||
        inventory_count < 0 || inventory_count > 65536 ||
        (control_identity_count > 0 && control_identity == nullptr) ||
        (visible_identity_count > 0 && visible_identity == nullptr) ||
        (inventory_count > 0 && inventory == nullptr) ||
        !borrow_optional_buffer(env, control_identity, control_identity_count, &control_bytes, &control_count) ||
        !borrow_optional_buffer(env, visible_identity, visible_identity_count, &visible_bytes, &visible_count) ||
        !borrow_optional_buffer(env, inventory, inventory_count, &inventory_bytes, &inventory_size)) {
        return -1;
    }
    using Function = std::int32_t (*)(
        std::int32_t, const std::uint8_t*, std::size_t,
        const std::uint8_t*, std::size_t, const std::uint8_t*, std::size_t);
    const Function function = require_symbol<Function>(
        env, "tessera_tmux_window_size_replay_proves_exclusive_ownership");
    if (function == nullptr) return -1;
    return function(window_id, control_bytes, control_count, visible_bytes, visible_count,
        inventory_bytes, inventory_size);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_tmuxAuthorityCommands(
    JNIEnv* env, jobject, jobject request, jint request_count
) {
    using Function = std::int32_t (*)(const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t);
    const Function function = require_symbol<Function>(env, "tessera_tmux_authority_commands");
    if (function == nullptr) return nullptr;
    const auto* bytes = static_cast<const std::uint8_t*>(env->GetDirectBufferAddress(request));
    if (bytes == nullptr || request_count <= 0 || env->GetDirectBufferCapacity(request) < request_count) return nullptr;
    return build_shared_command(env, "shared tmux authority commands failed",
        [&](std::uint8_t* output, std::size_t capacity) { return function(bytes, request_count, output, capacity); });
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_tmuxAuthorityQueryReply(
    JNIEnv* env, jobject, jobject request, jint request_count
) {
    using Function = std::int32_t (*)(const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t);
    const Function function = require_symbol<Function>(env, "tessera_tmux_authority_query_reply");
    if (function == nullptr) return nullptr;
    const auto* bytes = static_cast<const std::uint8_t*>(env->GetDirectBufferAddress(request));
    if (bytes == nullptr || request_count <= 0 || env->GetDirectBufferCapacity(request) < request_count) return nullptr;
    return build_shared_command(env, "shared tmux authority query reply failed",
        [&](std::uint8_t* output, std::size_t capacity) { return function(bytes, request_count, output, capacity); });
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_tmuxAuthorityResolveOwner(
    JNIEnv* env, jobject, jobject request, jint request_count
) {
    using Function = std::int64_t (*)(const std::uint8_t*, std::size_t);
    const Function function = require_symbol<Function>(env, "tessera_tmux_authority_resolve_owner");
    if (function == nullptr) return -1;
    const auto* bytes = static_cast<const std::uint8_t*>(env->GetDirectBufferAddress(request));
    if (bytes == nullptr || request_count <= 0 || env->GetDirectBufferCapacity(request) < request_count) return -1;
    return function(bytes, request_count);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_tmuxAgentCommandIsReadOnly(
    JNIEnv* env, jobject, jobject command, jint command_count
) {
    using Function = std::int32_t (*)(const std::uint8_t*, std::size_t);
    const Function function = require_symbol<Function>(env, "tessera_tmux_agent_command_is_read_only");
    if (function == nullptr) return -1;
    const auto* bytes = static_cast<const std::uint8_t*>(env->GetDirectBufferAddress(command));
    if (bytes == nullptr || command_count <= 0 || env->GetDirectBufferCapacity(command) < command_count) return -1;
    return function(bytes, command_count);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_tmuxAgentCommandIsAuthorityNeutral(
    JNIEnv* env, jobject, jobject command, jint command_count
) {
    using Function = std::int32_t (*)(const std::uint8_t*, std::size_t);
    const Function function = require_symbol<Function>(env, "tessera_tmux_agent_command_is_authority_neutral");
    if (function == nullptr) return -1;
    const auto* bytes = static_cast<const std::uint8_t*>(env->GetDirectBufferAddress(command));
    if (bytes == nullptr || command_count <= 0 || env->GetDirectBufferCapacity(command) < command_count) return -1;
    return function(bytes, command_count);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_tmuxClientSizeLatestFenceCommand(
    JNIEnv* env,
    jobject /* receiver */
) {
    using Function = std::int32_t (*)(std::uint8_t*, std::size_t);
    const Function function = require_symbol<Function>(
        env, "tessera_tmux_client_size_latest_fence_command"
    );
    if (function == nullptr) return nullptr;
    return build_shared_command(
        env,
        "shared tmux latest fence command failed",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(output, capacity);
        }
    );
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_sessionAuthorityGates(
    JNIEnv* env,
    jobject /* receiver */
) {
    using Function = std::int32_t (*)(std::uint8_t*, std::size_t);
    const Function function = require_symbol<Function>(env, "tessera_session_authority_gates");
    if (function == nullptr) return nullptr;
    return build_shared_command(
        env,
        "shared session authority gates failed",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(output, capacity);
        }
    );
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_tmuxWindowCommand(
    JNIEnv* env,
    jobject /* receiver */,
    jobject request,
    jint request_count
) {
    const std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (!borrow_optional_buffer(env, request, request_count, &bytes, &size) || bytes == nullptr) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid tmux window command request");
        return nullptr;
    }
    using Function = std::int32_t (*)(
        const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t);
    const Function function = require_symbol<Function>(env, "tessera_tmux_window_command");
    if (function == nullptr) return nullptr;
    return build_shared_command(env, "shared tmux window command failed",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(bytes, size, output, capacity);
        });
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_tmuxWindowReorderPlan(
    JNIEnv* env,
    jobject /* receiver */,
    jobject request,
    jint request_count
) {
    const std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (!borrow_optional_buffer(env, request, request_count, &bytes, &size) || bytes == nullptr) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid tmux window reorder request");
        return nullptr;
    }
    using Function = std::int32_t (*)(
        const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t);
    const Function function = require_symbol<Function>(env, "tessera_tmux_window_reorder_plan");
    if (function == nullptr) return nullptr;
    return build_shared_command(env, "shared tmux window reorder plan failed",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(bytes, size, output, capacity);
        });
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_tmuxWindowCapabilities(
    JNIEnv* env,
    jobject /* receiver */,
    jobject request,
    jint request_count
) {
    const std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (!borrow_optional_buffer(env, request, request_count, &bytes, &size) || bytes == nullptr) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid tmux version request");
        return nullptr;
    }
    using Function = std::int32_t (*)(
        const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t);
    const Function function = require_symbol<Function>(env, "tessera_tmux_window_capabilities");
    if (function == nullptr) return nullptr;
    return build_shared_command(env, "shared tmux window capabilities failed",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(bytes, size, output, capacity);
        });
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_tmuxSessionGroupMembers(
    JNIEnv* env,
    jobject /* receiver */,
    jobject request,
    jint request_count
) {
    const std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (!borrow_optional_buffer(env, request, request_count, &bytes, &size) || bytes == nullptr) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid tmux session-group reply");
        return nullptr;
    }
    using Function = std::int32_t (*)(
        const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t);
    const Function function = require_symbol<Function>(env, "tessera_tmux_session_group_members");
    if (function == nullptr) return nullptr;
    return build_shared_command(env, "shared tmux session-group parse failed",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(bytes, size, output, capacity);
        });
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_tmuxSessionGroupRenumberCommands(
    JNIEnv* env,
    jobject /* receiver */,
    jobject request,
    jint request_count
) {
    const std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (!borrow_optional_buffer(env, request, request_count, &bytes, &size) || bytes == nullptr) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid tmux session-group members");
        return nullptr;
    }
    using Function = std::int32_t (*)(
        const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t);
    const Function function = require_symbol<Function>(
        env, "tessera_tmux_session_group_renumber_commands");
    if (function == nullptr) return nullptr;
    return build_shared_command(env, "shared tmux session-group renumber failed",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(bytes, size, output, capacity);
        });
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentIntegrationAbiVersion(
    JNIEnv* env, jobject /* receiver */
) {
    using Function = std::uint32_t (*)();
    const Function function = require_symbol<Function>(env, "tessera_agent_integration_abi_version");
    return function == nullptr ? 0 : static_cast<jint>(function());
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentIntegrationMaxConfigBytes(
    JNIEnv* env, jobject /* receiver */
) {
    using Function = std::size_t (*)();
    const Function function = require_symbol<Function>(env, "tessera_agent_integration_abi_max_config_bytes");
    return function == nullptr ? 0 : static_cast<jlong>(function());
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentIntegrationMaxInstallAttempts(
    JNIEnv* env, jobject /* receiver */
) {
    using Function = std::size_t (*)();
    const Function function = require_symbol<Function>(env, "tessera_agent_integration_abi_max_install_attempts");
    return function == nullptr ? 0 : static_cast<jint>(function());
}

template <typename Function>
jstring agent_integration_command(JNIEnv* env, const char* symbol, const char* message) {
    const Function function = require_symbol<Function>(env, symbol);
    if (function == nullptr) return nullptr;
    return build_shared_command(env, message, [&](std::uint8_t* output, std::size_t capacity) {
        return function(output, capacity);
    });
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentIngestionReadStatus(
    JNIEnv* env, jobject, jobject request, jint request_count
) {
    const std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (!borrow_optional_buffer(env, request, request_count, &bytes, &size) || bytes == nullptr || size > 4096) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid Agent read status"); return nullptr;
    }
    using Function = std::int32_t (*)(const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t);
    const Function function = require_symbol<Function>(env, "tessera_agent_ingestion_read_status");
    if (function == nullptr) return nullptr;
    return build_shared_command(env, "shared Agent read status failed", [&](std::uint8_t* output, std::size_t capacity) {
        return function(bytes, size, output, capacity);
    });
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentIntegrationCheckPolicy(
    JNIEnv* env, jobject /* receiver */, jint consecutive_failures
) {
    if (consecutive_failures < 0) {
        throw_java(env, "java/lang/IllegalArgumentException", "negative integration failure count");
        return nullptr;
    }
    using Function = std::int32_t (*)(std::uint32_t, std::uint8_t*, std::size_t);
    const Function function = require_symbol<Function>(env, "tessera_agent_integration_check_policy");
    if (function == nullptr) return nullptr;
    return build_shared_command(env, "shared Agent integration check policy failed",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(static_cast<std::uint32_t>(consecutive_failures), output, capacity);
        });
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentHostDeploymentCommand(
    JNIEnv* env, jobject, jobject request, jint request_count
) {
    const std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (!borrow_optional_buffer(env, request, request_count, &bytes, &size) || bytes == nullptr || size > 65536) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid Agent deployment request"); return nullptr;
    }
    using Function = std::int32_t (*)(const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t);
    const Function function = require_symbol<Function>(env, "tessera_agent_host_deployment_command");
    if (function == nullptr) return nullptr;
    return build_shared_command(env, "shared Agent deployment command failed", [&](std::uint8_t* output, std::size_t capacity) {
        return function(bytes, size, output, capacity);
    });
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentIntegrationStatusCommand(
    JNIEnv* env, jobject /* receiver */
) {
    using Function = std::int32_t (*)(std::uint8_t*, std::size_t);
    return agent_integration_command<Function>(env, "tessera_agent_integration_status_command", "shared Agent integration status command failed");
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentIntegrationCodexHooksReadCommand(
    JNIEnv* env, jobject /* receiver */
) {
    using Function = std::int32_t (*)(std::uint8_t*, std::size_t);
    return agent_integration_command<Function>(env, "tessera_agent_integration_codex_hooks_read_command", "shared Agent integration Codex read command failed");
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentIntegrationClaudeSettingsReadCommand(
    JNIEnv* env, jobject /* receiver */
) {
    using Function = std::int32_t (*)(std::uint8_t*, std::size_t);
    return agent_integration_command<Function>(env, "tessera_agent_integration_claude_settings_read_command", "shared Agent integration Claude read command failed");
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentIntegrationKimiConfigReadCommand(
    JNIEnv* env, jobject /* receiver */
) {
    using Function = std::int32_t (*)(std::uint8_t*, std::size_t);
    return agent_integration_command<Function>(env, "tessera_agent_integration_kimi_config_read_command", "shared Agent integration Kimi read command failed");
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentIntegrationShellStatusCommand(
    JNIEnv* env, jobject /* receiver */, jobject process_ids, jint process_ids_count
) {
    const std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (!borrow_optional_buffer(env, process_ids, process_ids_count, &bytes, &size) || bytes == nullptr || size > 4096) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid Agent shell process IDs");
        return nullptr;
    }
    using Function = std::int32_t (*)(const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t);
    const Function function = require_symbol<Function>(env, "tessera_agent_integration_shell_status_command");
    if (function == nullptr) return nullptr;
    return build_shared_command(env, "shared Agent current-shell status command failed", [&](std::uint8_t* output, std::size_t capacity) {
        return function(bytes, size, output, capacity);
    });
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentIntegrationProcessDiscoveryCommand(
    JNIEnv* env, jobject /* receiver */, jobject scope, jint scope_count
) {
    const std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (!borrow_optional_buffer(env, scope, scope_count, &bytes, &size) || bytes == nullptr || size > 256) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid Agent process discovery scope");
        return nullptr;
    }
    using Function = std::int32_t (*)(const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t);
    const Function function = require_symbol<Function>(env, "tessera_agent_integration_process_discovery_command");
    if (function == nullptr) return nullptr;
    return build_shared_command(env, "shared Agent process discovery command failed", [&](std::uint8_t* output, std::size_t capacity) {
        return function(bytes, size, output, capacity);
    });
}

template <typename Function>
jstring agent_integration_parse_output(
    JNIEnv* env, const char* symbol, const char* message, jobject input, jint input_count
) {
    const std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (!borrow_optional_buffer(env, input, input_count, &bytes, &size) || bytes == nullptr || size > 65536) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid Agent integration probe output");
        return nullptr;
    }
    const Function function = require_symbol<Function>(env, symbol);
    if (function == nullptr) return nullptr;
    return build_shared_command(env, message, [&](std::uint8_t* output, std::size_t capacity) {
        return function(bytes, size, output, capacity);
    });
}

template <typename Function>
jstring agent_markdown_parse_output(
    JNIEnv* env, jobject input, jint input_count
) {
    const std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (input_count < 0 ||
        !borrow_optional_buffer(env, input, input_count, &bytes, &size) ||
        size > kAgentMarkdownMaxInputBytes ||
        (input_count > 0 && bytes == nullptr)) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid Agent Markdown input");
        return nullptr;
    }
    const Function function = require_symbol<Function>(env, "tessera_agent_markdown_parse");
    if (function == nullptr) return nullptr;
    const std::int32_t required = function(bytes, size, nullptr, 0);
    if (required <= 0 || static_cast<std::size_t>(required) > kAgentMarkdownMaxOutputBytes) {
        throw_java(env, "java/lang/IllegalArgumentException", "shared Agent Markdown parse failed");
        return nullptr;
    }
    return build_shared_command(env, "shared Agent Markdown parse failed", [&](std::uint8_t* output, std::size_t capacity) {
        return function(bytes, size, output, capacity);
    });
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentIntegrationParseStatus(
    JNIEnv* env, jobject /* receiver */, jobject input, jint input_count
) {
    using Function = std::int32_t (*)(const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t);
    return agent_integration_parse_output<Function>(env, "tessera_agent_integration_parse_status", "shared Agent integration status parse failed", input, input_count);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentIntegrationClassifyInstallOutput(
    JNIEnv* env, jobject /* receiver */, jobject input, jint input_count
) {
    using Function = std::int32_t (*)(const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t);
    return agent_integration_parse_output<Function>(env, "tessera_agent_integration_classify_install_output", "shared Agent install classification failed", input, input_count);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentIntegrationParseShellStatus(
    JNIEnv* env, jobject /* receiver */, jobject input, jint input_count
) {
    using Function = std::int32_t (*)(const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t);
    return agent_integration_parse_output<Function>(env, "tessera_agent_integration_parse_shell_status", "shared Agent shell status parse failed", input, input_count);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentProjectorDiagnostics(
    JNIEnv* env, jobject /* receiver */, jobject input, jint input_count
) {
    using Function = std::int32_t (*)(const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t);
    const std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (!borrow_optional_buffer(env, input, input_count, &bytes, &size) || bytes == nullptr || size > 262144) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid projector diagnostic input");
        return nullptr;
    }
    const Function function = require_symbol<Function>(env, "tessera_agent_projector_diagnostics");
    if (function == nullptr) return nullptr;
    return build_shared_command(env, "shared projector diagnostic parse failed", [&](std::uint8_t* output, std::size_t capacity) {
        return function(bytes, size, output, capacity);
    });
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentIntegrationParseLifecycleEvent(
    JNIEnv* env, jobject /* receiver */, jobject input, jint input_count
) {
    using Function = std::int32_t (*)(const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t);
    return agent_integration_parse_output<Function>(env, "tessera_agent_integration_parse_lifecycle_event", "shared Agent lifecycle parse failed", input, input_count);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentMarkdownParse(
    JNIEnv* env, jobject /* receiver */, jobject input, jint input_count
) {
    using Function = std::int32_t (*)(const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t);
    return agent_markdown_parse_output<Function>(env, input, input_count);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentPageSearch(
    JNIEnv* env, jobject, jobject input, jint input_count
) {
    const std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (input_count <= 0 || !borrow_optional_buffer(env, input, input_count, &bytes, &size) || size > 410000 || bytes == nullptr) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid Agent page search input");
        return nullptr;
    }
    using Function = std::int32_t (*)(const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t);
    const Function function = require_symbol<Function>(env, "tessera_agent_page_search");
    if (function == nullptr) return nullptr;
    return build_shared_command(env, "shared Agent page search failed", [&](std::uint8_t* output, std::size_t capacity) {
        return function(bytes, size, output, capacity);
    });
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentComposerMatches(
    JNIEnv* env, jobject, jobject input, jint input_count
) {
    const std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (!borrow_optional_buffer(env, input, input_count, &bytes, &size) || bytes == nullptr || size > 262144) return JNI_FALSE;
    using Function = std::int32_t (*)(const std::uint8_t*, std::size_t);
    const Function function = require_symbol<Function>(env, "tessera_agent_composer_matches");
    return function != nullptr && function(bytes, size) == 1 ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentComposerAssess(
    JNIEnv* env, jobject, jobject input, jint input_count
) {
    const std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (!borrow_optional_buffer(env, input, input_count, &bytes, &size) || bytes == nullptr || size > 2 * 1024 * 1024) return -1;
    using Function = std::int32_t (*)(const std::uint8_t*, std::size_t);
    const Function function = require_symbol<Function>(env, "tessera_agent_composer_assess");
    return function != nullptr ? function(bytes, size) : -1;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentComposerInsertion(
    JNIEnv* env, jobject, jobject input, jint input_count
) {
    using Function = std::int32_t (*)(const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t);
    const std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (!borrow_optional_buffer(env, input, input_count, &bytes, &size) || bytes == nullptr || size > 262144) return nullptr;
    const Function function = require_symbol<Function>(env, "tessera_agent_composer_insertion");
    if (function == nullptr) return nullptr;
    return build_shared_command(env, "shared composer insertion failed", [&](std::uint8_t* output, std::size_t capacity) {
        return function(bytes, size, output, capacity);
    });
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentIntegrationParseConfigs(
    JNIEnv* env, jobject /* receiver */, jobject input, jint input_count
) {
    const std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (!borrow_optional_buffer(env, input, input_count, &bytes, &size) || bytes == nullptr || size > 8388608) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid Agent integration config output");
        return nullptr;
    }
    using Function = std::int32_t (*)(const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t);
    const Function function = require_symbol<Function>(env, "tessera_agent_integration_parse_configs");
    if (function == nullptr) return nullptr;
    return build_shared_command(env, "shared Agent config parse failed", [&](std::uint8_t* output, std::size_t capacity) {
        return function(bytes, size, output, capacity);
    });
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentIntegrationParseProcessDiscovery(
    JNIEnv* env, jobject /* receiver */, jobject scope, jint scope_count, jobject input, jint input_count
) {
    const std::uint8_t *scope_bytes = nullptr, *input_bytes = nullptr;
    std::size_t scope_size = 0, input_size = 0;
    if (!borrow_optional_buffer(env, scope, scope_count, &scope_bytes, &scope_size) ||
        (scope_size == 0 ? scope_bytes != nullptr : (scope_bytes == nullptr || scope_size > 256)) ||
        !borrow_optional_buffer(env, input, input_count, &input_bytes, &input_size) || input_bytes == nullptr || input_size > 65536) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid Agent process discovery response");
        return nullptr;
    }
    using Function = std::int32_t (*)(const std::uint8_t*, std::size_t, const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t);
    const Function function = require_symbol<Function>(env, "tessera_agent_integration_parse_process_discovery");
    if (function == nullptr) return nullptr;
    return build_shared_command(env, "shared Agent process discovery parse failed", [&](std::uint8_t* output, std::size_t capacity) {
        return function(scope_bytes, scope_size, input_bytes, input_size, output, capacity);
    });
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentIntegrationApplyCurrentShellCommand(
    JNIEnv* env, jobject /* receiver */
) {
    using Function = std::int32_t (*)(std::uint8_t*, std::size_t);
    return agent_integration_command<Function>(env, "tessera_agent_integration_apply_current_shell_command", "shared Agent shell apply command failed");
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentIntegrationPersistApplyCurrentShellCommand(
    JNIEnv* env, jobject /* receiver */
) {
    using Function = std::int32_t (*)(std::uint8_t*, std::size_t);
    return agent_integration_command<Function>(env, "tessera_agent_integration_persist_apply_current_shell_command", "shared Agent shell persist command failed");
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentIntegrationInstallCommand(
    JNIEnv* env, jobject /* receiver */,
    jboolean codex_present, jobject codex, jint codex_count,
    jboolean claude_present, jobject claude, jint claude_count,
    jboolean kimi_present, jobject kimi, jint kimi_count
) {
    const std::uint8_t *codex_bytes = nullptr, *claude_bytes = nullptr, *kimi_bytes = nullptr;
    std::size_t codex_size = 0, claude_size = 0, kimi_size = 0;
    if (!borrow_optional_buffer(env, codex, codex_count, &codex_bytes, &codex_size) ||
        !borrow_optional_buffer(env, claude, claude_count, &claude_bytes, &claude_size) ||
        !borrow_optional_buffer(env, kimi, kimi_count, &kimi_bytes, &kimi_size)) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid Agent integration config snapshot");
        return nullptr;
    }
    using Function = std::int32_t (*)(
        std::int32_t, const std::uint8_t*, std::size_t,
        std::int32_t, const std::uint8_t*, std::size_t,
        std::int32_t, const std::uint8_t*, std::size_t,
        std::uint8_t*, std::size_t
    );
    const Function function = require_symbol<Function>(env, "tessera_agent_integration_install_command");
    if (function == nullptr) return nullptr;
    return build_shared_command(env, "shared Agent integration install command failed", [&](std::uint8_t* output, std::size_t capacity) {
        return function(
            codex_present ? 1 : 0, codex_bytes, codex_size,
            claude_present ? 1 : 0, claude_bytes, claude_size,
            kimi_present ? 1 : 0, kimi_bytes, kimi_size,
            output, capacity
        );
    });
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentIntegrationResolve(
    JNIEnv* env, jobject /* receiver */, jobject request, jint request_count
) {
    const std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (!borrow_optional_buffer(env, request, request_count, &bytes, &size) || bytes == nullptr || size > 4096) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid Agent integration observation");
        return nullptr;
    }
    using Function = std::int32_t (*)(
        const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t
    );
    const Function function = require_symbol<Function>(env, "tessera_agent_integration_resolve");
    if (function == nullptr) return nullptr;
    return build_shared_command(env, "shared Agent integration decision failed", [&](std::uint8_t* output, std::size_t capacity) {
        return function(bytes, size, output, capacity);
    });
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_classifyAgentProviders(
    JNIEnv* env, jobject /* receiver */, jobject descriptors, jint descriptor_count
) {
    const std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (!borrow_optional_buffer(env, descriptors, descriptor_count, &bytes, &size) || bytes == nullptr) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid Agent process descriptors");
        return nullptr;
    }
    using Function = std::int32_t (*)(const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t);
    const Function function = require_symbol<Function>(env, "tessera_agent_provider_classify");
    if (function == nullptr) return nullptr;
    return build_shared_command(env, "shared Agent provider classification failed", [&](std::uint8_t* output, std::size_t capacity) {
        return function(bytes, size, output, capacity);
    });
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_tmuxClassifyLaunchFailure(
    JNIEnv* env,
    jobject /* receiver */,
    jint exit_status,
    jboolean has_exit_status,
    jobject output,
    jint output_count
) {
    const std::uint8_t* output_bytes = nullptr;
    std::size_t output_size = 0;
    if (!borrow_optional_buffer(env, output, output_count, &output_bytes, &output_size)) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid tmux launch failure arguments");
        return 0;
    }
    using Function = std::int32_t (*)(std::int32_t, std::int32_t, const std::uint8_t*, std::size_t);
    const Function function = require_symbol<Function>(
        env, "tessera_tmux_classify_launch_failure"
    );
    if (function == nullptr) return 0;
    return function(
        exit_status,
        has_exit_status == JNI_TRUE ? 1 : 0,
        output_bytes,
        output_size
    );
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_tmuxPeerLabel(
    JNIEnv* env,
    jobject /* receiver */,
    jobject peer_display_name,
    jint peer_display_name_count,
    jobject self_display_name,
    jint self_display_name_count,
    jobject known_device_names,
    jint known_device_names_count
) {
    const std::uint8_t* peer_bytes = nullptr;
    std::size_t peer_size = 0;
    const std::uint8_t* self_bytes = nullptr;
    std::size_t self_size = 0;
    const std::uint8_t* known_bytes = nullptr;
    std::size_t known_size = 0;
    if (!borrow_optional_buffer(env, peer_display_name, peer_display_name_count, &peer_bytes, &peer_size) ||
        !borrow_optional_buffer(env, self_display_name, self_display_name_count, &self_bytes, &self_size) ||
        !borrow_optional_buffer(env, known_device_names, known_device_names_count, &known_bytes, &known_size) ||
        self_bytes == nullptr) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid tmux peer label arguments");
        return nullptr;
    }
    using Function = std::int32_t (*)(
        const std::uint8_t*, std::size_t,
        const std::uint8_t*, std::size_t,
        const std::uint8_t*, std::size_t,
        std::uint8_t*, std::size_t
    );
    const Function function = require_symbol<Function>(env, "tessera_tmux_peer_label");
    if (function == nullptr) return nullptr;
    return build_shared_command(
        env,
        "shared tmux peer label failed",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(
                peer_bytes, peer_size,
                self_bytes, self_size,
                known_bytes, known_size,
                output, capacity
            );
        }
    );
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_compactTmuxCanvasProjection(
    JNIEnv* env,
    jobject /* receiver */,
    jint window_columns,
    jint window_rows,
    jint window_x,
    jint window_y,
    jint focus_columns,
    jint focus_rows,
    jint focus_x,
    jint focus_y,
    jdouble cell_width,
    jdouble cell_height,
    jdouble viewport_width,
    jdouble viewport_height,
    jdoubleArray output
) {
    if (output == nullptr || env->GetArrayLength(output) < 5) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid tmux canvas output");
        return -1;
    }
    using Function = std::int32_t (*)(
        std::int32_t, std::int32_t, std::int32_t, std::int32_t,
        std::int32_t, std::int32_t, std::int32_t, std::int32_t,
        double, double, double, double,
        double*
    );
    const Function function = require_symbol<Function>(
        env, "tessera_tmux_compact_canvas_projection"
    );
    if (function == nullptr) return -1;
    double values[5] = {};
    const std::int32_t status = function(
        window_columns, window_rows, window_x, window_y,
        focus_columns, focus_rows, focus_x, focus_y,
        cell_width, cell_height, viewport_width, viewport_height,
        values
    );
    if (status == 1) env->SetDoubleArrayRegion(output, 0, 5, values);
    return static_cast<jint>(status);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_stamplessTmuxPeerShouldRaise(
    JNIEnv* env,
    jobject /* receiver */,
    jboolean participates_in_authority,
    jboolean window_size_policy_known,
    jboolean window_size_policy_is_latest,
    jboolean rederive_in_flight,
    jboolean already_peer,
    jboolean reclaim_in_flight,
    jboolean layout_is_for_rendered_window,
    jint layout_columns,
    jint layout_rows,
    jint local_columns,
    jint local_rows,
    jdouble seconds_since_local_size_replay
) {
    using Function = std::int32_t (*)(
        std::int32_t, std::int32_t, std::int32_t, std::int32_t,
        std::int32_t, std::int32_t, std::int32_t,
        std::int32_t, std::int32_t, std::int32_t, std::int32_t,
        double
    );
    const Function function = require_symbol<Function>(
        env, "tessera_tmux_stampless_peer_should_raise"
    );
    if (function == nullptr) return -1;
    return static_cast<jint>(function(
        participates_in_authority ? 1 : 0,
        window_size_policy_known ? 1 : 0,
        window_size_policy_is_latest ? 1 : 0,
        rederive_in_flight ? 1 : 0,
        already_peer ? 1 : 0,
        reclaim_in_flight ? 1 : 0,
        layout_is_for_rendered_window ? 1 : 0,
        layout_columns, layout_rows, local_columns, local_rows,
        seconds_since_local_size_replay
    ));
}

extern "C" JNIEXPORT void JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_destroyTmuxRuntime(
    JNIEnv* env,
    jobject /* receiver */,
    jlong handle
) {
    const auto bridge = find_tmux_runtime(handle);
    if (bridge == nullptr) return;
    bool expected = false;
    if (!bridge->closing.compare_exchange_strong(expected, true)) return;
    std::unique_lock<std::recursive_mutex> call_lock(bridge->tmux_call_mutex);
    if (bridge->tmux_active_calls > 0) {
        // close() is permitted from the synchronous callback.  Destroying the
        // Swift handle here would free the runtime while its outer feed/submit
        // frame is still executing; the outer call performs cleanup instead.
        bridge->tmux_destroy_pending = true;
        return;
    }
    destroy_tmux_runtime_locked(env, bridge);
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_compactTmuxClientSize(
    JNIEnv* env,
    jobject /* receiver */,
    jint viewport_columns,
    jint viewport_rows,
    jobject layout,
    jint layout_count,
    jint focus_pane_id,
    jint window_columns,
    jint window_rows,
    jint focus_columns,
    jint focus_rows
) {
    const std::uint8_t* layout_bytes = nullptr;
    std::size_t layout_size = 0;
    // No length cap here: the core parser owns the layout limit and sizes
    // an oversized layout by ratio like any other it refuses.
    if (layout_count < 0 ||
        (layout_count > 0 && layout == nullptr) ||
        !borrow_optional_buffer(env, layout, layout_count, &layout_bytes, &layout_size)) {
        return 0;
    }
    using Function = std::uint64_t (*)(
        std::int32_t,
        std::int32_t,
        const std::uint8_t*,
        std::size_t,
        std::int32_t,
        std::int32_t,
        std::int32_t,
        std::int32_t,
        std::int32_t
    );
    const Function function = require_symbol<Function>(
        env,
        "tessera_tmux_compact_layout_client_size"
    );
    if (function == nullptr) return 0;
    return static_cast<jlong>(function(
        viewport_columns,
        viewport_rows,
        layout_bytes,
        layout_size,
        focus_pane_id,
        window_columns,
        window_rows,
        focus_columns,
        focus_rows
    ));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_compactTmuxReprojection(
    JNIEnv* env,
    jobject /* receiver */,
    jint viewport_columns,
    jint viewport_rows,
    jint last_columns,
    jint last_rows,
    jobject layout,
    jint layout_count,
    jint focus_pane_id,
    jint window_columns,
    jint window_rows,
    jint focus_columns,
    jint focus_rows,
    jlongArray memo
) {
    // The memo is two opaque words, read and replaced in place.
    if (memo == nullptr || env->GetArrayLength(memo) < 2) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid compact tmux memo");
        return -1;
    }
    const std::uint8_t* layout_bytes = nullptr;
    std::size_t layout_size = 0;
    if (layout_count < 0 ||
        (layout_count > 0 && layout == nullptr) ||
        !borrow_optional_buffer(env, layout, layout_count, &layout_bytes, &layout_size)) {
        return -1;
    }
    using Function = std::int32_t (*)(
        std::int32_t,
        std::int32_t,
        std::int32_t,
        std::int32_t,
        const std::uint8_t*,
        std::size_t,
        std::int32_t,
        std::int32_t,
        std::int32_t,
        std::int32_t,
        std::int32_t,
        std::uint64_t*
    );
    const Function function = require_symbol<Function>(
        env,
        "tessera_tmux_compact_layout_reprojection"
    );
    if (function == nullptr) return -1;
    jlong words[2] = {0, 0};
    env->GetLongArrayRegion(memo, 0, 2, words);
    std::uint64_t updated[2] = {
        static_cast<std::uint64_t>(words[0]),
        static_cast<std::uint64_t>(words[1]),
    };
    const std::int32_t decision = function(
        viewport_columns,
        viewport_rows,
        last_columns,
        last_rows,
        layout_bytes,
        layout_size,
        focus_pane_id,
        window_columns,
        window_rows,
        focus_columns,
        focus_rows,
        updated
    );
    if (decision >= 0) {
        words[0] = static_cast<jlong>(updated[0]);
        words[1] = static_cast<jlong>(updated[1]);
        env->SetLongArrayRegion(memo, 0, 2, words);
    }
    return static_cast<jint>(decision);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_defaultTmuxSessionName(
    JNIEnv* env,
    jobject /* receiver */,
    jobject host_key,
    jint count
) {
    void* address = env->GetDirectBufferAddress(host_key);
    const jlong capacity = env->GetDirectBufferCapacity(host_key);
    if (address == nullptr || count <= 0 || count > capacity) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid automatic tmux host key");
        return nullptr;
    }
    using Function = std::int32_t (*)(
        const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t
    );
    const Function function = require_symbol<Function>(
        env, "tessera_tmux_default_session_name"
    );
    if (function == nullptr) return nullptr;
    std::uint8_t output[64] = {};
    const std::int32_t output_count = function(
        static_cast<const std::uint8_t*>(address),
        static_cast<std::size_t>(count),
        output,
        sizeof(output)
    );
    if (output_count <= 0 || output_count >= static_cast<std::int32_t>(sizeof(output))) {
        throw_java(env, "java/lang/IllegalStateException", "shared automatic tmux target failed");
        return nullptr;
    }
    output[output_count] = 0;
    return env->NewStringUTF(reinterpret_cast<const char*>(output));
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_assembleTmuxRepaint(
    JNIEnv* env,
    jobject /* receiver */,
    jobject metadata,
    jint metadata_count,
    jobject capture,
    jint capture_count,
    jboolean terminal_alt,
    jint client_rows
) {
    void* metadata_address = env->GetDirectBufferAddress(metadata);
    void* capture_address = env->GetDirectBufferAddress(capture);
    const jlong metadata_capacity = env->GetDirectBufferCapacity(metadata);
    const jlong capture_capacity = env->GetDirectBufferCapacity(capture);
    if (metadata_address == nullptr || capture_address == nullptr ||
        metadata_count <= 0 || metadata_count > metadata_capacity ||
        capture_count < 0 || capture_count > capture_capacity) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid tmux repaint payload");
        return nullptr;
    }
    using Function = std::int32_t (*)(
        const std::uint8_t*, std::size_t,
        const std::uint8_t*, std::size_t,
        std::int32_t, std::int32_t,
        std::uint8_t*, std::size_t
    );
    const Function function = require_symbol<Function>(env, "tessera_tmux_assemble_repaint");
    if (function == nullptr) return nullptr;
    const auto* metadata_bytes = static_cast<const std::uint8_t*>(metadata_address);
    const auto* capture_bytes = static_cast<const std::uint8_t*>(capture_address);
    const std::int32_t required = function(
        metadata_bytes, metadata_count, capture_bytes, capture_count,
        terminal_alt ? 1 : 0, client_rows, nullptr, 0
    );
    if (required < 0) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid tmux repaint metadata");
        return nullptr;
    }
    std::unique_ptr<std::uint8_t[]> output(new std::uint8_t[required]);
    const std::int32_t written = function(
        metadata_bytes, metadata_count, capture_bytes, capture_count,
        terminal_alt ? 1 : 0, client_rows, output.get(), required
    );
    if (written != required) {
        throw_java(env, "java/lang/IllegalStateException", "shared tmux repaint assembly failed");
        return nullptr;
    }
    jbyteArray result = env->NewByteArray(written);
    if (result != nullptr && written > 0) {
        env->SetByteArrayRegion(result, 0, written, reinterpret_cast<const jbyte*>(output.get()));
    }
    return result;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_crossDeviceAbiVersion(
    JNIEnv* env,
    jobject /* receiver */
) {
    using Function = std::uint32_t (*)();
    const Function function = require_symbol<Function>(env, "tessera_cross_device_abi_version");
    return function == nullptr ? 0 : static_cast<jint>(function());
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_crossDeviceMaxPayloadBytes(
    JNIEnv* env,
    jobject /* receiver */
) {
    using Function = std::size_t (*)();
    const Function function = require_symbol<Function>(env, "tessera_cross_device_abi_max_payload_bytes");
    return function == nullptr ? 0 : static_cast<jlong>(function());
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_createCrossDeviceRuntime(
    JNIEnv* env,
    jobject /* receiver */,
    jobject event_sink
) {
    if (event_sink == nullptr) return 0;
    jclass sink_class = env->GetObjectClass(event_sink);
    if (sink_class == nullptr) return 0;
    jmethodID on_event = env->GetMethodID(sink_class, "onEvent", "(Ljava/nio/ByteBuffer;)V");
    env->DeleteLocalRef(sink_class);
    if (on_event == nullptr) return 0;
    JavaVM* vm = nullptr;
    if (env->GetJavaVM(&vm) != JNI_OK) return 0;
    jobject listener = env->NewGlobalRef(event_sink);
    if (listener == nullptr) return 0;
    const auto bridge = std::make_shared<RuntimeBridge>();
    bridge->token = next_cross_device_runtime_token.fetch_add(1);
    bridge->vm = vm;
    bridge->listener = listener;
    bridge->on_event = on_event;
    {
        std::lock_guard<std::mutex> lock(registry_mutex);
        cross_device_runtimes.emplace(bridge->token, bridge);
    }
    const CoreRuntimeCreate create = require_symbol<CoreRuntimeCreate>(
        env, "tessera_cross_device_runtime_create"
    );
    if (create != nullptr) {
        bridge->core_runtime = create(deliver_cross_device_event, bridge.get());
    }
    if (bridge->core_runtime == nullptr) {
        std::lock_guard<std::mutex> lock(registry_mutex);
        cross_device_runtimes.erase(bridge->token);
        env->DeleteGlobalRef(listener);
        return 0;
    }
    return bridge->token;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_sendCrossDeviceRuntime(
    JNIEnv* env,
    jobject /* receiver */,
    jlong handle,
    jobject payload,
    jint offset,
    jint count
) {
    const auto bridge = find_cross_device_runtime(handle);
    if (bridge == nullptr || bridge->closing.load()) return -2;
    void* address = env->GetDirectBufferAddress(payload);
    const jlong capacity = env->GetDirectBufferCapacity(payload);
    if (address == nullptr || offset < 0 || count <= 0 ||
        static_cast<jlong>(offset) + count > capacity) return -1;
    const CoreRuntimeCall send = require_symbol<CoreRuntimeCall>(
        env, "tessera_cross_device_runtime_send"
    );
    if (send == nullptr) return -1;
    const auto* bytes = static_cast<const std::uint8_t*>(address) + offset;
    return static_cast<jint>(send(bridge->core_runtime, bytes, count));
}

extern "C" JNIEXPORT void JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_destroyCrossDeviceRuntime(
    JNIEnv* env,
    jobject /* receiver */,
    jlong handle
) {
    const auto bridge = find_cross_device_runtime(handle);
    if (bridge == nullptr) return;
    bool expected = false;
    if (!bridge->closing.compare_exchange_strong(expected, true)) return;
    const CoreRuntimeDestroy destroy = require_symbol<CoreRuntimeDestroy>(
        env, "tessera_cross_device_runtime_destroy"
    );
    if (destroy != nullptr) destroy(bridge->core_runtime);
    {
        std::lock_guard<std::mutex> lock(registry_mutex);
        cross_device_runtimes.erase(handle);
    }
    if (bridge->listener != nullptr) {
        env->DeleteGlobalRef(bridge->listener);
        bridge->listener = nullptr;
    }
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentAbiVersion(
    JNIEnv* env,
    jobject /* receiver */
) {
    using Function = std::uint32_t (*)();
    const Function function = require_symbol<Function>(env, "tessera_agent_abi_version");
    return function == nullptr ? 0 : static_cast<jint>(function());
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentMaxPayloadBytes(
    JNIEnv* env,
    jobject /* receiver */
) {
    using Function = std::size_t (*)();
    const Function function = require_symbol<Function>(env, "tessera_agent_abi_max_payload_bytes");
    return function == nullptr ? 0 : static_cast<jlong>(function());
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_createAgentRuntime(
    JNIEnv* env,
    jobject /* receiver */,
    jobject event_sink
) {
    if (event_sink == nullptr) return 0;
    jclass sink_class = env->GetObjectClass(event_sink);
    if (sink_class == nullptr) return 0;
    jmethodID on_event = env->GetMethodID(sink_class, "onEvent", "(Ljava/nio/ByteBuffer;)V");
    env->DeleteLocalRef(sink_class);
    if (on_event == nullptr) return 0;
    JavaVM* vm = nullptr;
    if (env->GetJavaVM(&vm) != JNI_OK) return 0;
    jobject listener = env->NewGlobalRef(event_sink);
    if (listener == nullptr) return 0;

    const auto bridge = std::make_shared<RuntimeBridge>();
    bridge->token = next_agent_runtime_token.fetch_add(1);
    bridge->vm = vm;
    bridge->listener = listener;
    bridge->on_event = on_event;
    {
        std::lock_guard<std::mutex> lock(registry_mutex);
        agent_runtimes.emplace(bridge->token, bridge);
    }
    const CoreRuntimeCreate create = require_symbol<CoreRuntimeCreate>(
        env, "tessera_agent_runtime_create"
    );
    if (create != nullptr) {
        bridge->core_runtime = create(
            deliver_agent_event,
            reinterpret_cast<void*>(static_cast<std::uintptr_t>(bridge->token))
        );
    }
    if (bridge->core_runtime == nullptr) {
        std::lock_guard<std::mutex> lock(registry_mutex);
        agent_runtimes.erase(bridge->token);
        env->DeleteGlobalRef(listener);
        return 0;
    }
    return bridge->token;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_sendAgentRuntime(
    JNIEnv* env,
    jobject /* receiver */,
    jlong handle,
    jobject payload,
    jint offset,
    jint count
) {
    const auto bridge = find_agent_runtime(handle);
    if (bridge == nullptr || bridge->closing.load()) return -2;
    void* address = env->GetDirectBufferAddress(payload);
    const jlong capacity = env->GetDirectBufferCapacity(payload);
    if (address == nullptr || offset < 0 || count <= 0 ||
        static_cast<std::size_t>(count) > kAgentMaxPayloadBytes ||
        static_cast<jlong>(offset) + count > capacity) return -1;
    const CoreRuntimeCall send = require_symbol<CoreRuntimeCall>(
        env, "tessera_agent_runtime_send"
    );
    if (send == nullptr) return -1;
    const auto* bytes = static_cast<const std::uint8_t*>(address) + offset;
    return static_cast<jint>(send(bridge->core_runtime, bytes, count));
}

// Returns the positive response byte count, or the C ABI's -1/-2 status. The
// caller supplies direct buffers so no Java heap pointer crosses into Swift.
extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_registerAgentPlatformProof(
    JNIEnv* env,
    jobject /* receiver */,
    jlong handle,
    jobject registration,
    jint registration_offset,
    jint registration_count,
    jobject response,
    jint response_offset,
    jint response_capacity
) {
    const auto bridge = find_agent_runtime(handle);
    if (bridge == nullptr || bridge->closing.load()) return -2;
    if (registration == nullptr || response == nullptr) return -1;
    void* registration_address = env->GetDirectBufferAddress(registration);
    void* response_address = env->GetDirectBufferAddress(response);
    const jlong registration_size = env->GetDirectBufferCapacity(registration);
    const jlong response_size = env->GetDirectBufferCapacity(response);
    if (registration_address == nullptr || response_address == nullptr || registration_offset < 0 ||
        registration_count <= 0 || response_offset < 0 || response_capacity <= 0 ||
        static_cast<std::size_t>(registration_count) > 16 * 1024 ||
        static_cast<std::size_t>(response_capacity) > 16 * 1024 ||
        static_cast<jlong>(registration_offset) + registration_count > registration_size ||
        static_cast<jlong>(response_offset) + response_capacity > response_size) return -1;
    const AgentRuntimeRegister register_proof = require_symbol<AgentRuntimeRegister>(
        env, "tessera_agent_runtime_register_platform_proof"
    );
    if (register_proof == nullptr) return -1;
    std::size_t response_count = 0;
    const auto result = register_proof(
        bridge->core_runtime,
        static_cast<const std::uint8_t*>(registration_address) + registration_offset,
        static_cast<std::size_t>(registration_count),
        static_cast<std::uint8_t*>(response_address) + response_offset,
        static_cast<std::size_t>(response_capacity),
        &response_count
    );
    if (result != 0) return static_cast<jint>(result);
    if (response_count == 0 || response_count > static_cast<std::size_t>(response_capacity)) return -1;
    return static_cast<jint>(response_count);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_registerAgentPlatformBinding(
    JNIEnv* env,
    jobject /* receiver */,
    jlong handle,
    jobject registration,
    jint registration_offset,
    jint registration_count,
    jobject response,
    jint response_offset,
    jint response_capacity
) {
    const auto bridge = find_agent_runtime(handle);
    if (bridge == nullptr || bridge->closing.load()) return -2;
    if (registration == nullptr || response == nullptr) return -1;
    void* registration_address = env->GetDirectBufferAddress(registration);
    void* response_address = env->GetDirectBufferAddress(response);
    const jlong registration_size = env->GetDirectBufferCapacity(registration);
    const jlong response_size = env->GetDirectBufferCapacity(response);
    if (registration_address == nullptr || response_address == nullptr || registration_offset < 0 ||
        registration_count <= 0 || response_offset < 0 || response_capacity <= 0 ||
        static_cast<std::size_t>(registration_count) > 16 * 1024 ||
        static_cast<std::size_t>(response_capacity) > 16 * 1024 ||
        static_cast<jlong>(registration_offset) + registration_count > registration_size ||
        static_cast<jlong>(response_offset) + response_capacity > response_size) return -1;
    const AgentRuntimeRegister register_binding = require_symbol<AgentRuntimeRegister>(
        env, "tessera_agent_runtime_register_platform_binding"
    );
    if (register_binding == nullptr) return -1;
    std::size_t response_count = 0;
    const auto result = register_binding(
        bridge->core_runtime,
        static_cast<const std::uint8_t*>(registration_address) + registration_offset,
        static_cast<std::size_t>(registration_count),
        static_cast<std::uint8_t*>(response_address) + response_offset,
        static_cast<std::size_t>(response_capacity),
        &response_count
    );
    if (result != 0) return static_cast<jint>(result);
    if (response_count == 0 || response_count > static_cast<std::size_t>(response_capacity)) return -1;
    return static_cast<jint>(response_count);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_registerAgentPlatformConformances(
    JNIEnv* env,
    jobject /* receiver */,
    jlong handle,
    jobject registration,
    jint registration_offset,
    jint registration_count
) {
    const auto bridge = find_agent_runtime(handle);
    if (bridge == nullptr || bridge->closing.load()) return -2;
    if (registration == nullptr) return -1;
    void* registration_address = env->GetDirectBufferAddress(registration);
    const jlong registration_size = env->GetDirectBufferCapacity(registration);
    if (registration_address == nullptr || registration_offset < 0 || registration_count <= 0 ||
        static_cast<std::size_t>(registration_count) > 4 * 1024 ||
        static_cast<jlong>(registration_offset) + registration_count > registration_size) return -1;
    const CoreRuntimeCall register_conformances = require_symbol<CoreRuntimeCall>(
        env, "tessera_agent_runtime_register_platform_conformances"
    );
    if (register_conformances == nullptr) return -1;
    return static_cast<jint>(register_conformances(
        bridge->core_runtime,
        static_cast<const std::uint8_t*>(registration_address) + registration_offset,
        static_cast<std::size_t>(registration_count)
    ));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_registerAgentPlatformCandidate(
    JNIEnv* env, jobject /* receiver */, jlong handle, jobject registration, jint offset, jint count
) {
    const auto bridge = find_agent_runtime(handle);
    if (bridge == nullptr || bridge->closing.load()) return -2;
    if (registration == nullptr || offset < 0 || count <= 0 || count > 32 * 1024) return -1;
    void* address = env->GetDirectBufferAddress(registration);
    const jlong capacity = env->GetDirectBufferCapacity(registration);
    if (address == nullptr || static_cast<jlong>(offset) + count > capacity) return -1;
    const CoreRuntimeCall call = require_symbol<CoreRuntimeCall>(env, "tessera_agent_runtime_register_platform_candidate");
    return call == nullptr ? -1 : static_cast<jint>(call(bridge->core_runtime, static_cast<const std::uint8_t*>(address) + offset, count));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_removeAgentPlatformCandidate(
    JNIEnv* env, jobject /* receiver */, jlong handle, jobject registration, jint offset, jint count
) {
    const auto bridge = find_agent_runtime(handle);
    if (bridge == nullptr || bridge->closing.load()) return -2;
    if (registration == nullptr || offset < 0 || count <= 0 || count > 2 * 1024) return -1;
    void* address = env->GetDirectBufferAddress(registration);
    const jlong capacity = env->GetDirectBufferCapacity(registration);
    if (address == nullptr || static_cast<jlong>(offset) + count > capacity) return -1;
    const CoreRuntimeCall call = require_symbol<CoreRuntimeCall>(env, "tessera_agent_runtime_remove_platform_candidate");
    return call == nullptr ? -1 : static_cast<jint>(call(bridge->core_runtime, static_cast<const std::uint8_t*>(address) + offset, count));
}

extern "C" JNIEXPORT void JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_destroyAgentRuntime(
    JNIEnv* env,
    jobject /* receiver */,
    jlong handle
) {
    const auto bridge = find_agent_runtime(handle);
    if (bridge == nullptr) return;
    bool expected = false;
    if (!bridge->closing.compare_exchange_strong(expected, true)) return;
    const CoreRuntimeDestroy destroy = require_symbol<CoreRuntimeDestroy>(
        env, "tessera_agent_runtime_destroy"
    );
    if (destroy != nullptr) destroy(bridge->core_runtime);
    {
        std::lock_guard<std::mutex> lock(registry_mutex);
        agent_runtimes.erase(handle);
    }
    if (bridge->listener != nullptr) {
        env->DeleteGlobalRef(bridge->listener);
        bridge->listener = nullptr;
    }
}

namespace {

/*
 * ---------------------------------------------------------------------------
 * Stateless shared-policy bridges.
 *
 * Every function below is pure: no handle, no runtime, no callback. They share
 * the two-phase string/bytes contract already used by the command builders —
 * a null buffer reports the exact byte count, then a second call fills exactly
 * that many bytes — so a result whose length depends on its input is never
 * silently truncated by a fixed ceiling.
 * ---------------------------------------------------------------------------
 */

/*
 * Same contract as build_shared_command, except a ZERO-byte answer is a
 * legitimate result rather than a failure. Some of these calls have a correct
 * empty answer: encoding a pointer event while mouse reporting is off produces
 * no bytes at all, and exporting an empty pin store produces an empty file.
 * Reporting either as an error would make the caller invent a fallback.
 */
template <typename Build>
jbyteArray build_shared_bytes(JNIEnv* env, const char* what, Build build) {
    const std::int32_t required = build(nullptr, 0);
    if (required < 0) {
        throw_java(env, "java/lang/IllegalArgumentException", what);
        return nullptr;
    }
    const auto size = static_cast<std::size_t>(required);
    std::unique_ptr<std::uint8_t[]> output(new std::uint8_t[size + 1]);
    const std::int32_t written = build(output.get(), size);
    if (written != required) {
        throw_java(env, "java/lang/IllegalStateException", what);
        return nullptr;
    }
    jbyteArray result = env->NewByteArray(written);
    if (result != nullptr && written > 0) {
        env->SetByteArrayRegion(
            result, 0, written, reinterpret_cast<const jbyte*>(output.get())
        );
    }
    return result;
}

using SharedPureBytesToText = std::int32_t (*)(
    const std::uint8_t*, std::size_t, std::uint8_t*, std::size_t
);
using SharedPureTwoBuffersToText = std::int32_t (*)(
    const std::uint8_t*, std::size_t,
    const std::uint8_t*, std::size_t,
    std::uint8_t*, std::size_t
);
using SharedPureNoInputToText = std::int32_t (*)(std::uint8_t*, std::size_t);
using SharedPurePredicate = std::int32_t (*)(const std::uint8_t*, std::size_t);

/* One required direct buffer in, canonical JSON or UTF-8 text out. */
jstring shared_text_from_buffer(
    JNIEnv* env,
    const char* symbol,
    const char* what,
    jobject input,
    jint input_count
) {
    const std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (!borrow_optional_buffer(env, input, input_count, &bytes, &size) || bytes == nullptr) {
        throw_java(env, "java/lang/IllegalArgumentException", what);
        return nullptr;
    }
    const SharedPureBytesToText function = require_symbol<SharedPureBytesToText>(env, symbol);
    if (function == nullptr) return nullptr;
    return build_shared_command(env, what, [&](std::uint8_t* output, std::size_t capacity) {
        return function(bytes, size, output, capacity);
    });
}

/* Two buffers, either of which the caller may legitimately leave empty. */
jstring shared_text_from_two_buffers(
    JNIEnv* env,
    const char* symbol,
    const char* what,
    jobject first,
    jint first_count,
    jobject second,
    jint second_count
) {
    const std::uint8_t* first_bytes = nullptr;
    const std::uint8_t* second_bytes = nullptr;
    std::size_t first_size = 0;
    std::size_t second_size = 0;
    if (!borrow_optional_buffer(env, first, first_count, &first_bytes, &first_size) ||
        !borrow_optional_buffer(env, second, second_count, &second_bytes, &second_size)) {
        throw_java(env, "java/lang/IllegalArgumentException", what);
        return nullptr;
    }
    const SharedPureTwoBuffersToText function =
        require_symbol<SharedPureTwoBuffersToText>(env, symbol);
    if (function == nullptr) return nullptr;
    return build_shared_command(env, what, [&](std::uint8_t* output, std::size_t capacity) {
        return function(first_bytes, first_size, second_bytes, second_size, output, capacity);
    });
}

jstring shared_text_no_input(JNIEnv* env, const char* symbol, const char* what) {
    const SharedPureNoInputToText function = require_symbol<SharedPureNoInputToText>(env, symbol);
    if (function == nullptr) return nullptr;
    return build_shared_command(env, what, [&](std::uint8_t* output, std::size_t capacity) {
        return function(output, capacity);
    });
}

/* Returns the shared function's own integer verdict; -1 stays -1. */
jint shared_predicate(JNIEnv* env, const char* symbol, jobject input, jint input_count) {
    const std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (!borrow_optional_buffer(env, input, input_count, &bytes, &size)) return -1;
    const SharedPurePredicate function = require_symbol<SharedPurePredicate>(env, symbol);
    if (function == nullptr) return -1;
    return static_cast<jint>(function(bytes, size));
}

} // namespace

// MARK: - Terminal input

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_inputEncodeAccessoryKey(
    JNIEnv* env, jobject /* receiver */,
    jobject id, jint id_count, jint modifier_bits, jboolean application_cursor_mode
) {
    const std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (!borrow_optional_buffer(env, id, id_count, &bytes, &size) || bytes == nullptr) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid accessory key id");
        return nullptr;
    }
    using Function = std::int32_t (*)(
        const std::uint8_t*, std::size_t, std::int32_t, std::int32_t,
        std::uint8_t*, std::size_t
    );
    const Function function = require_symbol<Function>(env, "tessera_input_encode_accessory_key");
    if (function == nullptr) return nullptr;
    return build_shared_bytes(env, "shared accessory key encoding failed",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(
                bytes, size, modifier_bits, application_cursor_mode ? 1 : 0, output, capacity
            );
        });
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_inputApplySoftwareModifiers(
    JNIEnv* env, jobject /* receiver */, jobject input, jint input_count, jint modifier_bits
) {
    const std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (!borrow_optional_buffer(env, input, input_count, &bytes, &size) || bytes == nullptr) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid typed key event");
        return nullptr;
    }
    using Function = std::int32_t (*)(
        const std::uint8_t*, std::size_t, std::int32_t, std::uint8_t*, std::size_t
    );
    const Function function =
        require_symbol<Function>(env, "tessera_input_apply_software_modifiers");
    if (function == nullptr) return nullptr;
    return build_shared_bytes(env, "shared software modifier encoding failed",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(bytes, size, modifier_bits, output, capacity);
        });
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_inputEncodeMouseEvent(
    JNIEnv* env, jobject /* receiver */, jobject request, jint request_count
) {
    const std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (!borrow_optional_buffer(env, request, request_count, &bytes, &size) || bytes == nullptr) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid mouse event");
        return nullptr;
    }
    const SharedPureBytesToText function =
        require_symbol<SharedPureBytesToText>(env, "tessera_input_encode_mouse_event");
    if (function == nullptr) return nullptr;
    return build_shared_bytes(env, "shared mouse encoding failed",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(bytes, size, output, capacity);
        });
}


extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_inputScrollRoute(
    JNIEnv* env,
    jobject /* receiver */,
    jboolean buffer_is_alternate,
    jboolean mouse_reporting,
    jboolean mouse_reporting_implies_alt_screen
) {
    using Function = std::int32_t (*)(std::int32_t, std::int32_t, std::int32_t);
    const Function function = require_symbol<Function>(
        env,
        "tessera_input_scroll_route"
    );
    if (function == nullptr) return -1;
    return function(
        buffer_is_alternate ? 1 : 0,
        mouse_reporting ? 1 : 0,
        mouse_reporting_implies_alt_screen ? 1 : 0
    );
}
extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_inputAccessoryCatalog(
    JNIEnv* env, jobject /* receiver */
) {
    return shared_text_no_input(
        env, "tessera_input_accessory_catalog", "shared accessory catalog failed"
    );
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_inputAccessoryBarOrder(
    JNIEnv* env, jobject /* receiver */, jobject request, jint request_count
) {
    return shared_text_from_buffer(
        env, "tessera_input_accessory_bar_order", "shared accessory bar order failed",
        request, request_count
    );
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_inputRenderChord(
    JNIEnv* env, jobject /* receiver */, jobject request, jint request_count
) {
    return shared_text_from_buffer(
        env, "tessera_input_render_chord", "shared chord rendering failed",
        request, request_count
    );
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_inputModifierArmingTransition(
    JNIEnv* env, jobject /* receiver */, jobject request, jint request_count
) {
    return shared_text_from_buffer(
        env, "tessera_input_modifier_arming_transition", "shared modifier arming failed",
        request, request_count
    );
}

// MARK: - Session policy

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_sessionRestoreVerdict(
    JNIEnv* env, jobject /* receiver */, jobject request, jint request_count
) {
    return shared_text_from_buffer(
        env, "tessera_session_restore_verdict", "shared restore verdict failed",
        request, request_count
    );
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_sessionRestoreEvaluate(
    JNIEnv* env, jobject /* receiver */, jobject request, jint request_count
) {
    return shared_text_from_buffer(
        env, "tessera_session_restore_evaluate", "shared restore evaluation failed",
        request, request_count
    );
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_sessionRestoreWindowClosure(
    JNIEnv* env, jobject /* receiver */,
    jint remaining_cohort_count,
    jdouble elapsed_since_window_opened_seconds,
    jdouble max_window_seconds,
    jboolean has_unanswered_prompt
) {
    using Function = std::int32_t (*)(
        std::int32_t, double, double, std::int32_t, std::uint8_t*, std::size_t
    );
    const Function function =
        require_symbol<Function>(env, "tessera_session_restore_window_closure");
    if (function == nullptr) return nullptr;
    return build_shared_command(env, "shared restore window closure failed",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(
                remaining_cohort_count,
                elapsed_since_window_opened_seconds,
                max_window_seconds,
                has_unanswered_prompt ? 1 : 0,
                output, capacity
            );
        });
}

extern "C" JNIEXPORT jdouble JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_sessionRestoreChargeDelta(
    JNIEnv* env, jobject /* receiver */,
    jdouble now_seconds,
    jdouble last_charge_at_seconds,
    jboolean has_last_charge_at,
    jboolean is_prompting,
    jdouble max_tick_seconds
) {
    using Function = double (*)(double, double, std::int32_t, std::int32_t, double);
    const Function function =
        require_symbol<Function>(env, "tessera_session_restore_charge_delta");
    if (function == nullptr) return 0.0;
    return function(
        now_seconds,
        last_charge_at_seconds,
        has_last_charge_at ? 1 : 0,
        is_prompting ? 1 : 0,
        max_tick_seconds
    );
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_sessionRestorePersistMode(
    JNIEnv* env, jobject /* receiver */,
    jboolean is_active,
    jboolean has_preserved_snapshots,
    jboolean is_window_open,
    jboolean has_cohort_entries
) {
    using Function = std::int32_t (*)(
        std::int32_t, std::int32_t, std::int32_t, std::int32_t, std::uint8_t*, std::size_t
    );
    const Function function =
        require_symbol<Function>(env, "tessera_session_restore_persist_mode");
    if (function == nullptr) return nullptr;
    return build_shared_command(env, "shared restore persist mode failed",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(
                is_active ? 1 : 0,
                has_preserved_snapshots ? 1 : 0,
                is_window_open ? 1 : 0,
                has_cohort_entries ? 1 : 0,
                output, capacity
            );
        });
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_sessionRestoreDocumentRules(
    JNIEnv* env, jobject /* receiver */, jobject request, jint request_count
) {
    return shared_text_from_buffer(
        env, "tessera_session_restore_document_rules", "shared restore document rules failed",
        request, request_count
    );
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_sessionRestoreStartupAction(
    JNIEnv* env, jobject /* receiver */, jobject request, jint request_count
) {
    return shared_text_from_buffer(
        env, "tessera_session_restore_startup_action", "shared restore startup action failed",
        request, request_count
    );
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_sessionRestoreEffectivePolicy(
    JNIEnv* env, jobject /* receiver */,
    jobject stored_policy, jint stored_policy_count, jboolean uses_compact_shell
) {
    static constexpr const char* what = "shared restore effective policy failed";
    const std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (!borrow_optional_buffer(env, stored_policy, stored_policy_count, &bytes, &size) ||
        bytes == nullptr) {
        throw_java(env, "java/lang/IllegalArgumentException", what);
        return nullptr;
    }
    using Function = std::int32_t (*)(
        const std::uint8_t*, std::size_t, std::int32_t, std::uint8_t*, std::size_t
    );
    const Function function =
        require_symbol<Function>(env, "tessera_session_restore_effective_policy");
    if (function == nullptr) return nullptr;
    return build_shared_command(env, what, [&](std::uint8_t* output, std::size_t capacity) {
        return function(bytes, size, uses_compact_shell ? 1 : 0, output, capacity);
    });
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_sessionRestorePersistPlan(
    JNIEnv* env, jobject /* receiver */, jobject request, jint request_count
) {
    return shared_text_from_buffer(
        env, "tessera_session_restore_persist_plan", "shared restore persist plan failed",
        request, request_count
    );
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_sessionResizeNote(
    JNIEnv* env, jobject /* receiver */, jobject request, jint request_count
) {
    return shared_text_from_buffer(
        env, "tessera_session_resize_note", "shared resize note failed",
        request, request_count
    );
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_sessionResizeSettle(
    JNIEnv* env, jobject /* receiver */, jobject request, jint request_count
) {
    return shared_text_from_buffer(
        env, "tessera_session_resize_settle", "shared resize settle failed",
        request, request_count
    );
}

extern "C" JNIEXPORT jdouble JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_sessionResizeSettleSeconds(
    JNIEnv* env, jobject /* receiver */
) {
    using Function = double (*)();
    const Function function =
        require_symbol<Function>(env, "tessera_session_resize_settle_seconds");
    return function == nullptr ? 0.0 : function();
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_sessionRemoteProcessEnded(
    JNIEnv* env, jobject /* receiver */, jint exit_status, jboolean has_exit_status
) {
    using Function = std::int32_t (*)(std::int32_t, std::int32_t);
    const Function function =
        require_symbol<Function>(env, "tessera_session_remote_process_ended");
    if (function == nullptr) return -1;
    return static_cast<jint>(function(exit_status, has_exit_status ? 1 : 0));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_sessionRetainsRestoreRecord(
    JNIEnv* env, jobject /* receiver */, jint exit_status, jboolean has_exit_status
) {
    using Function = std::int32_t (*)(std::int32_t, std::int32_t);
    const Function function =
        require_symbol<Function>(env, "tessera_session_retains_restore_record");
    if (function == nullptr) return -1;
    return static_cast<jint>(function(exit_status, has_exit_status ? 1 : 0));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_sessionMoshRemoteProcessEnded(
    JNIEnv* env, jobject /* receiver */, jboolean is_shutdown_completion
) {
    using Function = std::int32_t (*)(std::int32_t);
    const Function function =
        require_symbol<Function>(env, "tessera_session_mosh_remote_process_ended");
    if (function == nullptr) return -1;
    return static_cast<jint>(function(is_shutdown_completion ? 1 : 0));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_sessionShouldRetry(
    JNIEnv* env, jobject /* receiver */, jobject request, jint request_count
) {
    return shared_predicate(env, "tessera_session_should_retry", request, request_count);
}

extern "C" JNIEXPORT jdouble JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_sessionRetryDelaySeconds(
    JNIEnv* env, jobject /* receiver */, jint attempt
) {
    using Function = double (*)(std::int32_t);
    const Function function =
        require_symbol<Function>(env, "tessera_session_retry_delay_seconds");
    return function == nullptr ? 0.0 : function(attempt);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_sessionRetryMaxAttempts(
    JNIEnv* env, jobject /* receiver */
) {
    using Function = std::int32_t (*)();
    const Function function =
        require_symbol<Function>(env, "tessera_session_retry_max_attempts");
    return function == nullptr ? 0 : static_cast<jint>(function());
}

// MARK: - Mosh and redaction

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_moshParseConnectResponse(
    JNIEnv* env, jobject /* receiver */,
    jobject standard_output, jint standard_output_count,
    jobject standard_error, jint standard_error_count
) {
    return shared_text_from_two_buffers(
        env, "tessera_mosh_parse_connect_response", "shared mosh connect parse failed",
        standard_output, standard_output_count, standard_error, standard_error_count
    );
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_moshServerNewCommand(
    JNIEnv* env, jobject /* receiver */, jobject launch_command, jint launch_command_count
) {
    const std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (!borrow_optional_buffer(env, launch_command, launch_command_count, &bytes, &size)) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid mosh launch command");
        return nullptr;
    }
    const SharedPureBytesToText function =
        require_symbol<SharedPureBytesToText>(env, "tessera_mosh_server_new_command");
    if (function == nullptr) return nullptr;
    return build_shared_command(env, "shared mosh server command failed",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(bytes, size, output, capacity);
        });
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_moshServerTerminationScript(
    JNIEnv* env, jobject /* receiver */, jint pid
) {
    using Function = std::int32_t (*)(std::int32_t, std::uint8_t*, std::size_t);
    const Function function =
        require_symbol<Function>(env, "tessera_mosh_server_termination_script");
    if (function == nullptr) return nullptr;
    return build_shared_command(env, "shared mosh termination script failed",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(pid, output, capacity);
        });
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_moshServerLivenessVerdict(
    JNIEnv* env, jobject /* receiver */, jobject output, jint output_count
) {
    const std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (!borrow_optional_buffer(env, output, output_count, &bytes, &size)) return -1;
    using Function = std::int32_t (*)(const std::uint8_t*, std::size_t);
    const Function function =
        require_symbol<Function>(env, "tessera_mosh_server_liveness_verdict");
    return function == nullptr ? -1 : static_cast<jint>(function(bytes, size));
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_moshServerLivenessScript(
    JNIEnv* env, jobject /* receiver */, jint pid
) {
    using Function = std::int32_t (*)(std::int32_t, std::uint8_t*, std::size_t);
    const Function function =
        require_symbol<Function>(env, "tessera_mosh_server_liveness_script");
    if (function == nullptr) return nullptr;
    return build_shared_command(env, "shared mosh liveness script failed",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(pid, output, capacity);
        });
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_moshServerLivenessGraceMilliseconds(
    JNIEnv* env, jobject /* receiver */
) {
    using Function = std::uint64_t (*)();
    const Function function =
        require_symbol<Function>(env, "tessera_mosh_server_liveness_grace_milliseconds");
    return function == nullptr ? 0 : static_cast<jlong>(function());
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_moshServerLivenessNextProbeMilliseconds(
    JNIEnv* env, jobject /* receiver */, jint outcome, jint consecutive_host_failures, jint asked_owner
) {
    using Function = std::int64_t (*)(std::int32_t, std::int32_t, std::int32_t);
    const Function function = require_symbol<Function>(
        env, "tessera_mosh_server_liveness_next_probe_milliseconds");
    return function == nullptr
        ? -1
        : static_cast<jlong>(function(outcome, consecutive_host_failures, asked_owner));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_moshTranscriptSuggestsMissingServer(
    JNIEnv* env, jobject /* receiver */,
    jobject standard_output, jint standard_output_count,
    jobject standard_error, jint standard_error_count
) {
    const std::uint8_t* out_bytes = nullptr;
    const std::uint8_t* err_bytes = nullptr;
    std::size_t out_size = 0;
    std::size_t err_size = 0;
    if (!borrow_optional_buffer(
            env, standard_output, standard_output_count, &out_bytes, &out_size
        ) ||
        !borrow_optional_buffer(
            env, standard_error, standard_error_count, &err_bytes, &err_size
        )) {
        return -1;
    }
    using Function = std::int32_t (*)(
        const std::uint8_t*, std::size_t, const std::uint8_t*, std::size_t
    );
    const Function function =
        require_symbol<Function>(env, "tessera_mosh_transcript_suggests_missing_server");
    if (function == nullptr) return -1;
    return static_cast<jint>(function(out_bytes, out_size, err_bytes, err_size));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_moshDetachedServerPid(
    JNIEnv* env, jobject /* receiver */, jobject transcript, jint transcript_count
) {
    return shared_predicate(
        env, "tessera_mosh_detached_server_pid", transcript, transcript_count
    );
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_moshNormalizedConnectKey(
    JNIEnv* env, jobject /* receiver */, jobject key, jint key_count
) {
    return shared_text_from_buffer(
        env, "tessera_mosh_normalized_connect_key", "shared mosh key normalization failed",
        key, key_count
    );
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_moshBootstrapTranscriptSummary(
    JNIEnv* env, jobject /* receiver */,
    jobject standard_output, jint standard_output_count,
    jobject standard_error, jint standard_error_count
) {
    return shared_text_from_two_buffers(
        env, "tessera_mosh_bootstrap_transcript_summary", "shared mosh transcript summary failed",
        standard_output, standard_output_count, standard_error, standard_error_count
    );
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_redactSensitive(
    JNIEnv* env, jobject /* receiver */,
    jobject text, jint text_count,
    jobject patterns, jint patterns_count
) {
    return shared_text_from_two_buffers(
        env, "tessera_redact_sensitive", "shared redaction failed",
        text, text_count, patterns, patterns_count
    );
}

// MARK: - OS detection

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_osDetectionProbeCommand(
    JNIEnv* env, jobject /* receiver */
) {
    return shared_text_no_input(
        env, "tessera_os_detection_probe_command", "shared OS detection probe failed"
    );
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_osDetectionParse(
    JNIEnv* env, jobject /* receiver */, jobject probe_output, jint probe_output_count
) {
    return shared_text_from_buffer(
        env, "tessera_os_detection_parse", "shared OS detection parse failed",
        probe_output, probe_output_count
    );
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_osDetectionParseFamily(
    JNIEnv* env, jobject /* receiver */, jobject probe_output, jint probe_output_count
) {
    const std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (!borrow_optional_buffer(env, probe_output, probe_output_count, &bytes, &size) ||
        bytes == nullptr) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid OS detection probe output");
        return nullptr;
    }
    const SharedPureBytesToText function =
        require_symbol<SharedPureBytesToText>(env, "tessera_os_detection_parse_family");
    if (function == nullptr) return nullptr;
    // "no family identified" is the ordinary outcome for a host whose banner
    // said nothing useful, so it comes back as null rather than an exception.
    if (function(bytes, size, nullptr, 0) <= 0) return nullptr;
    return build_shared_command(env, "shared OS family parse failed",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(bytes, size, output, capacity);
        });
}

// MARK: - Host-key trust

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_trustCheck(
    JNIEnv* env, jobject /* receiver */, jobject request, jint request_count
) {
    return shared_text_from_buffer(
        env, "tessera_trust_check", "shared host-key check failed", request, request_count
    );
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_trustNormalizeEndpoint(
    JNIEnv* env, jobject /* receiver */, jobject host, jint host_count, jint port
) {
    const std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (!borrow_optional_buffer(env, host, host_count, &bytes, &size) || bytes == nullptr) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid endpoint host");
        return nullptr;
    }
    using Function = std::int32_t (*)(
        const std::uint8_t*, std::size_t, std::int32_t, std::uint8_t*, std::size_t
    );
    const Function function = require_symbol<Function>(env, "tessera_trust_normalize_endpoint");
    if (function == nullptr) return nullptr;
    return build_shared_command(env, "shared endpoint normalization failed",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(bytes, size, port, output, capacity);
        });
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_trustSha256Fingerprint(
    JNIEnv* env, jobject /* receiver */, jobject blob, jint blob_count, jboolean padded
) {
    const std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (!borrow_optional_buffer(env, blob, blob_count, &bytes, &size) || bytes == nullptr) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid host key blob");
        return nullptr;
    }
    using Function = std::int32_t (*)(
        const std::uint8_t*, std::size_t, std::int32_t, std::uint8_t*, std::size_t
    );
    const Function function = require_symbol<Function>(env, "tessera_trust_sha256_fingerprint");
    if (function == nullptr) return nullptr;
    return build_shared_command(env, "shared fingerprint failed",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(bytes, size, padded ? 1 : 0, output, capacity);
        });
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_trustKnownHostsImportPlan(
    JNIEnv* env, jobject /* receiver */, jobject request, jint request_count
) {
    return shared_text_from_buffer(
        env, "tessera_trust_known_hosts_import_plan", "shared known_hosts import plan failed",
        request, request_count
    );
}

/*
 * Export returns raw UTF-8 rather than a jstring because an empty pin store
 * has a correct empty answer, and the shared string builder treats a zero
 * byte count as a failure. Kotlin decodes it.
 */
extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_trustKnownHostsExport(
    JNIEnv* env, jobject /* receiver */, jobject records, jint records_count
) {
    const std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (!borrow_optional_buffer(env, records, records_count, &bytes, &size) || bytes == nullptr) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid known_hosts records");
        return nullptr;
    }
    const SharedPureBytesToText function =
        require_symbol<SharedPureBytesToText>(env, "tessera_trust_known_hosts_export");
    if (function == nullptr) return nullptr;
    return build_shared_bytes(env, "shared known_hosts export failed",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(bytes, size, output, capacity);
        });
}

// MARK: - Port forwarding

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_forwardingValidateRule(
    JNIEnv* env, jobject /* receiver */, jobject request, jint request_count
) {
    return shared_text_from_buffer(
        env, "tessera_forwarding_validate_rule", "shared forwarding validation failed",
        request, request_count
    );
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_forwardingCapabilities(
    JNIEnv* env, jobject /* receiver */, jint transport, jboolean ssh_side_channel_available
) {
    using Function = std::int32_t (*)(
        std::int32_t, std::int32_t, std::uint8_t*, std::size_t
    );
    const Function function = require_symbol<Function>(env, "tessera_forwarding_capabilities");
    if (function == nullptr) return nullptr;
    return build_shared_command(env, "shared forwarding capabilities failed",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(
                transport, ssh_side_channel_available ? 1 : 0, output, capacity
            );
        });
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_forwardingRequiresRestart(
    JNIEnv* env, jobject /* receiver */, jobject request, jint request_count
) {
    return shared_predicate(env, "tessera_forwarding_requires_restart", request, request_count);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_forwardingPortableLocalSubset(
    JNIEnv* env, jobject /* receiver */, jobject rules, jint rules_count
) {
    return shared_text_from_buffer(
        env, "tessera_forwarding_portable_local_subset", "shared manifest rule subset failed",
        rules, rules_count
    );
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_forwardingWebTarget(
    JNIEnv* env, jobject /* receiver */, jobject rule, jint rule_count
) {
    return shared_text_from_buffer(
        env, "tessera_forwarding_web_target", "shared forwarding web target failed",
        rule, rule_count
    );
}

// MARK: - tmux and agent validation

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_tmuxSessionNameValidate(
    JNIEnv* env, jobject /* receiver */, jobject name, jint name_count
) {
    return shared_predicate(env, "tessera_tmux_session_name_validate", name, name_count);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_tmuxTargetIdValidate(
    JNIEnv* env, jobject /* receiver */, jobject value, jint value_count, jint kind
) {
    const std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (!borrow_optional_buffer(env, value, value_count, &bytes, &size)) return -1;
    using Function = std::int32_t (*)(const std::uint8_t*, std::size_t, std::int32_t);
    const Function function = require_symbol<Function>(env, "tessera_tmux_target_id_validate");
    if (function == nullptr) return -1;
    return static_cast<jint>(function(bytes, size, kind));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_tmuxInlineHistoryShouldRequest(
    JNIEnv* env,
    jobject /* receiver */,
    jboolean can_deepen,
    jboolean request_in_flight,
    jint rows_above_oldest,
    jint viewport_rows,
    jboolean crossed_oldest_row
) {
    using Function = std::int32_t (*)(
        std::int32_t, std::int32_t, std::int32_t, std::int32_t, std::int32_t
    );
    const Function function = require_symbol<Function>(
        env,
        "tessera_tmux_inline_history_should_request"
    );
    if (function == nullptr) return -1;
    return function(
        can_deepen ? 1 : 0,
        request_in_flight ? 1 : 0,
        rows_above_oldest,
        viewport_rows,
        crossed_oldest_row ? 1 : 0
    );
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentValidateBranch(
    JNIEnv* env, jobject /* receiver */, jobject branch, jint branch_count
) {
    return shared_predicate(env, "tessera_agent_validate_branch", branch, branch_count);
}

// MARK: - Pairing QR and cross-device canonicalization

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_setupFlowProject(
    JNIEnv* env, jobject /* receiver */, jobject input, jint input_count
) {
    return shared_text_from_buffer(
        env, "tessera_setup_flow_project_v1", "shared setup presentation failed",
        input, input_count
    );
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_pairingQrDecodeOffer(
    JNIEnv* env, jobject /* receiver */, jobject text, jint text_count
) {
    return shared_text_from_buffer(
        env, "tessera_pairing_qr_decode_offer", "shared pairing QR decode failed",
        text, text_count
    );
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_pairingQrEncodeOffer(
    JNIEnv* env, jobject /* receiver */, jobject offer, jint offer_count
) {
    return shared_text_from_buffer(
        env, "tessera_pairing_qr_encode_offer", "shared pairing QR encode failed",
        offer, offer_count
    );
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_crossDeviceCanonicalizeCommand(
    JNIEnv* env, jobject /* receiver */, jobject command, jint command_count
) {
    const std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (!borrow_optional_buffer(env, command, command_count, &bytes, &size) || bytes == nullptr) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid cross-device command");
        return nullptr;
    }
    const SharedPureBytesToText function =
        require_symbol<SharedPureBytesToText>(env, "tessera_cross_device_canonicalize_command");
    if (function == nullptr) return nullptr;
    return build_shared_bytes(env, "shared cross-device canonicalization failed",
        [&](std::uint8_t* output, std::size_t capacity) {
            return function(bytes, size, output, capacity);
        });
}

// MARK: - Continuation route identity

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_continuationRouteIdentity(
    JNIEnv* env, jobject /* receiver */, jobject request, jint request_count
) {
    return shared_text_from_buffer(
        env, "tessera_continuation_route_identity", "shared route identity failed",
        request, request_count
    );
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_continuationDescriptorRouteIdentity(
    JNIEnv* env, jobject /* receiver */, jobject descriptor, jint descriptor_count
) {
    return shared_text_from_buffer(
        env, "tessera_continuation_descriptor_route_identity",
        "shared descriptor route identity failed",
        descriptor, descriptor_count
    );
}

extern "C" JNIEXPORT jint JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentInitialLoadPageCount(JNIEnv* env, jobject) {
    using Function = std::int32_t (*)();
    const Function function = require_symbol<Function>(env, "tessera_agent_initial_load_page_count");
    return function != nullptr ? function() : 0;
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentProcessProofTimeoutMilliseconds(JNIEnv* env, jobject) {
    using Function = std::uint64_t (*)();
    const Function function = require_symbol<Function>(env, "tessera_agent_process_proof_timeout_milliseconds");
    return function != nullptr ? static_cast<jlong>(function()) : 0;
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentReadRetryDelayMilliseconds(JNIEnv* env, jobject, jint failures) {
    using Function = std::uint64_t (*)(std::int32_t);
    const Function function = require_symbol<Function>(env, "tessera_agent_read_retry_delay_milliseconds");
    return function != nullptr ? static_cast<jlong>(function(failures)) : 0;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_bambouville_tessera_core_bridge_NativeCoreBindings_agentInitialLoadShouldPrefetch(
    JNIEnv* env, jobject, jint completed_pages, jint flags
) {
    using Function = std::int32_t (*)(std::int32_t, std::uint32_t);
    const Function function = require_symbol<Function>(env, "tessera_agent_initial_load_should_prefetch");
    return function != nullptr && function(completed_pages, static_cast<std::uint32_t>(flags)) == 1 ? JNI_TRUE : JNI_FALSE;
}
