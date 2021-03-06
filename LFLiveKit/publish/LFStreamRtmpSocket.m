//
//  LFStreamRTMPSocket.m
//  LFLiveKit
//
//  Created by LaiFeng on 16/5/20.
//  Copyright © 2016年 LaiFeng All rights reserved.
//

#import "LFStreamRTMPSocket.h"

#if __has_include(<pili-librtmp/rtmp.h>)
#import <pili-librtmp/rtmp.h>
#else
#import "rtmp.h"
#import "LFLiveKit.h"
#endif

static const NSInteger RetryTimesBreaken = 5;  ///<  重连1分钟  3秒一次 一共20次
static const NSInteger RetryTimesMargin = 3;

NSErrorDomain const kLFStreamRTMPSocketErrorDomain = @"RTMP Stream Socket";

#define RTMP_RECEIVE_TIMEOUT    2
#define DATA_ITEMS_MAX_COUNT 100
#define RTMP_DATA_RESERVE_SIZE 400
#define RTMP_HEAD_SIZE (sizeof(RTMPPacket) + RTMP_MAX_HEADER_SIZE)

#define SAVC(x)    static const AVal av_ ## x = AVC(#x)

static const AVal av_setDataFrame = AVC("@setDataFrame");
static const AVal av_SDKVersion = AVC("LFLiveKit 2.4.0");
SAVC(onMetaData);
SAVC(duration);
SAVC(width);
SAVC(height);
SAVC(videocodecid);
SAVC(videodatarate);
SAVC(framerate);
SAVC(audiocodecid);
SAVC(audiodatarate);
SAVC(audiosamplerate);
SAVC(audiosamplesize);
//SAVC(audiochannels);
SAVC(stereo);
SAVC(encoder);
//SAVC(av_stereo);
SAVC(fileSize);
SAVC(avc1);
SAVC(mp4a);

void RTMPErrorCallback(RTMPError *rtmpError, void *userData) ;
void ConnectionTimeCallback(PILI_CONNECTION_TIME *conn_time, void *userData) ;
@interface LFStreamRTMPSocket ()<LFStreamingBufferDelegate>
{
    PILI_RTMP *_rtmp;
}
@property (nonatomic, weak) id<LFStreamSocketDelegate> delegate;
@property (nonatomic, strong) LFLiveStreamInfo *stream;
@property (nonatomic, strong) LFStreamingBuffer *buffer;
@property (nonatomic, strong) LFLiveDebug *debugInfo;
//错误信息
@property (nonatomic, assign) RTMPError error;
@property (nonatomic, assign) NSInteger retryTimes4netWorkBreaken;
@property (nonatomic, assign) NSInteger reconnectInterval;
@property (nonatomic, assign) NSInteger reconnectCount;

@property (atomic, assign) BOOL isSending;
@property (nonatomic, assign) BOOL isConnected;
@property (nonatomic, assign) BOOL isConnecting;
@property (nonatomic, assign) BOOL isReconnecting;

@property (nonatomic, assign) BOOL sendVideoHead;
@property (nonatomic, assign) BOOL sendAudioHead;
@property(nonatomic) BOOL shouldFlushBuffer;
@property(nonatomic, strong)
    LFLiveStreamDataDeliverySample *dataDeliverySample;
@property(nonatomic) CFTimeInterval lastStreamDataUpdateTS;
@property(nonatomic, strong) NSTimer *liveStreamDataDeliveryUpdateTimer;
@end

@implementation LFStreamRTMPSocket {
    NSOperationQueue *_rtmpSendQueue;
}
@synthesize latency = _latency,
            dataDeliverySampleUpdateBlock = _bufferInfosUpdateBlock,
            streamDataDeliveryUpdateInterval = _liveStreamDataDeliveryInterval;

#pragma mark -- LFStreamSocket
- (nullable instancetype)initWithStream:(nullable LFLiveStreamInfo *)stream{
    return [self initWithStream:stream reconnectInterval:0 reconnectCount:0];
}

