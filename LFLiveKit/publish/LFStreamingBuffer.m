//
//  LFStreamingBuffer.m
//  LFLiveKit
//
//  Created by LaiFeng on 16/5/20.
//  Copyright © 2016年 LaiFeng All rights reserved.
//

#import "LFStreamingBuffer.h"
#import "NSMutableArray+LFAdd.h"

static const NSUInteger defaultSortBufferMaxCount = 5;///< 排序10个内
static const NSUInteger defaultUpdateInterval = 1;///< 更新频率为1s
static const NSUInteger defaultCallBackInterval = 5;///< 5s计时一次
static const NSUInteger defaultSendBufferMaxCount = 600;///< 最大缓冲区为600

@interface LFStreamingBuffer (){
    dispatch_semaphore_t _lock;
}

@property (nonatomic, strong) NSMutableArray <LFFrame *> *sortList;
@property (nonatomic, strong, readwrite) NSMutableArray <LFFrame *> *mutableList;
@property (nonatomic, strong) NSMutableArray *thresholdList;

/** 处理buffer缓冲区情况 */
@property (nonatomic, assign) NSInteger currentInterval;
@property (nonatomic, assign) NSInteger callBackInterval;
@property (nonatomic, assign) NSInteger updateInterval;
@property (nonatomic, assign) BOOL startTimer;

@end

@implementation LFStreamingBuffer

- (instancetype)init {
    if (self = [super init]) {
        
        _lock = dispatch_semaphore_create(1);
        self.updateInterval = defaultUpdateInterval;
        self.callBackInterval = defaultCallBackInterval;
        self.maxCount = defaultSendBufferMaxCount;
        self.lastDropFrames = 0;
        self.startTimer = NO;
    }
    return self;
}

- (void)dealloc {
}

#pragma mark -- Custom

- (NSArray <LFFrame *> *_Nonnull)list {
  NSArray *list;
  @synchronized(self.mutableList) {
    list = [self.mutableList copy];
  }
  return list;
}

- (void)appendObject:(LFFrame *)frame {
  if (!frame)
    return;
  if (!_startTimer) {
    _startTimer = YES;
    [self tick];
  }

  dispatch_semaphore_wait(_lock, DISPATCH_TIME_FOREVER);
  if (self.sortList.count < defaultSortBufferMaxCount) {
    [self.sortList addObject:frame];
  } else {
    ///< 排序
    [self.sortList addObject:frame];
    [self.sortList sortUsingFunction:frameDataCompare context:nil];
    /// 丢帧
    [self removeExpireFrame];
    /// 添加至缓冲区
    LFFrame *firstFrame = [self.sortList lfPopFirstObject];

    if (firstFrame)
      @synchronized(self.mutableList) {
        [self.mutableList addObject:firstFrame];
      }
  }
  dispatch_semaphore_signal(_lock);
}

- (LFFrame *)popFirstObject {
  dispatch_semaphore_wait(_lock, DISPATCH_TIME_FOREVER);
  LFFrame *firstFrame;
  @synchronized (self.mutableList) {
    firstFrame = [self.mutableList lfPopFirstObject];
  }
  dispatch_semaphore_signal(_lock);
  return firstFrame;
}

- (void)removeAllObject {
  dispatch_semaphore_wait(_lock, DISPATCH_TIME_FOREVER);
  [self.sortList removeAllObjects];
  @synchronized (self.mutableList) {
    [self.mutableList removeAllObjects];
  }
  dispatch_semaphore_signal(_lock);
}

- (NSUInteger)size {
  dispatch_semaphore_wait(_lock, DISPATCH_TIME_FOREVER);
  __block NSUInteger size = 0;
  [self.list enumerateObjectsUsingBlock:^(LFFrame *item,
                                          NSUInteger idx,
                                          BOOL *stop) {
    size += item.size;
  }];
  dispatch_semaphore_signal(_lock);
  return size;
}


- (void)removeExpireFrame {
    if (self.list.count < self.maxCount) return;

    NSArray *pFrames = [self expirePFrames];///< 第一个P到第一个I之间的p帧
    self.lastDropFrames += [pFrames count];
    if (pFrames && pFrames.count > 0) {
        @synchronized (self.mutableList) {
          [self.mutableList removeObjectsInArray:pFrames];
        }
        return;
    }

    NSArray *iFrames = [self expireIFrames];///<  删除一个I帧（但一个I帧可能对应多个nal）
    self.lastDropFrames += [iFrames count];
    if (iFrames && iFrames.count > 0) {
        @synchronized (self.mutableList) {
          [self.mutableList removeObjectsInArray:iFrames];
        }
        return;
    }

    @synchronized (self.mutableList) {
      [self.mutableList removeAllObjects];
    }
}

