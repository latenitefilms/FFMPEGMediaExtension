//
//  LibAVTrackReader.m
//  LibAVExtension
//
//  Created by Anton Marini on 7/25/24.
//

#import "LibAVTrackReader.h"
#import "LibAVFormatReader.h"
#import <CoreMedia/CoreMedia.h>

@interface LibAVTrackReader ()
@property (readwrite, strong) LibAVFormatReader* formatReader;
@property (readwrite, assign) NSUInteger streamIndex;
@end

@implementation LibAVTrackReader

- (instancetype) initWithFormatReader:(LibAVFormatReader*)formatReader stream:(AVStream*)stream atIndex:(NSUInteger)index;
{
    self = [super init];
    if (self != nil)
    {
        self.formatReader = formatReader;
        self.streamIndex = index;

        self->stream = stream;

    }
    return self;
}


- (void)generateSampleCursorAtFirstSampleInDecodeOrderWithCompletionHandler:(nonnull void (^)(id<MESampleCursor> _Nullable, NSError * _Nullable))completionHandler {
    
}

- (void)generateSampleCursorAtLastSampleInDecodeOrderWithCompletionHandler:(nonnull void (^)(id<MESampleCursor> _Nullable, NSError * _Nullable))completionHandler { 
    
}

- (void)generateSampleCursorAtPresentationTimeStamp:(CMTime)presentationTimeStamp completionHandler:(nonnull void (^)(id<MESampleCursor> _Nullable, NSError * _Nullable))completionHandler { 
    
}


- (void)loadTrackInfoWithCompletionHandler:(nonnull void (^)(METrackInfo * _Nullable, NSError * _Nullable))completionHandler {
    
    CMFormatDescriptionRef format = [self formatDescription];
    
    if (format != NULL)
    {
        NSArray* formats = @[(id)CFBridgingRelease(format)];
        
        METrackInfo* trackInfo = [[METrackInfo alloc] initWithMediaType:[self streamMediaType]
                                                                trackID:(CMPersistentTrackID)self->stream->index
                                                     formatDescriptions:formats];
        
        // TODO: How to know if a stream is enabled?
        // trackInfo.enabled = ??
        
        // do this in place
        completionHandler(trackInfo, nil);
    }
    
    
    
}

// MARK: - Helper Methods

- (CMMediaType) streamMediaType
{
    CMMediaType type;
    
    switch (self->stream->codecpar->codec_type)
    {
        case AVMEDIA_TYPE_UNKNOWN:
            return -1;
            
        case AVMEDIA_TYPE_VIDEO:
            return kCMMediaType_Video;

        case AVMEDIA_TYPE_AUDIO:
            return kCMMediaType_Audio;

        case AVMEDIA_TYPE_DATA:
            return kCMMediaType_Metadata; //?

        case AVMEDIA_TYPE_SUBTITLE:
            return kCMMediaType_Subtitle;

        case AVMEDIA_TYPE_ATTACHMENT:
            return -1;

        case AVMEDIA_TYPE_NB:
            return -1;
    }
}

- (nullable CMFormatDescriptionRef) formatDescription
{
    switch (self->stream->codecpar->codec_type)
    {
        case AVMEDIA_TYPE_UNKNOWN:
            return NULL;
        case AVMEDIA_TYPE_VIDEO:
            return [self videoFormatDescription];

        case AVMEDIA_TYPE_AUDIO:
            return [self audioFormatDescription];

        case AVMEDIA_TYPE_DATA:
            return NULL;

        case AVMEDIA_TYPE_SUBTITLE:
            return NULL;

        case AVMEDIA_TYPE_ATTACHMENT:
            return NULL;

        case AVMEDIA_TYPE_NB:
            return NULL;
    }
}

- (nullable CMFormatDescriptionRef) videoFormatDescription
{
    CMFormatDescriptionRef formatDescription = NULL;

    CMVideoCodecType codecType = (CMVideoCodecType) self->stream->codecpar->codec_tag;

    // Create video format description
    OSStatus status = CMVideoFormatDescriptionCreate(kCFAllocatorDefault,
                                                     codecType,
                                                     self->stream->codecpar->width,
                                                     self->stream->codecpar->height,
                                                     NULL,  // Optional extensions
                                                     &formatDescription);
    
    if (status != noErr)
    {
        // Handle error
        return NULL;
    }
    
    return formatDescription;
}

