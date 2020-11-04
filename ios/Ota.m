
#import "Ota.h"
#import "Unzip.h"

#import <React/RCTReloadCommand.h>

#pragma mark - Common Defines
#define CC_SHA256_DIGEST_LENGTH         32          /* digest length in bytes */

#define KEY_BUNDLE_DOWNLOAD_URL         @"react-native-server-host"

#define KEY_APP_VERSION                 @"app-version"
#define KEY_HASH                        @"hash"
#define KEY_LAST_BUNDLE                 @"last-bundle"

#define PATH_BUNDLE                     @"bundle"
#define PATH_BUNDLE_UNZIP_EXCEPTION     @"bundle/"
#define PATH_BUNDLE_DEFAULT             @"main.bundle"
#define JS_CODE                         @"main.jsbundle"

#pragma mark - MD5 Categories
#import <CommonCrypto/CommonDigest.h>

@interface NSData (md5)
- (NSString *) md5;
@end

@implementation NSData (md5)

-(NSString*)md5{
  const char *cStr = [self bytes];
  unsigned char digest[CC_MD5_DIGEST_LENGTH];
  CC_MD5( cStr, (CC_LONG)self.length, digest );
  
  NSMutableString *ret = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH*2];
  for (int i = 0; i<CC_MD5_DIGEST_LENGTH; i++) {
    [ret appendFormat:@"%02x",digest[i]];
  }
  return ret;
}

@end

@interface NSString (md5)

- (NSString *)md5;

@end

@implementation NSString (md5)
- (NSString *)md5
{
  const char * cStr = [self UTF8String];
  unsigned char digest[CC_MD5_DIGEST_LENGTH];
  
  CC_MD5(cStr, (CC_LONG)strlen(cStr), digest);
  
  NSMutableString *ret = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
  for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++)
  [ret appendFormat:@"%02x",digest[i]];
  
  return ret;
}

@end

typedef BOOL(^UnarchiverCallback)(NSString *fileName);

@interface Unarchiver : NSObject <UnzipDelegate>
@property (atomic, strong) UnarchiverCallback callback;
+ (instancetype)unarchiverWithCallback:(UnarchiverCallback)callback;
@end

@implementation Unarchiver

+ (instancetype)unarchiverWithCallback:(UnarchiverCallback)callback {
  if( !callback ) return nil;
  Unarchiver *instance = [[self alloc] init];
  instance.callback = callback;
  return instance;
}

- (BOOL)shouldUnzipFile:(NSString *)archivePath fileName:(NSString *)fileName{
  return self.callback( fileName );
}

@end

#pragma mark - Ota

@interface Ota ()<RCTReloadListener>

@property (nonatomic, strong) NSString *bundleHash;
@property (nonatomic, assign) NSUInteger bundleSize;

@end

static NSString *_passphrase = nil;
static NSString *_appId = nil;
static NSString *_provider = nil;

@implementation Ota

+ (void)setAppId:(NSString *)appId passphrase:(NSString *)passphrase provider:(NSString *)provider
{
  _appId = appId;
  _passphrase = passphrase;
  _provider = provider;
}

+ (NSString *)appId{
  return _appId;
}
+ (NSString *)passphrase{
  return _passphrase;
}
+ (NSString *)provider{
  return _provider;
}

+ (NSString *)appVersion {
  return [NSString stringWithFormat:@"%@.%@",
    [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
    [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"]
  ];
}

+ (NSString *)pathForDefaultBundle {
  return [[NSBundle mainBundle] pathForResource:PATH_BUNDLE_DEFAULT ofType:nil];
}

+ (NSString *)path {
  return [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject] ;
}

+ (NSString *)pathForUnarchived {
  return [self.path stringByAppendingPathComponent:PATH_BUNDLE];
}

+ (NSString *)pathForHash:(NSString *)hash {
  return [self.path stringByAppendingPathComponent:hash];
}

+ (NSString *)pathForLocalJSCodeLocation {
  return [[self.path stringByAppendingPathComponent:PATH_BUNDLE] stringByAppendingPathComponent:JS_CODE];
}

+ (void)setHash:(NSString *)hash {
  [NSUserDefaults.standardUserDefaults setObject:@{
    KEY_APP_VERSION: self.appVersion,
    KEY_HASH : hash
  } forKey:KEY_LAST_BUNDLE];
  [NSUserDefaults.standardUserDefaults synchronize];
}

+ (NSString *)lastHash {
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  NSDictionary* last = [defaults objectForKey:KEY_LAST_BUNDLE];
  
  id hash = nil;
  id appversion = nil;
  
  // for past versions saved version info with dictionary issue.
  if( last ) {
    hash       = last[KEY_HASH];
    appversion = last[KEY_APP_VERSION];
  }
  
  NSLog(@"lastBundleInfo : %@:%@", hash, appversion);
  if( hash && appversion )
    return [self.appVersion isEqualToString:appversion] && [self isHashAvailable:hash] ? hash : nil;
  else
    return nil;
}

+ (BOOL)isHashAvailable:(NSString *)hash {
  NSFileManager * fm = NSFileManager.defaultManager;
  if( ![fm fileExistsAtPath:[self pathForHash:hash]] || ![fm fileExistsAtPath:self.pathForUnarchived] ) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:KEY_LAST_BUNDLE];
    [NSUserDefaults.standardUserDefaults synchronize];
    return NO;
  }
  
  return YES;
}

