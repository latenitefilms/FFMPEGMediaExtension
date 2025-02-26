//
//  LibAVSampleCursor.m
//  LibAVExtensionHost
//
//  Created by Anton Marini on 7/31/24.
//

#import "LibAVSampleCursor.h"
#import "LibAVTrackReader.h"
#import "LibAVFormatReader.h"

#import <libavformat/avformat.h>
#import <libavcodec/avcodec.h>
#import <libavformat/avio.h>
#import <libavutil/file.h>

typedef struct  {
    int successOrFail;
    CMTime packetPTS;
    CMTime packetDTS;
    CMTime packetDuration;
} LibAVSampleCursorReadResults;


@interface LibAVSampleCursor ()
@property (readwrite, strong) LibAVTrackReader* trackReader;

// Required Private Setters
@property (nonatomic, readwrite) CMTime presentationTimeStamp;
@property (nonatomic, readwrite) CMTime decodeTimeStamp;
@property (nonatomic, readwrite) CMTime currentSampleDuration;
@property (nonatomic, readwrite, nullable) __attribute__((NSObject)) CMFormatDescriptionRef currentSampleFormatDescription;

// Optional Sync Private Setters
@property (nonatomic, readwrite) AVSampleCursorSyncInfo syncInfo;
@property (nonatomic, readwrite) AVSampleCursorDependencyInfo currentSampleDependencyInfo;
@property (nonatomic, readwrite) CMTime decodeTimeOfLastSampleReachableByForwardSteppingThatIsAlreadyLoadedByByteSource;

// private
@property (nonatomic, readwrite, assign) NSUInteger sampleOffset;
@property (nonatomic, readwrite, assign) NSUInteger sampleSize;



@end

@implementation LibAVSampleCursor
{
    
    // We use this to proxy loading from the vended bytes from whatever the hell sandbox
    // into something that AVFormat can handle
    AVPacket *packet;
}

- (instancetype) initWithTrackReader:(LibAVTrackReader*)trackReader pts:(CMTime)pts;
{
    self = [super init];
    if (self)
    {
        NSLog(@"LibAVSampleCursor %@ init", self);

        self->packet = av_packet_alloc();

        self.trackReader = trackReader;
        
        // TODO: THis assumes we
        // * have a file we can seek to
        // * there isnt any dumb shit™ happening
        CMTime uneditedDuration = CMTimeMake(trackReader->stream->duration, trackReader->stream->time_base.den);
        self.decodeTimeOfLastSampleReachableByForwardSteppingThatIsAlreadyLoadedByByteSource = uneditedDuration;
        
        self.presentationTimeStamp = kCMTimeZero;
        self.decodeTimeStamp = kCMTimeZero;
        self.currentSampleDuration = kCMTimeIndefinite;
        
        // TODO: Check assumption - Im assuming we wont have formats change mid stream?
        self.currentSampleFormatDescription = [trackReader formatDescription];
        
        self.sampleSize = 0;
        self.sampleOffset = 0;
        
        // Populate some of our properties off of the first packet and reset
        [self seekToPTS:pts];
        [self readAPacketAndUpdateState];
//        [self seekToPTS:pts];
    }
    
    return self;
}

- (instancetype) initWithTrackReader:(LibAVTrackReader *)trackReader
                                 pts:(CMTime)pts
                                 dts:(CMTime)dts
                            duration:(CMTime)duration
                                size:(NSUInteger)sampleSize
                              offset:(NSUInteger)offset
                            syncInfo:(AVSampleCursorSyncInfo)syncInfo
                      dependencyInfo:(AVSampleCursorDependencyInfo)dependencyInfo

{
    self = [super init];
    if (self)
    {
        NSLog(@"LibAVSampleCursor %@ init with pts %@ /dts %@", self, CMTimeCopyDescription(kCFAllocatorDefault, pts), CMTimeCopyDescription(kCFAllocatorDefault, dts));

        self->packet = av_packet_alloc();

        self.trackReader = trackReader;
        
        self.presentationTimeStamp = pts;
        self.decodeTimeStamp = dts;
        self.currentSampleDuration = duration;
        
        // TODO: Check assumption - Im assuming we wont have formats change mid stream?
        self.currentSampleFormatDescription = [trackReader formatDescription];
        
        self.sampleSize = sampleSize;
        self.sampleOffset = offset;
        
        self.syncInfo = syncInfo;
        self.currentSampleDependencyInfo = dependencyInfo;
    }

    return self;
}

