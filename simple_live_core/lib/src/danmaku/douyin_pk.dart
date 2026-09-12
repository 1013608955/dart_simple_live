import 'dart:convert';
import 'dart:typed_data';

// ============================================================================
// 抖音直播 PK 分数 / 进度条 解析与状态跟踪   v2（支持多人团战）
//
// 目标位置：simple_live_core/lib/src/danmaku/douyin_pk.dart
//
// v2 变更：数据模型从 left/right 两人改为 N 个参与者 + 队伍分组，
//          支持 1v1 对比条 与 多人团战（顶部总队条 + 每框分数/名字）两种形态。
//
// 不扩充 douyin.proto，手写 protobuf wire-format 解码（原因见 README.md）。
//
// 字段号依据：官方逆向 schema 的 Webcast.Im / Webcast.Data 命名空间
//   LinkMicBattle(Im)   : battle_settings=2, battle_mode=3,
//                         user_infos=6 (map<int64, Data.BattleUserInfo>)
//   BattleSettings(Im)  : battle_id=2, start_time_ms=3, duration=4,
//                         punish_duration=19, punish_start_time_ms=20,
//                         steal_tower_duration=38, battle_status=40
//   LinkMicArmies(Im)   : user_armies_map=2, user_armies_list=3,
//                         rank_list_v2=4, top_show_text=5
//   UserArmies          : user_armies=1
//   UserArmy            : user_id=1, score=2, nickname=3, avatar_thumb=4
//   Data.BattleUserInfo : user=1(BaseUserInfo), pk_role=7, multi_pk_team_id=10
//   Data.BaseUserInfo   : user_id=1, nick_name=2, avatar_thumb=3
//   Data.Image          : url_list=1 (repeated string)
// ============================================================================

/// protobuf wire-format 极简读取器
class PbReader {
  final Uint8List _b;
  int _pos = 0;

  PbReader(List<int> bytes) : _b = Uint8List.fromList(bytes);

  bool get hasMore => _pos < _b.length;

  int readVarint() {
    var result = 0;
    var shift = 0;
    while (_pos < _b.length) {
      final b = _b[_pos++];
      result |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) return result;
      shift += 7;
      if (shift >= 64) break;
    }
    return result;
  }

  int readInt() => readVarint();

  Uint8List readBytes() {
    final len = readVarint();
    var end = _pos + len;
    if (end > _b.length) end = _b.length;
    if (end < 0) end = 0;
    final out = Uint8List.sublistView(_b, _pos, end);
    _pos = end;
    return out;
  }

  String readString() => utf8.decode(readBytes(), allowMalformed: true);

  void skipField(int wireType) {
    switch (wireType) {
      case 0:
        readVarint();
        break;
      case 1:
        _pos += 8;
        break;
      case 2:
        readBytes();
        break;
      case 5:
        _pos += 4;
        break;
      default:
        throw FormatException('PbReader: 不支持的 wireType=$wireType');
    }
  }

  /// 遍历当前层级字段。[onField] 返回 true 表示已自行消费并推进了读取位置。
  void forEachField(bool Function(int fieldNumber, int wireType) onField) {
    while (_pos < _b.length) {
      final tag = readVarint();
      final fieldNumber = tag >> 3;
      final wireType = tag & 0x07;
      if (fieldNumber == 0) return;
      if (!onField(fieldNumber, wireType)) skipField(wireType);
    }
  }

  /// 收集当前层级所有 varint 字段，其余自动跳过（用于兼容字段号漂移）
  Map<int, int> varintFields() {
    final out = <int, int>{};
    forEachField((f, w) {
      if (w == 0) {
        out[f] = readVarint();
        return true;
      }
      return false;
    });
    return out;
  }
}

// ─────────────────────────── 数据模型 ───────────────────────────

enum LivePkPhase { running, punish, finished }

enum LivePkMode { unknown, solo, team }

class LivePkSide {
  final int userId;
  final String nickname;
  final String? avatar;
  final int score;

  /// PK 内当前名次（user_scores.battle_rank），0 = 未知
  final int rank;

  /// 队伍 id，0 表示未知 / 未分组
  final int teamId;

  /// 服务端 multi_pk_team_score（队伍总分）。user_scores 里没有 team id，
  /// 同队成员携带同一个队伍总分值；0 = 无队伍分（个人赛 / 未同步）
  final int teamScore;

  const LivePkSide({
    required this.userId,
    required this.nickname,
    required this.score,
    this.avatar,
    this.rank = 0,
    this.teamId = 0,
    this.teamScore = 0,
  });
}

class LivePkState {
  final int battleId;
  final int startTimeMs;
  final int durationMs;
  final LivePkPhase phase;
  final LivePkMode mode;

  /// 参与者。顺序来自服务端推送，团队战时假定与画面网格顺序一致
  /// （该假设必须在 Phase 0 抓包验证，见 PLAN.md）
  final List<LivePkSide> participants;

  final String? topShowText;
  final int punishStartMs;
  final int punishDurationMs;

  /// 是否为组队赛（多人分队伍比总分）。
  /// false = 个人赛（每人自己的分），UI 不显示双方进度条、只显示倒计时+每框分数
  final bool teamBattle;

  /// 本房主播 uid（user_scores field 18==1 标记；0 = 未知）。
  /// 顶部条的左队=本房队（与网页版一致）
  final int localUserId;

  /// 被主持人放大画面的主播 uid（EnlargeGuest 消息；0 = 无）。
  /// 放大布局 = 该主播占左侧大格，其余在右列堆叠
  final int enlargedUserId;

  /// 放大构图已确认开启（房间详情 enlarge_guest 标记或 EnlargeGuest 消息）。
  /// 多人（≥3 人）格子布局据此用"左大格+右侧小格"模板；
  /// 未确认放大时一律均匀网格（9 人局实测 3x3）
  final bool bigMode;

