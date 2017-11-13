//
//  LFVideoFrame.m
//  LFLiveKit
//
//  Created by LaiFeng on 16/5/20.
//  Copyright © 2016年 LaiFeng All rights reserved.
//

#import "LFVideoFrame.h"

@implementation LFVideoFrame
- (NSUInteger)size {
  return [super size] + self.sps.length + self.pps.length;
}

@end