- (nullable instancetype)initWithStream:(nullable LFLiveStreamInfo *)stream reconnectInterval:(NSInteger)reconnectInterval reconnectCount:(NSInteger)reconnectCount{
    if (!stream) @throw [NSException exceptionWithName:@"LFStreamRtmpSocket init error" reason:@"stream is nil" userInfo:nil];
    if (self = [super init]) {
        _stream = stream;
        if (reconnectInterval > 0) _reconnectInterval = reconnectInterval;
        else _reconnectInterval = RetryTimesMargin;
        
        if (reconnectCount > 0) _reconnectCount = reconnectCount;
        else _reconnectCount = RetryTimesBreaken;
        
        [self addObserver:self forKeyPath:@"isSending" options:NSKeyValueObservingOptionNew context:nil];//这里改成observer主要考虑一直到发送出错情况下，可以继续发送
        self.latency = 30000;
    }
    return self;
}

- (void)dealloc{
    [self removeObserver:self forKeyPath:@"isSending"];
}

- (void)start {
    __weak typeof(self) weakSelf = self;
    [self.rtmpSendQueue addOperationWithBlock:^{
      [weakSelf _start];
    }];
    self.lastStreamDataUpdateTS = 0;
    [self.liveStreamDataDeliveryUpdateTimer invalidate];
    self.liveStreamDataDeliveryUpdateTimer = [NSTimer
        scheduledTimerWithTimeInterval:self.streamDataDeliveryUpdateInterval
                                target:self
                              selector:@selector(streamDataDeliveryUpdate:)
                              userInfo:nil
                               repeats:YES];
}

- (void)streamDataDeliveryUpdate:(NSTimer *)timer {
  if (self.dataDeliverySampleUpdateBlock) {
    @synchronized(self.dataDeliverySample) {
        if (self.dataDeliverySample) {
            self.dataDeliverySampleUpdateBlock([self.dataDeliverySample copy]);
        }
        self.dataDeliverySample = nil;
    }
  }
}

- (void)_start {
    if (!_stream) return;
    if (_isConnecting) return;
    if (_rtmp != NULL) return;
    self.debugInfo.streamId = self.stream.streamId;
    self.debugInfo.uploadUrl = self.stream.url;
    self.debugInfo.isRtmp = YES;
    if (_isConnecting) return;
    
    _isConnecting = YES;
    if (self.delegate && [self.delegate respondsToSelector:@selector(socketStatus:status:)]) {
        [self.delegate socketStatus:self status:LFLivePending];
    }
    
    if (_rtmp != NULL) {
        PILI_RTMP_Close(_rtmp, &_error);
        PILI_RTMP_Free(_rtmp);
    }
    [self RTMP264_Connect:(char *)[_stream.url cStringUsingEncoding:NSASCIIStringEncoding]];
}

- (void)stop:(BOOL)flushPendingFrames completion:(void (^)())completion {
    [self.liveStreamDataDeliveryUpdateTimer invalidate];
    @synchronized (self.dataDeliverySample) {
      self.dataDeliverySample = nil;
    }
    if (flushPendingFrames) {
        [self.rtmpSendQueue cancelAllOperations];
    }
    __block LFStreamRTMPSocket *blockSelf = self;
    [self.rtmpSendQueue addOperationWithBlock:^{
      [blockSelf _stop];
      [NSObject cancelPreviousPerformRequestsWithTarget:blockSelf];
      blockSelf = nil;
      if (completion) {
          dispatch_async(dispatch_get_main_queue(), ^{
            completion();
          });
      }
    }];
}

- (void)_stop {
    if (self.delegate && [self.delegate respondsToSelector:@selector(socketStatus:status:)]) {
        [self.delegate socketStatus:self status:LFLiveStop];
    }
    if (_rtmp != NULL) {
        PILI_RTMP_Close(_rtmp, &_error);
        PILI_RTMP_Free(_rtmp);
        _rtmp = NULL;
    }
    [self clean];
}

- (void)sendFrame:(LFFrame *)frame {
    if (!frame) return;
    [self.buffer appendObject:frame];
    
    if(!self.isSending){
        [self sendFrame];
    }
}

- (void)flushBuffer {
  @synchronized (self) {
    self.shouldFlushBuffer = YES;
  }
}

