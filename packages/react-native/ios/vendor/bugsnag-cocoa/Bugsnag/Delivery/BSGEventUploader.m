//
//  BSGEventUploader.m
//  Bugsnag
//
//  Created by Nick Dowell on 17/02/2021.
//  Copyright © 2021 Bugsnag Inc. All rights reserved.
//

#import "BSGEventUploader.h"

#import "BSGEventUploadKSCrashReportOperation.h"
#import "BSGEventUploadObjectOperation.h"
#import "BSGFileLocations.h"
#import "BugsnagConfiguration.h"
#import "BugsnagLogger.h"


@interface BSGEventUploader () <BSGEventUploadOperationDelegate>

@property (readonly, nonatomic) NSString *eventsDirectory;

@property (readonly, nonatomic) NSString *kscrashReportsDirectory;

@property (readonly, nonatomic) NSOperationQueue *scanQueue;

@property (readonly, nonatomic) NSOperationQueue *uploadQueue;

@end


// MARK: -

@implementation BSGEventUploader

@synthesize apiClient = _apiClient;
@synthesize configuration = _configuration;
@synthesize notifier = _notifier;

- (instancetype)initWithConfiguration:(BugsnagConfiguration *)configuration notifier:(BugsnagNotifier *)notifier {
    if (self = [super init]) {
        _apiClient = [[BugsnagApiClient alloc] initWithSession:configuration.session queueName:@""];
        _configuration = configuration;
        _eventsDirectory = [BSGFileLocations current].events;
        _kscrashReportsDirectory = [BSGFileLocations current].kscrashReports;
        _notifier = notifier;
        _scanQueue = [[NSOperationQueue alloc] init];
        _scanQueue.maxConcurrentOperationCount = 1;
        _scanQueue.name = @"com.bugsnag.event-scanner";
        _uploadQueue = [[NSOperationQueue alloc] init];
        _uploadQueue.maxConcurrentOperationCount = 1;
        _uploadQueue.name = @"com.bugsnag.event-uploader";
    }
    return self;
}

- (void)dealloc {
    [_scanQueue cancelAllOperations];
    [_uploadQueue cancelAllOperations];
}

// MARK: - Public API

- (void)uploadEvent:(BugsnagEvent *)event completionHandler:(nullable void (^)(void))completionHandler {
    BSGEventUploadObjectOperation *operation = [[BSGEventUploadObjectOperation alloc] initWithEvent:event delegate:self];
    operation.completionBlock = completionHandler;
    [self.uploadQueue addOperation:operation];
}

- (void)uploadStoredEvents {
    if (self.scanQueue.operationCount > 1) {
        // Prevent too many scan operations being scheduled
        return;
    }
    bsg_log_debug(@"Will scan stored events");
    [self.scanQueue addOperationWithBlock:^{
        NSMutableArray<NSString *> *sortedFiles = [self sortedEventFiles];
        [self deleteExcessFiles:sortedFiles];
        NSArray<BSGEventUploadFileOperation *> *operations = [self uploadOperationsWithFiles:sortedFiles];
        bsg_log_debug(@"Uploading %lu stored events", (unsigned long)operations.count);
        [self.uploadQueue addOperations:operations waitUntilFinished:NO];
    }];
}

- (void)uploadLatestStoredEvent:(void (^)(void))completionHandler {
    NSString *latestFile = [self sortedEventFiles].lastObject;
    BSGEventUploadFileOperation *operation = latestFile ? [self uploadOperationsWithFiles:@[latestFile]].lastObject : nil;
    if (!operation) {
        bsg_log_warn(@"Could not find a stored event to upload");
        completionHandler();
        return;
    }
    operation.completionBlock = completionHandler;
    [self.uploadQueue addOperation:operation];
}

// MARK: - Implementation

/// Returns the stored event files sorted from oldest to most recent.
- (NSMutableArray<NSString *> *)sortedEventFiles {
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    
    NSMutableDictionary<NSString *, NSDate *> *creationDates = [NSMutableDictionary dictionary];
    
    for (NSString *directory in @[self.eventsDirectory, self.kscrashReportsDirectory]) {
        NSError *error = nil;
        NSArray<NSString *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:&error];
        if (!entries) {
            bsg_log_err(@"%@", error);
            continue;
        }
        
        for (NSString *filename in entries) {
            if (![filename.pathExtension isEqual:@"json"] || [filename hasSuffix:@"-CrashState.json"]) {
                continue;
            }
            
            NSString *file = [directory stringByAppendingPathComponent:filename];
            NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:file error:nil];
            creationDates[file] = attributes.fileCreationDate;
            [files addObject:file];
        }
    }
    
    [files sortUsingComparator:^NSComparisonResult(NSString *lhs, NSString *rhs) {
        return [creationDates[lhs] compare:creationDates[rhs]];
    }];
    
    return files;
}

/// Deletes the oldest files until no more than `config.maxPersistedEvents` remain and removes them from the array.
- (void)deleteExcessFiles:(NSMutableArray<NSString *> *)sortedEventFiles {
    while (sortedEventFiles.count > self.configuration.maxPersistedEvents) {
        NSString *file = sortedEventFiles[0];
        NSError *error = nil;
        if ([NSFileManager.defaultManager removeItemAtPath:file error:&error]) {
            bsg_log_debug(@"Deleted %@ to comply with maxPersistedEvents", file);
        } else {
            bsg_log_err(@"Error while deleting file: %@", error);
        }
        [sortedEventFiles removeObject:file];
    }
}

/// Creates an upload operation for each file that is not currently being uploaded
- (NSArray<BSGEventUploadFileOperation *> *)uploadOperationsWithFiles:(NSArray<NSString *> *)files {
    NSMutableArray<BSGEventUploadFileOperation *> *operations = [NSMutableArray array];
    
    NSMutableSet<NSString *> *currentFiles = [NSMutableSet set];
    for (id operation in self.uploadQueue.operations) {
        if ([operation isKindOfClass:[BSGEventUploadFileOperation class]]) {
            [currentFiles addObject:((BSGEventUploadFileOperation *)operation).file];
        }
    }
    
    for (NSString *file in files) {
        if ([currentFiles containsObject:file]) {
            continue;
        }
        NSString *directory = file.stringByDeletingLastPathComponent;
        if ([directory isEqualToString:self.kscrashReportsDirectory]) {
            [operations addObject:[[BSGEventUploadKSCrashReportOperation alloc] initWithFile:file delegate:self]];
        } else {
            [operations addObject:[[BSGEventUploadFileOperation alloc] initWithFile:file delegate:self]];
        }
    }
    
    return operations;
}

// MARK: - BSGEventUploadOperationDelegate

- (void)uploadOperationDidStoreEventPayload:(BSGEventUploadOperation *)uploadOperation {
    [self deleteExcessFiles:[self sortedEventFiles]];
}

@end
