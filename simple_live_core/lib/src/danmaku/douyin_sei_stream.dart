/// 抖音旁路 FLV 连接：拉同一播放流，解析 SEI 布局喂给回调。
///
/// 设计约定（2026-09-18 定稿）：
/// - 不做 Isolate：SEI 约 2s 一条，解析为轻量字节扫描，主 Isolate 开销可忽略。
/// - 不自取流地址：复用调用方已解析好的 FLV URL（LiveRoomDetail.data），
///   避免二次 API 请求触发风控。
/// - 全程静默失败：任何异常只关连接，绝不影响播放（mpv 用自己的连接）。
/// - URL 失效（403/404/5xx）：按 [retryInterval] 重试，由外部在换房/停止时 stop。
library;

import 'dart:async';
import 'dart:io';

import 'douyin_sei.dart';

class DouyinSeiStream {
  final DouyinSeiParser _parser = DouyinSeiParser();
  HttpClient? _client;
  HttpClientRequest? _request;
  HttpClientResponse? _response;
  StreamSubscription<List<int>>? _subscription;
  Timer? _retryTimer;
  bool _stopped = true;
  int _retryCount = 0;

  static const retryInterval = Duration(seconds: 5);
  static const maxRetry = 6;

  /// 流 URL（flv_pull_url 中的低清地址即可，SEI 与清晰度无关）
  String? url;

  /// 请求头（复用站点的 cookie）
  Map<String, String> headers = {};

  /// 解析出新布局时回调（约 2s 一次，仅在内容变化时才有意义）
  void Function(SeiLayout layout)? onLayout;

  /// 生命周期事件（retry/give-up 等），供上层写诊断日志
  void Function(String event)? onEvent;

  /// 重试上限用尽放弃（URL 失效/流已轮换），上层应换新 URL 后重新 start
  void Function()? onGiveUp;

  bool get running => !_stopped;

  Future<void> start(String flvUrl, {Map<String, String>? requestHeaders}) async {
    url = flvUrl;
    headers = requestHeaders ?? const {};
    _stopped = false;
    _retryCount = 0;
    await _connect();
  }

  Future<void> _connect() async {
    if (_stopped || url == null || url!.isEmpty) return;
    try {
      _client = HttpClient();
      _client!.connectionTimeout = const Duration(seconds: 10);
      _client!.autoUncompress = false;
      final req = await _client!.getUrl(Uri.parse(url!));
      headers.forEach((k, v) => req.headers.set(k, v));
      _request = req;
      final resp = await req.close().timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        await _closeTransport();
        _scheduleRetry();
        return;
      }
      _response = resp;
      _retryCount = 0;
      _subscription = resp.listen(
        (chunk) {
          try {
            final layout = _parser.feed(chunk);
            if (layout != null) {
              onLayout?.call(layout);
            }
          } catch (_) {
            // 解析异常不中断连接，解析器内部状态自恢复
          }
        },
        onError: (_) => _scheduleRetry(),
        onDone: () => _scheduleRetry(),
        cancelOnError: true,
      );
    } catch (_) {
      await _closeTransport();
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    if (_stopped) return;
    _retryCount += 1;
    if (_retryCount > maxRetry) {
      onEvent?.call('give-up after $maxRetry retries (url 失效/流已轮换)');
      onGiveUp?.call();
      return;
    }
    onEvent?.call('retry #$_retryCount');
    _retryTimer?.cancel();
    _retryTimer = Timer(retryInterval, _connect);
  }

  Future<void> _closeTransport() async {
    try {
      await _subscription?.cancel();
    } catch (_) {}
    _subscription = null;
    try {
      _request?.abort();
    } catch (_) {}
    _request = null;
    try {
      _response?.detachSocket();
    } catch (_) {}
    _response = null;
    try {
      _client?.close(force: true);
    } catch (_) {}
    _client = null;
  }

  Future<void> stop() async {
    _stopped = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    await _closeTransport();
    _parser.reset();
  }
}