- (void)setDelegate:(id<LFStreamSocketDelegate>)delegate {
    _delegate = delegate;
}

#pragma mark -- CustomMethod
- (void)sendFrame {
    __weak typeof(self) weakSelf = self;
    [self.rtmpSendQueue addOperationWithBlock:^{
      if(weakSelf.shouldFlushBuffer) {
          weakSelf.shouldFlushBuffer = NO;
          [weakSelf.buffer removeAllObject];
      }
      if (!weakSelf.isSending && weakSelf.buffer.list.count > 0) {
          weakSelf.isSending = YES;

          if (!weakSelf.isConnected || weakSelf.isReconnecting || weakSelf.isConnecting || !_rtmp){
              weakSelf.isSending = NO;
              return;
          }

          // 调用发送接口
          LFFrame *frame = [weakSelf.buffer popFirstObject];
          if ([frame isKindOfClass:[LFVideoFrame class]]) {
              if (!weakSelf.sendVideoHead) {
                  weakSelf.sendVideoHead = YES;
                  if(!((LFVideoFrame*)frame).sps || !((LFVideoFrame*)frame).pps){
                      weakSelf.isSending = NO;
                      return;
                  }

                  weakSelf.lastStreamDataUpdateTS = CACurrentMediaTime();
                  [weakSelf sendVideoHeader:(LFVideoFrame *)frame];
                  [weakSelf sendVideo:(LFVideoFrame *)frame];
              } else {
                  [weakSelf sendVideo:(LFVideoFrame *)frame];
              }
          } else {
              if (!weakSelf.sendAudioHead) {
                  weakSelf.sendAudioHead = YES;
                  if(!((LFAudioFrame*)frame).audioInfo){
                      weakSelf.isSending = NO;
                      return;
                  }
                  [weakSelf sendAudioHeader:(LFAudioFrame *)frame];
                  [weakSelf sendAudio:frame];
              } else {
                  [weakSelf sendAudio:frame];
              }
          }

          if (weakSelf.dataDeliverySampleUpdateBlock &&
            [frame isKindOfClass:[LFVideoFrame class]]) {
              @synchronized(weakSelf.dataDeliverySample) {
                  if (!weakSelf.dataDeliverySample) {
                      weakSelf.dataDeliverySample =
                        [LFLiveStreamDataDeliverySample new];
                  }
                  weakSelf.dataDeliverySample.videoBytesSent += frame.size;
                  weakSelf.dataDeliverySample.pendingBytes = weakSelf.buffer.size;
                  if (weakSelf.lastStreamDataUpdateTS != 0) {
                      weakSelf.dataDeliverySample.timeInterval +=
                        CACurrentMediaTime() - weakSelf.lastStreamDataUpdateTS;
                  }
                  weakSelf.lastStreamDataUpdateTS = CACurrentMediaTime();
              }
          }

          //debug更新
          weakSelf.debugInfo.totalFrame++;
          weakSelf.debugInfo.dropFrame += weakSelf.buffer.lastDropFrames;
          weakSelf.buffer.lastDropFrames = 0;

          weakSelf.debugInfo.dataFlow += frame.data.length;
          weakSelf.debugInfo.elapsedMilli = CACurrentMediaTime() * 1000 - weakSelf.debugInfo.timeStamp;
          if (weakSelf.debugInfo.elapsedMilli < 1000) {
              weakSelf.debugInfo.bandwidth += frame.data.length;
              if ([frame isKindOfClass:[LFAudioFrame class]]) {
                  weakSelf.debugInfo.capturedAudioCount++;
              } else {
                  weakSelf.debugInfo.capturedVideoCount++;
              }

              weakSelf.debugInfo.unSendCount = weakSelf.buffer.list.count;
          } else {
              weakSelf.debugInfo.currentBandwidth = weakSelf.debugInfo.bandwidth;
              weakSelf.debugInfo.currentCapturedAudioCount = weakSelf.debugInfo.capturedAudioCount;
              weakSelf.debugInfo.currentCapturedVideoCount = weakSelf.debugInfo.capturedVideoCount;
              if (weakSelf.delegate && [weakSelf.delegate respondsToSelector:@selector(socketDebug:debugInfo:)]) {
                  [weakSelf.delegate socketDebug:weakSelf debugInfo:weakSelf.debugInfo];
              }
              weakSelf.debugInfo.bandwidth = 0;
              weakSelf.debugInfo.capturedAudioCount = 0;
              weakSelf.debugInfo.capturedVideoCount = 0;
              weakSelf.debugInfo.timeStamp = CACurrentMediaTime() * 1000;
          }

          //修改发送状态
          dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            //< 这里只为了不循环调用sendFrame方法 调用栈是保证先出栈再进栈
            weakSelf.isSending = NO;
          });

      }
    }];
}

