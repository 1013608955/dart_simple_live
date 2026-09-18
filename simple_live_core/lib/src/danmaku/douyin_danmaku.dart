import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/common/web_socket_util.dart';
import 'package:simple_live_core/src/danmaku/douyin_emoji_assets.dart';
import 'package:simple_live_core/src/danmaku/douyin_pk.dart';
import 'package:simple_live_core/src/danmaku/douyin_sei_stream.dart';
import 'package:simple_live_core/src/scripts/douyin_sign.dart';

import 'proto/douyin.pb.dart';

class DouyinDanmakuArgs {
  final String webRid;
  final String roomId;
  final String userId;
  final String cookie;

  /// 旁路 SEI 连接用的 FLV 地址（可选，UI 层从画质列表注入）。
  /// 用于解析连麦格位（app_data.grids）与放大者（focus_id），
  /// 为空则跳过 SEI 解析（回退环序/座位表）
  final String? flvUrl;
  DouyinDanmakuArgs({
    required this.webRid,
    required this.roomId,
    required this.userId,
    required this.cookie,
    this.flvUrl,
  });
  @override
  String toString() {
    return json.encode({
      "webRid": webRid,
      "roomId": roomId,
      "userId": userId,
      "cookie": cookie,
      "flvUrl": flvUrl,
    });
  }
}

class DouyinDanmaku implements LiveDanmaku {
  @override
  int heartbeatTime = 10 * 1000;

  @override
  Function(LiveMessage msg)? onMessage;
  @override
  Function(String msg)? onClose;
  @override
  Function()? onReady;
  String serverUrl = "wss://webcast3-ws-web-lq.douyin.com/webcast/im/push/v2/";
  late DouyinDanmakuArgs danmakuArgs;
  bool _danmakuArgsReady = false; // 防止保留逻辑读到未初始化的 late 变量
  WebScoketUtils? webScoketUtils;
  final List<LiveMessage> _pendingChatMessages = <LiveMessage>[];
  Timer? _flushChatTimer;
  _DouyinImContext? _imContext;
  bool _contextRefreshUsed = false;

  /// 抖音 PK 分数跟踪器（PK 条只在 PK 期间有值）
  final DouyinPkTracker pkTracker = DouyinPkTracker();

  /// 旁路 SEI 连接（拉同一 FLV 解析格位/放大者；播放用 mpv 自己的连接）
  DouyinSeiStream? _seiStream;

  /// SEI 旁路放弃重连（URL 失效/流轮换）时回调，UI 层应换新 URL 重启
  void Function()? onSeiGiveUp;

  /// SEI 旁路空闲断开标记（非连线流自动省带宽；WS 出现连麦/战局消息时唤醒）
  bool _seiIdleClosed = false;

  /// PK 状态变化回调，由 UI 层注册
  Function(LivePkState state)? onPkState;

  // ---- PK 诊断日志（临时，用于排查"PK条不显示"）----
  final Set<String> _seenMethods = <String>{};
  File? _pkLogFile;

  int _pkDumpSeq = 0;

  /// LinkMicMethod 落盘计数（独立限量，避免挤占其他 dump 名额）
  int _linkmicDumpSeq = 0;

  /// LinkmicUI 落盘计数：完整 positions 包较大，不能被 60 条总限挤掉
  int _uiDumpSeq = 0;

  /// 把 PK 类消息的原始字节落盘，供离线分析 protobuf 字段结构
  void _pkDumpPayload(String method, List<int> payload, {bool force = false}) {
    try {
      if (!force && _pkDumpSeq >= 60) return; // 限量，避免占盘
      final dir = Directory('${Directory.systemTemp.path}/pk_dump');
      dir.createSync(recursive: true);
      final safe = method.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');
      // 文件名带连接会话标签：dump 计数器每条连接从 0 重来，
      // 不加标签会跨会话同名互相覆盖（2026-09-15 排查 2v2 时被坑）
      final f = File('${dir.path}/${safe}_${_pkSessionTag}_$_pkDumpSeq.bin');
      _pkDumpSeq++;
      f.writeAsBytesSync(payload, flush: true);
      _pkDebug("DUMP ${f.path} (${payload.length}B)");
    } catch (_) {}
  }

  /// 本条弹幕连接的会话标签（HHmmss），用于 dump 文件名防碰撞
  late final String _pkSessionTag = _newSessionTag();
  static String _newSessionTag() {
    final n = DateTime.now();
    return '${n.hour.toString().padLeft(2, '0')}'
        '${n.minute.toString().padLeft(2, '0')}'
        '${n.second.toString().padLeft(2, '0')}';
  }

  // ---- SYNCORDER 日志（变化检测 + 限量）----
  String? _lastSyncSig;
  int _syncLogCount = 0;

  /// 每包 user_scores/linked_users 数组序：仅在序变化（或首包）时记录，
  /// 最多 40 条/连接——验证「首包序=进频道序=格子序」假设用
  void _logSyncOrder() {
    final sig = pkTracker.debugSyncSignature;
    if (sig == _lastSyncSig) return;
    _lastSyncSig = sig;
    if (_syncLogCount >= 40) return; // 乱序房间每包都变，限量防刷屏
    _syncLogCount++;
    _pkDebug("SYNCORDER $sig${_syncLogCount >= 40 ? ' (达到上限，后续变化不再记录)' : ''}");
  }

