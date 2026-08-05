#import "include/MoshBridge.h"

#include <chrono>
#include <exception>
#include <limits>
#include <memory>
#include <string>

#import "MoshClient.h"
#import "MoshCoreProbe.h"

static NSString *const MoshBridgeErrorDomain = @"com.bambouville.Tessera.MoshBridge";

typedef NS_ENUM(NSInteger, MoshBridgeErrorCode) {
    MoshBridgeErrorCodeUnknown = 1,
};

static NSError *MoshBridgeUnknownError(void) {
    return [NSError errorWithDomain:MoshBridgeErrorDomain
                               code:MoshBridgeErrorCodeUnknown
                           userInfo:@{
                               NSLocalizedDescriptionKey: @"Unknown mosh bridge failure."
                           }];
}

static NSError *MoshBridgeErrorFromException(const std::exception &error) {
    NSString *message = [NSString stringWithUTF8String:error.what()];
    if (message == nil || message.length == 0) {
        message = @"Unknown mosh bridge failure.";
    }
    return [NSError errorWithDomain:MoshBridgeErrorDomain
                               code:MoshBridgeErrorCodeUnknown
                           userInfo:@{
                               NSLocalizedDescriptionKey: message
                           }];
}

static void MoshBridgeSecureClearString(std::string &value) {
    volatile char *bytes = value.empty() ? nullptr : value.data();
    for (size_t index = 0; index < value.size(); ++index) {
        bytes[index] = 0;
    }
    value.clear();
    value.shrink_to_fit();
}

class MoshBridgeSensitiveStringScopeClear {
public:
    explicit MoshBridgeSensitiveStringScopeClear(std::string &value)
        : value_(value) {}
    ~MoshBridgeSensitiveStringScopeClear() {
        MoshBridgeSecureClearString(value_);
    }

private:
    std::string &value_;
};

template <typename Fn>
static BOOL MoshBridgePerformBool(NSError **error, Fn &&fn) {
    try {
        fn();
        return YES;
    } catch (const std::exception &exception) {
        if (error != nullptr) {
            *error = MoshBridgeErrorFromException(exception);
        }
        return NO;
    } catch (...) {
        if (error != nullptr) {
            *error = MoshBridgeUnknownError();
        }
        return NO;
    }
}

template <typename Fn>
static NSUInteger MoshBridgePerformTick(NSError **error, Fn &&fn) {
    try {
        const std::chrono::milliseconds wait = fn();
        if (wait == std::chrono::milliseconds::max()) {
            return NSUIntegerMax;
        }

        const long long count = wait.count();
        if (count <= 0) {
            return 0;
        }

        const auto max_count = static_cast<unsigned long long>(NSUIntegerMax);
        const auto clamped = static_cast<unsigned long long>(count);
        return static_cast<NSUInteger>(std::min(clamped, max_count));
    } catch (const std::exception &exception) {
        if (error != nullptr) {
            *error = MoshBridgeErrorFromException(exception);
        }
        return 0;
    } catch (...) {
        if (error != nullptr) {
            *error = MoshBridgeUnknownError();
        }
        return 0;
    }
}

@interface MoshBridgeClient () {
@private
    std::unique_ptr<MoshClient> _client;
}
@end

@implementation MoshBridgeProbe

+ (NSInteger)probe {
    return (NSInteger)mosh_core_probe();
}

+ (NSInteger)cryptoProbe {
    return (NSInteger)mosh_crypto_probe();
}

+ (NSInteger)primitiveProbe {
    return (NSInteger)mosh_ccrypto_primitive_probe();
}

@end

@implementation MoshBridgeClient

- (nullable instancetype)initWithHost:(NSString *)host
                                 port:(NSInteger)port
                            base64Key:(NSString *)base64Key
                                error:(NSError * _Nullable * _Nullable)error {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    try {
        // Keep exactly one explicit bridge-side native copy and wipe it on
        // both success and every exception path. MoshClient takes this by
        // const reference so 22-byte libc++ small-string storage is never
        // moved through uncleared by-value constructor parameters.
        std::string bootstrapKey(base64Key.UTF8String ?: "");
        MoshBridgeSensitiveStringScopeClear clearBootstrapKey(bootstrapKey);
        _client = std::make_unique<MoshClient>(
            std::string(host.UTF8String ?: ""),
            static_cast<int>(port),
            bootstrapKey);

        __weak MoshBridgeClient *weakSelf = self;
        _client->set_output_callback([weakSelf](const uint8_t *bytes, size_t length) {
            MoshBridgeClient *strongSelf = weakSelf;
            if (strongSelf == nil || length == 0) {
                return;
            }

            MoshBridgeOutputHandler handler = strongSelf.outputHandler;
            if (handler == nil) {
                return;
            }

            NSData *data = [NSData dataWithBytes:bytes length:length];
            handler(data);
        });
    } catch (const std::exception &exception) {
        if (error != nullptr) {
            *error = MoshBridgeErrorFromException(exception);
        }
        return nil;
    } catch (...) {
        if (error != nullptr) {
            *error = MoshBridgeUnknownError();
        }
        return nil;
    }

    return self;
}

- (BOOL)start:(NSError * _Nullable * _Nullable)error {
    return MoshBridgePerformBool(error, [&] {
        _client->start();
    });
}

- (NSUInteger)tick:(NSError * _Nullable * _Nullable)error {
    return MoshBridgePerformTick(error, [&] {
        return _client->tick();
    });
}

- (BOOL)injectBytes:(NSData *)data error:(NSError * _Nullable * _Nullable)error {
    return MoshBridgePerformBool(error, [&] {
        _client->inject_user_bytes(
            static_cast<const uint8_t *>(data.bytes),
            static_cast<size_t>(data.length));
    });
}

- (BOOL)resizeWithColumns:(NSInteger)columns
                     rows:(NSInteger)rows
                    error:(NSError * _Nullable * _Nullable)error {
    return MoshBridgePerformBool(error, [&] {
        _client->resize(static_cast<int>(columns), static_cast<int>(rows));
    });
}

- (BOOL)forceFullRepaint:(NSError * _Nullable * _Nullable)error {
    return MoshBridgePerformBool(error, [&] {
        _client->force_full_repaint();
    });
}

- (void)shutdown {
    if (_client == nullptr) {
        return;
    }

    try {
        _client->shutdown();
    } catch (...) {
        // Never let C++ failures escape into Swift during teardown.
    }
    // Deterministically run MoshClient/Network/Crypto destructors now instead
    // of waiting for ARC to reclaim this Objective-C wrapper.
    _client.reset();
}

- (int)socketFD {
    if (_client == nullptr) {
        return -1;
    }

    return _client->socket_fd();
}

- (NSArray<NSNumber *> *)socketFDs {
    if (_client == nullptr) {
        return @[];
    }

    const std::vector<int> fds = _client->socket_fds();
    NSMutableArray<NSNumber *> *result =
        [NSMutableArray arrayWithCapacity:fds.size()];
    for (const int fd : fds) {
        [result addObject:@(fd)];
    }
    return result;
}

- (BOOL)isConnected {
    return _client != nullptr && _client->connected();
}

- (BOOL)isTransportReachable {
    return _client != nullptr && _client->transport_reachable();
}

- (BOOL)isShutdownComplete {
    return _client != nullptr && _client->shutdown_complete();
}

- (BOOL)applicationModeCursorKeys {
    return _client != nullptr && _client->application_mode_cursor_keys();
}

- (BOOL)retainsBootstrapKeyMaterial {
    return _client != nullptr && _client->retains_bootstrap_key_material();
}

@end