  /// 放大（画中画）布局：本房主播全屏、对手小窗（仅 2 人局）
  final bool pipMode;

  const LivePkState({
    this.battleId = 0,
    this.startTimeMs = 0,
    this.durationMs = 0,
    this.phase = LivePkPhase.running,
    this.mode = LivePkMode.unknown,
    this.participants = const [],
    this.topShowText,
    this.punishStartMs = 0,
    this.punishDurationMs = 0,
    this.teamBattle = false,
    this.localUserId = 0,
    this.enlargedUserId = 0,
    this.bigMode = false,
    this.pipMode = false,
  });

  int get count => participants.length;

  bool get hasScores => participants.length >= 2;

  /// 1v1 便捷访问
  LivePkSide? get left => participants.isEmpty ? null : participants.first;
  LivePkSide? get right => participants.length >= 2 ? participants[1] : null;

  int get totalScore {
    var t = 0;
    for (final p in participants) {
      t += p.score;
    }
    return t;
  }

  /// 1v1 左方占比 0.0~1.0；无分数时 0.5
  double get leftRatio {
    final a = left?.score ?? 0;
    final b = right?.score ?? 0;
    final t = a + b;
    if (t <= 0) return 0.5;
    final r = a / t;
    if (r < 0) return 0;
    if (r > 1) return 1;
    return r;
  }

  /// 队伍分桶（teamId -> 队伍总分）。
  /// 组队赛：队伍总分直接取服务端值——proto 的 UserScores 无 team id，
  /// 同队成员携带同一个 multi_pk_team_score；队伍分缺省（=0）也要入桶，
  /// 否则对手队总分 0 时进度条右侧无法显示 0（与网页版不符）。
  Map<int, int> get teamScores {
    final out = <int, int>{};
    for (final p in participants) {
      out[p.teamId] = p.teamScore > 0 ? p.teamScore : 0;
    }
    return out;
  }

  /// 顶部队伍条 [左队总分, 右队总分, 左占比]。
  /// 左 = 本房主播所在队（与网页版一致）；本房未知时取总分高的队。
  List<double> teamBar() {
    final ts = teamScores;
    if (ts.isEmpty) return const [0, 0, 0.5];
    final localTeam = localTeamId;
    int? leftKey = (localTeam != null && ts.containsKey(localTeam))
        ? localTeam
        : null;
    leftKey ??= ts.keys.reduce((a, b) => (ts[b]! > ts[a]!) ? b : a);
    final left = ts[leftKey] ?? 0;
    var right = 0;
    ts.forEach((k, v) {
      if (k != leftKey) right += v;
    });
    final total = left + right;
    final r = total <= 0 ? 0.5 : left / total;
    return [left.toDouble(), right.toDouble(), r];
  }

  /// 本房主播所在队伍键（localUserId 未知或不在参与者里时为 null）
  int? get localTeamId {
    if (localUserId == 0) return null;
    for (final p in participants) {
      if (p.userId == localUserId) return p.teamId;
    }
    return null;
  }

  double timeProgress(int nowMs) {
    if (durationMs <= 0 || startTimeMs <= 0) return 0;
    final p = (nowMs - startTimeMs) / durationMs;
    if (p < 0) return 0;
    if (p > 1) return 1;
    return p;
  }

  int remainingMs(int nowMs) {
    final r = startTimeMs + durationMs - nowMs;
    return r > 0 ? r : 0;
  }

  @override
  String toString() =>
      'LivePkState(battle=$battleId mode=$mode phase=$phase n=$count '
      'teams=$teamScores start=$startTimeMs dur=$durationMs)';
}

class _Army {
  final int userId;
  final int score;
  final String nickname;
  final String? avatar;
  _Army({
    required this.userId,
    required this.score,
    required this.nickname,
    this.avatar,
  });
}

// ─────────────────────────── 状态跟踪器 ───────────────────────────

class DouyinPkTracker {
  LivePkState? _state;
  LivePkState? get state => _state;

  /// 状态变化回调（含每次分数更新）
  Function(LivePkState state)? onUpdate;

  /// 调试：命中 PK 关键词但未被识别的 method（抓包期发现真实 method 名）
  void Function(String method)? onUnhandledPkMethod;

  /// userId → teamId（来自 LinkMicBattle.user_infos）
  final Map<int, int> _teamMap = <int, int>{};

  /// 参与者顺序锚点：首次出现顺序视为画面网格顺序（待抓包验证）
  final List<int> _order = <int>[];

  /// 昵称/头像缓存（Armies 可能不带昵称，用 Battle 里的补）
  final Map<int, _Army> _profile = <int, _Army>{};

  /// 每人最新分数
  final Map<int, int> _latestScores = <int, int>{};

  int _clockOffsetMs = 0;

  int get nowMs => DateTime.now().millisecondsSinceEpoch + _clockOffsetMs;

  /// 用 Response.now 校正本地时钟（在 _consumeResponse 里调用一次即可）
  void syncServerTime(int serverNowMs) {
    if (serverNowMs > 0) {
      _clockOffsetMs = serverNowMs - DateTime.now().millisecondsSinceEpoch;
    }
  }

  // ---- 诊断用只读计数（供日志输出）----
  int get debugNameCount => _nNames.length;
  int get debugOrderCount => _nOrder.length;
  int get debugProfileCount => _profile.length;

  /// 当前格子顺序（uid 列表，供日志核对映射）
  List<int> get debugOrder => List.of(_nOrder);

  /// 设置放大（画中画）模式。来源：房间详情 enlarge_guest 标记（定时刷新）
  /// 或 EnlargeGuest 消息；仅在 2 人局生效（state.pipMode 会按人数门控）
  void setPipMode(bool on) {
    if (_nPipMode == on) return;
    _nPipMode = on;
    _rebuildNew();
  }