  /// 追加一行到 %TEMP%\simple_live_pk_debug.log；超过 8MB 自动轮换：
  /// 旧文件改名为 .1（覆盖更早一份），最多 2 份共 16MB，
  /// 防长时间观看把 TEMP 撑爆（2026-09-14 实测单文件 150MB+）。
  /// 任何异常都吞掉，绝不影响播放
  /// 外部诊断写入 pk 日志（供 controller 转发 tracker 内部事件）
  void debugPkLog(String line) => _pkDebug(line);

  void _pkDebug(String line) {
    try {
      _pkLogFile ??= File('${Directory.systemTemp.path}/simple_live_pk_debug.log');
      final f = _pkLogFile!;
      if (f.existsSync() && f.lengthSync() > 8 * 1024 * 1024) {
        try {
          final rotated = File('${f.path}.1');
          if (rotated.existsSync()) rotated.deleteSync();
          f.renameSync(rotated.path);
        } catch (_) {}
      }
      f.writeAsStringSync(
        "${DateTime.now().toIso8601String()} $line\n",
        mode: FileMode.append,
      );
    } catch (_) {}
  }

  DouyinDanmaku() {
    // 在构造器里接线，保证无论 UI 是否忘记挂 onPkState，状态都能送达
    pkTracker.onUpdate = _onPkUpdate;
  }

  void _onPkUpdate(LivePkState s) {
    // STATE 日志节流：礼物高峰每次上分都触发（实测 931 条/5 分钟），
    // 同步文件 IO 太密——1 秒最多一条；人数/阶段/放大变化立即放行
    final stateKey =
        '${s.count}|${s.phase}|${s.enlargedUserId}|${s.battleId}';
    final now = DateTime.now().millisecondsSinceEpoch;
    if (stateKey != _lastStateLogKey || now - _lastStateLogAt >= 1000) {
      _lastStateLogKey = stateKey;
      _lastStateLogAt = now;
      _pkDebug(
        "STATE count=${s.count} teams=${s.teamScores} "
        "rawTeam=${pkTracker.debugRawTeamScores} ranks=${pkTracker.debugRanks} "
        "order=${pkTracker.debugOrder} local=${s.localUserId} "
        "seat=${pkTracker.debugSeatOrder} uiSeat=${pkTracker.debugUiSeat} nickHint=${pkTracker.debugLocalNickHint} "
        "nicks=${s.participants.map((p) => '${p.userId}:${p.nickname}').join('|')} "
        "pip=${s.pipMode} big=${s.bigMode} enl=${s.enlargedUserId} "
        "seatRoom=${pkTracker.debugSeatRoom} "
        "roomRes=${pkTracker.debugRoomResolvedCount}/${pkTracker.debugSeatRoom.length} "
        "hasScores=${s.hasScores} phase=${s.phase} battleId=${s.battleId} "
        "scores=${pkTracker.debugScores} "
        "start=${pkTracker.debugStartMs} dur=${pkTracker.debugDurSec}s punish=${pkTracker.debugPunishSec}s clockOffset=${pkTracker.debugClockOffsetMs}ms"
        "names=${pkTracker.debugNameCount} profile=${pkTracker.debugProfileCount} "
        "sei=${pkTracker.debugSeiState}",
      );
    }
    onPkState?.call(s);
    _maybeFetchNicknames(s);
    _maybeResolveSeatRooms();
  }

  String _lastStateLogKey = '';
  int _lastStateLogAt = 0;

  // ---- 对手昵称 HTTP 查询（WS 消息不含昵称，房间详情只有本房名） ----
  // 每个房间实例每个 uid 只查一次（含失败）；单轮最多查 3 个，防风控
  final Set<int> _nickFetchDone = <int>{};
  bool _nickFetchInFlight = false;

  // ---- 座位表房间号 -> uid 解析（linker_map 的值是 room_id 非 uid，
  // 2026-09-13 三房间实测；reflow 接口按 room_id 查房主 uid+昵称） ----
  bool _roomResolveInFlight = false;

  /// 主动触发座位表房间号解析。普通连麦时参与者全靠座位表，而座位
  /// 解析原本只由 PK 状态更新驱动——连麦没战斗消息就永远不触发，
  /// 名字/礼物值徽章一个都不出（死锁）。UI 层在推完座位表后调用
  void resolveSeatRooms() => _maybeResolveSeatRooms();

  void _maybeResolveSeatRooms() {
    if (_roomResolveInFlight) return;
    final pending = pkTracker.pendingRoomIds;
    if (pending.isEmpty) return;
    _roomResolveInFlight = true;
    () async {
      try {
        for (final roomId in pending.take(3)) {
          final owner = await _fetchRoomOwnerByRoomId(roomId);
          if (owner != null) {
            _pkDebug("ROOMRES $roomId -> uid=${owner.$1} nick=${owner.$2}");
            pkTracker.applyRoomOwner(roomId, owner.$1, owner.$2);
          } else {
            _pkDebug("ROOMRES $roomId 查询无结果");
            pkTracker.applyRoomOwner(roomId, 0, '');
          }
        }
      } catch (e) {
        _pkDebug("ROOMRES 查询异常: $e");
      } finally {
        _roomResolveInFlight = false;
      }
    }();
  }

