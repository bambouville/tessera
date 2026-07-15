#ifndef MOSH_BRIDGE_H
#define MOSH_BRIDGE_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^MoshBridgeOutputHandler)(NSData *data);

/// Minimal spike probe: calls into MoshCore's C++ `mosh_core_probe` through
/// ObjC++ and returns the result. Presence of this symbol + a successful call
/// proves the Swift → ObjC++ → C++ toolchain chain is intact.
@interface MoshBridgeProbe : NSObject
+ (NSInteger)probe;
/// Spike 2 probe: AES-OCB encrypt/decrypt roundtrip via upstream mosh's
/// Crypto::Session, backed by Apple CommonCrypto.
+ (NSInteger)cryptoProbe;
/// Spike 2 primitive probe: raw AES-128 ECB via CommonCrypto (no OCB).
/// Isolates whether the primitive works before blaming OCB.
+ (NSInteger)primitiveProbe;
@end

@interface MoshBridgeClient : NSObject

- (nullable instancetype)initWithHost:(NSString *)host
                                 port:(NSInteger)port
                            base64Key:(NSString *)base64Key
                                error:(NSError * _Nullable * _Nullable)error NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@property (nonatomic, copy, nullable) MoshBridgeOutputHandler outputHandler;
@property (nonatomic, readonly) int socketFD;
@property (nonatomic, readonly) NSArray<NSNumber *> *socketFDs;
@property (nonatomic, readonly, getter=isConnected) BOOL connected;
@property (nonatomic, readonly, getter=isTransportReachable) BOOL transportReachable;
@property (nonatomic, readonly, getter=isShutdownComplete) BOOL shutdownComplete;
@property (nonatomic, readonly) BOOL applicationModeCursorKeys;
/// Testable lifetime invariant: false immediately after `start` initializes
/// the binary crypto session, and after teardown.
@property (nonatomic, readonly) BOOL retainsBootstrapKeyMaterial;

- (BOOL)start:(NSError * _Nullable * _Nullable)error;
- (NSUInteger)tick:(NSError * _Nullable * _Nullable)error;
- (BOOL)injectBytes:(NSData *)data error:(NSError * _Nullable * _Nullable)error;
- (BOOL)resizeWithColumns:(NSInteger)columns
                     rows:(NSInteger)rows
                    error:(NSError * _Nullable * _Nullable)error;
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END

#endif