- (void) dealloc
{
    av_packet_free(&(self->packet));
    self->packet = NULL;
    
    self.trackReader = nil;
    self.currentSampleFormatDescription = NULL;
}

// MARK: - MESampleCursor Protocol Requirements

- (nonnull id)copyWithZone:(nullable NSZone *)zone
{
//    NSLog(@"LibAVSampleCursor %@ copyWithZone", self);

    LibAVSampleCursor* copy = [[LibAVSampleCursor alloc] initWithTrackReader:self.trackReader
                                                                         pts:self.presentationTimeStamp
                                                                         dts:self.decodeTimeStamp
                                                                    duration:self.currentSampleDuration
                                                                        size:self.sampleSize
                                                                      offset:self.sampleOffset
                                                                    syncInfo:self.syncInfo
                                                              dependencyInfo:self.currentSampleDependencyInfo];

    NSLog(@"LibAVSampleCursor %@ created copy %@", self, copy);

    return copy;
}

// MARK: - Step By Time

- (void)stepByDecodeTime:(CMTime)deltaDecodeTime
       completionHandler:(nonnull void (^)(CMTime, BOOL, NSError * _Nullable))completionHandler
{
    CMTime targetDTS = CMTimeAdd(self.decodeTimeStamp, deltaDecodeTime);
    
    CMTimeRange trackTimeRange = CMTimeRangeMake(kCMTimeZero, self.trackReader.formatReader.duration);
    
    BOOL wasPinned = false;
    
    if ( !CMTimeRangeContainsTime(trackTimeRange, targetDTS) )
    {
        targetDTS = CMTimeClampToRange(targetDTS, trackTimeRange);
        wasPinned = TRUE;
    }
    
    int ret = [self seekToDTS:targetDTS];
    
    if (ret < 0)
    {
        NSError* error = [self libAVFormatErrorFrom:ret];
        completionHandler(self.decodeTimeStamp, wasPinned, error);
        return;
    }
    
    ret = [self readAPacketAndUpdateState];
    
    if (ret < 0)
    {
        NSError* error = [self libAVFormatErrorFrom:ret];
        completionHandler(self.decodeTimeStamp, wasPinned, error);
        return;
    }
    
    completionHandler(self.decodeTimeStamp, wasPinned, nil);
}

- (void)stepByPresentationTime:(CMTime)deltaPresentationTime
             completionHandler:(nonnull void (^)(CMTime, BOOL, NSError * _Nullable))completionHandler
{
    NSLog(@"LibAVSampleCursor %@ stepByPresentationTime delta PTS %@", self, CMTimeCopyDescription(kCFAllocatorDefault, deltaPresentationTime));
    CMTime targetPTS = CMTimeAdd(self.presentationTimeStamp, deltaPresentationTime);

    CMTimeRange trackTimeRange = CMTimeRangeMake(kCMTimeZero, self.trackReader.formatReader.duration);

    BOOL wasPinned = false;

    if ( !CMTimeRangeContainsTime(trackTimeRange, targetPTS) )
    {
        targetPTS = CMTimeClampToRange(targetPTS, trackTimeRange);
        wasPinned = TRUE;
    }
    
    int ret = [self seekToPTS:targetPTS];

    ret = [self readAPacketAndUpdateState];
    
    if (ret < 0)
    {
        NSError* error = [self libAVFormatErrorFrom:ret];
        completionHandler(self.presentationTimeStamp, wasPinned, error);
        return;
    }
    
    ret = [self readAPacketAndUpdateState];
    
    if (ret < 0)
    {
        NSError* error = [self libAVFormatErrorFrom:ret];
        completionHandler(self.presentationTimeStamp, wasPinned, error);
        return;
    }
    
    completionHandler(self.presentationTimeStamp, wasPinned, nil);
}