  /// room_id -> (uid, nickname)（reflow 接口，与 DouyinSite 同端点；
  /// 接口只需 ttwid cookie，无需 abogus 签名）
  Future<(int, String)?> _fetchRoomOwnerByRoomId(int roomId) async {
    final url = 'https://webcast.amemv.com/webcast/room/reflow/info/'
        '?type_id=0&live_id=1&room_id=$roomId&sec_user_id='
        '&version_code=99.99.99&app_id=6383';
    final bytes = await HttpClient.instance.getBytes(
      url,
      header: _socketHeaders(),
    ).timeout(const Duration(seconds: 8));
    if (bytes.isEmpty) return null;
    final obj = jsonDecode(utf8.decode(bytes));
    if (obj is! Map) return null;
    final data = obj["data"];
    if (data is! Map) return null;
    final room = data["room"];
    if (room is! Map) return null;
    final owner = room["owner"];
    if (owner is! Map) return null;
    final uid = int.tryParse(
        owner["id_str"]?.toString() ?? owner["id"]?.toString() ?? '');
    if (uid == null || uid <= 0) return null;
    final nick = owner["nickname"]?.toString() ?? '';
    return (uid, nick);
  }


  void _maybeFetchNicknames(LivePkState s) {
    if (_nickFetchInFlight) return;
    final targets = <int>[];
    for (final p in s.participants) {
      if (p.userId == 0) continue;
      if (_nickFetchDone.contains(p.userId)) continue;
      // 占位符形如 "主播NNN"；已有真名的不查
      if (!p.nickname.startsWith('主播')) continue;
      targets.add(p.userId);
      if (targets.length >= 3) break;
    }
    if (targets.isEmpty) return;
    _nickFetchInFlight = true;
    () async {
      try {
        for (final uid in targets) {
          _nickFetchDone.add(uid);
          final nick = await _fetchNicknameByUid(uid);
          if (nick != null && nick.isNotEmpty) {
            _pkDebug("NICK $uid -> $nick");
            pkTracker.applyNicknames({uid: nick});
          } else {
            _pkDebug("NICK $uid 查询无结果");
          }
        }
      } catch (e) {
        _pkDebug("NICK 查询异常: $e");
      } finally {
        _nickFetchInFlight = false;
      }
    }();
  }

  /// user_id -> 昵称（aweme 用户主页接口，复用 cookie + abogus 签名）。
  /// 接口无官方文档，响应结构按常见形态防御性解析，失败返回 null
  Future<String?> _fetchNicknameByUid(int uid) async {
    final unsigned = Uri
        .parse("https://www.douyin.com/aweme/v1/web/user/profile/other/")
        .replace(queryParameters: {
          "device_platform": "webapp",
          "aid": "6383",
          "channel": "channel_pc_web",
          "user_id": "$uid",
        }).toString();
    final signed = DouyinSign.getAbogusUrlWithMsToken(
      unsigned,
      DouyinSite.kDefaultUserAgent,
      msToken: _cookieValue("msToken"),
    );
    final bytes =
        await HttpClient.instance.getBytes(signed, header: _socketHeaders());
    if (bytes.isEmpty) return null;
    final obj = jsonDecode(utf8.decode(bytes));
    if (obj is Map) {
      dynamic user = obj["user"];
      if (user == null && obj["data"] is Map) user = obj["data"]["user"];
      if (user is Map) {
        final nick = user["nickname"]?.toString();
        return (nick == null || nick.isEmpty) ? null : nick;
      }
    }
    return null;
  }
  static const int _maxChatFlushBatch = 50;
  static const Duration _chatFlushInterval = Duration(milliseconds: 80);

  @override
  Future start(dynamic args) async {
    final startStopwatch = Stopwatch()..start();
    final newArgs = args as DouyinDanmakuArgs;
    // 保留上一轮注入的旁路地址：画质/线路解析（_reloadPlayUrls）可能
    // 先于 start() 完成，其注入的 flvUrl 会被这里整体换 args 抹掉，
    // SEI 旁路永远起不来（2026-09-19 实测：重进房 INJECT 先完成、
    // start 随后把 flvUrl 抹空）。仅同房间保留；换房视为新流
    if (_danmakuArgsReady &&
        danmakuArgs.flvUrl != null &&
        (newArgs.flvUrl == null || newArgs.flvUrl!.isEmpty) &&
        danmakuArgs.webRid == newArgs.webRid &&
        danmakuArgs.roomId == newArgs.roomId) {
      danmakuArgs = DouyinDanmakuArgs(
        webRid: newArgs.webRid,
        roomId: newArgs.roomId,
        userId: newArgs.userId,
        cookie: newArgs.cookie,
        flvUrl: danmakuArgs.flvUrl,
      );
    } else {
      danmakuArgs = newArgs;
    }
    _danmakuArgsReady = true;
    _contextRefreshUsed = false;
    // 本房 internalRoomId：linker_map 座位表里值等于它的条目即本房格
    final ownRoomId = int.tryParse(danmakuArgs.roomId);
    if (ownRoomId != null && ownRoomId > 0) {
      pkTracker.setOwnRoomId(ownRoomId);
    }
    try {
      _imContext = await _fetchImContext();
    } catch (e) {
      CoreLog.w("[DouyinDanmaku] 动态弹幕上下文获取失败，使用兼容地址：$e");
    }
    _openWebSocket(args);
    _startSeiStream();
    startStopwatch.stop();
    CoreLog.i(
      "[DouyinDanmaku] start(${danmakuArgs.webRid}) 耗时 ${startStopwatch.elapsedMilliseconds}ms",
    );
  }

