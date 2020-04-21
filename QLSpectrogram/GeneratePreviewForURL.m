#include <CoreFoundation/CoreFoundation.h>
#include <CoreServices/CoreServices.h>
#include <QuickLook/QuickLook.h>

#include <AppKit/AppKit.h>
#include <CoreImage/CoreImage.h>
#include <Accelerate/Accelerate.h>

#include "AudioReader.h"

/*------------------------------------------------------------------------------
 * QuickLook programming guide:
 * https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/Quicklook_Programming_Guide/Articles/QLDrawGraphContext.html
 *
 * Debugging QuickLook plugins:
 * https://medium.com/@fousa/debug-your-quick-look-plugin-50762525d2c2
 *
 * UTIs:
 * https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/UTIRef/Articles/System-DeclaredUniformTypeIdentifiers.html#//apple_ref/doc/uid/TP40009259-SW1
 *
 *
 * TODO:
 *  - Add support for playback
 *  - Add support for changing min/max spectrogram values
 *  - Map spectrogram to colour values
 *  - Log-Y axis
 *  - Add grid
 *  - Check start/end points (spectral leakage appears at end of file)
 *----------------------------------------------------------------------------*/

OSStatus GeneratePreviewForURL(void *thisInterface,
                               QLPreviewRequestRef preview,
                               CFURLRef url,
                               CFStringRef contentTypeUTI,
                               CFDictionaryRef options);

void CancelPreviewGeneration(void *thisInterface,
                             QLPreviewRequestRef preview);

