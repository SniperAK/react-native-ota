//
//  SSZipArchive.m
//  SSZipArchive
//
//  Created by Sam Soffes on 7/21/10.
//  Copyright (c) Sam Soffes 2010-2015. All rights reserved.
//
#import "Unzip.h"
#include "ota_compat.h"
#include <SSZipArchive/mz_zip.h>
#include <zlib.h>
#include <sys/stat.h>
#include <SSZipArchive/SSZipArchive.h>

#define CHUNK 16384

@interface NSData(Unzip)
- (NSString *)_base64RFC4648 API_AVAILABLE(macos(10.9), ios(7.0), watchos(2.0), tvos(9.0));
- (NSString *)_hexString;
@end

@implementation NSData (Unzip)
- (NSString *)_base64RFC4648
{
  NSString *strName = [self base64EncodedStringWithOptions:0];
  strName = [strName stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
  strName = [strName stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
  return strName;
}

- (NSString *)_hexString
{
  const char *hexChars = "0123456789ABCDEF";
  NSUInteger length = self.length;
  const unsigned char *bytes = self.bytes;
  char *chars = malloc(length * 2);
  if (chars == NULL) {
    // we directly raise an exception instead of using NSAssert to make sure assertion is not disabled as this is irrecoverable
    [NSException raise:@"NSInternalInconsistencyException" format:@"failed malloc" arguments:nil];
    return nil;
  }
  char *s = chars;
  NSUInteger i = length;
  while (i--) {
    *s++ = hexChars[*bytes >> 4];
    *s++ = hexChars[*bytes & 0xF];
    bytes++;
  }
  NSString *str = [[NSString alloc] initWithBytesNoCopy:chars
                                                 length:length * 2
                                               encoding:NSASCIIStringEncoding
                                           freeWhenDone:YES];
  return str;
}

@end

@interface Unzip ()
+ (NSDate *)_dateWithMSDOSFormat:(UInt32)msdosDateTime;
@end

@implementation Unzip
{
  NSString *_path;
  NSString *_filename;
  zipFile _zip;
}


+ (BOOL)_fileIsSymbolicLink:(unz_file_info*) fileInfo
{
  //
  // Determine whether this is a symbolic link:
  // - File is stored with 'version made by' value of UNIX (3),
  //   as per https://www.pkware.com/documents/casestudies/APPNOTE.TXT
  //   in the upper byte of the version field.
  // - BSD4.4 st_mode constants are stored in the high 16 bits of the
  //   external file attributes (defacto standard, verified against libarchive)
  //
  // The original constants can be found here:
  //    https://minnie.tuhs.org/cgi-bin/utree.pl?file=4.4BSD/usr/include/sys/stat.h
  //
  const uLong ZipUNIXVersion = 3;
  const uLong BSD_SFMT = 0170000;
  const uLong BSD_IFLNK = 0120000;
  
  BOOL fileIsSymbolicLink = ((fileInfo->version >> 8) == ZipUNIXVersion) && BSD_IFLNK == (BSD_SFMT & (fileInfo->external_fa >> 16));
  return fileIsSymbolicLink;
}

#pragma mark - Password check

+ (NSCalendar *)_gregorian
{
  static NSCalendar *gregorian;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    gregorian = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
  });
  
  return gregorian;
}

