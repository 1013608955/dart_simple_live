/// 抖音直播流 SEI 布局解析器。
///
/// 从旁路 FLV 连接的字节流中提取连麦格子布局（app_data）。
/// 真实格式（2026-09-18 实流验证，tools/fetch_stream_sei.py）：
///   FLV video tag(AVC, packetType=1)
///     → AVCC NALU（4 字节长度前缀）
///     → NAL type=6 (SEI)
///     → payload_type=100 (0x64)，size 为 ff 填充变长
///     → body = UTF-8 JSON（尾部 0x80 rbsp trailing）
///   外层 JSON: {app_data:"<转义JSON>", live_crop:{...}, ...}
///   app_data: {ver, grids:[{p,x,y,w,h,uid_str,mute_audio,talk_volume}],
///              anchor_interact_info:{focus_id, owner_index, layout_type}}
/// 兼容分支：payload_type=5 时跳过 16 字节 UUID 再取 JSON（网页播放器路径）。
library;

import 'dart:convert';

/// 单个连麦格子的布局信息
class SeiGrid {
  final int slot;
  final double x;
  final double y;
  final double w;
  final double h;
  final String linkmicId;
  final bool muteAudio;
  final double talkVolume;

  const SeiGrid({
    required this.slot,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.linkmicId,
    this.muteAudio = false,
    this.talkVolume = 0,
  });

  static SeiGrid? fromJson(Map<String, dynamic> json) {
    final id = json["uid_str"]?.toString() ?? "";
    if (id.isEmpty) return null;
    double? toNum(v) => v is num ? v.toDouble() : double.tryParse("$v");
    final x = toNum(json["x"]);
    final y = toNum(json["y"]);
    final w = toNum(json["w"]);
    final h = toNum(json["h"]);
    if (x == null || y == null || w == null || h == null) return null;
    return SeiGrid(
      slot: (json["p"] is num) ? (json["p"] as num).toInt() : 0,
      x: x,
      y: y,
      w: w,
      h: h,
      linkmicId: id,
      muteAudio: json["mute_audio"] == 1,
      talkVolume: toNum(json["talk_volume"]) ?? 0,
    );
  }
}

/// 一次 SEI 解析出的完整布局状态
class SeiLayout {
  /// grId 版本号（ver 字段）
  final int ver;

  /// 本房主播槽位（anchor_interact_info.owner_index），-1 表示未知
  final int ownerSlot;

  /// 放大者 linkmic_id（anchor_interact_info.focus_id），空表示无放大
  final String focusLinkmicId;

  final List<SeiGrid> grids;

  /// 外层 timestamp（毫秒）
  final int timestamp;

  const SeiLayout({
    required this.ver,
    required this.ownerSlot,
    required this.focusLinkmicId,
    required this.grids,
    required this.timestamp,
  });

  bool get isEmpty => grids.isEmpty;
}

/// FLV/NALU/SEI 增量解析器。喂数据，出布局。
class DouyinSeiParser {
  final _buf = <int>[];
  bool _headerSkipped = false;
  int _seiCount = 0;

  /// 垃圾流防护上限：非 FLV 数据永远切不出 tag，超限丢弃重来
  static const int _maxBuffer = 8 << 20; // 8MB

  int get seiCount => _seiCount;

  /// 当前已解析的最新布局（无变化时返回同一引用）
  SeiLayout? latest;

  /// 喂入任意长度的流字节，内部缓冲并按 FLV tag 切分。
  /// 返回本次新解析出的布局（可能为 null）。
  SeiLayout? feed(List<int> bytes) {
    _buf.addAll(bytes);
    // 防护：接到非 FLV 流（错误页/HTML/HLS 误接）时 tag 永远切不出来，
    // 缓冲会无限增长——超限直接丢弃（旁路解析可牺牲，内存不可失控）
    if (_buf.length > _maxBuffer || _pending.length > _maxBuffer) {
      _buf.clear();
      _pending.clear();
      _headerSkipped = false;
    }
    if (!_headerSkipped) {
      if (_buf.length < 13) return null;
      // FLV header: 'FLV' + version + flags + headerSize(4B)，随后 4B PreviousTagSize0
      if (_buf[0] != 0x46 || _buf[1] != 0x4C || _buf[2] != 0x56) {
        // 不是 FLV（可能从 tag 流中间接入），放弃头部校验按 tag 流处理
        _headerSkipped = true;
      } else {
        final headerSize = _readU32(_buf, 9);
        final skip = 9 + headerSize + 4;
        if (_buf.length < skip) return null;
        _buf.removeRange(0, skip);
        _headerSkipped = true;
      }
    }
    SeiLayout? result;
    while (true) {
      final tag = _tryPopTag();
      if (tag == null) break;
      final layout = _handleTag(tag);
      if (layout != null) {
        latest = layout;
        result = layout;
      }
    }
    return result;
  }

  void reset() {
    _buf.clear();
    _headerSkipped = false;
    _pending.clear();
    latest = null;
  }

  final _pending = <int>[];

  // 按 FLV tag 结构切分：11B 头 + body + 4B prevSize
  List<int>? _tryPopTag() {
    if (_buf.isNotEmpty) {
      _pending.addAll(_buf);
      _buf.clear();
    }
    if (_pending.length < 11) return null;
    final bodySize =
        (_pending[1] << 16) | (_pending[2] << 8) | _pending[3];
    final total = 11 + bodySize + 4;
    if (_pending.length < total) return null;
    final tag = _pending.sublist(0, total);
    _pending.removeRange(0, total);
    return tag;
  }