- (NSArray *)expirePFrames {
    NSMutableArray *pframes = [[NSMutableArray alloc] init];
    for (NSInteger index = 0; index < self.list.count; index++) {
        LFFrame *frame = [self.list objectAtIndex:index];
        if ([frame isKindOfClass:[LFVideoFrame class]]) {
            LFVideoFrame *videoFrame = (LFVideoFrame *)frame;
            if (videoFrame.isKeyFrame && pframes.count > 0) {
                break;
            } else if (!videoFrame.isKeyFrame) {
                [pframes addObject:frame];
            }
        }
    }
    return pframes;
}

- (NSArray *)expireIFrames {
    NSMutableArray *iframes = [[NSMutableArray alloc] init];
    uint64_t timeStamp = 0;
    for (NSInteger index = 0; index < self.list.count; index++) {
        LFFrame *frame = [self.list objectAtIndex:index];
        if ([frame isKindOfClass:[LFVideoFrame class]] && ((LFVideoFrame *)frame).isKeyFrame) {
            if (timeStamp != 0 && timeStamp != frame.timestamp) break;
            [iframes addObject:frame];
            timeStamp = frame.timestamp;
        }
    }
    return iframes;
}

NSInteger frameDataCompare(id obj1, id obj2, void *context){
    LFFrame *frame1 = (LFFrame *)obj1;
    LFFrame *frame2 = (LFFrame *)obj2;

    if (frame1.timestamp == frame2.timestamp)
        return NSOrderedSame;
    else if (frame1.timestamp > frame2.timestamp)
        return NSOrderedDescending;
    return NSOrderedAscending;
}

- (LFLiveBufferState)currentBufferState {
    NSInteger currentCount = 0;
    NSInteger increaseCount = 0;
    NSInteger decreaseCount = 0;

    for (NSNumber *number in self.thresholdList) {
        if (number.integerValue > currentCount) {
            increaseCount++;
        } else{
            decreaseCount++;
        }
        currentCount = [number integerValue];
    }

    if (increaseCount >= self.callBackInterval) {
        return LFLiveBufferIncrease;
    }

    if (decreaseCount >= self.callBackInterval) {
        return LFLiveBufferDecline;
    }
    
    return LFLiveBufferUnknown;
}

#pragma mark -- Setter Getter
- (NSMutableArray *)mutableList {
    if (!_mutableList) {
      _mutableList = [[NSMutableArray alloc] init];
    }
    return _mutableList;
}

- (NSMutableArray *)sortList {
    if (!_sortList) {
        _sortList = [[NSMutableArray alloc] init];
    }
    return _sortList;
}

- (NSMutableArray *)thresholdList {
    if (!_thresholdList) {
        _thresholdList = [[NSMutableArray alloc] init];
    }
    return _thresholdList;
}

#pragma mark -- 采样
- (void)tick {
    /** 采样 3个阶段   如果网络都是好或者都是差给回调 */
    _currentInterval += self.updateInterval;

    dispatch_semaphore_wait(_lock, DISPATCH_TIME_FOREVER);
    [self.thresholdList addObject:@(self.list.count)];
    dispatch_semaphore_signal(_lock);

    if (self.currentInterval >= self.callBackInterval) {
        LFLiveBufferState state = [self currentBufferState];
        if (state == LFLiveBufferIncrease) {
            if (self.delegate && [self.delegate respondsToSelector:@selector(streamingBuffer:bufferState:)]) {
                [self.delegate streamingBuffer:self bufferState:LFLiveBufferIncrease];
            }
        } else if (state == LFLiveBufferDecline) {
            if (self.delegate && [self.delegate respondsToSelector:@selector(streamingBuffer:bufferState:)]) {
                [self.delegate streamingBuffer:self bufferState:LFLiveBufferDecline];
            }
        }

        self.currentInterval = 0;
        [self.thresholdList removeAllObjects];
    }
    __weak typeof(self) _self = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.updateInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(_self) self = _self;
        [self tick];
    });
}

@end