  Map<String, String> _buildQueryParameters({
    String? cursor,
    String? internalExt,
    int? dynamicHeartbeat,
  }) {
    final ts = DateTime.now().millisecondsSinceEpoch;
    return {
      "app_name": "douyin_web",
      "version_code": "180800",
      "webcast_sdk_version": "1.3.0",
      "update_version_code": "1.3.0",
      "compress": "gzip",
      "resp_content_type": "protobuf",
      "cursor": cursor ?? "h-1_t-${ts}_r-1_d-1_u-1",
      "host": "https://live.douyin.com",
      "aid": "6383",
      "live_id": "1",
      "did_rule": "3",
      "debug": "false",
      "maxCacheMessageNumber": "20",
      "endpoint": "live_pc",
      "support_wrds": "1",
      "im_path": "/webcast/im/fetch/",
      "user_unique_id": danmakuArgs.userId,
      "device_platform": "web",
      "cookie_enabled": "true",
      "screen_width": "1920",
      "screen_height": "1080",
      "browser_language": "zh-CN",
      "browser_platform": "Win32",
      "browser_name": "Mozilla",
      "browser_version": DouyinSite.kDefaultUserAgent.replaceAll(
        "Mozilla/",
        "",
      ),
      "browser_online": "true",
      "tz_name": "Asia/Shanghai",
      "identity": "audience",
      "room_id": danmakuArgs.roomId,
      "heartbeatDuration": dynamicHeartbeat?.toString() ?? "0",
      if (internalExt != null && internalExt.isNotEmpty)
        "internal_ext": internalExt,
    };
  }

  Map<String, dynamic> _signatureParameters() {
    return DouyinSign.getDefaultSignatureParams(
      danmakuArgs.roomId,
      danmakuArgs.userId,
    );
  }

  Map<String, dynamic> _socketHeaders() {
    // resolveSeatRooms 可能早于 start(args) 触发（控制器 initDanmau 在
    // start 之前推座位表并主动触发解析），此时 danmakuArgs 尚未初始化
    //（late），直接读会崩。用兜底头先查，10s 刷新会带完整 cookie 重试
    String cookie = '';
    String webRid = '';
    try {
      cookie = danmakuArgs.cookie;
      webRid = danmakuArgs.webRid;
    } catch (_) {}
    return {
      "Accept": "application/json, text/plain, */*",
      "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
      "Cache-Control": "no-cache",
      "Pragma": "no-cache",
      "User-Agent": DouyinSite.kDefaultUserAgent,
      "Cookie": cookie,
      "Origin": "https://live.douyin.com",
      "Referer": "https://live.douyin.com/$webRid",
    };
  }

  Future<_DouyinImContext?> _fetchImContext() async {
    try {
      final query = _buildQueryParameters();
      final signature = DouyinSign.getSignatureForParams(
        _signatureParameters(),
      );
      final unsignedUri = Uri.parse(
        "https://live.douyin.com/webcast/im/fetch/",
      ).replace(queryParameters: {...query, "signature": signature});
      final requestUrl = DouyinSign.getAbogusUrlWithMsToken(
        unsignedUri.toString(),
        DouyinSite.kDefaultUserAgent,
        msToken: _cookieValue("msToken"),
      );
      final bytes = await HttpClient.instance.getBytes(
        requestUrl,
        header: _socketHeaders(),
      );
      if (bytes.isEmpty) {
        CoreLog.w(
          "[DouyinDanmaku] IM 预取失败：空响应 cookie=${danmakuArgs.cookie.trim().isNotEmpty}",
        );
        return null;
      }
      final response = _decodeImResponse(bytes);
      final pushServer = response.pushServer.trim();
      final cursor = response.cursor.trim().isNotEmpty
          ? response.cursor.trim()
          : response.liveCursor.trim();
      if (cursor.isEmpty) {
        CoreLog.w("[DouyinDanmaku] IM 预取缺少动态游标");
        return null;
      }
      _consumeResponse(response);
      final duration = response.heartbeatDuration.toInt();
      if (duration > 0) {
        heartbeatTime = duration.clamp(1000, 120000);
      }
      CoreLog.i(
        "[DouyinDanmaku] IM 预取成功 host=${pushServer.isEmpty ? 'fallback' : _redactHost(pushServer)} heartbeat=${heartbeatTime}ms",
      );
      return _DouyinImContext(
        pushServer: pushServer.isEmpty ? serverUrl : pushServer,
        cursor: cursor,
        internalExt: response.internalExt,
        heartbeatDuration: duration,
      );
    } on CoreError catch (e) {
      final reason = e.statusCode == 444
          ? "HTTP 444 风控限制"
          : e.statusCode > 0
          ? "HTTP ${e.statusCode}"
          : e.message;
      CoreLog.w(
        "[DouyinDanmaku] IM 预取失败：$reason cookie=${danmakuArgs.cookie.trim().isNotEmpty}",
      );
      return null;
    } on FormatException catch (e) {
      CoreLog.w("[DouyinDanmaku] IM 预取 protobuf 解析失败：$e");
      return null;
    } catch (e) {
      CoreLog.w("[DouyinDanmaku] IM 预取响应不可用：$e");
      return null;
    }
  }