- (void)clean {
    _isConnecting = NO;
    _isReconnecting = NO;
    _isSending = NO;
    _isConnected = NO;
    _sendAudioHead = NO;
    _sendVideoHead = NO;
    self.debugInfo = nil;
    [self.buffer removeAllObject];
    self.retryTimes4netWorkBreaken = 0;
}

- (NSInteger)RTMP264_Connect:(char *)push_url {
    //由于摄像头的timestamp是一直在累加，需要每次得到相对时间戳
    //分配与初始化
    _rtmp = PILI_RTMP_Alloc();
    PILI_RTMP_Init(_rtmp);

    //设置URL
    if (PILI_RTMP_SetupURL(_rtmp, push_url, &_error) == FALSE) {
        //log(LOG_ERR, "RTMP_SetupURL() failed!");
        goto Failed;
    }

    _rtmp->m_errorCallback = RTMPErrorCallback;
    _rtmp->m_connCallback = ConnectionTimeCallback;
    _rtmp->m_userData = (__bridge void *)self;
    _rtmp->m_msgCounter = 1;
    _rtmp->Link.timeout = RTMP_RECEIVE_TIMEOUT;
    _rtmp->m_nBufferMS = _latency;

    //设置可写，即发布流，这个函数必须在连接前使用，否则无效
    PILI_RTMP_EnableWrite(_rtmp);

    //连接服务器
    if (PILI_RTMP_Connect(_rtmp, NULL, &_error) == FALSE) {
        goto Failed;
    }

    //连接流
    if (PILI_RTMP_ConnectStream(_rtmp, 0, &_error) == FALSE) {
        goto Failed;
    }

    if (self.delegate && [self.delegate respondsToSelector:@selector(socketStatus:status:)]) {
        [self.delegate socketStatus:self status:LFLiveStart];
    }

    [self sendMetaData];

    _isConnected = YES;
    _isConnecting = NO;
    _isReconnecting = NO;
    _isSending = NO;
    return 0;

Failed:
    PILI_RTMP_Close(_rtmp, &_error);
    PILI_RTMP_Free(_rtmp);
    _rtmp = NULL;
    NSString *message = [NSString stringWithCString:_error.message
                                           encoding:NSUTF8StringEncoding];
    NSError *error =
        [NSError errorWithDomain:kLFStreamRTMPSocketErrorDomain
                            code:_error.code
                        userInfo:@{NSLocalizedDescriptionKey : message}];
    [self reconnectWithError:error];
    return -1;
}

#pragma mark -- Rtmp Send

