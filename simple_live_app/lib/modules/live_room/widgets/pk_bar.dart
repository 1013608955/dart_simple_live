import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'package:simple_live_core/src/danmaku/douyin_pk.dart';

// ============================================================================
// 抖音 PK / 连麦 UI   v9
//
// 形态区分（依据 2026-09-12 实测与用户截图）：
//   组队赛(teamBattle=true)   → 顶部双方进度条 + 倒计时（榜十总榜样式）
//   1v1(count==2)             → 顶部双方进度条 + 倒计时
//   个人赛(count>2, 非组队)   → 仅紧凑倒计时，无进度条；每框显示 名字+分数
//   未开 PK 的多人连麦        → 每框仅显示主播名字
//   任意时刻(viewers>0)       → 右上角「观看人数: N」黑底红字角标（仿网页版）
//
// 位置换算：播放器默认 BoxFit.contain 会留黑边，必须按视频实际显示矩形定位。
// 多人(count>2)合成画面（竖屏 1080x1920）格子带 = 视频高度 18.75%~68.75%
// （模板：顶部背景带 360 + 格子区 960 + 底部 600，三张截图实测一致）。
// 格子布局自适应（_layoutCells）：4人=2x2；3人/主持人放大=左大格+右列堆叠。
// 徽章=每格左下（名次+分数，0 分不显名次）、名字=每格右下。
// 组队赛条=teamBar()：左=本房主播所在队（field 18 标记）。
// ============================================================================

class DouyinPkLayer extends StatefulWidget {
  final Rx<LivePkState?> state;
  final int Function() nowMs;

  /// 视频真实宽高比（宽/高）提供器。null 或 <=0 表示未知，按铺满处理
  final double? Function()? videoAspectRatioProvider;

  /// 播放器缩放模式提供器：0=contain 1=fill 2=cover 3=contain16:9 4=contain4:3
  final int Function()? scaleModeProvider;

  /// 房间实时观看人数（抖音 RoomUserSeq → controller.online）。
  /// null = 非抖音站点，不显示人数角标；值 <=0 时角标隐藏（数据未到不闪 0）
  final Rx<int>? viewerCount;

  /// 本房主播昵称（来自房间详情 HTTP 接口，WS 消息不含昵称）。
  /// 用于本房格子的真名显示；对手昵称仍为占位符
  final String localNickname;

  /// 直播间标题（房间详情），渲染在视频顶部居中（仿网页版黑底白字胶囊）。
  /// PK 期间下移避让进度条，与观看人数角标同排
  final String title;

  const DouyinPkLayer({
    super.key,
    required this.state,
    required this.nowMs,
    this.videoAspectRatioProvider,
    this.scaleModeProvider,
    this.viewerCount,
    this.localNickname = '',
    this.title = '',
  });

  @override
  State<DouyinPkLayer> createState() => _DouyinPkLayerState();
}