  Response _decodeImResponse(List<int> bytes) {
    var payload = bytes;
    if (payload.isNotEmpty && payload[0] == 0x7b) {
      throw const FormatException("响应为JSON，可能缺少protobuf参数或触发风控");
    }
    if (payload.length >= 2 && payload[0] == 0x1f && payload[1] == 0x8b) {
      payload = gzip.decode(payload);
    }
    return Response.fromBuffer(payload);
  }

  String? _cookieValue(String name) {
    for (final part in danmakuArgs.cookie.split(';')) {
      final pieces = part.trim().split('=');
      if (pieces.length >= 2 && pieces.first.trim() == name) {
        return pieces.sublist(1).join('=').trim();
      }
    }
    return null;
  }

  String _normalizePushServer(String value) {
    var server = value.trim();
    if (server.isEmpty) {
      return serverUrl;
    }
    if (!server.contains('://')) {
      server = 'wss://$server';
    }
    final uri = Uri.parse(server);
    return uri
        .replace(
          scheme: 'wss',
          path: uri.path.isEmpty || uri.path == '/'
              ? '/webcast/im/push/v2/'
              : uri.path,
        )
        .toString();
  }

  String _buildSocketUrl(String base, _DouyinImContext? context) {
    final uri = Uri.parse(base).replace(
      scheme: 'wss',
      queryParameters: {
        ..._buildQueryParameters(
          cursor: context?.cursor,
          internalExt: context?.internalExt,
          dynamicHeartbeat: context?.heartbeatDuration,
        ),
        "signature": DouyinSign.getSignatureForParams(_signatureParameters()),
      },
    );
    return uri.toString();
  }

  List<String> _socketUrls(_DouyinImContext? context) {
    final dynamicUrl = context == null
        ? null
        : _buildSocketUrl(_normalizePushServer(context.pushServer), context);
    final staticUrl = _buildSocketUrl(serverUrl, context);
    final urls = <String>[
      if (dynamicUrl != null && dynamicUrl.isNotEmpty) dynamicUrl,
      staticUrl,
      staticUrl.replaceAll('webcast3-ws-web-lq', 'webcast5-ws-web-lf'),
      staticUrl.replaceAll('webcast3-ws-web-lq', 'webcast5-ws-web-hl'),
      staticUrl.replaceAll('webcast3-ws-web-lq', 'webcast3-ws-web-hl'),
      staticUrl.replaceAll('webcast3-ws-web-lq', 'webcast3-ws-web-lf'),
    ];
    return urls.toSet().toList();
  }

  void _openWebSocket(dynamic args) {
    final urls = _socketUrls(_imContext);
    CoreLog.d(
      "[DouyinDanmaku] 连接弹幕服务器 room=${danmakuArgs.webRid} candidates=${urls.length} dynamic=${_imContext != null}",
    );
    webScoketUtils = WebScoketUtils(
      url: urls.first,
      backupUrls: urls.skip(1).toList(),
      headers: _socketHeaders(),
      heartBeatTime: heartbeatTime,
      onMessage: decodeMessage,
      onReady: () {
        onReady?.call();
        joinRoom(args);
      },
      onHeartBeat: heartbeat,
      onReconnect: () {
        onClose?.call("与服务器断开连接，正在尝试重连");
      },
      onClose: (e) {
        CoreLog.w("[DouyinDanmaku] WebSocket 握手/连接失败：$e");
        if (!_contextRefreshUsed && _imContext != null) {
          _contextRefreshUsed = true;
          unawaited(_refreshContextAndReconnect(args, e));
          return;
        }
        onClose?.call("服务器连接失败（握手或传输失败）$e");
      },
    );
    webScoketUtils?.connect();
  }

  Future<void> _refreshContextAndReconnect(dynamic args, String error) async {
    CoreLog.w("[DouyinDanmaku] 动态推送连接失败，刷新 IM 上下文：$error");
    try {
      final context = await _fetchImContext();
      if (context != null) {
        webScoketUtils?.close();
        _imContext = context;
        _openWebSocket(args);
        return;
      }
    } catch (e) {
      CoreLog.w("[DouyinDanmaku] 刷新 IM 上下文失败：$e");
    }
    onClose?.call("服务器连接失败（动态上下文刷新后握手失败）$error");
  }

  @override
  void heartbeat() {
    var obj = PushFrame();
    obj.payloadType = 'hb';
    webScoketUtils?.sendMessage(obj.writeToBuffer());
  }

  void decodeMessage(args) {
    final stopwatch = Stopwatch()..start();
    var wssPackage = PushFrame.fromBuffer(args);
    var decompressed = gzip.decode(wssPackage.payload);
    var payloadPackage = Response.fromBuffer(decompressed);
    final counts = _consumeResponse(payloadPackage, logId: wssPackage.logId);
    stopwatch.stop();
    if (stopwatch.elapsedMilliseconds >= 16 || counts.$2 >= 20) {
      CoreLog.i(
        "[DouyinDanmaku] decodeMessage 耗时 ${stopwatch.elapsedMilliseconds}ms messages=${counts.$1} chats=${counts.$2}",
      );
    }
  }