- (void)sendMetaData {
    PILI_RTMPPacket packet;

    char pbuf[2048], *pend = pbuf + sizeof(pbuf);

    packet.m_nChannel = 0x03;                   // control channel (invoke)
    packet.m_headerType = RTMP_PACKET_SIZE_LARGE;
    packet.m_packetType = RTMP_PACKET_TYPE_INFO;
    packet.m_nTimeStamp = 0;
    packet.m_nInfoField2 = _rtmp->m_stream_id;
    packet.m_hasAbsTimestamp = TRUE;
    packet.m_body = pbuf + RTMP_MAX_HEADER_SIZE;

    char *enc = packet.m_body;
    enc = AMF_EncodeString(enc, pend, &av_setDataFrame);
    enc = AMF_EncodeString(enc, pend, &av_onMetaData);

    *enc++ = AMF_OBJECT;

    enc = AMF_EncodeNamedNumber(enc, pend, &av_duration, 0.0);
    enc = AMF_EncodeNamedNumber(enc, pend, &av_fileSize, 0.0);

    // videosize
    enc = AMF_EncodeNamedNumber(enc, pend, &av_width, _stream.videoConfiguration.videoSize.width);
    enc = AMF_EncodeNamedNumber(enc, pend, &av_height, _stream.videoConfiguration.videoSize.height);

    // video
    enc = AMF_EncodeNamedString(enc, pend, &av_videocodecid, &av_avc1);

    enc = AMF_EncodeNamedNumber(enc, pend, &av_videodatarate, _stream.videoConfiguration.videoBitRate / 1000.f);
    enc = AMF_EncodeNamedNumber(enc, pend, &av_framerate, _stream.videoConfiguration.videoFrameRate);

    // audio
    enc = AMF_EncodeNamedString(enc, pend, &av_audiocodecid, &av_mp4a);
    enc = AMF_EncodeNamedNumber(enc, pend, &av_audiodatarate, _stream.audioConfiguration.audioBitrate);

    enc = AMF_EncodeNamedNumber(enc, pend, &av_audiosamplerate, _stream.audioConfiguration.audioSampleRate);
    enc = AMF_EncodeNamedNumber(enc, pend, &av_audiosamplesize, 16.0);
    enc = AMF_EncodeNamedBoolean(enc, pend, &av_stereo, _stream.audioConfiguration.numberOfChannels == 2);

    // sdk version
    enc = AMF_EncodeNamedString(enc, pend, &av_encoder, &av_SDKVersion);

    *enc++ = 0;
    *enc++ = 0;
    *enc++ = AMF_OBJECT_END;

    packet.m_nBodySize = (uint32_t)(enc - packet.m_body);
    if (!PILI_RTMP_SendPacket(_rtmp, &packet, FALSE, &_error)) {
        return;
    }
}

- (void)sendVideoHeader:(LFVideoFrame *)videoFrame {

    unsigned char *body = NULL;
    NSInteger iIndex = 0;
    NSInteger rtmpLength = 1024;
    const char *sps = videoFrame.sps.bytes;
    const char *pps = videoFrame.pps.bytes;
    NSInteger sps_len = videoFrame.sps.length;
    NSInteger pps_len = videoFrame.pps.length;

    body = (unsigned char *)malloc(rtmpLength);
    memset(body, 0, rtmpLength);

    body[iIndex++] = 0x17;
    body[iIndex++] = 0x00;

    body[iIndex++] = 0x00;
    body[iIndex++] = 0x00;
    body[iIndex++] = 0x00;

    body[iIndex++] = 0x01;
    body[iIndex++] = sps[1];
    body[iIndex++] = sps[2];
    body[iIndex++] = sps[3];
    body[iIndex++] = 0xff;

    /*sps*/
    body[iIndex++] = 0xe1;
    body[iIndex++] = (sps_len >> 8) & 0xff;
    body[iIndex++] = sps_len & 0xff;
    memcpy(&body[iIndex], sps, sps_len);
    iIndex += sps_len;

    /*pps*/
    body[iIndex++] = 0x01;
    body[iIndex++] = (pps_len >> 8) & 0xff;
    body[iIndex++] = (pps_len) & 0xff;
    memcpy(&body[iIndex], pps, pps_len);
    iIndex += pps_len;

    [self sendPacket:RTMP_PACKET_TYPE_VIDEO data:body size:iIndex nTimestamp:0];
    free(body);
}