// MARK: - Step By Frame

- (void)stepInDecodeOrderByCount:(int64_t)stepCount
                completionHandler:(void (^)(int64_t actualStepCount, NSError * _Nullable error))completionHandler
{
    NSLog(@"LibAVSampleCursor %@ stepInDecodeOrderByCount  %lli", self, stepCount);
//        
    int64_t actualSteps = 0;
    
    CMTime startingTimeStamp = self.decodeTimeStamp;
    
    BOOL foundNextDTSOrErrored = NO;
    
    while ( !foundNextDTSOrErrored )
    {
        if ( [self readAPacketAndUpdateState] )
        {
            actualSteps++;
                        
            if ( CMTIME_COMPARE_INLINE(self.decodeTimeStamp, >=, startingTimeStamp))
            {
                
                foundNextDTSOrErrored = true;
                completionHandler(actualSteps, nil);
                
                return;
            }
        }

        else
        {
            foundNextDTSOrErrored = true;
            break;
        }
    }
    
    NSError *error = [NSError errorWithDomain:@"libavformat.ffmpeg" code:-1 userInfo:nil];
    completionHandler(actualSteps, error);
}

// The issue here is that we should only count
- (void)stepInPresentationOrderByCount:(int64_t)stepCount completionHandler:(nonnull void (^)(int64_t, NSError * _Nullable))completionHandler
{
    NSLog(@"LibAVSampleCursor %@ stepInPresentationOrderByCount  %lli", self, stepCount);

    int64_t actualSteps = 0;
    
    CMTime startingTimeStamp = self.presentationTimeStamp;
    
    BOOL foundNextDTSOrErrored = NO;
    
    while ( !foundNextDTSOrErrored )
    {
        if ( [self readAPacketAndUpdateState] )
        {
            actualSteps++;
                        
            if ( CMTIME_COMPARE_INLINE(self.presentationTimeStamp, >=, startingTimeStamp))
            {                
                foundNextDTSOrErrored = true;
                completionHandler(actualSteps, nil);
                
                return;
            }
        }

        else
        {
            foundNextDTSOrErrored = true;
            break;
        }
    }
    
    NSError *error = [NSError errorWithDomain:@"libavformat.ffmpeg" code:-1 userInfo:nil];
    completionHandler(actualSteps, error);
}

-(BOOL)samplesWithEarlierDTSsMayHaveLaterPTSsThanCursor:(id<MESampleCursor>)cursor
{
    return YES;
}

-(BOOL)samplesWithLaterDTSsMayHaveEarlierPTSsThanCursor:(id<MESampleCursor>)cursor
{
    return YES;
}

// MARK: - Sample Location - I could not get these to work

//- (MESampleLocation * _Nullable) sampleLocationReturningError:(NSError *__autoreleasing _Nullable * _Nullable) error
//{
////    if ( self.currentSampleDependencyInfo.sampleDependsOnOthers )
////    {
////        NSLog(@"sampleLocationReturningError - have sampleDependsOnOthers - returning MEErrorLocationNotAvailable ");
////        *error = [NSError errorWithDomain:@"sampleLocationReturningError" code:MEErrorLocationNotAvailable userInfo:nil];
////        return NULL;
////    }
//    
////    NSLog( @"LibAVSampleCursor sampleLocationReturningError offset: %li, length: %li", self.sampleOffset, self.sampleSize );
//
//    AVSampleCursorStorageRange range;
//    range.offset = self.sampleOffset;
//    range.length = self.sampleSize;
//    
//    MESampleLocation* location = [[MESampleLocation alloc] initWithByteSource:self.trackReader.formatReader.byteSource sampleLocation:range];
//    
//    return location;
//}
//
//- (MESampleCursorChunk * _Nullable) chunkDetailsReturningError:(NSError *__autoreleasing _Nullable * _Nullable) error
//{
////    if ( self.currentSampleDependencyInfo.sampleDependsOnOthers)
////    {
////        NSLog(@"chunkDetailsReturningError - have sampleDependsOnOthers - returning MEErrorLocationNotAvailable ");
////        *error = [NSError errorWithDomain:@"sampleLocationReturningError" code:MEErrorLocationNotAvailable userInfo:nil];
////        return NULL;
////    }
//
//    NSLog(@"chunkDetailsReturningError");
//
//    AVSampleCursorStorageRange range;
//    range.offset = self.sampleOffset;
//    range.length = self.sampleSize;
//
//    AVSampleCursorChunkInfo info;
//    info.chunkSampleCount = 1; // NO IDEA LOLZ
//    info.chunkHasUniformSampleSizes = false;
//    info.chunkHasUniformSampleDurations = true;
//    info.chunkHasUniformFormatDescriptions = true;
//    
//    MESampleCursorChunk* chunk = [[MESampleCursorChunk alloc] initWithByteSource:self.trackReader.formatReader.byteSource
//                                                               chunkStorageRange:range
//                                                                       chunkInfo:info
//                                                          sampleIndexWithinChunk:0];
//    
//    return chunk;
//}