  /// 退出连线/PK 结束后跟踪器清空（UI 层 stop 时调用 reset）
  /// 注入本房主播 uid（来自房间详情 owner.id_str）。
  /// 注意：user_scores 的 field 18 不是本房标记（实测会翻转到对手，
  /// 导致 1v1 左右互换、本房真名刷到对手格子上），勿再用它识别本房
  void setLocalUserId(int uid) {
    if (uid <= 0 || _nLocalId == uid) return;
    _nLocalId = uid;
    _rebuildSeatOrderIfFullyResolved();
    _rebuildNew();
  }

  /// 注入本房主播昵称提示（房间详情 userName）。owner uid 缺失时，
  /// 用 HTTP 查回的真名与之匹配，识别本房格（队色/条方向依赖）
  void setLocalNicknameHint(String nick) {
    _localNickHint = nick.trim();
    _matchLocalByNick();
  }

  static String _normNick(String s) =>
      s.replaceAll(RegExp(r'[^0-9A-Za-z一-龥]'), '');

  void _matchLocalByNick() {
    if (_nLocalId != 0 || _localNickHint.isEmpty) return;
    final hint = _normNick(_localNickHint);
    if (hint.isEmpty) return;
    for (final entry in _nNames.entries) {
      if (_normNick(entry.value) == hint) {
        _nLocalId = entry.key;
        _rebuildSeatOrderIfFullyResolved();
        _rebuildNew();
        return;
      }
    }
  }

  /// 注入连麦座位表（房间详情 linker_map）。
  /// 2026-09-13 实测语义：position -> room_id（房间号，不是 uid！
  /// 三个单人房样本的值都等于该房自己的 internalRoomId）。
  /// PK/连麦时 9 个主播各在自己房间，座位表给出每格对应哪个房间；
  /// 房间号 -> uid 由 UI 层用 reflow 接口解析后经 applyRoomOwner 回填。
  void setSeatRoomMap(Map<int, int> posToRoomId) {
    final clean = <int, int>{};
    posToRoomId.forEach((pos, rid) {
      if (pos >= 0 && rid > 0) clean[pos] = rid;
    });
    // 座位表从有到无 = 全员退出连线：清空参与者（徽章随之消失）。
    // 仅在之前确有座位数据时清，避免误伤无 linker_map 的房间；
    // 连续 2 次空表才清——单次空表可能只是详情接口风控抖动
    //（2026-09-13 夜间实测：战斗期间 API 会间歇性降级），误清会
    // 把进行中的战局徽章全部打没
    if (clean.isEmpty) {
      if (_seatRoomMap.isNotEmpty) {
        _seatEmptyStreak++;
        if (_seatEmptyStreak >= 2) {
          _seatRoomMap.clear();
          _seatOrder.clear();
          _roomOwner.clear();
          _nTotals.clear();
          _nRank.clear();
          _nTeamScore.clear();
          _nAnchorTeam.clear();
          _nNames.removeWhere((u, n) => n.startsWith('主播'));
          _nOrder.clear();
          _rebuildNew();
        }
      }
      return;
    }
    _seatEmptyStreak = 0;
    var changed = clean.length != _seatRoomMap.length ||
        clean.entries.any((e) => _seatRoomMap[e.key] != e.value);
    if (changed) {
      _seatRoomMap
        ..clear()
        ..addEntries(clean.entries);
      _rebuildSeatOrderIfFullyResolved();
    }
    if (changed) _rebuildNew();
  }

  /// 本房 internalRoomId（弹幕 args.roomId）：座位表里值等于它的
  /// 条目即本房位置，无需 reflow 解析
  void setOwnRoomId(int roomId) {
    if (roomId <= 0 || _ownRoomId == roomId) return;
    _ownRoomId = roomId;
    _rebuildSeatOrderIfFullyResolved();
  }

  /// 待解析的房间号（未尝试过或上次尝试已超 90s 的），UI 层逐个 reflow 查询。
  /// PK 局里 linker 值 = 战斗频道号（实测等于 BattleStatus 的 battleId，
  /// 不是真房间），reflow 查不到，直接跳过避免每 90s 白查一次
  List<int> get pendingRoomIds {
    final now = DateTime.now().millisecondsSinceEpoch;
    final battleChannel = int.tryParse(_nBattleIdStr ?? '') ?? 0;
    final out = <int>[];
    for (final rid in _seatRoomMap.values) {
      if (battleChannel != 0 && rid == battleChannel) continue;
      if (_roomOwner.containsKey(rid)) continue;
      final last = _roomOwnerAttempts[rid];
      if (last != null && now - last < 90000) continue;
      out.add(rid);
    }
    return out;
  }

  /// reflow 查询结果回填：room_id -> (uid, nickname)。
  /// 全部座位都解析成功后才启用座位排序（防部分解析把格子排错）
  void applyRoomOwner(int roomId, int uid, String nickname) {
    _roomOwnerAttempts[roomId] = DateTime.now().millisecondsSinceEpoch;
    if (uid <= 0) {
      _rebuildSeatOrderIfFullyResolved();
      return;
    }
    _roomOwner[roomId] = uid;
    if (nickname.isNotEmpty) _nNames[uid] = nickname;
    _rebuildSeatOrderIfFullyResolved();
    _rebuildNew();
  }