- (void)sendVideo:(LFVideoFrame *)frame {

    NSInteger i = 0;
    NSInteger rtmpLength = frame.data.length + 9;
    unsigned char *body = (unsigned char *)malloc(rtmpLength);
    memset(body, 0, rtmpLength);

    if (frame.isKeyFrame) {
        body[i++] = 0x17;        // 1:Iframe  7:AVC
    } else {
        body[i++] = 0x27;        // 2:Pframe  7:AVC
    }
    body[i++] = 0x01;    // AVC NALU
    body[i++] = 0x00;
    body[i++] = 0x00;
    body[i++] = 0x00;
    body[i++] = (frame.data.length >> 24) & 0xff;
    body[i++] = (frame.data.length >> 16) & 0xff;
    body[i++] = (frame.data.length >>  8) & 0xff;
    body[i++] = (frame.data.length) & 0xff;
    memcpy(&body[i], frame.data.bytes, frame.data.length);

    [self sendPacket:RTMP_PACKET_TYPE_VIDEO data:body size:(rtmpLength) nTimestamp:frame.timestamp];
    free(body);
}

- (NSInteger)sendPacket:(unsigned int)nPacketType data:(unsigned char *)data size:(NSInteger)size nTimestamp:(uint64_t)nTimestamp {
    NSInteger rtmpLength = size;
    PILI_RTMPPacket rtmp_pack;
    PILI_RTMPPacket_Reset(&rtmp_pack);
    PILI_RTMPPacket_Alloc(&rtmp_pack, (uint32_t)rtmpLength);

    rtmp_pack.m_nBodySize = (uint32_t)size;
    memcpy(rtmp_pack.m_body, data, size);
    rtmp_pack.m_hasAbsTimestamp = 0;
    rtmp_pack.m_packetType = nPacketType;
    if (_rtmp) rtmp_pack.m_nInfoField2 = _rtmp->m_stream_id;
    rtmp_pack.m_nChannel = 0x04;
    rtmp_pack.m_headerType = RTMP_PACKET_SIZE_LARGE;
    if (RTMP_PACKET_TYPE_AUDIO == nPacketType && size != 4) {
        rtmp_pack.m_headerType = RTMP_PACKET_SIZE_MEDIUM;
    }
    rtmp_pack.m_nTimeStamp = (uint32_t)nTimestamp;

    NSInteger nRet = [self RtmpPacketSend:&rtmp_pack];

    PILI_RTMPPacket_Free(&rtmp_pack);
    return nRet;
}

- (NSInteger)RtmpPacketSend:(PILI_RTMPPacket *)packet {
    if (_rtmp && PILI_RTMP_IsConnected(_rtmp)) {
        int success = PILI_RTMP_SendPacket(_rtmp, packet, 0, &_error);
        return success;
    }
    return -1;
}

- (void)sendAudioHeader:(LFAudioFrame *)audioFrame {

    NSInteger rtmpLength = audioFrame.audioInfo.length + 2;     /*spec data长度,一般是2*/
    unsigned char *body = (unsigned char *)malloc(rtmpLength);
    memset(body, 0, rtmpLength);

    /*AF 00 + AAC RAW data*/
    body[0] = 0xAF;
    body[1] = 0x00;
    memcpy(&body[2], audioFrame.audioInfo.bytes, audioFrame.audioInfo.length);          /*spec_buf是AAC sequence header数据*/
    [self sendPacket:RTMP_PACKET_TYPE_AUDIO data:body size:rtmpLength nTimestamp:0];
    free(body);
}

- (void)sendAudio:(LFFrame *)frame {

    NSInteger rtmpLength = frame.data.length + 2;    /*spec data长度,一般是2*/
    unsigned char *body = (unsigned char *)malloc(rtmpLength);
    memset(body, 0, rtmpLength);

    /*AF 01 + AAC RAW data*/
    body[0] = 0xAF;
    body[1] = 0x01;
    memcpy(&body[2], frame.data.bytes, frame.data.length);
    [self sendPacket:RTMP_PACKET_TYPE_AUDIO data:body size:rtmpLength nTimestamp:frame.timestamp];
    free(body);
}

