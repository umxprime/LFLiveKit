//
// Created by Giroptic on 13/11/2017.
// Copyright (c) 2017 Giroptic. All rights reserved.
//
#import "LFLiveStreamDataDeliverySample.h"


@implementation LFLiveStreamDataDeliverySample
- (id)copy {
  LFLiveStreamDataDeliverySample *copy = [LFLiveStreamDataDeliverySample new];

  if (copy != nil) {
    copy.videoBytesSent = self.videoBytesSent;
    copy.timeInterval = self.timeInterval;
    copy.pendingBytes = self.pendingBytes;
  }

  return copy;
}
@end