// MARK: - Sample Buffer Delivery - Works

////// Lets try a new strategy - simply implement this method and provide fully decoded frames to Core Media?
- (void)loadSampleBufferContainingSamplesToEndCursor:(nullable id<MESampleCursor>)endSampleCursor completionHandler:(void (^)(CMSampleBufferRef _Nullable newSampleBuffer, NSError * _Nullable error))completionHandler
{
    NSLog(@"LibAVSampleCursor: %@ loadSampleBufferContainingSamplesToEndCursor endCursor%@", self, endSampleCursor);
       
    if (self->packet)
    {
        CMSampleBufferRef sampleBuffer = [self createSampleBufferFromAVPacketWithoutDecoding:self->packet];
        
        if ( sampleBuffer != NULL )
        {
            NSLog(@"LibAVSampleCursor: %@ loadSampleBufferContainingSamplesToEndCursor Got Sample Buffer %@", self, sampleBuffer);
            
            completionHandler(sampleBuffer, nil);
                    
            CFRelease(sampleBuffer);
            return;
        }
    }
   
    completionHandler(nil, nil);
}

// MARK: - NO PROTOCOL REQUIREMENTS BELOW -

// MARK: Sample Buffer Helper

- (nullable CMSampleBufferRef)createSampleBufferFromAVPacketWithoutDecoding:(const AVPacket *)packet
{
    CMSampleBufferRef sampleBuffer = NULL;

    // Create a CMBlockBuffer from the packet data
    CMBlockBufferRef blockBuffer = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,
                                                         (void *)packet->data,
                                                         packet->size,
                                                         kCFAllocatorDefault,
                                                         NULL,
                                                         0,
                                                         packet->size,
                                                         kCMBlockBufferAlwaysCopyDataFlag,
                                                         &blockBuffer
                                                         );
    
    if (status != kCMBlockBufferNoErr)
    {
        NSLog(@"Failed to create CMBlockBuffer");
        return NULL;
    }

    
    CMSampleTimingInfo timingInfo;
    timingInfo.duration = self.currentSampleDuration;
    timingInfo.presentationTimeStamp = self.presentationTimeStamp;
    timingInfo.decodeTimeStamp = self.decodeTimeStamp;
    
    // Create the sample buffer
    status = CMSampleBufferCreateReady(kCFAllocatorDefault,
                                       blockBuffer,
                                       self.currentSampleFormatDescription,
                                       1,
                                       1,
                                       &timingInfo,
                                       0,
                                       NULL,
                                       &sampleBuffer);
    

//      CFRelease(blockBuffer);
      
      if (status != noErr) {
          NSLog(@"Failed to create sample buffer");
          return NULL;
      }
      
      return sampleBuffer;
}

// MARK: - Seeking Helper Functions

- (void) seekToBeginningOfFile
{
    // TODO: Not technically correct
    [self seekToPTS:kCMTimeZero];
}

- (void) seekToEndOfFile
{
    // TODO: Not technically correct
    [self seekToPTS:self.trackReader.formatReader.duration];
}