+ (NSString *)md5:(NSString *)path {
  return [NSFileManager.defaultManager fileExistsAtPath:path] ? [[NSData dataWithContentsOfFile:path] md5] : nil;
}

+ (BOOL)unarchive:(NSString *)path
      destination:(NSString *)destination
        overWrite:(UnarchiverCallback)overWriteCallback
        didFinish:(ErrorBlock)didFinish {
  NSTimeInterval s = NSDate.date.timeIntervalSinceReferenceDate;
  NSLog(@"start unarchive to %@", self.path);
  NSError *error = nil;
  BOOL success = [Unzip unzipFileAtPath:path
                          toDestination:destination
                     preserveAttributes:YES
                              overwrite:YES
                               password:self.passphrase
                                  error:&error
                               delegate:[Unarchiver unarchiverWithCallback:overWriteCallback]
                        progressHandler:^(NSString *entry, unz_file_info zipInfo, long entryNumber, long total) { }
                      completionHandler:^(NSString *path, BOOL succeeded, NSError *error) {
    NSLog(@"finish unarchive : %.2f s", NSDate.date.timeIntervalSinceReferenceDate - s );
    didFinish( error );
  }];
  
  if( error ) {
    NSLog(@"Ota :: error with unarchive 1 : %@", error);
    didFinish(error);
  }
  return success;
}

+ (BOOL)unarchive:(NSString *)path didFinish:(ErrorBlock)didFinish {
  return [self unarchive:path destination:self.path overWrite:nil didFinish:didFinish];
}

+ (void)prepareLaunch {
  NSString *lastHash = self.lastHash;
  NSFileManager *fm = NSFileManager.defaultManager;
  
  if( self.lastHash && [fm fileExistsAtPath:self.pathForUnarchived] ) {
    NSString *path = [self pathForHash:lastHash];
    [self.class unarchive:path destination:self.path overWrite:^BOOL(NSString *fileName) {
      return [fileName rangeOfString:JS_CODE].location != NSNotFound;
    } didFinish:^(NSError *error){
    }];
  }
  else {
    id last = [NSUserDefaults.standardUserDefaults objectForKey:KEY_LAST_BUNDLE];
    NSString *oldHash = nil;
    if( last )
      oldHash = last[KEY_HASH];
    
    if( oldHash && [fm fileExistsAtPath:[self pathForHash:oldHash]])
      [fm removeItemAtPath:[self pathForHash:oldHash] error:nil];
    
    NSString* defaultBundleHash = [self md5:self.pathForDefaultBundle];
    NSString* copiedBundlePath  = [self pathForHash:defaultBundleHash];
    NSError* error = nil;
    [fm copyItemAtPath:self.pathForDefaultBundle toPath:copiedBundlePath error:&error];
    
    [self unarchive:copiedBundlePath
        destination:self.path
          overWrite:nil
          didFinish:^(NSError *error) {
      self.hash = [self md5:self.pathForDefaultBundle];
    }];
  }
}

+ (NSURL *)sourceURLForBridge {
  [self prepareLaunch];
  return [NSURL fileURLWithPath:self.pathForLocalJSCodeLocation];
}

#pragma mark - Module Method

+ (BOOL)requiresMainQueueSetup {
  return YES;
}

RCT_EXPORT_MODULE();

- (NSArray<NSString *> *)supportedEvents {
  return @[];
}

- (NSDictionary *)constantsToExport {
  NSString * hash = self.class.lastHash;
  NSDictionary *constrains = @{
    @"appId"      : _appId,
    @"provider"   : _provider,
    @"passphrase" : _passphrase,
    @"hash"       : hash ? hash : [NSNull null],
    @"path"       : self.class.path
  };
  return constrains;
}

RCT_EXPORT_METHOD(reloadApp) {
  NSLog(@"Ota :: reloadApp");
  dispatch_async(dispatch_get_main_queue(), ^{
    [super.bridge reload];
  });
}

RCT_EXPORT_METHOD(getLastHash:(RCTResponseSenderBlock)callback) {
  callback(@[self.class.lastHash ? self.class.lastHash : NSNull.null ]);
}

RCT_EXPORT_METHOD(setLastHash:(NSString *)hash finishCallback:(RCTResponseSenderBlock)callback) {
  self.class.hash = hash;
  callback(@[]);
}

RCT_EXPORT_METHOD(setSavedBundleDownloadURL:(NSString *)url) {
  [NSUserDefaults.standardUserDefaults setObject:url forKey:KEY_BUNDLE_DOWNLOAD_URL];
  [NSUserDefaults.standardUserDefaults synchronize];
}

RCT_EXPORT_METHOD(unzip:(NSString *)target destination:(NSString *)destination overWrite:(BOOL)overWrite resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
  [self.class unarchive:target destination:destination overWrite:^BOOL(NSString* file){
    return overWrite ? YES : [file rangeOfString:JS_CODE].location != NSNotFound;
  } didFinish:^(NSError *error) {
    if( !error ) resolve(@(YES));
    else reject(@"zip_error", @"unable to zip", error);
  }];
}

RCT_EXPORT_METHOD(md5:(NSString *)path callback:(RCTResponseSenderBlock)callback) {
  NSString* hash = [self.class md5:path];
  NSLog(@"Ota::hash : %@", hash );
  callback(@[hash ? hash : NSNull.null]);
}

- (void)didReceiveReloadCommand{
  
}


@end