  /// 座位表 -> _seatOrder（position -> uid）：仅当每个座位都解析出
  /// uid 且 uid 在当前参与者名单里（战斗分已同步）才应用，防幻影格子
  void _rebuildSeatOrderIfFullyResolved() {
    if (_seatRoomMap.isEmpty) return;
    final mapped = <int, int>{};
    var allResolved = true;
    _seatRoomMap.forEach((pos, rid) {
      final uid = rid == _ownRoomId
          ? _nLocalId
          : (_roomOwner[rid] ?? 0);
      if (uid <= 0) {
        allResolved = false;
        return;
      }
      mapped[pos] = uid;
    });
    if (!allResolved || mapped.isEmpty) return;
    // 本房 uid 未知（owner 提取失败且昵称兜底未命中）时无法锚定本房格，
    // 放弃本次应用（保持回退顺序），日志可见
    if (_nLocalId == 0 && _seatRoomMap.containsValue(_ownRoomId)) {
      return;
    }
    // 战斗已同步出参与者名单时，座位 uid 必须与名单一致（防房间号换人）
    if (_nTotals.length >= 2) {
      final knownUids = _nTotals.keys.toSet();
      if (!mapped.values.every(knownUids.contains)) return;
    }
    if (_seatOrder.length == mapped.length &&
        mapped.entries.every((e) => _seatOrder[e.key] == e.value)) {
      return;
    }
    _seatOrder
      ..clear()
      ..addEntries(mapped.entries);
    for (final uid in mapped.values) {
      if (!_nTotals.containsKey(uid)) {
        _nTotals[uid] = 0; // 普通连麦：座位里的人即参与者，0 分也要入列
      }
      if (!_nNames.containsKey(uid)) _nNames[uid] = '主播${uid % 1000}';
    }
    _rebuildNew();
  }

  /// HTTP 查询到的昵称回填（uid -> 昵称），并触发一次状态重发
  void applyNicknames(Map<int, String> names) {
    var changed = false;
    names.forEach((uid, nick) {
      if (uid != 0 && nick.isNotEmpty && _nNames[uid] != nick) {
        _nNames[uid] = nick;
        changed = true;
      }
    });
    if (changed) _rebuildNew();
    _matchLocalByNick();
  }

  /// 每个主播携带的原始 multi_pk_team_score（验证同队是否同值用）
  Map<int, int> get debugRawTeamScores => Map.of(_nTeamScore);

  /// 每个主播的 battle_rank（验证格子顺序用）
  Map<int, int> get debugRanks => Map.of(_nRank);

  /// 座位表原始数据（核对 linker_map 用）
  Map<int, int> get debugSeatOrder => Map.of(_seatOrder);

  /// 座位房间号表 + 解析进度（核对 room_id->uid 用）
  Map<int, int> get debugSeatRoom => Map.of(_seatRoomMap);
  int get debugRoomResolvedCount => _roomOwner.length;
  int get debugOwnRoomId => _ownRoomId;

  /// 本房昵称提示
  String get debugLocalNickHint => _localNickHint;

  void reset() {
    _state = null;
    _teamMap.clear();
    _order.clear();
    _profile.clear();
    _latestScores.clear();
    // 新协议状态一并清理
    _nTotals.clear();
    _nNames.clear();
    _nOrder.clear();
    _nTeamScore.clear();
    _nAnchorTeam.clear();
    _nRank.clear();
    _nLocalId = 0;
    _nEnlargedUid = 0;
    _nPipMode = false;
    _seatRoomMap.clear();
    _roomOwner.clear();
    _roomOwnerAttempts.clear();
    _ownRoomId = 0;
    _seatEmptyStreak = 0;
    _seatOrder.clear();
    _nBattleIdStr = null;
    _nPhase = 0;
    _nStartMs = 0;
    _nDurSec = 0;
    _nPunishSec = 0;
    _nActive = false;
    _nHasTeamScores = false;
  }

  void _emit() {
    final s = _state;
    if (s != null) onUpdate?.call(s);
  }

  LivePkSide _buildSide(int userId) {
    final prof = _profile[userId];
    return LivePkSide(
      userId: userId,
      nickname: prof?.nickname ?? '',
      avatar: prof?.avatar,
      score: _latestScores[userId] ?? 0,
      teamId: _teamMap[userId] ?? 0,
    );
  }

  void _rebuild(LivePkPhase phase, {int? battleId, int? start, int? dur}) {
    final prev = _state;
    final ids = <int>[..._order];
    for (final k in _latestScores.keys) {
      if (!ids.contains(k)) ids.add(k);
    }
    for (final k in _profile.keys) {
      if (!ids.contains(k)) ids.add(k);
    }
    final parts = <LivePkSide>[];
    for (final id in ids) {
      if (!_latestScores.containsKey(id) && !_profile.containsKey(id)) continue;
      parts.add(_buildSide(id));
    }
    _state = LivePkState(
      battleId: battleId ?? prev?.battleId ?? 0,
      startTimeMs: start ?? prev?.startTimeMs ?? 0,
      durationMs: dur ?? prev?.durationMs ?? 0,
      phase: phase,
      mode: parts.length > 2 ? LivePkMode.team : LivePkMode.solo,
      participants: parts,
      topShowText: prev?.topShowText,
      punishDurationMs: prev?.punishDurationMs ?? 0,
      punishStartMs: prev?.punishStartMs ?? 0,
    );
  }

  /// WebcastLinkMicBattleMethod → LinkMicBattle：PK 开始 / 状态同步
  ///
  /// 注意：必须在解析完 user_infos（队伍映射）之后再重建状态，
  /// 否则 teamMap 尚未填充，participants 的 teamId 会全是 0。
  void onBattle(List<int> payload) {
    int? id;
    int? start;
    int? dur;

    final r = PbReader(payload);
    r.forEachField((f, w) {
      // battle_settings
      if (f == 2 && w == 2) {
        final v = PbReader(r.readBytes()).varintFields();
        id = v[2] ?? 0;
        start = v[3] ?? 0;
        dur = v[4] ?? 0;
        if (dur == 0 && start == 0) {
          id = v[1] ?? 0;
          start = v[2] ?? 0;
          dur = v[3] ?? 0;
        }
        return true;
      }
      // user_infos: map<int64, BattleUserInfo> —— 提供 teamId 与昵称
      if (f == 6 && w == 2) {
        final entry = PbReader(r.readBytes());
        var key = 0;
        List<int>? value;
        entry.forEachField((mf, mw) {
          if (mf == 1 && mw == 0) {
            key = entry.readVarint();
            return true;
          }
          if (mf == 2 && mw == 2) {
            value = entry.readBytes();
            return true;
          }
          return false;
        });
        if (value != null) _parseBattleUserInfo(key, value!);
        return true;
      }
      return false;
    });

    // 末尾统一重建一次，此时 teamMap / profile 已就绪
    _rebuild(LivePkPhase.running, battleId: id, start: start, dur: dur);
    _emit();
  }

