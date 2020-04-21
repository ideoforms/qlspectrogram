#import "AudioReader.h"

#import <AudioToolbox/AudioToolbox.h>

@implementation AudioReader

- (id)init
{
    self = [super init];
    
    self.sampleRate = 44100;
    self.numFrames = 0;
    self.data = NULL;
    
    return self;
}

- (NSUInteger)read:(NSURL *)fileURL
{
    OSErr               err;
    OSStatus            status;
    UInt32              propSize;
    ExtAudioFileRef     audioFile;
    
    /*------------------------------------------------------------------------*
     * Set up audiofile for reading
     *------------------------------------------------------------------------*/
    status = ExtAudioFileOpenURL ((__bridge CFURLRef) fileURL, &audioFile);
    NSAssert2(status == noErr, @"ExtAudioFileOpenURL %@ error: %ld", fileURL, (long) status);
    
    /*------------------------------------------------------------------------*
     * Query length in frames
     *------------------------------------------------------------------------*/
    SInt64 numFrames;
    propSize = sizeof(numFrames);
	err = ExtAudioFileGetProperty(audioFile, kExtAudioFileProperty_FileLengthFrames , &propSize, &numFrames);
    NSAssert1(err == noErr, @"ExtAudioFileGetProperty FileLengthFrames error: %d", err);
    
    self.numFrames = (unsigned int) numFrames;
    self.data = calloc((unsigned long) numFrames, sizeof(float));
	
    /*------------------------------------------------------------------------*
     * Set format to read to: 32-bit float, mono
     *------------------------------------------------------------------------*/
    AudioStreamBasicDescription clientFormat;
    propSize = sizeof(clientFormat);
    memset(&clientFormat, 0, propSize);
    
    clientFormat.mFormatID              = kAudioFormatLinearPCM;
    clientFormat.mSampleRate            = self.sampleRate;
    clientFormat.mFormatFlags           = kLinearPCMFormatFlagIsFloat;
    clientFormat.mChannelsPerFrame      = 1;
    clientFormat.mBitsPerChannel        = 32;
    clientFormat.mFramesPerPacket       = 1;
    clientFormat.mBytesPerFrame         = clientFormat.mBitsPerChannel * clientFormat.mChannelsPerFrame / 8;
    clientFormat.mBytesPerPacket        = clientFormat.mFramesPerPacket * clientFormat.mBytesPerFrame;
    clientFormat.mReserved              = 0;
    
    err = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientDataFormat, propSize, &clientFormat);
    NSAssert1(err == noErr, @"ExtAudioFileSetProperty FileDataFormat failed: %d", err);
    
    /*------------------------------------------------------------------------*
     * Seek to start of audio file
     *------------------------------------------------------------------------*/
    err = ExtAudioFileSeek(audioFile, 0);
    NSAssert1(err == noErr, @"ExtAudioFileSeek seek 0 failed: %d", err);

    /*------------------------------------------------------------------------*
     * Create AudioBufferList to read into
     *------------------------------------------------------------------------*/
    AudioBufferList buf;
    buf.mNumberBuffers = 1;
    buf.mBuffers[0].mNumberChannels = 1;
    buf.mBuffers[0].mDataByteSize = (unsigned int) numFrames * sizeof(float);
    
    /*------------------------------------------------------------------------*
     * Iteratively read into our buffer, until we have no more frames left
     * to read.
     *------------------------------------------------------------------------*/
    UInt32 offset = 0;
	while (offset < numFrames)
	{
        buf.mBuffers[0].mData = self.data + offset;

        UInt32 size = (unsigned int) (numFrames - offset) * sizeof(float);
		err = ExtAudioFileRead(audioFile, &size, &buf);
        NSAssert1(err == noErr, @"ExtAudioFileRead failed: %d", err);
        
        offset += size;
        NSLog(@"AudioReader: read %ld more frames (offset now %ld)",
             (long) size, (long) offset);
        if (size == 0)
            break;
	}

    /*------------------------------------------------------------------------*
     * Dispose of our audio file ref and return the total number of frames.
     *------------------------------------------------------------------------*/
    err = ExtAudioFileDispose(audioFile);
    NSAssert1(err == noErr, @"ExtAudioFileDispose failed: %d", err);
    NSLog(@"AudioReader: read total %lld frames", numFrames);
    
    return (NSUInteger) numFrames;
}

@end
