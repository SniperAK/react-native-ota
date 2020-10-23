#ifndef _UNZIP_H
#define _UNZIP_H

#include <SSZipArchive/SSZipCommon.h>

@import Foundation;

NS_ASSUME_NONNULL_BEGIN

@protocol UnzipDelegate;

@interface Unzip : NSObject

+ (BOOL)unzipFileAtPath:(NSString *)path
          toDestination:(NSString *)destination
     preserveAttributes:(BOOL)preserveAttributes
              overwrite:(BOOL)overwrite
               password:(nullable NSString *)password
                  error:(NSError **)error
               delegate:(nullable id<UnzipDelegate>)delegate
        progressHandler:(nullable void (^)(NSString *entry, unz_file_info zipInfo, long entryNumber, long total))progressHandler
      completionHandler:(nullable void (^)(NSString *path, BOOL succeeded, NSError *error))completionHandler;

@end

@protocol UnzipDelegate <NSObject>

@optional

- (BOOL)shouldUnzipFile:(NSString *)archivePath fileName:(NSString *)fileName;

@end

NS_ASSUME_NONNULL_END

#endif /* _SSZIPARCHIVEEXTENDED_H */