  void _parseBattleUserInfo(int mapKey, List<int> bytes) {
    var userId = mapKey;
    var teamId = 0;
    var nickname = '';
    String? avatar;

    final r = PbReader(bytes);
    r.forEachField((f, w) {
      if (f == 1 && w == 2) {
        final br = PbReader(r.readBytes());
        br.forEachField((bf, bw) {
          if (bf == 1 && bw == 0) {
            userId = br.readVarint();
            return true;
          }
          if (bf == 2 && bw == 2) {
            nickname = br.readString();
            return true;
          }
          if (bf == 3 && bw == 2) {
            avatar = _firstImageUrl(br.readBytes());
            return true;
          }
          return false;
        });
        return true;
      }
      if (f == 10 && w == 0) {
        teamId = r.readVarint();
        return true;
      }
      return false;
    });

    if (userId == 0) return;
    _teamMap[userId] = teamId;
    final old = _profile[userId];
    _profile[userId] = _Army(
      userId: userId,
      score: old?.score ?? 0,
      nickname: nickname.isNotEmpty ? nickname : (old?.nickname ?? ''),
      avatar: avatar ?? old?.avatar,
    );
    if (!_order.contains(userId)) _order.add(userId);
  }

  /// WebcastLinkMicArmiesMethod → LinkMicArmies：PK 分数实时更新
  void onArmies(List<int> payload) {
    final collected = <int, _Army>{};
    String? topText;

    final r = PbReader(payload);
    r.forEachField((f, w) {
      if (w != 2) return false;
      final bytes = r.readBytes();
      switch (f) {
        case 2: // map<int64, UserArmies>
          {
            final er = PbReader(bytes);
            er.forEachField((mf, mw) {
              if (mf == 2 && mw == 2) {
                final a = _parseUserArmies(er.readBytes());
                if (a != null) collected[a.userId] = a;
                return true;
              }
              return false;
            });
            return true;
          }
        case 3: // repeated UserArmies
          {
            final a = _parseUserArmies(bytes);
            if (a != null) collected[a.userId] = a;
            return true;
          }
        case 5: // top_show_text
          {
            topText = utf8.decode(bytes, allowMalformed: true);
            return true;
          }
        default:
          return false;
      }
    });

    if (collected.isEmpty && topText == null) return;

    for (final a in collected.values) {
      _latestScores[a.userId] = a.score;
      final old = _profile[a.userId];
      _profile[a.userId] = _Army(
        userId: a.userId,
        score: a.score,
        nickname: a.nickname.isNotEmpty ? a.nickname : (old?.nickname ?? ''),
        avatar: a.avatar ?? old?.avatar,
      );
      if (!_order.contains(a.userId)) _order.add(a.userId);
    }

    _rebuild(LivePkPhase.running);
    if (topText != null) {
      final s = _state;
      if (s != null) {
        _state = LivePkState(
          battleId: s.battleId,
          startTimeMs: s.startTimeMs,
          durationMs: s.durationMs,
          phase: s.phase,
          mode: s.mode,
          participants: s.participants,
          topShowText: topText,
          punishDurationMs: s.punishDurationMs,
          punishStartMs: s.punishStartMs,
        );
      }
    }
    _emit();
  }

  /// WebcastLinkMicBattleFinishMethod → LinkMicBattleFinish：PK 结束
  void onFinish(List<int> payload) {
    final prev = _state;
    var punishDur = prev?.punishDurationMs ?? 0;
    var punishStart = 0;

    final r = PbReader(payload);
    r.forEachField((f, w) {
      if (f == 2 && w == 2) {
        final v = PbReader(r.readBytes()).varintFields();
        punishDur = v[19] ?? punishDur;
        punishStart = v[20] ?? 0;
        return true;
      }
      return false;
    });

    _state = LivePkState(
      battleId: prev?.battleId ?? 0,
      startTimeMs: prev?.startTimeMs ?? 0,
      durationMs: prev?.durationMs ?? 0,
      phase: punishDur > 0 ? LivePkPhase.punish : LivePkPhase.finished,
      mode: prev?.mode ?? LivePkMode.unknown,
      participants: prev?.participants ?? const [],
      topShowText: prev?.topShowText,
      punishDurationMs: punishDur,
      punishStartMs: punishStart,
    );
    _emit();
  }

  /// 注入 HTTP 侧拿到的初始状态（room.link_mic.battle_scores），可选
  void seedFromHttp({
    required Map<int, int> scores,
    int battleId = 0,
    int startTimeMs = 0,
    int durationMs = 0,
  }) {
    _latestScores.addAll(scores);
    for (final uid in scores.keys) {
      if (!_order.contains(uid)) _order.add(uid);
    }
    _rebuild(
      LivePkPhase.running,
      battleId: battleId,
      start: startTimeMs,
      dur: durationMs,
    );
    _emit();
  }

  static _Army? _parseUserArmies(List<int> bytes) {
    final r = PbReader(bytes);
    _Army? out;
    r.forEachField((f, w) {
      if (f == 1 && w == 2) {
        out = _parseUserArmy(r.readBytes());
        return true;
      }
      return false;
    });
    return out;
  }