  (int, int) _consumeResponse(Response payloadPackage, {dynamic logId}) {
    var messageCount = 0;
    var chatCount = 0;
    if (payloadPackage.needAck && logId != null) {
      sendAck(logId, payloadPackage.internalExt);
    }
    // 用服务端时间校正本地时钟，保证 PK 倒计时准确
    // _pkDebug("CLOCK now=${payloadPackage.now} local=${DateTime.now().millisecondsSinceEpoch} offset_before=${_clockOffsetMs}");
    pkTracker.syncServerTime(payloadPackage.now.toInt());
    for (var msg in payloadPackage.messagesList) {
      messageCount++;
      // 诊断：首次见到某 method 时记录（一次性，避免刷屏）
      if (_seenMethods.add(msg.method)) {
        _pkDebug("METHOD ${msg.method} payload=${msg.payload.length}B");
      }
      // SEI 旁路空闲断开时，连麦/战局消息到达 = 活动恢复
      _reviveSeiIfIdle(msg.method);
      if (msg.method == 'WebcastChatMessage') {
        final liveMessage = unPackWebcastChatMessage(msg.payload);
        if (liveMessage != null) {
          chatCount++;
          _enqueueChatMessage(liveMessage);
        }
      } else if (msg.method == 'WebcastRoomUserSeqMessage') {
        unPackWebcastRoomUserSeqMessage(msg.payload);
      } else if (msg.method == 'WebcastLinkMicBattleMethod' ||
          msg.method == 'WebcastLinkMicBattle') {
        _pkDebug("PK-battle(旧) 收到 payload=${msg.payload.length}B");
        _pkDumpPayload("battle_${msg.method}", msg.payload);
        pkTracker.onBattle(msg.payload);
      } else if (msg.method == 'WebcastLinkMicArmiesMethod' ||
          msg.method == 'WebcastLinkMicArmies') {
        _pkDebug("PK-armies(旧) 收到 payload=${msg.payload.length}B");
        _pkDumpPayload("armies_${msg.method}", msg.payload);
        pkTracker.onArmies(msg.payload);
      } else if (msg.method == 'WebcastLinkMicBattleFinishMethod' ||
          msg.method == 'WebcastLinkMicBattleFinish') {
        _pkDebug("PK-finish(旧) 收到 payload=${msg.payload.length}B");
        pkTracker.onFinish(msg.payload);
      }
      // ---- 新协议（2026-09 实测在用）----
      else if (msg.method == 'WebcastBattleStatusMessage') {
        _pkDebug("PK2-status 收到 payload=${msg.payload.length}B");
        _pkDumpPayload("bs_${msg.method}", msg.payload);
        pkTracker.onBattleStatus(msg.payload);
      } else if (msg.method == 'WebcastLinkmicPlayModeUpdateScoreMessage') {
        _pkDebug("PK2-score 收到 payload=${msg.payload.length}B");
        pkTracker.onScoreUpdate(msg.payload);
      } else if (msg.method == 'WebcastLinkMicMethod' ||
          msg.method == 'LinkMicMethod') {
        _pkDebug("PK2-sync($msg.method) 收到 payload=${msg.payload.length}B");
        // 落盘限量 12 份：核对 linked_users 顺序 / battle_rank / 队伍分用
        if (_linkmicDumpSeq < 12) {
          _pkDumpPayload("linkmic${_linkmicDumpSeq}_${msg.method}", msg.payload);
          _linkmicDumpSeq++;
        }
        pkTracker.onLinkMicMethod(msg.payload);
        _logSyncOrder();
      } else if (msg.method == 'WebcastLinkmicUIMessage') {
        if (_uiDumpSeq < 20) {
          _pkDumpPayload("ui${_uiDumpSeq}_${msg.method}", msg.payload,
              force: true);
          _uiDumpSeq++;
        }
        pkTracker.onLinkmicUI(msg.payload);
      } else if (msg.method == 'WebcastBattleEndPunishMessage') {
        _pkDebug("PK2-endpunish 收到 payload=${msg.payload.length}B");
        pkTracker.onBattleEndPunish(msg.payload);
      } else if (msg.method == 'WebcastLinkmicEnlargeGuestMessage') {
        _pkDebug("PK2-enlarge 收到 payload=${msg.payload.length}B");
        _pkDumpPayload("enlarge_${msg.method}", msg.payload);
        pkTracker.onEnlarge(msg.payload);
      } else if (msg.method == 'WebcastLinkMessage' ||
          msg.method == 'LinkMessage') {
        // 纯连麦（非 PK）名单事件：供"连线但没开 PK 时显示各主播名字"
        _pkDebug("LINK 收到 payload=${msg.payload.length}B");
        _pkDumpPayload("link_${msg.method}", msg.payload);
        pkTracker.onLinkMessage(msg.payload);
      } else if (isPkLikeMethod(msg.method)) {
        // 兜底：命中 PK 关键词但未识别的 method 名
        _pkDebug("PK-未知方法 ${msg.method} payload=${msg.payload.length}B");
        _pkDumpPayload(msg.method, msg.payload);
      }
    }
    return (messageCount, chatCount);
  }

  String _redactHost(String value) {
    try {
      final uri = Uri.parse(value.contains('://') ? value : 'wss://$value');
      return uri.host;
    } catch (_) {
      return 'invalid';
    }
  }

