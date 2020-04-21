
#import <Foundation/Foundation.h>

@interface AudioReader : NSObject

@property (assign) NSUInteger sampleRate;
@property (assign) NSUInteger numFrames;
@property (assign) float *data;

- (NSUInteger)read:(NSURL *)fileURL;

@end