  static _Army? _parseUserArmy(List<int> bytes) {
    var userId = 0;
    var score = 0;
    var nickname = '';
    String? avatar;

    final r = PbReader(bytes);
    r.forEachField((f, w) {
      switch (f) {
        case 1:
          if (w == 0) {
            userId = r.readVarint();
            return true;
          }
          return false;
        case 2:
          if (w == 0) {
            score = r.readVarint();
            return true;
          }
          return false;
        case 3:
          if (w == 2) {
            nickname = r.readString();
            return true;
          }
          return false;
        case 4:
          if (w == 2) {
            avatar = _firstImageUrl(r.readBytes());
            return true;
          }
          return false;
        default:
          return false;
      }
    });

    if (userId == 0) return null;
    return _Army(
      userId: userId,
      score: score,
      nickname: nickname,
      avatar: avatar,
    );
  }

  static String? _firstImageUrl(List<int> bytes) {
    String? url;
    final r = PbReader(bytes);
    r.forEachField((f, w) {
      if (f == 1 && w == 2) {
        final u = r.readString();
        if (url == null && u.startsWith('http')) url = u;
        return true;
      }
      return false;
    });
    return url;
  }

  // ==========================================================================
  // 新版协议（2026-09 实测）：WebcastLinkmic* / WebcastBattle*
  //
  // 旧协议（WebcastLinkMicBattleMethod / WebcastLinkMicArmiesMethod）在当前
  // 直播间已不再推送。新协议字段来源：Remember-the-past/douyin_proto 的
  // douyin.proto + 本机真实抓包盲解。
  //
  //   WebcastBattleStatusMessage
  //     2=战斗ID(str) 4=阶段(1进行/2惩罚) 6=总时长s 7=惩罚s 8=开始ms(str) 9=结束ms(str)
  //   WebcastLinkMicMethod            （总分同步）
  //     16=时长s 17=repeated UserScores{1=score,2=user_id,11=team_score}
  //   WebcastLinkmicPlayModeUpdateScoreMessage（增量加分）
  //     5=anchor_id 9=hot_score（增量，需累加）
  //   WebcastLinkmicUIMessage         （网格布局与昵称）
  //     3=Basic{5=repeated Position{1=position, 3=User{1=user_id(str), 2=nickname}}}
  //   WebcastBattleEndPunishMessage   （PK 结束）
  // ==========================================================================

  final Map<int, int> _nTotals = <int, int>{}; // anchorId -> 累计分数
  final Map<int, String> _nNames = <int, String>{}; // anchorId -> 昵称
  final List<int> _nOrder = <int>[]; // 按网格位置排序的 anchorId
  final Map<int, int> _nTeamScore = <int, int>{}; // teamId -> 队伍总分
  final Map<int, int> _nRank = <int, int>{}; // uid -> battle_rank（PK 内名次）
  int _nLocalId = 0; // 本房主播 uid（房间详情 owner.id_str，由 UI 层注入；0=未知）
  String _localNickHint = ''; // 本房主播昵称提示（房间详情 userName），昵称匹配兜底用
  /// 连麦座位表（房间详情 linker_map）：位置 -> room_id（房间号）。
  /// 房间号经 reflow 解析成 uid 后驱动 _seatOrder（格子顺序权威来源）
  final Map<int, int> _seatRoomMap = <int, int>{};
  int _seatEmptyStreak = 0; // 连续空表计数（防抖：≥2 才认定全员退出）
  final Map<int, int> _roomOwner = <int, int>{}; // room_id -> uid（已解析）
  final Map<int, int> _roomOwnerAttempts = <int, int>{}; // room_id -> 上次尝试时间
  int _ownRoomId = 0; // 本房 internalRoomId（弹幕 args.roomId）
  /// 座位表解析成功后的 position -> uid（格子顺序，权威来源）
  final Map<int, int> _seatOrder = <int, int>{};
  /// 放大构图确认开启：房间详情 enlarge_guest 标记（定时刷新注入）或
  /// EnlargeGuest 消息。2 人局=全屏+小窗构图，多人=左大格+右侧小格
  bool _nPipMode = false;
  int _nEnlargedUid = 0; // 被放大画面的主播 uid（EnlargeGuest；0=无）
  bool _nHasTeamScores = false; // user_scores 是否带队伍分（组队赛标志）
  final Map<int, int> _nAnchorTeam = <int, int>{}; // anchorId -> teamId
  String? _nBattleIdStr;
  int _nPhase = 0; // 1=进行中 2=惩罚
  int _nStartMs = 0;
  int _nDurSec = 0;
  int _nPunishSec = 0;
  bool _nActive = false;

  /// 回退格子顺序：本房优先（观看的房间通常是 PK 发起方，合成画面
  /// 首格=发起方），其余按首次入列序（≈挑战者加入顺序）。
  /// 注意：若本房只是挑战者（车轮战中途加入），真位置无法从现有
  /// 数据推出，此回退会错位
  List<int> _orderedIds() {
    final ids = _nTotals.keys.toList();
    if (_nLocalId != 0 && ids.contains(_nLocalId)) {
      ids.remove(_nLocalId);
      ids.insert(0, _nLocalId);
    }
    return ids;
  }

  /// WebcastBattleStatusMessage：PK 计时与阶段
  void onBattleStatus(List<int> payload) {
    final r = PbReader(payload);
    r.forEachField((f, w) {
      if (f == 2 && w == 2) {
        _nBattleIdStr = r.readString();
        return true;
      }
      if (f == 4 && w == 0) {
        _nPhase = r.readVarint();
        return true;
      }
      if (f == 6 && w == 0) {
        _nDurSec = r.readVarint();
        return true;
      }
      if (f == 7 && w == 0) {
        _nPunishSec = r.readVarint();
        return true;
      }
      if (f == 8 && w == 2) {
        _nStartMs = int.tryParse(r.readString()) ?? 0;
        return true;
      }
      if (f == 9 && w == 2) {
        final end = int.tryParse(r.readString()) ?? 0;
        if (_nStartMs > 0 && end > _nStartMs && _nDurSec == 0) {
          _nDurSec = ((end - _nStartMs) / 1000).round();
        }
        return true;
      }
      return false;
    });
    _nActive = true;
    _rebuildNew();
  }