- (nullable CMFormatDescriptionRef) audioFormatDescription
{
    CMAudioFormatDescriptionRef audioFormatDescription = NULL;
    
    AudioFormatID audioFormatID = (AudioFormatID)self->stream->codecpar->codec_tag;

    AudioStreamBasicDescription asbd = {0};
    asbd.mSampleRate = self->stream->codecpar->sample_rate;
    asbd.mChannelsPerFrame = self->stream->codecpar->ch_layout.nb_channels;
    asbd.mFormatID = audioFormatID;

    //Calculate layout size
    UInt32 layoutSize = offsetof(AudioChannelLayout, mChannelDescriptions[0]) + (self->stream->codecpar->ch_layout.nb_channels * sizeof(AudioChannelDescription));
    AudioChannelLayout *channelLayout = (AudioChannelLayout *)malloc(layoutSize);
    memset(channelLayout, 0, layoutSize);
    channelLayout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
    channelLayout->mNumberChannelDescriptions = self->stream->codecpar->ch_layout.nb_channels;
    
    // Set the channel descriptions based on the mask or map
    for (int i = 0; i < self->stream->codecpar->ch_layout.nb_channels; i++)
    {
        // Assume that the mask is used; handle custom maps if necessary
        uint64_t mask = self->stream->codecpar->ch_layout.u.mask;
        // Translate the mask bit to the appropriate Core Audio channel label
        // This is a simplified example; actual mapping requires matching specific bit positions
        if (mask & AV_CH_FRONT_LEFT)
        {
            channelLayout->mChannelDescriptions[i].mChannelLabel = kAudioChannelLabel_Left;
        }
        else if (mask * AV_CH_FRONT_RIGHT)
        {
            channelLayout->mChannelDescriptions[i].mChannelLabel = kAudioChannelLabel_Right;
        }
        else if (mask * AV_CH_FRONT_CENTER)
        {
            channelLayout->mChannelDescriptions[i].mChannelLabel = kAudioChannelLabel_Center;
        }
        else if (mask * AV_CH_LOW_FREQUENCY)
        {
            channelLayout->mChannelDescriptions[i].mChannelLabel = kAudioChannelLabel_LFEScreen;
        }
        else if (mask * AV_CH_BACK_LEFT)
        {
            channelLayout->mChannelDescriptions[i].mChannelLabel = kAudioChannelLabel_LeftBackSurround;
        }
        else if (mask * AV_CH_BACK_RIGHT)
        {
            channelLayout->mChannelDescriptions[i].mChannelLabel = kAudioChannelLabel_RightBackSurround;
        }
        else if (mask * AV_CH_FRONT_LEFT_OF_CENTER)
        {
            channelLayout->mChannelDescriptions[i].mChannelLabel = kAudioChannelLabel_LeftCenter;
        }
        else if (mask * AV_CH_FRONT_RIGHT_OF_CENTER)
        {
            channelLayout->mChannelDescriptions[i].mChannelLabel = kAudioChannelLabel_RightCenter;
        }
        else if (mask * AV_CH_BACK_CENTER)
        {
            channelLayout->mChannelDescriptions[i].mChannelLabel = kAudioChannelLabel_CenterSurround;
        }
        else if (mask * AV_CH_SIDE_LEFT)
        {
            channelLayout->mChannelDescriptions[i].mChannelLabel = kAudioChannelLabel_LeftSurroundDirect;
        }
        else if (mask * AV_CH_SIDE_RIGHT)
        {
            channelLayout->mChannelDescriptions[i].mChannelLabel = kAudioChannelLabel_RightSurroundDirect;
        }
        else if (mask * AV_CH_TOP_CENTER)
        {
            channelLayout->mChannelDescriptions[i].mChannelLabel = kAudioChannelLabel_TopCenterSurround;
        }

        // Handle other channels similarly...
    }
    
    // Create audio format description
    OSStatus status = CMAudioFormatDescriptionCreate(kCFAllocatorDefault,
                                                     &asbd,
                                                     layoutSize,
                                                     channelLayout,
                                                     0,       // Magic cookie size
                                                     NULL,    // Magic cookie
                                                     NULL,    // Extensions
                                                     &audioFormatDescription);
    
    if (status != noErr) {
        // Handle error
        return NULL;
    }
    
    return audioFormatDescription;
}

@end