// 断线重连
- (void)reconnectWithError:(NSError *)error {
    __weak typeof(self) weakSelf = self;
    [self.rtmpSendQueue addOperationWithBlock:^{
      if (weakSelf.retryTimes4netWorkBreaken++ < weakSelf.reconnectCount && !weakSelf.isReconnecting) {
          weakSelf.isConnected = NO;
          weakSelf.isConnecting = NO;
          weakSelf.isReconnecting = YES;
          dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf performSelector:@selector(_reconnect) withObject:nil afterDelay:weakSelf.reconnectInterval];
          });

      } else if (weakSelf.retryTimes4netWorkBreaken >= weakSelf.reconnectCount) {
          if (weakSelf.delegate && [weakSelf.delegate respondsToSelector:@selector(socketStatus:status:)]) {
              [weakSelf.delegate socketStatus:weakSelf status:LFLiveError];
          }
          if ([weakSelf.delegate
            respondsToSelector:@selector(socket:didFailWithError:)]) {
              NSDictionary *const userInfos = @{
                NSLocalizedDescriptionKey : @"Connection retry timed out.",
                NSUnderlyingErrorKey : error ? error : [[NSError alloc] init]
              };
              NSError *reconnectError =
                [NSError errorWithDomain:kLFStreamRTMPSocketErrorDomain
                                    code:LFLiveSocketError_ReConnectTimeOut
                                userInfo:userInfos];
              [weakSelf.delegate socket:weakSelf didFailWithError:reconnectError];
          }
      }
    }];
}

- (void)_reconnect{
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    
    _isReconnecting = NO;
    if(_isConnected) return;
    
    _isReconnecting = NO;
    if (_isConnected) return;
    if (_rtmp != NULL) {
        PILI_RTMP_Close(_rtmp, &_error);
        PILI_RTMP_Free(_rtmp);
        _rtmp = NULL;
    }
    _sendAudioHead = NO;
    _sendVideoHead = NO;
    
    if (self.delegate && [self.delegate respondsToSelector:@selector(socketStatus:status:)]) {
        [self.delegate socketStatus:self status:LFLiveRefresh];
    }
    
    if (_rtmp != NULL) {
        PILI_RTMP_Close(_rtmp, &_error);
        PILI_RTMP_Free(_rtmp);
    }
    [self RTMP264_Connect:(char *)[_stream.url cStringUsingEncoding:NSASCIIStringEncoding]];
}

#pragma mark -- CallBack
void RTMPErrorCallback(RTMPError *rtmpError, void *userData) {
  LFStreamRTMPSocket *socket = (__bridge LFStreamRTMPSocket *)userData;
  if (rtmpError && rtmpError->code < 0) {
    NSString *const description =
        rtmpError->message ? [NSString stringWithCString:rtmpError->message
                                                encoding:NSUTF8StringEncoding]
                           : @"";
    NSError *error =
        [NSError errorWithDomain:kLFStreamRTMPSocketErrorDomain
                            code:rtmpError->code
                        userInfo:@{NSLocalizedDescriptionKey : description}];
    [socket reconnectWithError:error];
  }
}

void ConnectionTimeCallback(PILI_CONNECTION_TIME *conn_time, void *userData) {
}

#pragma mark -- LFStreamingBufferDelegate
- (void)streamingBuffer:(nullable LFStreamingBuffer *)buffer bufferState:(LFLiveBufferState)state{
    if(self.delegate && [self.delegate respondsToSelector:@selector(socketBufferStatus:status:)]){
        [self.delegate socketBufferStatus:self status:state];
    }
}

#pragma mark -- Observer
-(void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context{
    if([keyPath isEqualToString:@"isSending"]){
        if(!self.isSending){
            [self sendFrame];
        }
    }
}

#pragma mark -- Getter Setter

- (LFStreamingBuffer *)buffer {
    if (!_buffer) {
        _buffer = [[LFStreamingBuffer alloc] init];
        _buffer.delegate = self;

    }
    return _buffer;
}

- (LFLiveDebug *)debugInfo {
    if (!_debugInfo) {
        _debugInfo = [[LFLiveDebug alloc] init];
    }
    return _debugInfo;
}

- (NSOperationQueue*)rtmpSendQueue{
    if(!_rtmpSendQueue){
        _rtmpSendQueue = [NSOperationQueue new];
        _rtmpSendQueue.maxConcurrentOperationCount = 1;
        _rtmpSendQueue.qualityOfService = NSQualityOfServiceDefault;
    }
    return _rtmpSendQueue;
}

@end