- (int) seekToPTS:(CMTime)time
{
//    // If we are at our current time, no need to seek
//    if (CMTIME_COMPARE_INLINE(time, ==, self.presentationTimeStamp) && CMTIME_IS_VALID( self.presentationTimeStamp ) && CMTIME_IS_VALID( time )  )
//    {
//        NSLog(@"LibAVSampleCursor: %@ seekToPTS already at %@", self, CMTimeCopyDescription(kCFAllocatorDefault, time));
//
//        return 1;
//    }
    
    NSLog(@"LibAVSampleCursor: %@ seekToPTS %@", self, CMTimeCopyDescription(kCFAllocatorDefault, time));

    return [self seekToTime:time flags: AVSEEK_FLAG_ANY ];
}

// TODO: Validate DTS seeking is correct for out of order codecs
- (int) seekToDTS:(CMTime)time
{
//    // If we are at our current time, no need to seek
//    if (CMTIME_COMPARE_INLINE(time, ==, self.decodeTimeStamp) && CMTIME_IS_VALID( self.decodeTimeStamp )  && CMTIME_IS_VALID( time )  )
//    {
//        NSLog(@"LibAVSampleCursor: %@ seekToDTS already at %@", self, CMTimeCopyDescription(kCFAllocatorDefault, time));
//        return 1;
//    }
    
    NSLog(@"LibAVSampleCursor: %@ seekToDTS %@", self, CMTimeCopyDescription(kCFAllocatorDefault, time));
    
    return [self seekToTime:time flags: AVSEEK_FLAG_ANY ];
}

- (int) seekToTime:(CMTime)time flags:(int)flags
{
    CMTime timeInStreamUnits = CMTimeConvertScale(time, self.trackReader->stream->time_base.den, kCMTimeRoundingMethod_Default);

    NSLog(@"LibAVSampleCursor: %@ seekToTime converted to %@", self, CMTimeCopyDescription(kCFAllocatorDefault, timeInStreamUnits));

    
    return avformat_seek_file(self.trackReader.formatReader->format_ctx,
                              self.trackReader.streamIndex - 1,
                              0,
                              timeInStreamUnits.value,
                              INT_MAX,
                              flags);
}


// Reciever must call av_packet_unref on this packer
- (int) readAPacketAndUpdateState
{
    NSLog(@"LibAVSampleCursor: %@ readAPacketAndUpdateState", self);

    while ( av_read_frame(self.trackReader.formatReader->format_ctx, self->packet) >= 0 )
    {
        if ( packet->stream_index == self.trackReader.streamIndex - 1 )
        {
            [self updateStateForPacket:self->packet];

            return 1;
        }
    }

    return -1;
}


// MARK: - State

// Use this after we reading vents a packet
- (void) updateStateForPacket:(const AVPacket*)packet
{
    // Update currentDTS based on the packet's DTS
    self.decodeTimeStamp = [self convertToCMTime:packet->dts timebase:self.trackReader->stream->time_base];
    self.presentationTimeStamp = [self convertToCMTime:packet->pts timebase:self.trackReader->stream->time_base];
    self.currentSampleDuration = [self convertToCMTime:packet->duration timebase:self.trackReader->stream->time_base];
    
    
    self.syncInfo = [self extractSyncInfoFrom:packet];
    self.currentSampleDependencyInfo = [self extractDependencyInfoFromPacket:packet codecParameters:self.trackReader->stream->codecpar];
    
    self.sampleSize = packet->size;
    self.sampleOffset = packet->pos;

    NSLog(@"LibAVSampleCursor: %@ updateStateForPacket Presentation Timestamp %@", self, CMTimeCopyDescription(kCFAllocatorDefault, self.presentationTimeStamp));
    NSLog(@"LibAVSampleCursor: %@ updateStateForPacket Decode Timestamp %@", self, CMTimeCopyDescription(kCFAllocatorDefault, self.decodeTimeStamp));
    NSLog(@"LibAVSampleCursor: %@ updateStateForPacket Duration %@", self, CMTimeCopyDescription(kCFAllocatorDefault, self.currentSampleDuration));
    NSLog(@"LibAVSampleCursor: %@ updateStateForPacket sampleOffset %lu", self, (unsigned long)self.sampleOffset);
    NSLog(@"LibAVSampleCursor: %@ updateStateForPacket sampleSize %lu", self, (unsigned long)self.sampleSize);
}