+ (NSString *)_filenameStringWithCString:(const char *)filename
                         version_made_by:(uint16_t)version_made_by
                    general_purpose_flag:(uint16_t)flag
                                    size:(uint16_t)size_filename {
  
  // Respect Language encoding flag only reading filename as UTF-8 when this is set
  // when file entry created on dos system.
  //
  // https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT
  //   Bit 11: Language encoding flag (EFS).  If this bit is set,
  //           the filename and comment fields for this file
  //           MUST be encoded using UTF-8. (see APPENDIX D)
  uint16_t made_by = version_made_by >> 8;
  BOOL made_on_dos = made_by == 0;
  BOOL languageEncoding = (flag & (1 << 11)) != 0;
  if (!languageEncoding && made_on_dos) {
    // APPNOTE.TXT D.1:
    //   D.2 If general purpose bit 11 is unset, the file name and comment should conform
    //   to the original ZIP character encoding.  If general purpose bit 11 is set, the
    //   filename and comment must support The Unicode Standard, Version 4.1.0 or
    //   greater using the character encoding form defined by the UTF-8 storage
    //   specification.  The Unicode Standard is published by the The Unicode
    //   Consortium (www.unicode.org).  UTF-8 encoded data stored within ZIP files
    //   is expected to not include a byte order mark (BOM).
    
    //  Code Page 437 corresponds to kCFStringEncodingDOSLatinUS
    NSStringEncoding encoding = CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingDOSLatinUS);
    NSString* strPath = [NSString stringWithCString:filename encoding:encoding];
    if (strPath) {
      return strPath;
    }
  }
  
  // attempting unicode encoding
  NSString * strPath = @(filename);
  if (strPath) {
    return strPath;
  }
  
  // if filename is non-unicode, detect and transform Encoding
  NSData *data = [NSData dataWithBytes:(const void *)filename length:sizeof(unsigned char) * size_filename];
  // Testing availability of @available (https://stackoverflow.com/a/46927445/1033581)
#if __clang_major__ < 9
  // Xcode 8-
  if (floor(NSFoundationVersionNumber) > NSFoundationVersionNumber10_9_2) {
#else
    // Xcode 9+
    if (@available(macOS 10.10, iOS 8.0, watchOS 2.0, tvOS 9.0, *)) {
#endif
      // supported encodings are in [NSString availableStringEncodings]
      [NSString stringEncodingForData:data encodingOptions:nil convertedString:&strPath usedLossyConversion:nil];
    } else {
      // fallback to a simple manual detect for macOS 10.9 or older
      NSArray<NSNumber *> *encodings = @[@(kCFStringEncodingGB_18030_2000), @(kCFStringEncodingShiftJIS)];
      for (NSNumber *encoding in encodings) {
        strPath = [NSString stringWithCString:filename encoding:(NSStringEncoding)CFStringConvertEncodingToNSStringEncoding(encoding.unsignedIntValue)];
        if (strPath) {
          break;
        }
      }
    }
    if (strPath) {
      return strPath;
    }
    
    // if filename encoding is non-detected, we default to something based on data
    // _hexString is more readable than _base64RFC4648 for debugging unknown encodings
    strPath = [data _hexString];
    return strPath;
  }


