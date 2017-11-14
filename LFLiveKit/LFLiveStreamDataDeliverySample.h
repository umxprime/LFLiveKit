//
// Created by Giroptic on 13/11/2017.
// Copyright (c) 2017 Giroptic. All rights reserved.
//
#import <Foundation/Foundation.h>

@class LFLiveStreamDataDeliverySample;

typedef void (^LFLiveStreamDataDeliverySampleUpdateBlock)(
  LFLiveStreamDataDeliverySample *sample);

/**
 * Infos regarding the data delivery to the stream.
 */
@interface LFLiveStreamDataDeliverySample : NSObject
/// Video bytes delivered.
@property(nonatomic, assign) NSUInteger videoBytesSent;

/// Time interval in seconds elapsed to deliver the video bytes.
@property(nonatomic, assign) NSTimeInterval timeInterval;

/// Bytes left in buffer.
@property(nonatomic, assign) NSUInteger pendingBytes;
@end