class _DouyinPkLayerState extends State<DouyinPkLayer> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// BoxFit.contain 下视频在控件内的实际显示矩形
  Rect _videoRect(Size box) {
    final ar = widget.videoAspectRatioProvider?.call();
    final mode = widget.scaleModeProvider?.call() ?? 0;
    if (ar == null || ar <= 0 || mode == 1 || mode == 2) {
      return Offset.zero & box;
    }
    final boxAr = box.width / box.height;
    if (ar > boxAr) {
      final h = box.width / ar;
      return Rect.fromLTWH(0, (box.height - h) / 2, box.width, h);
    } else {
      final w = box.height * ar;
      return Rect.fromLTWH((box.width - w) / 2, 0, w, box.height);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final s = widget.state.value;
      // 观看人数角标不依赖 PK 状态（viewerCount 为 null 表示非抖音站点）
      final viewers = widget.viewerCount?.value ?? 0;
      // 无 PK 数据、无人数且无标题时什么都不显示
      if ((s == null || s.count == 0) &&
          viewers <= 0 &&
          widget.title.isEmpty) {
        return const SizedBox.shrink();
      }
      // 惩罚倒计时走完 → PK 彻底结束，PK 元素全部消失（此前停在"PK结束(0s)"）。
      // 进行中但时间走完且无惩罚信号（如对方提前退出连线）→ 同样视为结束
      final pkOver = s != null &&
          ((s.phase == LivePkPhase.punish &&
                  s.punishDurationMs > 0 &&
                  s.punishStartMs > 0 &&
                  widget.nowMs() >= s.punishStartMs + s.punishDurationMs) ||
              (s.phase == LivePkPhase.running &&
                  s.startTimeMs > 0 &&
                  s.durationMs > 0 &&
                  widget.nowMs() >= s.startTimeMs + s.durationMs));
      if (s == null || s.count == 0) {
        // 无 PK 数据：只剩标题与人数角标
        if (viewers <= 0 && widget.title.isEmpty) {
          return const SizedBox.shrink();
        }
        return LayoutBuilder(
          builder: (context, c) {
            final rect = _videoRect(Size(c.maxWidth, c.maxHeight));
            final scale = (rect.width / 900).clamp(1.0, 2.2);
            return Stack(
              children: [
                if (widget.title.isNotEmpty)
                  Positioned(
                    top: rect.top + 8 * scale,
                    left: rect.left,
                    width: rect.width,
                    child: Center(
                      child: ConstrainedBox(
                        constraints:
                            BoxConstraints(maxWidth: rect.width * 0.52),
                        child: Container(
                          padding: EdgeInsets.symmetric(
                              horizontal: 10 * scale, vertical: 3 * scale),
                          decoration: BoxDecoration(
                            color: const Color(0xD90F1013),
                            borderRadius: BorderRadius.circular(5 * scale),
                          ),
                          child: Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 13 * scale,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (viewers > 0)
                  Positioned(
                    // 标题下方一行：长标题时人数角标纵向堆叠避让
                    top: rect.top +
                        8 * scale +
                        (widget.title.isNotEmpty ? 30 * scale : 0),
                    left: rect.left,
                    width: rect.width,
                    child: Align(
                      alignment: Alignment.topRight,
                      child: DouyinViewerCountBadge(
                          count: viewers, scale: scale),
                    ),
                  ),
              ],
            );
          },
        );
      }

      return LayoutBuilder(
        builder: (context, c) {
          final rect = _videoRect(Size(c.maxWidth, c.maxHeight));
          // PK 元素结束（pkOver）后条/倒计时消失，徽章（名字+分值）保留
          final hasBattle = s.durationMs > 0 && !pkOver;
          final scale = (rect.width / 900).clamp(1.0, 2.2);
          // 标题固定在视频顶部；PK 条下移避让标题（用户要求，勿改反）
          final hasTitle = widget.title.isNotEmpty;
          final barTop = rect.top + 8 * scale + (hasTitle ? 30 * scale : 0);
          // 人数角标纵向堆叠避让：标题行 → PK 条行 → 角标行，永不重叠
          final badgeTop = rect.top +
              8 * scale +
              (hasTitle ? 30 * scale : 0) +
              (hasBattle ? 52 * scale : 0);

          return Stack(
            children: [
              // 顶部居中：直播间标题（仿网页版黑底白字胶囊，位置固定）
              if (hasTitle)
                Positioned(
                  top: rect.top + 8 * scale,
                  left: rect.left,
                  width: rect.width,
                  child: Center(
                    child: ConstrainedBox(
                      constraints:
                          BoxConstraints(maxWidth: rect.width * 0.52),
                      child: Container(
                        padding: EdgeInsets.symmetric(
                            horizontal: 10 * scale, vertical: 3 * scale),
                        decoration: BoxDecoration(
                          color: const Color(0xD90F1013),
                          borderRadius: BorderRadius.circular(5 * scale),
                        ),
                        child: Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 13 * scale,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              // 顶部双方进度条（组队赛 / 1v1）
              if (hasBattle && (s.teamBattle || s.count == 2))
                Positioned(
                  top: barTop,
                  left: rect.left,
                  width: rect.width,
                  child: Center(
                    child: DouyinPkBar(
                        state: s, nowMs: widget.nowMs, scale: scale),
                  ),
                ),
              // 个人赛：紧凑倒计时（仿抖音「PK 06:51」样式）
              if (hasBattle && !(s.teamBattle || s.count == 2))
                Positioned(
                  top: barTop,
                  left: rect.left,
                  width: rect.width,
                  child: Center(
                    child: DouyinPkCountdownChip(
                        state: s, nowMs: widget.nowMs, scale: scale),
                  ),
                ),
              // 格子徽章（count>=2）：叠加在合成画面的格子上。
              // 实测（2026-09-12 多张截图交叉验证）：竖屏合成流(1080x1920)
              // 多人格子带 = 视频高度 18.75%~68.75%（模板 360+960+600）；
              // 1v1 = 两个格子并排占上部约 45%。布局自适应见 _layoutCells。
              // PK 期间显示 名次+分数（本房队粉/对方队蓝）；非 PK 连麦时
              // 有礼物值也显示（同网页版）；1v1 只显名字（分数在条上）。
              if (s.count >= 2)
                Positioned(
                  left: rect.left,
                  top: rect.top +
                      rect.height * (s.count == 2 ? 0 : 0.1875),
                  width: rect.width,
                  height: rect.height * (s.count == 2 ? 0.60 : 0.50),
                  child: DouyinPkGridOverlay(
                    state: s,
                    width: rect.width,
                    height: rect.height * (s.count == 2 ? 0.60 : 0.50),
                    hasBattle: hasBattle,
                    scale: scale,
                    localNickname: widget.localNickname,
                  ),
                ),
              // 右上角：实时观看人数（标题存在时与标题同排，人数靠右）
              if (viewers > 0)
                Positioned(
                  top: badgeTop,
                  left: rect.left,
                  width: rect.width,
                  child: Align(
                    alignment: Alignment.topRight,
                    child: DouyinViewerCountBadge(
                        count: viewers, scale: scale),
                  ),
                ),
            ],
          );
        },
      );
    });
  }
}

// ─────────────────── 顶部双方进度条（组队赛 / 1v1） ───────────────────

class DouyinPkBar extends StatelessWidget {
  final LivePkState state;
  final int Function() nowMs;
  final double scale;

  const DouyinPkBar({
    super.key,
    required this.state,
    required this.nowMs,
    this.scale = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final ds = scale;
    final isTeam = state.mode == LivePkMode.team;
    // 队伍条：[左队总分, 右队总分, 左占比]，左=本房主播所在队（teamBar）
    final bars = state.teamBar();
    // 1v1：条左=本房主播（用户口径，与格子层本房左置一致）。
    // 参与者顺序来自座位表，本房不一定在 [0]，直接用会左右反
    //（2026-09-13 实测：林昙房 1515/1819 分数反）
    var left = state.left;
    var right = state.right;
    if (!isTeam &&
        state.localUserId != 0 &&
        left != null &&
        right != null &&
        left.userId != state.localUserId &&
        right.userId == state.localUserId) {
      final t = left;
      left = right;
      right = t;
    }
    final ls = left?.score ?? 0;
    final rs = right?.score ?? 0;
    final ratio = isTeam
        ? bars[2]
        : (ls + rs > 0 ? ls / (ls + rs) : 0.5);
    final leftFlex = (ratio * 100).round().clamp(2, 98);
    final rightFlex = 100 - leftFlex;

    final leftScore = isTeam ? bars[0].round() : ls;
    final rightScore = isTeam ? bars[1].round() : rs;

    final remain = state.remainingMs(nowMs());
    final mm = (remain ~/ 60000).toString().padLeft(2, '0');
    final ss = ((remain % 60000) ~/ 1000).toString().padLeft(2, '0');
    final label = state.phase == LivePkPhase.punish
        ? _punishLabel(state, nowMs())
        : (state.durationMs > 0 ? '$mm:$ss' : 'PK');

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12 * ds, vertical: 6 * ds),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.45),
        borderRadius: BorderRadius.circular(12 * ds),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Colors.white,
              fontSize: 12 * ds,
              fontWeight: FontWeight.w500,
            ),
          ),
          SizedBox(height: 5 * ds),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 分数可达 7~9 位（队伍总分），FittedBox 防折行/溢出
              SizedBox(
                width: 76 * ds,
                height: 20 * ds,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '$leftScore',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14 * ds,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
              SizedBox(width: 8 * ds),
              SizedBox(
                width: 180 * ds,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4 * ds),
                  child: SizedBox(
                    height: 8 * ds,
                    child: Row(
                      children: [
                        Expanded(
                          flex: leftFlex,
                          child: Container(color: const Color(0xFFE24B8A)),
                        ),
                        Expanded(
                          flex: rightFlex,
                          child: Container(color: const Color(0xFF378ADD)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              SizedBox(width: 8 * ds),
              SizedBox(
                width: 76 * ds,
                height: 20 * ds,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '$rightScore',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14 * ds,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 惩罚阶段剩余秒数 → 「PK结束 (Ns)」
  static String _punishLabel(LivePkState s, int now) {
    final end = s.punishStartMs + s.punishDurationMs;
    if (s.punishDurationMs <= 0) return 'PK结束';
    final left = ((end - now) / 1000).ceil().clamp(0, 9999);
    return 'PK结束 (${left}s)';
  }
}

// ─────────────── 个人赛：紧凑倒计时（仿「PK 06:51」） ───────────────

class DouyinPkCountdownChip extends StatelessWidget {
  final LivePkState state;
  final int Function() nowMs;
  final double scale;

  const DouyinPkCountdownChip({
    super.key,
    required this.state,
    required this.nowMs,
    this.scale = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final ds = scale;
    final remain = state.remainingMs(nowMs());
    final mm = (remain ~/ 60000).toString().padLeft(2, '0');
    final ss = ((remain % 60000) ~/ 1000).toString().padLeft(2, '0');
    final label = state.phase == LivePkPhase.punish
        ? DouyinPkBar._punishLabel(state, nowMs())
        : 'PK $mm:$ss';

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10 * ds, vertical: 4 * ds),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.45),
        borderRadius: BorderRadius.circular(10 * ds),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white,
          fontSize: 13 * ds,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ─────────────── 多人：每格 名字 + 分数（布局自适应） ───────────────

/// 单个格子：参与者 + 在格子带内的占比矩形
class _PkCell {
  final LivePkSide side;
  final double left;
  final double top;
  final double width;
  final double height;
  const _PkCell(
    this.side, {
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });
}

/// 由参与人数推断网格列数（抖音连麦布局：4人=2x2、6人=3x2、
/// 8人=4x2（2026-09-12 实测）、9人=3x3；7人按 4 列 4+3 推测）
int _columnsFor(int n) {
  if (n <= 2) return 2;
  if (n <= 4) return 2;
  if (n <= 6) return 3;
  if (n <= 8) return 4;
  return 3;
}

/// 合成画面布局（返回格子带比例坐标）：
///   2 人（1v1）      → 两格并排占上部 62%（用户微调：名字再往下一点）
///   4 人            → 2x2 均匀网格
///   3 人            → 左侧大格（本房主播，未知则第 1 名）+ 右列 2 格按名次
///   9 人            → 默认 3x3 均匀网格（实测）；确认放大后才用
///                     左侧大格 + 右侧 3x3 八格
///   主持人放大       → 被放大者占左侧大格 + 其余右列堆叠
///   其他（5-6 人等） → 均匀网格（列数按人数推断，未实测）
List<_PkCell> _layoutCells(LivePkState s) {
  final n = s.count;
  if (n == 2) {
    // 2 人：本房主播固定在左（用户口径），对手在右；
    // 放大（画中画）时：本房全屏大画面、对手右下小窗（实测构图）
    var first = s.participants[0];
    var second = s.participants[1];
    if (s.localUserId != 0 && second.userId == s.localUserId) {
      first = s.participants[1];
      second = s.participants[0];
    }
    if (s.pipMode) {
      return [
        _PkCell(first, left: 0, top: 0, width: 1, height: 1),
        _PkCell(second, left: 0.70, top: 0.62, width: 0.28, height: 0.22),
      ];
    }
    return [
      _PkCell(first, left: 0, top: 0, width: 0.5, height: 1),
      _PkCell(second, left: 0.5, top: 0, width: 0.5, height: 1),
    ];
  }
  int? bigUid = s.enlargedUserId != 0 ? s.enlargedUserId : null;
  // 大格模板只在"确认放大"后启用（EnlargeGuest 消息指定被放大者，
  // 或房间详情 enlarge_guest 标记经 bigMode 透传）；3 人局连麦构图
  // 本身就是大格+右列。未放大的 9 人局是 3x3 均匀构图（2026-09-13
  // 实测），默认套大格模板会让分值/名字整体错位一格
  if (bigUid == null && (n == 3 || s.bigMode)) {
    bigUid = s.localUserId != 0 ? s.localUserId : _rank1Uid(s);
  }
  if (bigUid != null && n >= 3) {
    LivePkSide? big;
    final rest = <LivePkSide>[];
    for (final p in s.participants) {
      if (p.userId == bigUid && big == null) {
        big = p;
      } else {
        rest.add(p);
      }
    }
    big ??= s.participants.first;
    // 右列顺序保持参与者顺序（本房优先+加入序，见 tracker _orderedIds）。
    // 不能按名次排：3 人局实测 rank3 在上、rank1 在下，名次序与画面相反
    final cells = <_PkCell>[
      _PkCell(big, left: 0, top: 0, width: 0.5, height: 1),
    ];
    final m = rest.length;
    // 右侧小格列数：2-4 人单列（3 人局实测），5-6 人两列，7-9 人三列
    //（9 人局实测右侧 3x3）
    final rc = m <= 2 ? 1 : (m <= 6 ? 2 : 3);
    final rr = (m / rc).ceil();
    for (var i = 0; i < m; i++) {
      cells.add(_PkCell(
        rest[i],
        left: 0.5 + (i % rc) * (0.5 / rc),
        top: (i ~/ rc) / rr,
        width: 0.5 / rc,
        height: 1 / rr,
      ));
    }
    return cells;
  }
  // 组队局：合成画面按队伍分块，我队（=条左粉队）占左侧格子。
  // 2026-09-13 彭百万房 3v3 实测：我队 3 人占 [左上、中上、左下]，
  // 对方队占剩余（用户观察"我队都在左边"；名次序/加入序都不符合，
  // 只有按队伍分块吻合）。4人(2v2) 按左列 [0,2]；1v3 人数不均时
  // 我队按序占前几格，对方队填满剩余（v32 4人局实测）。
  // 我队成员在格子内的先后 = 参与者顺序（本房优先+加入序）
  if (s.teamBattle && (s.localTeamId ?? 0) != 0) {
    final localTeam = s.localTeamId!;
    final teamA = <LivePkSide>[];
    final teamB = <LivePkSide>[];
    for (final p in s.participants) {
      if (p.teamId == localTeam) {
        teamA.add(p);
      } else {
        teamB.add(p);
      }
    }
    if (teamA.isNotEmpty && teamB.isNotEmpty) {
      final List<int> aCells;
      switch (n) {
        case 2:
          aCells = const [0];
          break;
        case 4:
          aCells = const [0, 2];
          break;
        case 6:
          aCells = const [0, 1, 3];
          break;
        case 8:
          // 4v4 未实测，按"我队占左半"推
          aCells = const [0, 1, 4, 5];
          break;
        default:
          aCells = [
            for (var i = 0; i < teamA.length && i < n; i++) i,
          ];
      }
      final queue = <int>[
        for (var i = 0; i < n; i++)
          if (!aCells.contains(i)) i,
      ];
      final byCell = List<LivePkSide?>.filled(n, null);
      var qi = 0;
      for (var i = 0; i < teamA.length; i++) {
        final cell = i < aCells.length ? aCells[i] : queue[qi++];
        if (cell >= 0 && cell < n) byCell[cell] = teamA[i];
      }
      for (final p in teamB) {
        if (qi < queue.length) byCell[queue[qi++]] = p;
      }
      final cols2 = _columnsFor(n);
      final rows2 = (n / cols2).ceil();
      return [
        for (var i = 0; i < n; i++)
          if (byCell[i] != null)
            _PkCell(
              byCell[i]!,
              left: (i % cols2) / cols2,
              top: (i ~/ cols2) / rows2,
              width: 1 / cols2,
              height: 1 / rows2,
            ),
      ];
    }
  }
  final cols = _columnsFor(n);
  final rows = (n / cols).ceil();
  return [
    for (var i = 0; i < n; i++)
      _PkCell(
        s.participants[i],
        left: (i % cols) / cols,
        top: (i ~/ cols) / rows,
        width: 1 / cols,
        height: 1 / rows,
      ),
  ];
}

int _rank1Uid(LivePkState s) {
  for (final p in s.participants) {
    if (p.rank == 1) return p.userId;
  }
  return 0;
}

class DouyinPkGridOverlay extends StatelessWidget {
  final LivePkState state;
  final double width;
  final double height;
  final bool hasBattle;
  final double scale;
  final String localNickname;

  const DouyinPkGridOverlay({
    super.key,
    required this.state,
    required this.width,
    required this.height,
    required this.hasBattle,
    this.scale = 1.0,
    this.localNickname = '',
  });

  @override
  Widget build(BuildContext context) {
    final cells = _layoutCells(state);
    final localTeam = state.localTeamId;
    // 分数徽章：PK 期间常显（含 0，同网页版）；非 PK 连麦时有礼物值才显示；
    // 1v1 不显示分数（条上已有双方分数），只显名字
    final showScoresInBattle = hasBattle && state.count > 2;
    // 徽章随格子大小等比缩放：3x3/4x2 的小格子里徽章变小不溢出
    double cellBadgeScale(_PkCell c) =>
        ((c.width * width) / 175).clamp(0.55, 1.3).toDouble();
    // 统一名字字号：按当前最长的名字算出共同缩放——全员同字号，
    // 有人名字过长时全员等比缩小（避免个别缩、个别不缩的怪象）
    var nameScale = 1.0;
    for (final cell in cells) {
      final isLocalName = cell.side.userId == state.localUserId &&
          localNickname.isNotEmpty;
      final name = isLocalName ? localNickname : cell.side.nickname;
      final cs = cellBadgeScale(cell);
      final avail = cell.width * width * cs -
          24 * scale * cs -
          (showScoresInBattle ? 80 * scale * cs : 0);
      final need = name.length * 12.0 * scale * cs;
      if (need > avail && need > 0) {
        final r = avail / need;
        if (r < nameScale) nameScale = r;
      }
    }
    // 下限 0.8：缩小幅度保持轻微；极长名字在统一字号下省略号兜底，
    // 避免为个别的超长名把全员缩得过小（"互相影响"体感的根源）
    if (nameScale < 0.8) nameScale = 0.8;
    return Stack(
      children: [
        for (final cell in cells)
          Positioned(
            left: cell.left * width,
            top: cell.top * height,
            width: cell.width * width,
            height: cell.height * height,
            child: _PkCellBadge(
              side: cell.side,
              showScore: showScoresInBattle ||
                  (!hasBattle && cell.side.score > 0),
              scale: scale * cellBadgeScale(cell),
              nameScale: nameScale,
              // 乱斗局（无队伍分）用金冠/灰底蓝圈徽章，不用队色。
              // 不能挂在 hasBattle 上：PK 倒计时走完/惩罚走完的窗口里
              // hasBattle=false（条和倒计时消失），徽章配色若跟着变
              // 会出现"瞬间变回粉色再变回来"的闪跳（2026-09-13 实测）
              ffa: !state.teamBattle,
              isOpponent: localTeam != null &&
                  cell.side.teamId != 0 &&
                  cell.side.teamId != localTeam,
              displayName: cell.side.userId == state.localUserId &&
                      localNickname.isNotEmpty
                  ? localNickname
                  : null,
            ),
          ),
      ],
    );
  }
}

class _PkCellBadge extends StatelessWidget {
  final LivePkSide side;
  final bool showScore;
  final double scale;

  /// 对方队：徽章底色用条右侧的蓝色；本房队/未知用粉色
  final bool isOpponent;

  /// 乱斗局（无组队各自为战）：第 1 名金色皇冠徽章、其余灰底蓝圈名次章，
  /// 不用队色（2026-09-13 用户口径，仿抖音原版）
  final bool ffa;

  /// 显示昵称覆盖（本房主播真名），null 用 side.nickname
  final String? displayName;

  /// 名字统一字号缩放（全格一致，由 GridOverlay 按最长名计算）
  final double nameScale;

  const _PkCellBadge({
    required this.side,
    required this.showScore,
    this.scale = 1.0,
    this.isOpponent = false,
    this.ffa = false,
    this.displayName,
    this.nameScale = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final ds = scale;
    final isRank1 = side.rank == 1;
    final showRank = side.rank > 0 && side.score > 0;

    // 分数徽章底色：乱斗局金/灰；组队局按队色（对方蓝、本房粉）
    final Decoration pillDecoration;
    final Color scoreColor;
    if (ffa) {
      pillDecoration = isRank1
          ? BoxDecoration(
              // 半透金底（约 85% 不透明）：透出视频画面，皇冠更突出
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xD9E2D4A4), Color(0xD9CDBB85)],
              ),
              borderRadius: BorderRadius.circular(10 * ds),
            )
          : BoxDecoration(
              color: Colors.black.withOpacity(0.45),
              borderRadius: BorderRadius.circular(10 * ds),
            );
      scoreColor = isRank1 ? const Color(0xFF4A3A0D) : Colors.white;
    } else {
      pillDecoration = BoxDecoration(
        color: (isOpponent ? const Color(0xFF378ADD) : const Color(0xFFE24B8A))
            .withOpacity(0.9),
        borderRadius: BorderRadius.circular(10 * ds),
      );
      scoreColor = Colors.white;
    }

    // 名次章：乱斗第 1 名金色皇冠+白字 1；乱斗其余蓝圈数字；
    // 组队局维持原样式（第 1 金圈奖杯、其余黑圈）。
    // 0 分格网页版不显名次（只显示礼物图标+0），这里同样处理
    Widget rankChip;
    if (!showRank) {
      rankChip = Icon(Icons.card_giftcard, size: 11 * ds, color: Colors.white);
    } else if (ffa && isRank1) {
      rankChip = SizedBox(
        width: 18 * ds,
        height: 15 * ds,
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(painter: _CrownPainter()),
            ),
            Center(
              child: Padding(
                padding: EdgeInsets.only(top: 2.5 * ds),
                child: Text(
                  '1',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 8.5 * ds,
                    fontWeight: FontWeight.w800,
                    height: 1,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    } else if (ffa) {
      rankChip = Container(
        width: 15 * ds,
        height: 15 * ds,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0xFF3F7BD3),
        ),
        child: Center(
          child: Text(
            '${side.rank}',
            style: TextStyle(
              color: Colors.white,
              fontSize: 9.5 * ds,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );
    } else {
      rankChip = Container(
        width: 15 * ds,
        height: 15 * ds,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isRank1 ? const Color(0xFFB8832E) : Colors.black.withOpacity(0.45),
          border: isRank1
              ? Border.all(color: const Color(0xFFF0C060), width: 1.2 * ds)
              : null,
        ),
        child: Center(
          child: isRank1
              ? Icon(Icons.emoji_events,
                  size: 9 * ds, color: const Color(0xFFFFE9B0))
              : Text(
                  '${side.rank}',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 9.5 * ds,
                    fontWeight: FontWeight.w700,
                  ),
                ),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.all(6 * ds),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // 左下：名次 + 分数（未开 PK 时不显示）
          if (showScore)
            Container(
              padding:
                  EdgeInsets.symmetric(horizontal: 7 * ds, vertical: 2 * ds),
              decoration: pillDecoration,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  rankChip,
                  SizedBox(width: 3 * ds),
                  Text(
                    '${side.score}',
                    style: TextStyle(
                      color: scoreColor,
                      fontSize: 11 * ds,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          // 右下：主播名字（本房主播用房间详情里的真名，WS 消息不含昵称）。
          // 长名字自动缩小字号显示全名（FittedBox），不省略号截断。
          // 无 Spacer：spaceBetween 已两端对齐，名字拿到全部剩余宽度，
          // 避免被折半约束导致字号忽大忽小
          Flexible(
            child: Container(
              padding:
                  EdgeInsets.symmetric(horizontal: 6 * ds, vertical: 2 * ds),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.35),
                borderRadius: BorderRadius.circular(8 * ds),
              ),
              child: Text(
                (displayName != null && displayName!.isNotEmpty)
                    ? displayName!
                    : side.nickname,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12 * ds * nameScale,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 三尖皇冠剪影（乱斗第 1 名名次章底），仿抖音原版金色小皇冠。
/// 半透底色上为了保持醒目，加一圈深金描边
class _CrownPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(w * 0.04, h * 0.72)
      ..lineTo(w * 0.04, h * 0.30)
      ..lineTo(w * 0.28, h * 0.52)
      ..lineTo(w * 0.50, h * 0.04)
      ..lineTo(w * 0.72, h * 0.52)
      ..lineTo(w * 0.96, h * 0.30)
      ..lineTo(w * 0.96, h * 0.72)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFFF5C243)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF8A5A00).withOpacity(0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ─────────────── 右上角：实时观看人数（仿网页版黑底红字） ───────────────

class DouyinViewerCountBadge extends StatelessWidget {
  final int count;
  final double scale;

  const DouyinViewerCountBadge({
    super.key,
    required this.count,
    this.scale = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final ds = scale;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8 * ds, vertical: 2 * ds),
      decoration: BoxDecoration(
        // 网页版取样：底 (15,16,19) 近黑 ~85%、字 (255,0,0) 纯红
        color: const Color(0xD90F1013),
        borderRadius: BorderRadius.circular(4 * ds),
      ),
      child: Text(
        '观看人数: $count',
        style: TextStyle(
          color: const Color(0xFFFF0000),
          fontSize: 13 * ds,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