  /// WebcastLinkmicPlayModeUpdateScoreMessage：某主播的增量分数
  void onScoreUpdate(List<int> payload) {
    int? anchor;
    int? add;
    final r = PbReader(payload);
    r.forEachField((f, w) {
      if (f == 5 && w == 0) {
        anchor = r.readVarint();
        return true;
      }
      if (f == 9 && w == 0) {
        add = r.readVarint();
        return true;
      }
      return false;
    });
    if (anchor == null || anchor == 0) return;
    final a = anchor!; // 非空副本（int? 不能直接作 Map<int,int> 的 key）
    _nTotals[a] = (_nTotals[a] ?? 0) + (add ?? 0);
    _nActive = true;
    _rebuildNew();
  }

  /// WebcastLinkMicMethod：总分同步（含队伍分）
  void onLinkMicMethod(List<int> payload) {
    int? score;
    int? uid;
    int? teamScore;
    int? rank;
    int? teamRank;
    final syncOrder = <int>[];
    final scoreUids = <int>[];
    final r = PbReader(payload);
    r.forEachField((f, w) {
      // linked_users（45 = repeated Data.User{1=user_id,2=nick_name,3=avatar}）
      // 完整名单的顺序即连麦格子顺序（2026-09-12 两场实测回归验证）
      if (f == 45 && w == 2) {
        final u = PbReader(r.readBytes());
        int? luid;
        String? nick;
        u.forEachField((uf, uw) {
          if (uf == 1 && uw == 0) {
            luid = u.readVarint();
            return true;
          }
          if (uf == 2 && uw == 2) {
            nick = u.readString();
            return true;
          }
          return false;
        });
        if (luid != null && luid != 0) {
          final id = luid!;
          syncOrder.add(id);
          if (!_nOrder.contains(id)) _nOrder.add(id);
          if (nick != null && nick!.isNotEmpty) _nNames[id] = nick!;
        }
        return true;
      }
      // user_scores（真实抓包：score/user_id 都是 varint，wire type 0）
      if (f == 17 && w == 2) {
        final s = PbReader(r.readBytes());
        s.forEachField((sf, sw) {
          if (sf == 1 && sw == 0) {
            score = s.readVarint();
            return true;
          }
          if (sf == 2 && sw == 0) {
            uid = s.readVarint();
            return true;
          }
          if (sf == 8 && sw == 0) {
            rank = s.readVarint();
            return true;
          }
          if (sf == 11 && sw == 0) {
            teamScore = s.readVarint();
            if (teamScore != null && teamScore != 0) _nHasTeamScores = true;
            return true;
          }
          if (sf == 12 && sw == 0) {
            teamRank = s.readVarint();
            return true;
          }
          return false;
        });
        // 闭包内赋值的变量不做类型提升，这里用 ! 断言
        if (uid != null && uid != 0) {
          final u = uid!;
          final sc = score;
          final ts = teamScore;
          final rk = rank;
          final tr = teamRank;
          scoreUids.add(u);
          // uid 出现在 user_scores 即为参与者。field 1（个人分）为 0 时
          // protobuf 省略字段（sc==null），必须写入 0——否则 0 分主播会从
          // 参与者列表消失（2026-09-12 实测 4 人房只出 3 格）
          _nTotals[u] = sc ?? 0;
          if (rk != null && rk != 0) _nRank[u] = rk!;
          if (ts != null && ts != 0) {
            _nTeamScore[u] = ts;
            // 队伍键：优先 multi_pk_team_rank（field 12，队伍排名，同队同值）。
            // 不能用队伍分值当键——两队同分时会撞成一个桶
            // （2026-09-12 实测 12000:12000 时进度条右侧显示 0）
            _nAnchorTeam[u] = (tr != null && tr != 0) ? tr! : ts;
          } else if (tr != null && tr != 0) {
            _nAnchorTeam[u] = tr!;
          }
        }
        score = null;
        uid = null;
        teamScore = null;
        rank = null;
        teamRank = null;
        return true;
      }
      return false;
    });
    // 全量同步的 user_scores 未包含的 uid = 已退出 PK 的主播，剔除
    // （2026-09-12 实测 8 人局退出 1 人后徽章残留 8 个）
    if (scoreUids.length >= 2) {
      _nTotals.removeWhere((u, _) => !scoreUids.contains(u));
      _nRank.removeWhere((u, _) => !scoreUids.contains(u));
      _nTeamScore.removeWhere((u, _) => !scoreUids.contains(u));
      _nAnchorTeam.removeWhere((u, _) => !scoreUids.contains(u));
      _nNames.removeWhere((u, _) => !scoreUids.contains(u));
      _nOrder.removeWhere((u) => !scoreUids.contains(u));
    }
    // 首个同步消息的名单可能只含部分人（先到者被顶到队头，导致徽章整体
    // 错位一格），因此名单不短于已跟踪人数时整体重排；个别缺的人补在尾部
    if (syncOrder.length >= 2 && syncOrder.length >= _nOrder.length) {
      final known = Set<int>.of(_nOrder);
      _nOrder
        ..clear()
        ..addAll(syncOrder);
      for (final u in known) {
        if (!_nOrder.contains(u)) _nOrder.add(u);
      }
    }
    _nActive = true;
    _rebuildNew();
  }

