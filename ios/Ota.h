@import Foundation;
#import <React/RCTEventEmitter.h>

typedef void(^VoidBlock)(void);
typedef void(^BoolBlock)(BOOL success);
typedef void(^ErrorBlock)(NSError *error);

@interface Ota : RCTEventEmitter <RCTBridgeModule>

+ (NSURL *)bundleURL;

+ (void)setPassphrase:(NSString *)passphrase;
+ (void)setAppId:(NSString *)appId;
+ (void)setBundleServer:(NSString *)bundleServer;
+ (void)setDevPackageServer:(NSString *)devPackageServer;

+ (NSString *)lastHash;


@end

