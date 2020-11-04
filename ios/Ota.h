@import Foundation;
#import <React/RCTEventEmitter.h>

typedef void(^VoidBlock)(void);
typedef void(^BoolBlock)(BOOL success);
typedef void(^ErrorBlock)(NSError *error);

@interface Ota : RCTEventEmitter <RCTBridgeModule>

+ (void)setAppId:(NSString *)appId passphrase:(NSString *)passphrase provider:(NSString *)provider;

+ (NSURL *)sourceURLForBridge;

@end

