//
//  LFFrame.m
//  LFLiveKit
//
//  Created by LaiFeng on 16/5/20.
//  Copyright © 2016年 LaiFeng All rights reserved.
//

#import "LFFrame.h"

@implementation LFFrame

- (NSUInteger)size {
  return self.data.length + self.header.length;
}


@end
