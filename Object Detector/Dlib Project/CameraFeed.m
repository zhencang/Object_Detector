//
//  CameraFeed.m
//  Dlib Project
//
//  Created by Robert Sanders on 21/01/2017.
//  Copyright © 2017 Red Hand Technologies. All rights reserved.
//

#import "CameraFeed.h"

NSString * const kCameraID = @"com.apple.avfoundation.avcapturedevice.built-in_video:0";
NSString * const kWebcamID = @"com.apple.avfoundation.avcapturedevice.built-in_video:1";

#import <AVFoundation/AVFoundation.h>

@interface CameraFeed () <AVCaptureVideoDataOutputSampleBufferDelegate>

@property (nonatomic) BOOL isActive;
@property (nonatomic) CameraFeedPixelFormat pixelFormat;

@property (nonatomic, strong) AVCaptureSession *captureSession;

@end

@implementation CameraFeed

#pragma mark - Constructors

#pragma mark - Public

- (BOOL)openSessionForSource:(CameraSource)source prefferedPixelFormat:(CameraFeedPixelFormat)format error:(NSError *__autoreleasing  _Nullable *)error
{
    if (self.isActive) {
        if (error) {
            *error = [self errorWithMessage:@"Camera feed is already active."];
        }
        return NO;
    }
    
    self.captureSession = [[AVCaptureSession alloc] init];
    
    // device
    
    AVCaptureDevice *device = [self deviceForCameraSource:source];
    if (!device) {
        if (error) {
            *error = [self errorWithMessage:@"Failed to get device for camera source."];
        }
        self.captureSession = nil;
        return NO;
    }
    
    // input
    
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:error];
    if (!input) {
        return NO;
    }
    
    [self.captureSession addInput:input];
    
    // output
    
    AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
    
    dispatch_queue_t serial_queue = dispatch_queue_create("com.RedHand.serial_queue", DISPATCH_QUEUE_SERIAL);
    [output setSampleBufferDelegate:self queue:serial_queue];
    
    int pixelFormat = [self AVPixelFormatForFormat:format output:output];
    
    output.videoSettings = @{(__bridge id)kCVPixelBufferPixelFormatTypeKey: @(pixelFormat)};
    
    self.pixelFormat = [self formatForAVFormat:pixelFormat];
    
    [self.captureSession addOutput:output];
    
    return YES;
}

- (BOOL)openSessionForSource:(CameraSource)source error:(NSError *__autoreleasing  _Nullable *)error
{
    return [self openSessionForSource:source prefferedPixelFormat:CameraFeedPixelFormatBGRA error:error];
}

- (void)startStream
{
    if (self.isActive) {
        return;
    }
    
    self.isActive = YES;
    [self.captureSession startRunning];
}

- (void)stopStream
{
    if (!self.isActive) {
        return;
    }
    
    self.isActive = NO;
    [self.captureSession stopRunning];
}

#pragma mark - <AVCaptureVideoDataOutputSampleBufferDelegate>

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    // get base address of image buffer
    CVImageBufferRef tempBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    CVPixelBufferLockBaseAddress(tempBuffer, 0);
    
    //. get info
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(tempBuffer);
    size_t width = CVPixelBufferGetWidth(tempBuffer);
    size_t height = CVPixelBufferGetHeight(tempBuffer);
    unsigned char *rawData = (unsigned char *)CVPixelBufferGetBaseAddress(tempBuffer);
    
    // copy into own buffer
    unsigned char *buffer = (unsigned char *)malloc(bytesPerRow * height);
    memcpy(buffer, rawData, bytesPerRow * height);
    
    // release temp buffer
    CVPixelBufferUnlockBaseAddress(tempBuffer, 0);
    
    // create image frame
    core_image_format imageFormat = [self coreImageFormatForFormat:self.pixelFormat];
    core_image_frame *frame = core_image_create_frame(buffer, width, height, bytesPerRow / width, imageFormat);
    
    BOOL shouldReleaseBuffer = YES;
    if ([self.delegate respondsToSelector:@selector(cameraFeed:didRecieveImageData:)]) {
        shouldReleaseBuffer = NO;
        [self.delegate cameraFeed:self didRecieveImageData:frame];
    }
    
    if (self.handler) {
        self.handler(frame);
    }
    
    if (shouldReleaseBuffer) {
        core_image_release_frame(frame);
    }
}

#pragma mark - Private

- (NSError *)errorWithMessage:(NSString *)message
{
    NSDictionary *info = message ? @{NSLocalizedDescriptionKey: message} : nil;
    return [NSError errorWithDomain:@"CameraFeedDomain" code:CameraFeedErrorAlreadyActive userInfo:info];
}

- (AVCaptureDevice *)deviceForCameraSource:(CameraSource)source
{
    AVCaptureDevicePosition position = AVCaptureDevicePositionUnspecified;
    
    switch (source) {
        case CameraSourceCamera:
            position = AVCaptureDevicePositionBack;
            break;
        case CameraSourceWebcam:
            position = AVCaptureDevicePositionFront;
            break;
    }
    
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInDualCamera mediaType:AVMediaTypeVideo position:position];
    
    if (!device) {
        device = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera mediaType:AVMediaTypeVideo position:position];
    }
    
    return device;
}

- (int)AVPixelFormatForFormat:(CameraFeedPixelFormat)format output:(AVCaptureVideoDataOutput *)output
{
    int converted = -1;
    
    switch (format) {
        case CameraFeedPixelFormatBGRA:
            converted = kCVPixelFormatType_32BGRA;
            break;
        case CameraFeedPixelFormatBGR:
            converted = kCVPixelFormatType_24BGR;
            break;
        case CameraFeedPixelFormatRGB:
            converted = kCVPixelFormatType_24RGB;
            break;
        case CameraFeedPixelFormatRGBA:
            converted = kCVPixelFormatType_32RGBA;
            break;
        case CameraFeedPixelFormatGreyscale:
            converted = kCVPixelFormatType_16Gray;
            break;
        default:
            break;
    }
    
    // find if available otherwise default to BGRA
    for (NSNumber *num in output.availableVideoCVPixelFormatTypes) {
        if (num.intValue == converted) {
            return converted;
        }
    }
    
    return kCVPixelFormatType_32BGRA;
}

- (CameraFeedPixelFormat)formatForAVFormat:(int)AVFormat
{
    switch (AVFormat) {
        case kCVPixelFormatType_32BGRA:
            return CameraFeedPixelFormatBGRA;
        case kCVPixelFormatType_24BGR:
            return CameraFeedPixelFormatBGR;
        case kCVPixelFormatType_24RGB:
            return CameraFeedPixelFormatRGB;
        case kCVPixelFormatType_32RGBA:
            return CameraFeedPixelFormatRGBA;
        case kCVPixelFormatType_16Gray:
            return CameraFeedPixelFormatGreyscale;
        default:
            break;
    }
    
    return -1;
}

- (core_image_format)coreImageFormatForFormat:(CameraFeedPixelFormat)format
{
    switch (format) {
        case CameraFeedPixelFormatBGR:
            return kCoreImageFormat_bgr;
        case CameraFeedPixelFormatRGB:
            return kCoreImageFormat_rgb;
        case CameraFeedPixelFormatBGRA:
            return kCoreImageFormat_bgra;
        case CameraFeedPixelFormatRGBA:
            return kCoreImageFormat_rgba;
        case CameraFeedPixelFormatGreyscale:
            return kCoreImageFormat_greyscale;
    }
    
    return -1;
}


@end