+ (BOOL)unzipFileAtPath:(NSString *)path
          toDestination:(NSString *)destination
     preserveAttributes:(BOOL)preserveAttributes
              overwrite:(BOOL)overwrite
               password:(nullable NSString *)password
                  error:(NSError **)error
               delegate:(nullable id<UnzipDelegate>)delegate
        progressHandler:(nullable void (^)(NSString *entry, unz_file_info zipInfo, long entryNumber, long total))progressHandler
      completionHandler:(nullable void (^)(NSString *path, BOOL succeeded, NSError *error))completionHandler
{
  
  if (path.length == 0 || destination.length == 0)
  {
    NSDictionary *userInfo = @{NSLocalizedDescriptionKey: @"received invalid argument(s)"};
    NSError *err = [NSError errorWithDomain:SSZipArchiveErrorDomain code:SSZipArchiveErrorCodeInvalidArguments userInfo:userInfo];
    if (error)
    {
      *error = err;
    }
    if (completionHandler)
    {
      completionHandler(nil, NO, err);
    }
    return NO;
  }
  
  // Begin opening
  zipFile zip = unzOpen((const char*)[path UTF8String]);
  if (zip == NULL) {
    NSDictionary *userInfo = @{NSLocalizedDescriptionKey: @"failed to open zip file"};
    NSError *err = [NSError errorWithDomain:@"SSZipArchiveErrorDomain" code:-1 userInfo:userInfo];
    if (error)
      *error = err;
  
    if (completionHandler)
      completionHandler(nil, NO, err);

    return NO;
  }
  
  unsigned long long currentPosition = 0;
  
  unz_global_info  globalInfo = {0ul, 0ul};
  unzGetGlobalInfo(zip, &globalInfo);
  
  // Begin unzipping
  if (unzGoToFirstFile(zip) != UNZ_OK) {
    NSDictionary *userInfo = @{NSLocalizedDescriptionKey: @"failed to open first file in zip file"};
    NSError *err = [NSError errorWithDomain:@"SSZipArchiveErrorDomain" code:-2 userInfo:userInfo];
    if (error)
      *error = err;
  
    if (completionHandler)
      completionHandler(nil, NO, err);
    return NO;
  }
  
  BOOL success = YES;
  int ret = 0;
  int crc_ret =0;
  unsigned char buffer[4096] = {0};
  NSFileManager *fileManager = [NSFileManager defaultManager];
  NSMutableArray *directoriesModificationDates = [[NSMutableArray alloc] init];
  
  NSInteger currentFileNumber = 0;
  NSError *unzippingError;
  do {
    @autoreleasepool {
      if ([password length] == 0) {
        ret = unzOpenCurrentFile(zip);
      } else {
        ret = unzOpenCurrentFilePassword(zip, [password cStringUsingEncoding:NSASCIIStringEncoding]);
      }
      
      if (ret != UNZ_OK) {
        success = NO;
        break;
      }
      
      // Reading data and write to file
      unz_file_info fileInfo;
      memset(&fileInfo, 0, sizeof(unz_file_info));
      
      ret = unzGetCurrentFileInfo(zip, &fileInfo, NULL, 0, NULL, 0, NULL, 0);
      if (ret != UNZ_OK) {
        success = NO;
        unzCloseCurrentFile(zip);
        break;
      }
      
      currentPosition += fileInfo.compressed_size;
      
      
      char *filename = (char *)malloc(fileInfo.size_filename + 1);
      if (filename == NULL) return NO;
      
      
      unzGetCurrentFileInfo(zip, &fileInfo, filename, fileInfo.size_filename + 1, NULL, 0, NULL, 0);
      filename[fileInfo.size_filename] = '\0';
      
      // Message delegate
      
      if( [delegate respondsToSelector:@selector(shouldUnzipFile:fileName:)]) {
        if (![delegate shouldUnzipFile:path fileName:[NSString stringWithCString:filename encoding:NSUTF8StringEncoding]]) {
          unzCloseCurrentFile(zip);
          ret = unzGoToNextFile(zip);
          free(filename);
          continue;
        }
      }
      
      BOOL fileIsSymbolicLink = [self _fileIsSymbolicLink:&fileInfo];
      
      NSString * strPath = [Unzip _filenameStringWithCString:filename
                                             version_made_by:fileInfo.version
                                        general_purpose_flag:fileInfo.flag
                                                        size:fileInfo.size_filename];

      if ([strPath hasPrefix:@"__MACOSX/"]) {
        // ignoring resource forks: https://superuser.com/questions/104500/what-is-macosx-folder
        unzCloseCurrentFile(zip);
        ret = unzGoToNextFile(zip);
        free(filename);
        continue;
      }
      
      // Check if it contains directory
    
      //if filename contains chinese dir transform Encoding
      if (!strPath) {
        NSStringEncoding enc = CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000);
        strPath = [NSString  stringWithCString:filename encoding:enc];
      }
      //end by skyfox
      
      BOOL isDirectory = NO;
      if (filename[fileInfo.size_filename-1] == '/' || filename[fileInfo.size_filename-1] == '\\') {
        isDirectory = YES;
      }
      free(filename);
      
      // Contains a path
      if ([strPath rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\"]].location != NSNotFound) {
        strPath = [strPath stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
      }
      
      NSString *fullPath = [destination stringByAppendingPathComponent:strPath];
      NSError *err = nil;
      NSDictionary *directoryAttr;
      if (preserveAttributes) {
        NSDate *modDate = [[self class] _dateWithMSDOSFormat:(UInt32)fileInfo.mz_dos_date];
        directoryAttr = @{NSFileCreationDate: modDate, NSFileModificationDate: modDate};
        [directoriesModificationDates addObject: @{@"path": fullPath, @"modDate": modDate}];
      }
      if (isDirectory) {
        [fileManager createDirectoryAtPath:fullPath withIntermediateDirectories:YES attributes:directoryAttr  error:&err];
      } else {
        [fileManager createDirectoryAtPath:[fullPath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:directoryAttr error:&err];
      }
      if (nil != err) {
        if ([err.domain isEqualToString:NSCocoaErrorDomain] &&
            err.code == 640) {
          unzippingError = err;
          unzCloseCurrentFile(zip);
          success = NO;
          break;
        }
        NSLog(@"[SSZipArchive] Error: %@", err.localizedDescription);
      }
      
      if ([fileManager fileExistsAtPath:fullPath] && !isDirectory && !overwrite) {
        //FIXME: couldBe CRC Check?
        unzCloseCurrentFile(zip);
        ret = unzGoToNextFile(zip);
        continue;
      }
      
      if (!fileIsSymbolicLink) {
        FILE *fp = fopen((const char*)[fullPath UTF8String], "wb");
        while (fp) {
          int readBytes = unzReadCurrentFile(zip, buffer, 4096);
          
          if (readBytes > 0) {
            fwrite(buffer, readBytes, 1, fp );
          } else {
            break;
          }
        }
        
        if (fp) {
          fclose(fp);
          
          
          
          if (preserveAttributes) {
            
            // Set the original datetime property
            if (fileInfo.mz_dos_date != 0) {
              NSDate *orgDate = [[self class] _dateWithMSDOSFormat:(UInt32)fileInfo.mz_dos_date];
              NSDictionary *attr = @{NSFileModificationDate: orgDate};
              
              if (attr) {
                if ([fileManager setAttributes:attr ofItemAtPath:fullPath error:nil] == NO) {
                  // Can't set attributes
                  NSLog(@"[SSZipArchive] Failed to set attributes - whilst setting modification date");
                }
              }
            }
            
            // Set the original permissions on the file
            uLong permissions = fileInfo.external_fa >> 16;
            if (permissions != 0) {
              // Store it into a NSNumber
              NSNumber *permissionsValue = @(permissions);
              
              // Retrieve any existing attributes
              NSMutableDictionary *attrs = [[NSMutableDictionary alloc] initWithDictionary:[fileManager attributesOfItemAtPath:fullPath error:nil]];
              
              // Set the value in the attributes dict
              attrs[NSFilePosixPermissions] = permissionsValue;
              
              // Update attributes
              if ([fileManager setAttributes:attrs ofItemAtPath:fullPath error:nil] == NO) {
                // Unable to set the permissions attribute
                NSLog(@"[SSZipArchive] Failed to set attributes - whilst setting permissions");
              }
              
#if !__has_feature(objc_arc)
              [attrs release];
#endif
            }
          }
        }
        else
        {
          // if we couldn't open file descriptor we can validate global errno to see the reason
          if (errno == ENOSPC) {
            NSError *enospcError = [NSError errorWithDomain:NSPOSIXErrorDomain
                                                       code:ENOSPC
                                                   userInfo:nil];
            unzippingError = enospcError;
            unzCloseCurrentFile(zip);
            success = NO;
            break;
          }
        }
      }
      else
      {
        // Assemble the path for the symbolic link
        NSMutableString* destinationPath = [NSMutableString string];
        int bytesRead = 0;
        while((bytesRead = unzReadCurrentFile(zip, buffer, 4096)) > 0)
        {
          buffer[bytesRead] = (int)0;
          [destinationPath appendString:@((const char*)buffer)];
        }
        
        // Create the symbolic link (making sure it stays relative if it was relative before)
        int symlinkError = symlink([destinationPath cStringUsingEncoding:NSUTF8StringEncoding],
                                   [fullPath cStringUsingEncoding:NSUTF8StringEncoding]);
        
        if(symlinkError != 0)
        {
          NSLog(@"Failed to create symbolic link at \"%@\" to \"%@\". symlink() error code: %d", fullPath, destinationPath, errno);
        }
      }
      
      crc_ret = unzCloseCurrentFile( zip );
      if (crc_ret == UNZ_CRCERROR) {
        //CRC ERROR
        success = NO;
        break;
      }
      ret = unzGoToNextFile( zip );
            
      currentFileNumber++;
      if (progressHandler)
        progressHandler(strPath, fileInfo, currentFileNumber, globalInfo.number_entry);
    }
  } while(ret == UNZ_OK && ret != UNZ_END_OF_LIST_OF_FILE);
  
  // Close
  unzClose(zip);
  
  // The process of decompressing the .zip archive causes the modification times on the folders
  // to be set to the present time. So, when we are done, they need to be explicitly set.
  // set the modification date on all of the directories.
  if (success && preserveAttributes) {
    NSError * err = nil;
    for (NSDictionary * d in directoriesModificationDates) {
      if (![[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate: d[@"modDate"]} ofItemAtPath:d[@"path"] error:&err]) {
        NSLog(@"[SSZipArchive] Set attributes failed for directory: %@.", d[@"path"]);
      }
      if (err) {
        NSLog(@"[SSZipArchive] Error setting directory file modification date attribute: %@",err.localizedDescription);
      }
    }
#if !__has_feature(objc_arc)
    [directoriesModificationDates release];
#endif
  }
  
  NSError *retErr = nil;
  if (crc_ret == UNZ_CRCERROR)
  {
    NSDictionary *userInfo = @{NSLocalizedDescriptionKey: @"crc check failed for file"};
    retErr = [NSError errorWithDomain:@"SSZipArchiveErrorDomain" code:-3 userInfo:userInfo];
  }
  
  if (error) {
    if (unzippingError) {
      *error = unzippingError;
    }
    else {
      *error = retErr;
    }
  }
  if (completionHandler)
  {
    if (unzippingError) {
      completionHandler(path, success, unzippingError);
    }
    else
    {
      completionHandler(path, success, retErr);
    }
  }
  return success;
}

#pragma mark - Private

+ (NSString *)_temporaryPathForDiscardableFile
{
  static NSString *discardableFileName = @".DS_Store";
  static NSString *discardableFilePath = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    NSString *temporaryDirectoryName = [[NSUUID UUID] UUIDString];
    NSString *temporaryDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:temporaryDirectoryName];
    BOOL directoryCreated = [[NSFileManager defaultManager] createDirectoryAtPath:temporaryDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    discardableFilePath = directoryCreated ? [temporaryDirectory stringByAppendingPathComponent:discardableFileName] : nil;
    [@"" writeToFile:discardableFilePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
  });
  return discardableFilePath;
}

// Format from http://newsgroups.derkeiler.com/Archive/Comp/comp.os.msdos.programmer/2009-04/msg00060.html
// Two consecutive words, or a longword, YYYYYYYMMMMDDDDD hhhhhmmmmmmsssss
// YYYYYYY is years from 1980 = 0
// sssss is (seconds/2).
//
// 3658 = 0011 0110 0101 1000 = 0011011 0010 11000 = 27 2 24 = 2007-02-24
// 7423 = 0111 0100 0010 0011 - 01110 100001 00011 = 14 33 3 = 14:33:06
+ (NSDate *)_dateWithMSDOSFormat:(UInt32)msdosDateTime
{
  // the whole `_dateWithMSDOSFormat:` method is equivalent but faster than this one line,
  // essentially because `mktime` is slow:
  //NSDate *date = [NSDate dateWithTimeIntervalSince1970:dosdate_to_time_t(msdosDateTime)];
  static const UInt32 kYearMask = 0xFE000000;
  static const UInt32 kMonthMask = 0x1E00000;
  static const UInt32 kDayMask = 0x1F0000;
  static const UInt32 kHourMask = 0xF800;
  static const UInt32 kMinuteMask = 0x7E0;
  static const UInt32 kSecondMask = 0x1F;
  
  NSAssert(0xFFFFFFFF == (kYearMask | kMonthMask | kDayMask | kHourMask | kMinuteMask | kSecondMask), @"[SSZipArchive] MSDOS date masks don't add up");
  
  NSDateComponents *components = [[NSDateComponents alloc] init];
  components.year = 1980 + ((msdosDateTime & kYearMask) >> 25);
  components.month = (msdosDateTime & kMonthMask) >> 21;
  components.day = (msdosDateTime & kDayMask) >> 16;
  components.hour = (msdosDateTime & kHourMask) >> 11;
  components.minute = (msdosDateTime & kMinuteMask) >> 5;
  components.second = (msdosDateTime & kSecondMask) * 2;
  
  NSDate *date = [self._gregorian dateFromComponents:components];
  return date;
}

@end
