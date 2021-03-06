//
//  LFStreamSocket.h
//  LFLiveKit
//
//  Created by LaiFeng on 16/5/20.
//  Copyright © 2016年 LaiFeng All rights reserved.
//

#import <Foundation/Foundation.h>
#import "LFLiveStreamInfo.h"
#import "LFStreamingBuffer.h"
#import "LFLiveDebug.h"
#import "LFLiveStreamDataDeliverySample.h"


@protocol LFStreamSocket;
@protocol LFStreamSocketDelegate <NSObject>

/** callback buffer current status (回调当前缓冲区情况，可实现相关切换帧率 码率等策略)*/
- (void)socketBufferStatus:(nullable id <LFStreamSocket>)socket status:(LFLiveBufferState)status;
/** callback socket current status (回调当前网络情况) */
- (void)socketStatus:(nullable id <LFStreamSocket>)socket status:(LFLiveState)status;
/** callback socket errorcode */
- (void)socket:(nullable id<LFStreamSocket>)socket didFailWithError:(NSError *)error;
@optional
/** callback debugInfo */
- (void)socketDebug:(nullable id <LFStreamSocket>)socket debugInfo:(nullable LFLiveDebug *)debugInfo;
@end

@protocol LFStreamSocket <NSObject>
@property (nonatomic, assign) NSUInteger latency;
@property (nonatomic, copy) LFLiveStreamDataDeliverySampleUpdateBlock dataDeliverySampleUpdateBlock;
@property (nonatomic, assign) NSTimeInterval streamDataDeliveryUpdateInterval;
- (void)start;
- (void)stop:(BOOL)flushPendingFrames completion:(void (^)())completion;
- (void)sendFrame:(nullable LFFrame *)frame;
- (void)flushBuffer;
- (void)setDelegate:(nullable id <LFStreamSocketDelegate>)delegate;
@optional
- (nullable instancetype)initWithStream:(nullable LFLiveStreamInfo *)stream;
- (nullable instancetype)initWithStream:(nullable LFLiveStreamInfo *)stream reconnectInterval:(NSInteger)reconnectInterval reconnectCount:(NSInteger)reconnectCount;
@end