  SeiLayout? _handleTag(List<int> tag) {
    final type = tag[0];
    if (type != 9) return null; // 只要视频 tag
    final body = tag.sublist(11, tag.length - 4);
    if (body.length < 5) return null;
    // FLV video: frameType(4b) + codecId(4b)；codec 7 = AVC
    if ((body[0] & 0x0F) != 7) return null;
    if (body[1] != 1) return null; // 1 = NALU
    var p = 5; // 跳过 composition time
    SeiLayout? layout;
    while (p + 4 <= body.length) {
      final naluLen =
          (body[p] << 24) | (body[p + 1] << 16) | (body[p + 2] << 8) | body[p + 3];
      p += 4;
      if (naluLen <= 0 || p + naluLen > body.length) break;
      final nalu = body.sublist(p, p + naluLen);
      p += naluLen;
      if (nalu.isEmpty) continue;
      final nalType = nalu[0] & 0x1F;
      if (nalType != 6) continue; // SEI
      final sei = _parseSeiNalu(nalu);
      if (sei != null) {
        _seiCount++;
        final parsed = _extractLayout(sei);
        if (parsed != null) layout = parsed;
      }
    }
    return layout;
  }

  /// 解析一个 SEI NALU，返回信封 JSON 文本（app_data 所在层），失败返回 null
  String? _parseSeiNalu(List<int> nalu) {
    // 去掉 NAL header（1~2 字节，由 forbidden_zero_bit 后的 nuh_layer_id 决定；
    // 抖音流实测 1 字节，保守起见按 nalType 高 2 位判断）
    final hdrSize = ((nalu[0] >> 5) & 0x03) == 0 ? 1 : 2;
    if (nalu.length <= hdrSize) return null;
    var pl = _removeEpb(nalu.sublist(hdrSize));
    var i = 0;

    // 可能一帧含多条 SEI message，循环处理
    String? found;
    while (i < pl.length) {
      final start = i;
      // payload type
      var ptype = 0;
      while (i < pl.length && pl[i] == 255) {
        ptype += 255;
        i += 1;
      }
      if (i >= pl.length) break;
      ptype += pl[i];
      i += 1;
      // payload size
      var psize = 0;
      while (i < pl.length && pl[i] == 255) {
        psize += 255;
        i += 1;
      }
      if (i >= pl.length) break;
      psize += pl[i];
      i += 1;
      if (i + psize > pl.length) {
        // 尺寸异常，取剩余全部
        psize = pl.length - i;
      }
      var body = pl.sublist(i, i + psize);
      i += psize;
      // 实测：0xFF 填充后跟 JSON（type=100）；网页路径：type=5 + 16B UUID
      if (ptype == 5) {
        if (body.length > 16) body = body.sublist(16);
      }
      final text = _tryDecodeJsonText(body);
      if (text != null) found = text;
      if (found != null && i >= pl.length) break;
      if (i == start) break; // 防死循环
    }
    return found;
  }

  /// 从 SEI body 提取 JSON 文本：直接 JSON、或 0xFF 填充后 JSON
  String? _tryDecodeJsonText(List<int> body) {
    // 找第一个 '{'，且要求附近存在 app_data 或 ver 字段特征，避免误吃视频数据
    var start = -1;
    for (var i = 0; i < body.length; i++) {
      if (body[i] == 0x7B) {
        start = i;
        break;
      }
    }
    if (start < 0) return null;
    // 从尾部找 '}'（rbsp trailing 0x80 已含在 psize 内）
    var end = body.length;
    while (end > start && (body[end - 1] == 0x80 || body[end - 1] == 0x00)) {
      end -= 1;
    }
    if (end <= start) return null;
    try {
      final text = utf8.decode(body.sublist(start, end), allowMalformed: true);
      if (text.startsWith("{") && text.endsWith("}")) {
        return text;
      }
    } catch (_) {}
    return null;
  }

  /// 解析信封 JSON → SeiLayout。外层含 app_data 字符串则二次解析。
  SeiLayout? _extractLayout(String text) {
    try {
      final outer = json.decode(text);
      if (outer is! Map) return null;
      dynamic appData = outer["app_data"];
      if (appData is String) {
        appData = json.decode(appData);
      }
      if (appData is! Map) return null;
      return _buildLayout(appData);
    } catch (_) {
      return null;
    }
  }

  SeiLayout? _buildLayout(Map appData) {
    final gridsRaw = appData["grids"];
    if (gridsRaw is! List || gridsRaw.isEmpty) return null;
    final grids = <SeiGrid>[];
    for (final g in gridsRaw) {
      if (g is Map) {
        final grid = SeiGrid.fromJson(g.cast<String, dynamic>());
        if (grid != null) grids.add(grid);
      }
    }
    if (grids.isEmpty) return null;

    var ownerSlot = -1;
    var focusId = "";
    final info = appData["anchor_interact_info"];
    if (info is Map) {
      ownerSlot = (info["owner_index"] is num) ? (info["owner_index"] as num).toInt() : -1;
      focusId = info["focus_id"]?.toString() ?? "";
    }
    final ver = (appData["ver"] is num) ? (appData["ver"] as num).toInt() : 0;
    var ts = 0;
    if (appData["timestamp"] is num) {
      ts = (appData["timestamp"] as num).toInt();
    }
    return SeiLayout(
      ver: ver,
      ownerSlot: ownerSlot,
      focusLinkmicId: focusId,
      grids: grids,
      timestamp: ts,
    );
  }

  static int _readU32(List<int> b, int i) =>
      (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];

  static List<int> _removeEpb(List<int> b) {
    final out = <int>[];
    var i = 0;
    final n = b.length;
    while (i < n) {
      if (i + 2 < n && b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 3) {
        out.add(0);
        out.add(0);
        i += 3;
      } else {
        out.add(b[i]);
        i += 1;
      }
    }
    return out;
  }
}