  /// WebcastLinkmicUIMessage：网格位置与昵称
  void onLinkmicUI(List<int> payload) {
    final r = PbReader(payload);
    r.forEachField((f, w) {
      if (f == 3 && w == 2) {
        final basic = PbReader(r.readBytes());
        basic.forEachField((bf, bw) {
          if (bf == 5 && bw == 2) {
            final pos = PbReader(basic.readBytes());
            int? position;
            String? uidStr;
            String? nick;
            pos.forEachField((pf, pw) {
              if (pf == 1 && pw == 0) {
                position = pos.readVarint();
                return true;
              }
              if (pf == 3 && pw == 2) {
                final user = PbReader(pos.readBytes());
                user.forEachField((uf, uw) {
                  if (uf == 1 && uw == 2) {
                    uidStr = user.readString();
                    return true;
                  }
                  if (uf == 2 && uw == 2) {
                    nick = user.readString();
                    return true;
                  }
                  return false;
                });
                return true;
              }
              return false;
            });
            final uid = int.tryParse(uidStr ?? '') ?? 0;
            if (uid != 0) {
              _nNames[uid] = (nick?.isNotEmpty ?? false) ? nick! : '主播$uid';
              if (!_nOrder.contains(uid)) {
                if (position == null) {
                  _nOrder.add(uid);
                } else {
                  final idx = position!.clamp(0, _nOrder.length);
                  _nOrder.insert(idx, uid);
                }
              }
            }
            return true;
          }
          return false;
        });
        return true;
      }
      return false;
    });
    _rebuildNew();
  }

  /// WebcastBattleEndPunishMessage：PK 结束（惩罚阶段）
  void onBattleEndPunish(List<int> payload) {
    _nPhase = 2;
    _rebuildNew();
  }

  /// WebcastLinkmicEnlargeGuestMessage：主持人放大/恢复某主播画面。
  /// 实测字节（恢复事件）：field 2=动作（2=恢复，reason=play_mode_finish），
  /// field 3=子消息（疑似含被放大者 uid，待放大事件样本确认）
  void onEnlarge(List<int> payload) {
    int? action;
    int? uid;
    final r = PbReader(payload);
    r.forEachField((f, w) {
      if (f == 2 && w == 0) {
        action = r.readVarint();
        return true;
      }
      if (f == 3 && w == 2) {
        final sub = PbReader(r.readBytes());
        sub.forEachField((sf, sw) {
          if (sf == 1 && sw == 0) {
            uid = sub.readVarint();
            return true;
          }
          return false;
        });
        return true;
      }
      return false;
    });
    if (action == 2) {
      _nEnlargedUid = 0; // 恢复
      _nPipMode = false;
    } else if (action != null && uid != null && uid != 0) {
      _nEnlargedUid = uid!;
      _nPipMode = true; // 放大（实测本房放大时为全屏+小窗构图）
    }
    _rebuildNew();
  }

  void _rebuildNew() {
    // 顺序优先级：座位表（linker_map，权威）> linked_users > 出现序。
    // 出现序 = 本房优先 + 其余按首次入列序（≈加入战斗频道顺序）：
    // 2026-09-13 你好阿童房 3人/4人两轮实测，真格序都是
    // [本房, 小豆包, 妮可, 简丹]——发起方在首格、挑战者按加入顺序入格；
    // uid 排序与此无关（只碰对过 1-3 格）
    final ids = _seatOrder.isNotEmpty
        ? [for (final p in _seatOrder.keys.toList()..sort()) _seatOrder[p]!]
        : _nOrder.isNotEmpty
            ? _nOrder
            : _orderedIds();
    final parts = <LivePkSide>[];
    for (final id in ids) {
      parts.add(LivePkSide(
        userId: id,
        nickname: _nNames[id] ?? '主播${id % 1000}',
        score: _nTotals[id] ?? 0,
        rank: _nRank[id] ?? 0,
        teamId: _nAnchorTeam[id] ?? 0,
        teamScore: _nTeamScore[id] ?? 0,
      ));
    }
    if (parts.isEmpty) return;

    // 1v1 注意：不做"本房强制在左"的交换——合成画面的左右以
    // linker_map 座位表为准（随刷新更新，抖音换位我们跟随）；
    // 强行交换会与真实构图打架（2026-09-13 实测：瞬间正确后又反转）
    if (parts.length == 2) {
      parts[0] = LivePkSide(
        userId: parts[0].userId,
        nickname: parts[0].nickname,
        avatar: parts[0].avatar,
        score: parts[0].score,
        rank: parts[0].rank,
        teamId: 1,
        teamScore: parts[0].teamScore,
      );
      parts[1] = LivePkSide(
        userId: parts[1].userId,
        nickname: parts[1].nickname,
        avatar: parts[1].avatar,
        score: parts[1].score,
        rank: parts[1].rank,
        teamId: 2,
        teamScore: parts[1].teamScore,
      );
    }

    var phase = LivePkPhase.running;
    if (_nPhase == 2) phase = LivePkPhase.punish;

    // 大格模板只在确认放大后启用（enlarge 标记/消息）；未放大的
    // 9 人局是 3x3 均匀构图（2026-09-13 实测），不能默认套大格模板
    final bid = int.tryParse(_nBattleIdStr ?? '') ?? 0;
    _state = LivePkState(
      battleId: bid,
      startTimeMs: _nStartMs,
      durationMs: _nDurSec * 1000,
      phase: phase,
      mode: parts.length > 2 ? LivePkMode.team : LivePkMode.solo,
      participants: parts,
      topShowText: _state?.topShowText,
      punishDurationMs: _nPunishSec * 1000,
      punishStartMs: _nStartMs + _nDurSec * 1000,
      teamBattle: _nHasTeamScores,
      localUserId: _nLocalId,
      enlargedUserId: _nEnlargedUid,
      bigMode: _nPipMode,
      pipMode: _nPipMode && parts.length == 2,
    );
    _emit();
  }
}

/// 判断 method 是否疑似 PK 相关（抓包期兜底发现真实 method 名）
bool isPkLikeMethod(String method) {
  final m = method.toLowerCase();
  return m.contains('linkmic') ||
      m.contains('battle') ||
      m.contains('armies') ||
      m.contains('against');
}