OSStatus GeneratePreviewForURL(void *thisInterface,
                               QLPreviewRequestRef preview,
                               CFURLRef url,
                               CFStringRef contentTypeUTI,
                               CFDictionaryRef options)
{
    @autoreleasepool
    {
        /*------------------------------------------------------------------------------
         * Create graphics context to draw preview in.
         *----------------------------------------------------------------------------*/
        CGSize canvasSize = CGSizeMake(2048, 1200);
        CGContextRef cgContext = QLPreviewRequestCreateContext(preview, canvasSize, false, NULL);
        
        if (cgContext)
        {
            AudioReader *reader = [[AudioReader alloc] init];
            NSURL *nsurl = (__bridge NSURL *) url;
            [reader read:nsurl];

            NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithCGContext:cgContext flipped:YES];
            
            if (context)
            {
                /*------------------------------------------------------------------------------
                 * Init the current graphics context with a black background.
                 *----------------------------------------------------------------------------*/
                [NSGraphicsContext saveGraphicsState];
                [NSGraphicsContext setCurrentContext:context];
                [[NSColor colorWithWhite:0 alpha:1] set];
                NSRectFill(NSMakeRect(0, 0, canvasSize.width, canvasSize.height));
                
                /*------------------------------------------------------------------------------
                 * Init core values and allocate memory for magnitude spectrum and other
                 * auxiliary buffers.
                 *----------------------------------------------------------------------------*/
                int fft_size = 1024;
                int half_fft_size = fft_size / 2;
                float increment = (float) (reader.numFrames - fft_size) / canvasSize.width;
                float *spectrum = calloc(half_fft_size, sizeof(float));
                float *spectrum_db = calloc(half_fft_size, sizeof(float));
                float *windowed_data = calloc(fft_size, sizeof(float));
                float *window = calloc(fft_size, sizeof(float));
                uint8_t *rgba = (uint8_t *) malloc(canvasSize.width * canvasSize.height * 4);

                /*------------------------------------------------------------------------------
                 * vDSP FFT requires storing intermediate complex values in split format.
                 *----------------------------------------------------------------------------*/
                DSPSplitComplex spectrum_split;
                spectrum_split.realp = calloc(half_fft_size, sizeof(float));
                spectrum_split.imagp = calloc(half_fft_size, sizeof(float));
                
                /*------------------------------------------------------------------------------
                 * Create the FFT structure required for subsequent processing.
                 *----------------------------------------------------------------------------*/
                vDSP_Length log2blocksize = (vDSP_Length) log2f(fft_size);
                FFTSetup fftSetup = vDSP_create_fftsetup(log2blocksize, FFT_RADIX2);
                
                /*------------------------------------------------------------------------------
                 * Make a Hanning window.
                 *----------------------------------------------------------------------------*/
                vDSP_hann_window(window, fft_size, vDSP_HANN_NORM);
                
                [[NSColor colorWithWhite:1 alpha:1.0] set];
                
                for (int x = 0; x < canvasSize.width; x++)
                {
                    int sample_start = (int) ((float) x * increment);
                 
                    /*------------------------------------------------------------------------------
                     * Draw waveform.
                     *----------------------------------------------------------------------------*/
                    int sample_end = (int) ((float) (x + 1) * increment);
                    
                    float magnitude_min = 0.0f;
                    float magnitude_max = 0.0f;
                    for (int i = sample_start; i < sample_end; i++)
                    {
                        if (reader.data[i] < magnitude_min)
                        {
                            magnitude_min = reader.data[i];
                        }
                        if (reader.data[i] > magnitude_max)
                        {
                            magnitude_max = reader.data[i];
                        }
                    }

                    [NSBezierPath strokeLineFromPoint:NSMakePoint(x, canvasSize.height * 0.25 + canvasSize.height * (magnitude_min * 0.25))
                                              toPoint:NSMakePoint(x, canvasSize.height * 0.25 + canvasSize.height * (magnitude_max * 0.25))];

                    /*------------------------------------------------------------------------------
                     * Do FFT.
                     *----------------------------------------------------------------------------*/
                    vDSP_vmul(reader.data + sample_start, 1, window, 1, windowed_data, 1, fft_size);
                    vDSP_ctoz((COMPLEX *) windowed_data, 2, &spectrum_split, 1, half_fft_size);
                    vDSP_fft_zrip(fftSetup, &spectrum_split, 1, log2blocksize, FFT_FORWARD);
                    vDSP_zvmags(&spectrum_split, 1, spectrum, 1, half_fft_size);
                    
                    /*------------------------------------------------------------------------------
                     * Normalise FFT values.
                     *----------------------------------------------------------------------------*/
                    float scale = 1.0 / fft_size;
                    vDSP_vsmul(spectrum, 1, &scale, spectrum, 1, half_fft_size);
                    
                    /*------------------------------------------------------------------------------
                     * Convert FFT to dB.
                     *----------------------------------------------------------------------------*/
                    float one = 1;
                    vDSP_vdbcon(spectrum, 1, &one, spectrum_db, 1, half_fft_size, 1);
                    
                    /*------------------------------------------------------------------------------
                     * Map magnitude spectrum to 24-bit pixels on the bitmap image.
                     *----------------------------------------------------------------------------*/
                    for (int y = 0; y < half_fft_size; y++)
                    {
                        /*------------------------------------------------------------------------------
                         * Scale [-96, 0dB] to [0, 1]
                         *----------------------------------------------------------------------------*/
                        float value = 1.0 + (spectrum_db[y] / 96.0);
                        if (value > 1) value = 1;
                        if (value < 0) value = 0;
                        
                        rgba[(y * 4 * (int) canvasSize.width) + (x * 4 + 0)] = (uint8_t) (value * 255);
                        rgba[(y * 4 * (int) canvasSize.width) + (x * 4 + 1)] = (uint8_t) (value * 255);
                        rgba[(y * 4 * (int) canvasSize.width) + (x * 4 + 2)] = (uint8_t) (value * 255);
                        rgba[(y * 4 * (int) canvasSize.width) + (x * 4 + 3)] = 0;
                    }
                }
                
                /*------------------------------------------------------------------------------
                 * Create bitmap image in RGB colour space.
                 *----------------------------------------------------------------------------*/
                CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
                CGContextRef bitmapContext = CGBitmapContextCreate(rgba,
                                                                   canvasSize.width,
                                                                   canvasSize.height,
                                                                   8, // bitsPerComponent
                                                                   4 * canvasSize.width,
                                                                   colorSpace,
                                                                   kCGImageAlphaNoneSkipLast);
                
                CFRelease(colorSpace);
                
                CGImageRef cgImage = CGBitmapContextCreateImage(bitmapContext);
                NSImage *nsImage = [[NSImage alloc] initWithCGImage:cgImage size:canvasSize];
                
                /*------------------------------------------------------------------------------
                 * Draw our image to the current context.
                 *----------------------------------------------------------------------------*/
                [nsImage drawInRect:NSMakeRect(0, canvasSize.height / 2, canvasSize.width, canvasSize.height)];
                
                [[NSColor colorWithWhite:1 alpha:0.2] set];
                
                /*
                for (int g = 0; g < reader.sampleRate / 2; g += 1000)
                {
                    float y = (canvasSize.height * 0.5) + (canvasSize.height * 0.5) * ((float) g / (reader.sampleRate / 2));
                    [NSBezierPath strokeLineFromPoint:NSMakePoint(0, y) toPoint:NSMakePoint(canvasSize.width, y)];
                }
                */

                [[NSColor colorWithWhite:1 alpha:1.0] set];
                for (int s = 0; s < reader.numFrames; s += reader.sampleRate)
                {
                    float x = canvasSize.width * ((float) s / reader.numFrames);
                    [NSBezierPath strokeLineFromPoint:NSMakePoint(x, 0)
                                              toPoint:NSMakePoint(x, canvasSize.height / 100)];
                }

                
                /*------------------------------------------------------------------------------
                 * Finally, clean up all memory allocations, and restore previous
                 * graphics context.
                 *----------------------------------------------------------------------------*/
                free(spectrum);
                free(spectrum_db);
                free(spectrum_split.realp);
                free(spectrum_split.imagp);
                free(window);
                free(windowed_data);
                free(rgba);
                vDSP_destroy_fftsetup(fftSetup);
                
                [NSGraphicsContext restoreGraphicsState];
            }
            
            QLPreviewRequestFlushContext(preview, cgContext);
            CFRelease(cgContext);
        }
    }
    return noErr;
}

void CancelPreviewGeneration(void *thisInterface, QLPreviewRequestRef preview)
{
}