  LiveMessage? unPackWebcastChatMessage(List<int> payload) {
    var chatMessage = ChatMessage.fromBuffer(payload);
    final spans = _extractRtfSpans(chatMessage);
    if (spans.isEmpty) {
      _appendTextWithEmojiFallback(spans, chatMessage.content);
    }
    final imageUrls = spans
        .where((item) => item.isImage)
        .map((item) => item.imageUrl!.trim())
        .toSet()
        .toList();
    final message = _buildChatMessageText(chatMessage, spans);
    return LiveMessage(
      type: LiveMessageType.chat,
      color: LiveMessageColor.white,
      //暂不知道具体怎么转换颜色
      // color: chatMessage.common.fullScreenTextColor.
      //     ? LiveMessageColor.white
      //     : LiveMessageColor.numberToColor(color),
      message: message,
      userName: chatMessage.user.nickName,
      imageUrls: imageUrls.isEmpty ? null : imageUrls,
      spans: spans.isEmpty ? null : spans,
    );
  }

  void _enqueueChatMessage(LiveMessage message) {
    _pendingChatMessages.add(message);
    if (_pendingChatMessages.length >= _maxChatFlushBatch) {
      _flushChatTimer ??= Timer(Duration.zero, _flushChatMessages);
      return;
    }
    _flushChatTimer ??= Timer(_chatFlushInterval, _flushChatMessages);
  }

  void _flushChatMessages() {
    _flushChatTimer?.cancel();
    _flushChatTimer = null;
    if (_pendingChatMessages.isEmpty) {
      return;
    }
    final batchSize = _pendingChatMessages.length > _maxChatFlushBatch
        ? _maxChatFlushBatch
        : _pendingChatMessages.length;
    final batch = _pendingChatMessages.sublist(0, batchSize);
    _pendingChatMessages.removeRange(0, batchSize);
    for (final message in batch) {
      onMessage?.call(message);
    }
    if (_pendingChatMessages.isNotEmpty) {
      _flushChatTimer = Timer(_chatFlushInterval, _flushChatMessages);
    }
  }

  String _buildChatMessageText(
    ChatMessage chatMessage,
    List<LiveMessageSpan> spans,
  ) {
    final content = chatMessage.content.trim();
    if (content.isNotEmpty) {
      return content;
    }
    if (spans.isEmpty) {
      return chatMessage.content;
    }
    final buffer = StringBuffer();
    for (final span in spans) {
      if (span.isText) {
        buffer.write(span.text);
      }
    }
    return buffer.toString().trim();
  }

  List<LiveMessageSpan> _extractRtfSpans(ChatMessage chatMessage) {
    final spans = <LiveMessageSpan>[];
    if (!chatMessage.hasRtfContent()) {
      return spans;
    }
    for (final piece in chatMessage.rtfContent.piecesList) {
      if (piece.hasImageValue() && piece.imageValue.hasImage()) {
        final imageUrl = _extractImageUrl(piece.imageValue.image);
        if (imageUrl != null) {
          spans.add(LiveMessageSpan.image(imageUrl));
          continue;
        }
        final fallback = _extractImageFallbackText(piece.imageValue.image);
        if (fallback != null) {
          _appendTextWithEmojiFallback(spans, fallback);
        }
      }
      if (piece.stringValue.trim().isNotEmpty) {
        _appendTextWithEmojiFallback(spans, piece.stringValue);
      }
      if (piece.hasPatternRefValue()) {
        final pattern = piece.patternRefValue.defaultPattern.trim();
        if (pattern.isNotEmpty) {
          _appendTextWithEmojiFallback(spans, pattern);
        }
      }
    }
    return spans;
  }

  void _appendTextWithEmojiFallback(List<LiveMessageSpan> spans, String text) {
    if (text.isEmpty) {
      return;
    }
    var start = 0;
    for (final match in RegExp(r'\[[^\[\]]{1,16}\]').allMatches(text)) {
      final token = match.group(0);
      if (token == null) {
        continue;
      }
      final asset = douyinEmojiAssets[token];
      if (asset == null) {
        continue;
      }
      if (match.start > start) {
        spans.add(LiveMessageSpan.text(text.substring(start, match.start)));
      }
      spans.add(LiveMessageSpan.image(asset));
      start = match.end;
    }
    if (start < text.length) {
      spans.add(LiveMessageSpan.text(text.substring(start)));
    }
  }

  String? _extractImageUrl(Image image) {
    for (final url in image.urlListList) {
      final value = url.trim();
      if (value.startsWith('http://') || value.startsWith('https://')) {
        return value;
      }
    }
    final openWebUrl = image.openWebUrl.trim();
    if (openWebUrl.startsWith('http://') || openWebUrl.startsWith('https://')) {
      return openWebUrl;
    }
    final uri = image.uri.trim();
    if (uri.startsWith('http://') || uri.startsWith('https://')) {
      return uri;
    }
    return null;
  }

  String? _extractImageFallbackText(Image image) {
    final alternativeText = image.content.alternativeText.trim();
    if (alternativeText.isNotEmpty) {
      return alternativeText;
    }
    final name = image.content.name.trim();
    if (name.isNotEmpty) {
      return name;
    }
    final uri = image.uri.trim();
    if (uri.isNotEmpty) {
      return '[$uri]';
    }
    return null;
  }

  void unPackWebcastRoomUserSeqMessage(List<int> payload) {
    var roomUserSeqMessage = RoomUserSeqMessage.fromBuffer(payload);
    // 观看人数 = 当前观看人数（field 3 total，与抖音网页版口径一致）。
    // 已证伪的候选：totalUser(7)=热度类大数（小房间 1642 实为 6-7 人）、
    // online_user_for_anchor(10)=大房间 164 万实为 1.6 万、
    // total_pv_for_anchor(11)=累计观看 PV
    final cur = roomUserSeqMessage.total.toInt();
    final online = int.tryParse(roomUserSeqMessage.onlineUserForAnchor.trim()) ?? 0;
    final v = cur > 0
        ? cur
        : (online > 0 ? online : roomUserSeqMessage.totalUser.toInt());
    onMessage?.call(
      LiveMessage(
        type: LiveMessageType.online,
        data: v,
        color: LiveMessageColor.white,
        message: "",
        userName: "",
      ),
    );
  }