// MARK: - Sync Utility

- (AVSampleCursorSyncInfo) extractSyncInfoFrom:(const AVPacket*)packet
{
    AVSampleCursorSyncInfo syncInfo = {0};

    // Check if the packet is a keyframe (full sync)
    if (packet->flags & AV_PKT_FLAG_KEY)
    {
        syncInfo.sampleIsFullSync = YES;
    }
    else
    {
        syncInfo.sampleIsFullSync = NO;
    }

    // Partial sync determination is codec-specific and may not always be available
    syncInfo.sampleIsPartialSync = NO; // Defaulting to NO

    // Check if the packet is droppable (disposable or discardable)
    if (packet->flags & (AV_PKT_FLAG_DISPOSABLE | AV_PKT_FLAG_DISCARD))
    {
        syncInfo.sampleIsDroppable = YES;
    }
    else
    {
        syncInfo.sampleIsDroppable = NO;
    }

    return syncInfo;
}

- (AVSampleCursorDependencyInfo) extractDependencyInfoFromPacket:(const AVPacket*)packet codecParameters:(const AVCodecParameters*) codecpar
{
    AVSampleCursorDependencyInfo depInfo = {0};

    // Check if the packet is a keyframe
    BOOL isKeyframe = packet->flags & AV_PKT_FLAG_KEY;
    
    // Determine if the sample depends on others
    depInfo.sampleIndicatesWhetherItDependsOnOthers = YES;
    depInfo.sampleDependsOnOthers = !isKeyframe; // Keyframes don't depend on others

    // Determine if there are dependent samples
    depInfo.sampleIndicatesWhetherItHasDependentSamples = YES;
    depInfo.sampleHasDependentSamples = isKeyframe; // Keyframes typically have dependents

    // Redundant coding is codec-specific and often not directly exposed in FFmpeg
    depInfo.sampleIndicatesWhetherItHasRedundantCoding = NO;
    depInfo.sampleHasRedundantCoding = NO; // Defaulting to NO, this would require codec-specific logic

    return depInfo;
}

// MARK: - Utility

// Function to convert FFmpeg PTS/DTS to CMTime
- (CMTime) convertToCMTime:(int64_t)ptsOrDts timebase:(AVRational)timeBase
{
    if (ptsOrDts == AV_NOPTS_VALUE)
    {
        NSLog(@"LibAVSampleCursor Recieved Invalid timestamp AV_NOPTS_VALUE - returning kCMTimeInvalid");
        return kCMTimeIndefinite;
//        return
    }
    
    if (ptsOrDts == INT64_MAX)
    {
        NSLog(@"LibAVSampleCursor Recieved Invalid timestamp INT64_MAX - returning kCMTimeInvalid");
        return kCMTimePositiveInfinity;
    }
    else if (ptsOrDts == INT64_MIN)
    {
        NSLog(@"LibAVSampleCursor Recieved Invalid timestamp INT64_MIN - returning kCMTimeNegativeInfinity");
        return kCMTimeNegativeInfinity;
    }
        
    // Convert to seconds using the time base
    double seconds = (double)ptsOrDts * av_q2d(timeBase);
    
    // CMTime uses an int64 value to represent time, with a timescale to denote fractional seconds
    CMTime time = CMTimeMakeWithSeconds(seconds, timeBase.den);
    
//    NSLog(@"LibAVSampleCursor Converted %@", CMTimeCopyDescription(kCFAllocatorDefault, time));
    
    return time;
}

// MARK: Error

- (NSError*) libAVFormatErrorFrom:(int)returnCode
{
    NSError *error = [NSError errorWithDomain:@"libavformat.ffmpeg" code:returnCode userInfo:nil];

    return error;
}

@end