  void sendAck(var logId, String internalExt) {
    var obj = PushFrame();
    obj.payloadType = 'ack';
    obj.logId = logId;
    obj.payload = utf8.encode(internalExt);
    webScoketUtils?.sendMessage(obj.writeToBuffer());
  }

  void joinRoom(args) {
    var obj = PushFrame();
    obj.payloadType = 'hb';
    webScoketUtils?.sendMessage(obj.writeToBuffer());
  }

  @override
  Future stop() async {
    _flushChatTimer?.cancel();
    _flushChatTimer = null;
    _pendingChatMessages.clear();
    onMessage = null;
    onClose = null;
    onReady = null;
    // PK 状态同步清理，避免下个房间残留旧比分
    onPkState = null;
    pkTracker.reset();
    await _stopSeiStream();
    webScoketUtils?.close();
  }

  /// 空闲断开后，WS 出现连麦/战局消息 = 连线活动恢复，唤醒旁路
  void _reviveSeiIfIdle(String method) {
    if (!_seiIdleClosed) return;
    if (!method.contains('Link') && !method.contains('Battle')) return;
    _pkDebug("SEI 空闲唤醒（$method）");
    _seiIdleClosed = false;
    _startSeiStream();
  }

  /// 启动旁路 SEI 连接：拉同一 FLV 流解析连麦格位（app_data.grids）
  /// 与放大者（focus_id），喂给 pkTracker。flvUrl 缺失时静默跳过。
  /// 全程 try-catch——旁路任何失败都不影响弹幕/播放
  void _startSeiStream() {
    final flvUrl = danmakuArgs.flvUrl;
    if (flvUrl == null || flvUrl.isEmpty) {
      _pkDebug("SEI 旁路未启动：flvUrl 为空（画质列表未含 flv）");
      return;
    }
    // 先停旧连接：换房/换清晰度时旧流的 in-flight 回调会把上一个
    // 房间的布局写进当前 tracker（2026-09-18 实测 3/8 格交叉污染）
    unawaited(_stopSeiStream());
    try {
      final stream = DouyinSeiStream();
      stream.onLayout = (layout) {
        if (_seiStream != stream) return; // 已被更新的连接顶替
        try {
          pkTracker.applySeiLayout(layout);
          _pkDebug(
              "SEI-LAYOUT ver=${layout.ver} grids=${layout.grids.length} "
              "focus=${layout.focusLinkmicId.isEmpty ? '-' : layout.focusLinkmicId}");
        } catch (_) {}
      };
      stream.onEvent = (msg) => _pkDebug("SEI-EVENT $msg");
      stream.onGiveUp = () {
        // 流轮换（PK 结束/清晰度切换）导致 URL 失效：丢弃死连接并
        // 通知上层换新 URL（controller 重新解析播放地址后回调）
        _pkDebug("SEI-EVENT give-up，请求上层刷新 URL");
        _seiStream = null;
        onSeiGiveUp?.call();
      };
      stream.onIdleClose = () {
        // 非连线流（单人直播）自动省带宽：断开后 WS 出现连麦/战局
        // 消息时由 _reviveSeiIfIdle 唤醒
        _pkDebug("SEI 空闲断开（省带宽）");
        _seiStream = null;
        _seiIdleClosed = true;
      };
      _seiStream = stream;
      unawaited(stream.start(flvUrl));
      _pkDebug("SEI 旁路已启动 flv=${flvUrl.substring(0, flvUrl.length.clamp(0, 60))}");
      CoreLog.i("[DouyinDanmaku] SEI 旁路已启动");
    } catch (e) {
      _pkDebug("SEI 旁路启动异常：$e");
      CoreLog.w("[DouyinDanmaku] SEI 旁路启动失败（忽略）：$e");
    }
  }

  Future<void> _stopSeiStream() async {
    final stream = _seiStream;
    _seiStream = null;
    if (stream != null) {
      try {
        await stream.stop();
      } catch (_) {}
    }
  }

  /// 播放地址解析完成后由 UI 层注入（弹幕通常先于画质列表启动）：
  /// 更新 args 并补启动旁路；换 URL（切画质/线路）时重启连接
  void updateSeiFlvUrl(String flvUrl) {
    try {
      if (danmakuArgs.flvUrl == flvUrl && _seiStream != null) return;
      danmakuArgs = DouyinDanmakuArgs(
        webRid: danmakuArgs.webRid,
        roomId: danmakuArgs.roomId,
        userId: danmakuArgs.userId,
        cookie: danmakuArgs.cookie,
        flvUrl: flvUrl,
      );
      unawaited(_stopSeiStream());
      _startSeiStream();
    } catch (_) {}
  }
}

class _DouyinImContext {
  final String pushServer;
  final String cursor;
  final String internalExt;
  final int heartbeatDuration;

  const _DouyinImContext({
    required this.pushServer,
    required this.cursor,
    required this.internalExt,
    required this.heartbeatDuration,
  });
}
