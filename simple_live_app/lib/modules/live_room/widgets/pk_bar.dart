import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

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
// 格子布局自适应（_layoutCells）：4人=2x2；5人=上2下3（桁菜房实测）；
// 3人/主持人放大=左大格+右列堆叠。
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

  /// 是否显示直播间标题（默认 true）。关闭后标题不渲染，PK 条仍显示。
  final bool showTitle;

  /// 是否显示观看人数角标（默认 true）。关闭后角标不渲染，PK 条仍显示。
  final bool showViewerCount;

  /// 手动交换回调（uidA, uidB）：交换模式下点选两个格子后触发，
  /// 由外部转发到 pkTracker.registerManualSwap
  final void Function(int uidA, int uidB)? onManualSwap;

  /// PK 元素显隐（PK 条 + 名字徽章 + 交换）。与标题/人数独立——
  /// 「PK显示」关闭时标题/人数角标仍按各自开关渲染（2026-09-19 用户口径：
  /// PK显示按钮不应连带控制标题和人数）
  final bool showPkElements;

  const DouyinPkLayer({
    super.key,
    required this.state,
    required this.nowMs,
    this.videoAspectRatioProvider,
    this.scaleModeProvider,
    this.viewerCount,
    this.localNickname = '',
    this.title = '',
    this.showTitle = true,
    this.showViewerCount = true,
    this.showPkElements = true,
    this.onManualSwap,
  });

  @override
  State<DouyinPkLayer> createState() => _DouyinPkLayerState();
}

class _DouyinPkLayerState extends State<DouyinPkLayer> {
  Timer? _ticker;

  /// 手动交换模式：true 时格子可点击，点选两格交换位置
  bool _swapMode = false;

  /// 交换模式下的第一个被选中格子（uid）
  int? _swapPickUid;

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

  /// 交换模式的格子点击：第一击选中、第二击与另一格触发交换
  void _handleCellTap(int uid) {
    setState(() {
      if (_swapPickUid == null) {
        _swapPickUid = uid;
      } else if (_swapPickUid == uid) {
        _swapPickUid = null;
      } else {
        widget.onManualSwap?.call(_swapPickUid!, uid);
        _swapPickUid = null;
      }
    });
  }

  /// BoxFit.contain 下视频在控件内的实际显示矩形。
  /// 分辨率未知（视频未加载/流未出画面）时按整个窗口处理：
  /// 标题/角标贴窗口顶部，避免按猜测宽高比定位后悬在半空
  ///（2026-09-13 实测：横屏直播在竖屏窗口加载中，兜底 9:16 让标题悬空）
  Rect _videoRect(Size box) {
    final ar = widget.videoAspectRatioProvider?.call();
    final mode = widget.scaleModeProvider?.call() ?? 0;
    if (ar == null || ar <= 0 || mode == 1 || mode == 2) {
      return Offset.zero & box;
    }
    // 区分"播放器真的还没出画面"（宽高为 0）与真实宽高比：
    // provider 在宽高为 0 时会返回兜底猜测值，这里无法区分，
    // 因此由 provider 保证未知时返回 null（见 live_room_page 接线）
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
      final nowMs = widget.nowMs();
      // PK 生命周期 = 进行中时长 + 「PK 结束」60s 惩罚倒计时，全部走完
      // 条和分值才消失（用户口径 2026-09-14）。惩罚时长未知按 60s
      //（抖音常态），到位后由服务端真实值覆盖
      final punishDurMs =
          s != null && s.punishDurationMs > 0 ? s.punishDurationMs : 60000;
      final battleEndAtMs = s != null && s.startTimeMs > 0 && s.durationMs > 0
          ? s.startTimeMs + s.durationMs
          : 0;
      // 15 秒无消息兜底只针对"对方真退了"（count<=1）。
      // 进行中没人上分、以及「PK 结束 60s」窗口内服务端停推分数，
      // 都不能因超时把条/分值搞没（用户口径 2026-09-14）
      final stale = s != null && s.count <= 1;
      // SEI 精确几何可用：参与者带 seatX/Y/W/H（画布相对坐标）
      final seiGeometry =
          s != null && s.participants.any((p) => p.seatX != null);
      final pkOver = s != null &&
          ((battleEndAtMs > 0 && nowMs >= battleEndAtMs + punishDurMs) ||
              stale);
      if (s == null || s.count == 0) {
        // 无 PK 数据：只剩标题与人数角标
        if ((widget.title.isEmpty || !widget.showTitle) &&
            (viewers <= 0 || !widget.showViewerCount)) {
          return const SizedBox.shrink();
        }
        return LayoutBuilder(
          builder: (context, c) {
            final scale =
                (c.maxWidth / 900).clamp(1.0, 2.2);
            return Stack(
              children: [
                if (widget.title.isNotEmpty && widget.showTitle)
                  Positioned(
                    top: 8 * scale,
                    left: 0,
                    width: c.maxWidth,
                    child: IgnorePointer(
                      child: Center(
                        child: ConstrainedBox(
                          constraints:
                              BoxConstraints(maxWidth: c.maxWidth * 0.52),
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
                  ),
                if (viewers > 0 && widget.showViewerCount)
                  Positioned(
                    // 与标题同一行，右上角对齐
                    top: 8 * scale,
                    left: 0,
                    width: c.maxWidth,
                    child: IgnorePointer(
                      child: Align(
                        alignment: Alignment.topRight,
                        child: Padding(
                          padding: EdgeInsets.only(right: 12 * scale),
                          child: DouyinViewerCountBadge(
                              count: viewers, scale: scale),
                        ),
                      ),
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
          // 进行中进房收不到 BattleStatus（durationMs=0），此时靠分数流
          // （hasScoreFlow）判断战局存在，否则 PK 条要手动刷新才出现
          final hasBattle = s.count >= 2 &&
              (s.durationMs > 0 || s.hasScoreFlow) &&
              !pkOver;
          final scale = (rect.width / 900).clamp(1.0, 1.5);
          // 标题/条/角标贴窗口顶部（黑边上，用户口径 2026-09-13）：
          // 不随视频黑边移动，视频内不出现标题。徽章仍贴视频格子。
          // 2026-09-19 全屏口径：竖屏视频在横屏全屏里，画布带顶
          // （0.188×高）离窗口顶会很远，PK 条悬在黑边上离格子太远——
          // 条锚定改为"不低于格带顶上方 68*scale"：小窗口保持原位
          // （带顶-68 ≈ 原 50），大间隔全屏自动下移贴到格带上沿
          final hasTitle = widget.title.isNotEmpty && widget.showTitle;
          final cellsTopFrac = seiGeometry
              ? s!.participants
                  .map((p) => p.seatY)
                  .whereType<double>()
                  .reduce((a, b) => a < b ? a : b)
              : 0.1875;
          final cellsTopY = rect.top + cellsTopFrac * rect.height;
          final barTop = math.max(
            rect.top + 50 * scale,
            cellsTopY - 68 * scale,
          );
          // 人数角标与标题同一行（用户口径 2026-09-13：右上角对齐标题），
          // PK 条/倒计时在下一行不与角标重叠
          // 人数角标下移 46*scale：右上角是播放器悬停按钮区（鼠标一动
          // 就出现），原 8*scale 顶行会与之重叠（2026-09-19 全屏实测）
          final badgeTop = rect.top + 54 * scale;

          return Stack(
            children: [
              // 顶部居中：直播间标题（仿网页版黑底白字胶囊，位置固定）
              if (hasTitle)
                Positioned(
                  top: 8 * scale,
                  left: 0,
                  width: c.maxWidth,
                  child: IgnorePointer(
                    child: Center(
                      child: ConstrainedBox(
                        constraints:
                            BoxConstraints(maxWidth: c.maxWidth * 0.52),
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
                ),
              /// 顶部双方进度条（组队赛 / 1v1）
              // 条压真实画面顶边：视频区可能在窗口内嵌着（BoxFit.contain
              // 留黑边），用 _videoRect 算出的 rect.top 就是真实画面顶。
              // 用户口径 2026-09-14：条下移 50 像素看效果
              if (widget.showPkElements &&
                  hasBattle &&
                  (s.teamBattle || s.count == 2))
                Positioned(
                  top: barTop,
                  left: rect.left,
                  width: rect.width,
                  child: IgnorePointer(
                    child: Center(
                      child: DouyinPkBar(
                          state: s, nowMs: widget.nowMs, scale: scale),
                    ),
                  ),
                ),
              // 个人赛：紧凑倒计时（仿抖音「PK 06:51」样式）
              if (widget.showPkElements &&
                  hasBattle &&
                  !(s.teamBattle || s.count == 2))
                Positioned(
                  top: barTop,
                  left: rect.left,
                  width: rect.width,
                  child: IgnorePointer(
                    child: Center(
                      child: DouyinPkCountdownChip(
                          state: s, nowMs: widget.nowMs, scale: scale),
                    ),
                  ),
                ),
              // 格子徽章（count>=2）：叠加在合成画面的格子上。
              // 状态超时 15 秒无更新（对方中途退出连线）时隐去，防徽章挂屏。
              // 交换模式下格子可点击（点选两格互换），其余时候不响应指针
              if (widget.showPkElements && s.count >= 2 && !stale)
                Positioned(
                  left: rect.left,
                  // SEI 几何（seatX 等有值）：坐标是画布相对（0~1 对应完整
                  // 1080x1920 合成画布），覆盖层必须铺满完整视频 rect 1:1
                  // 映射。旧 0.1875/0.50 带状偏移只适用于无 SEI 的模板
                  // 兜底（截图模板时代：格子带 = 画布 y 18.75%~68.75%）
                  top: rect.top +
                      (seiGeometry
                          ? 0
                          : rect.height *
                              (s.count == 2
                                  ? 0
                                  : (s.bigMode ? 0 : 0.1875))),
                  width: rect.width,
                  height: seiGeometry
                      ? rect.height
                      : rect.height *
                          (s.count == 2
                              ? 0.60
                              : (s.bigMode ? 1.0 : 0.50)),
                  child: IgnorePointer(
                    ignoring: !_swapMode,
                    child: DouyinPkGridOverlay(
                      state: s,
                      width: rect.width,
                      height: seiGeometry
                          ? rect.height
                          : rect.height *
                              (s.count == 2
                                  ? 0.60
                                  : (s.bigMode ? 1.0 : 0.50)),
                      hasBattle: hasBattle,
                      pkOver: pkOver,
                      scale: scale,
                      localNickname: widget.localNickname,
                      swapMode: _swapMode,
                      selectedUid: _swapPickUid,
                      onCellTap: _handleCellTap,
                    ),
                  ),
                ),
              // 手动交换开关（左上角 ⇄）：进入交换模式后点选两格互换
              if (widget.showPkElements && s != null && s.count >= 2 && !stale)
                Positioned(
                  left: rect.left + 6 * scale,
                  top: rect.top + 8 * scale,
                  child: GestureDetector(
                    onTap: () => setState(() {
                      _swapMode = !_swapMode;
                      _swapPickUid = null;
                    }),
                    child: Container(
                      padding: EdgeInsets.symmetric(
                          horizontal: 8 * scale, vertical: 4 * scale),
                      decoration: BoxDecoration(
                        color: _swapMode
                            ? const Color(0xE6FE2C55)
                            : const Color(0xD90F1013),
                        borderRadius: BorderRadius.circular(6 * scale),
                      ),
                      child: Text(
                        _swapMode ? '完成' : '⇄',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12 * scale,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ),
              if (widget.showPkElements &&
                  _swapMode &&
                  s != null &&
                  s.count >= 2)
                Positioned(
                  left: rect.left + 52 * scale,
                  top: rect.top + 10 * scale,
                  child: Container(
                    padding: EdgeInsets.symmetric(
                        horizontal: 8 * scale, vertical: 4 * scale),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.55),
                      borderRadius: BorderRadius.circular(6 * scale),
                    ),
                    child: Text(
                      _swapPickUid == null
                          ? '交换模式：点击两个格子互换位置'
                          : '已选中，点击另一格完成交换',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 11 * scale,
                      ),
                    ),
                  ),
                ),
              // 右上角：实时观看人数（标题存在时与标题同排，人数靠右）
              if (viewers > 0 && widget.showViewerCount)
                Positioned(
                  top: badgeTop,
                  left: 0,
                  width: c.maxWidth,
                  child: IgnorePointer(
                    child: Align(
                      alignment: Alignment.topRight,
                      child: Padding(
                        padding: EdgeInsets.only(right: 12 * scale),
                        child: DouyinViewerCountBadge(
                            count: viewers, scale: scale),
                      ),
                    ),
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

  /// PK 计时诊断开关：true 时每次 build 打印 nowMs/startMs/durMs/endAt/remainMs/inPunish
  /// 用于诊断 PK 条倒计时偏差（如软件 vs 网页差几分钟的问题）
  static bool diagnosePkTimer = false;

  const DouyinPkBar({
    super.key,
    required this.state,
    required this.nowMs,
    this.scale = 1.0,
  });

  void _pkDebug(String line) {
    try {
      final f =
          File('${Directory.systemTemp.path}/simple_live_pk_debug.log');
      f.writeAsStringSync("$line\n", mode: FileMode.append);
    } catch (_) {}
  }

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
    // 双方至少各占 15% 宽（数字能完整显示，用户口径 2026-09-14）
    // 原 clamp(2,98) 太窄，差距大时弱势方条几乎消失
    final leftFlex = (ratio * 100).round().clamp(15, 85);
    final rightFlex = 100 - leftFlex;

    final leftScore = isTeam ? bars[0].round() : ls;
    final rightScore = isTeam ? bars[1].round() : rs;

    final remain = state.remainingMs(nowMs());
    final mm = (remain ~/ 60000).toString().padLeft(2, '0');
    final ss = ((remain % 60000) ~/ 1000).toString().padLeft(2, '0');
    // 惩罚阶段以时间判断（phase 字段可能晚到/缺失）：进行中时间走完
    // 即进入「PK 结束」60s 读秒（用户口径 2026-09-14）
    final endAt = state.startTimeMs + state.durationMs;
    final inPunish =
        state.durationMs > 0 && state.startTimeMs > 0 && nowMs() >= endAt;
    // DIAG: 打印 UI 端实际计算用的时间值，便于诊断 PK 条倒计时偏差
    if (diagnosePkTimer) {
      _pkDebug(
        "PK-TIMER nowMs=${nowMs()} startMs=${state.startTimeMs} durMs=${state.durationMs} "
        "endAt=$endAt remainMs=$remain inPunish=$inPunish phase=${state.phase}",
      );
    }
    final label = inPunish
        ? _punishLabel(state, nowMs())
        : (state.durationMs > 0 ? '$mm:$ss' : 'PK');

    return LayoutBuilder(
      // 条宽 = 整窗宽 100%（用户口径 2026-09-14）
      builder: (context, c) {
        return SizedBox(
      // 仿官方 PK 条：近全宽渐变胶囊（左粉右蓝），两端大分值，
      // 底部中央叠「PK mm:ss」小黑胶囊（2026-09-14 用户供图）
      width: c.maxWidth,
      height: 34 * ds,
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: 22 * ds,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(11 * ds),
              child: Row(
                children: [
                  Expanded(
                    flex: leftFlex,
                    child: Container(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [Color(0xFFFE2C55), Color(0xFFFF7EA6)],
                        ),
                      ),
                      alignment: Alignment.centerLeft,
                      padding: EdgeInsets.only(left: 10 * ds),
                      // 极端比分（如 16万 vs 111万）时粉段宽度只有 15%，
                      // 6 位数字会被裁掉左侧几位；用 FittedBox(scaleDown)
                      // 在超宽时自动缩字号，文字总能完整显示
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '$leftScore',
                          maxLines: 1,
                          softWrap: false,
                          style: TextStyle(
                            color: const Color(0xFF8A1030),
                            fontSize: 15 * ds,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    flex: rightFlex,
                    child: Container(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [Color(0xFF9FD8F5), Color(0xFF0FA9E6)],
                        ),
                      ),
                      alignment: Alignment.centerRight,
                      padding: EdgeInsets.only(right: 10 * ds),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Text(
                          '$rightScore',
                          maxLines: 1,
                          softWrap: false,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 15 * ds,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 中央「PK mm:ss」小黑胶囊，压在条的底边中点上
          Container(
            padding:
                EdgeInsets.symmetric(horizontal: 10 * ds, vertical: 1 * ds),
            decoration: BoxDecoration(
              color: const Color(0xE6101120),
              borderRadius: BorderRadius.circular(9 * ds),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'PK',
                  style: TextStyle(
                    color: const Color(0xFFFE2C55),
                    fontSize: 11 * ds,
                    fontWeight: FontWeight.w900,
                    fontStyle: FontStyle.italic,
                  ),
                ),
                SizedBox(width: 4 * ds),
                Text(
                  label,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11 * ds,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
        ),
        );
      },
    );
  }

  /// 惩罚阶段剩余秒数 → 「PK结束 (Ns)」
  /// 惩罚时长未知按 60s（服务端给了用真实值，未给先兜底，到位后覆盖）
  static String _punishLabel(LivePkState s, int now) {
    final start =
        s.punishStartMs > 0 ? s.punishStartMs : s.startTimeMs + s.durationMs;
    final dur = s.punishDurationMs > 0 ? s.punishDurationMs : 60000;
    final left = ((start + dur - now) / 1000).ceil().clamp(0, 9999);
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
    // 惩罚阶段以时间判断（phase 字段可能晚到/缺失）
    final endAt = state.startTimeMs + state.durationMs;
    final inPunish =
        state.durationMs > 0 && state.startTimeMs > 0 && nowMs() >= endAt;
    final label = inPunish
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
/// 8人=4x2（2026-09-12 实测）、9人=3x3；7人按 4 列 4+3 推测）。
/// 5 人不用列数（走 2+3 马赛克，见 _fiveCells）。
int _columnsFor(int n) {
  if (n <= 2) return 2;
  if (n <= 4) return 2;
  if (n <= 6) return 3;
  if (n <= 8) return 4;
  return 3;
}

/// 5 人官方构图：上 2 下 3（2026-09-14 桁菜房实测）。
/// 截图窗口 810x739 缝：上下约对半（y=371/739≈0.50），
/// 上排中缝 x=395/810≈0.49，下排三分 x=261/529 ≈ 0.32/0.65。
/// 取整成 0.5 / 1/3，与画面差 <2%，徽章贴格底不受影响。
/// 座位序已是格子序时，按人数套几何、人按 index 放，不再按队伍重排。
/// 6 人列优先 3x2（左列 0/1、中列 2/3、右列 4/5）；4 人列优先 2x2；
/// 5 人上2下3；其余用 _columnsFor 行优先（9 人 3x3 实测）。
List<_PkCell> _cellsByIndex(List<LivePkSide> ordered) {
  final n = ordered.length;
  if (n == 5) return _fiveCells(ordered);
  if (n == 6) {
    const cols = 3;
    const rows = 2;
    return [
      for (var i = 0; i < n; i++)
        _PkCell(
          ordered[i],
          left: (i ~/ rows) / cols,
          top: (i % rows) / rows,
          width: 1 / cols,
          height: 1 / rows,
        ),
    ];
  }
  final cols = _columnsFor(n);
  final rows = (n / cols).ceil();
  final columnMajor = n == 4 || n == 8;
  return [
    for (var i = 0; i < n; i++)
      _PkCell(
        ordered[i],
        left: (columnMajor ? (i ~/ rows) : (i % cols)) / cols,
        top: (columnMajor ? (i % rows) : (i ~/ cols)) / rows,
        width: 1 / cols,
        height: 1 / rows,
      ),
  ];
}

List<_PkCell> _fiveCells(List<LivePkSide> ordered) {
  const specs = <List<double>>[
    [0, 0, 0.5, 0.5], // 0 上左
    [0.5, 0, 0.5, 0.5], // 1 上右
    [0, 0.5, 1 / 3, 0.5], // 2 下左
    [1 / 3, 0.5, 1 / 3, 0.5], // 3 下中
    [2 / 3, 0.5, 1 / 3, 0.5], // 4 下右
  ];
  return [
    for (var i = 0; i < ordered.length && i < 5; i++)
      _PkCell(
        ordered[i],
        left: specs[i][0],
        top: specs[i][1],
        width: specs[i][2],
        height: specs[i][3],
      ),
  ];
}

/// 合成画面布局（返回格子带比例坐标）：
///   2 人（1v1）      → 两格并排占上部 62%（用户微调：名字再往下一点）
///   4 人            → 2x2 均匀网格
///   3 人            → 左侧大格（本房主播，未知则第 1 名）+ 右列 2 格按名次
///   5 人            → 上 2 下 3（2026-09-14 桁菜房实测，非 3x2）
///   9 人            → 默认 3x3 均匀网格（实测）；确认放大后才用
///                     左侧大格 + 右侧 3x3 八格
///   主持人放大       → 被放大者占左侧大格 + 其余右列堆叠
///   其他（6 人等）   → 均匀网格（列数按人数推断）
List<_PkCell> _layoutCells(LivePkState s) {
  final n = s.count;
  // SEI 精确格位优先（服务端随视频流下发的权威坐标，2026-09-19）：
  // 有坐标的成员直接按百分比铺格，不再套人数模板——模板对 3 人
  // （左大格0.5x0.5+右列两小格）这类构图永远猜不准。≥2 人有坐标
  // 即整体采用；个别缺坐标的成员跳过（宁缺勿错，比错位好排查）
  final seatCells = <_PkCell>[];
  for (final p in s.participants) {
    if (p.seatX != null && p.seatY != null && p.seatW != null && p.seatH != null) {
      seatCells.add(_PkCell(
        p,
        left: p.seatX!,
        top: p.seatY!,
        width: p.seatW!,
        height: p.seatH!,
      ));
    }
  }
  if (seatCells.length >= 2) {
    return seatCells;
  }
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
  // 官方座位序（LinkmicUI positions / linker_map）已排好 participants，
  // 按 index 铺几何。组队 aCells 猜测三轮 6 人每次换的格子都不同，已证伪。
  if (s.hasSeatOrder && n >= 3) {
    return _cellsByIndex(s.participants);
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
    // 右侧小格列数：2-4 人单列纵向堆叠（截图实测：4 人放大局右侧 3 人为
    // 3x1 单列，之前逻辑 m=3 时 rc=2 导致错位）；5-6 人两列，7-9 人三列
    final rc = m <= 4 ? 1 : (m <= 6 ? 2 : 3);
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
  // 本房队伍未知时兜底用分数高的队伍当本房队（与 teamBar 一致，
  // 避免 owner 详情缺失时跳过组队分支落到乱斗布局，2026-09-14 实测
  // 4 人 2v2 局 localTeamId 未知 → 走到 4 人乱斗 → 蓝队位置反）
  // 6 人组队：走下面组队分支的 aCells（2026-09-14 小好房 3v3 实测，
  // 纯 participants 下标不打乱队伍，粉队整列+中上已有多轮不好使对）
  if (s.teamBattle) {
    final ts = s.teamScores;
    int? localTeam = s.localTeamId;
    // owner uid 已知时直接用其所在队伍（2026-09-14 实测 8 人局
    // 粉队 332 vs 蓝队 17335，粉队是本房但分数低，按"分数高=本房队"
    // 兜底会把本房队识别错）。owner 缺失才退到"分数高的队伍"
    if ((localTeam ?? 0) == 0 && s.localUserId != 0) {
      for (final p in s.participants) {
        if (p.userId == s.localUserId && p.teamId != 0) {
          localTeam = p.teamId;
          break;
        }
      }
    }
    if ((localTeam ?? 0) == 0 && ts.isNotEmpty) {
      localTeam = ts.keys.reduce((a, b) => (ts[b]! > ts[a]!) ? b : a);
    }
    if ((localTeam ?? 0) != 0) {
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
          // 2v2 我队占左列；3v1 时单人队固定右上（cell 1），
          // 三人队占其余三格（2026-09-14 实测：单人队挂右下与官方不符）
          aCells = switch ((teamA.length, teamB.length)) {
            (1, 3) => const [0],
            (3, 1) => const [0, 2, 3],
            _ => const [0, 2],
          };
          break;
        case 5:
          // 上2下3：我队靠左。2v3 我队占上左+下左 [0,2]；
          // 1v4 单人占上左 [0]；3v2 / 4v1 我队占左半再向下铺
          // [0,2,3] / [0,2,3,4]（2026-09-14 桁菜房 2v3 实测）
          aCells = switch ((teamA.length, teamB.length)) {
            (1, 4) => const [0],
            (2, 3) => const [0, 2],
            (3, 2) => const [0, 2, 3],
            (4, 1) => const [0, 2, 3, 4],
            _ => const [0, 2],
          };
          break;
        case 6:
          // 3x2 列优先（左列 0/1、中列 2/3、右列 4/5）。
          // 2026-09-14 小好房 3v3：粉队 [左上,左下,中上]=[0,1,2]，简单按序；
          // 早期桁菜房曾报 [0,2,1]，但那是把 participants 当格子序铺（
          // 无队伍分块）时的错位，分组填格后 [0,1,2] 才对。
          aCells = switch ((teamA.length, teamB.length)) {
            (4, 2) => const [0, 1, 2, 3],
            (2, 4) => const [0, 1],
            _ => const [0, 1, 2],
          };
          break;
        case 8:
          // 4x2 列优先（左列 0/1、中左 2/3、中右 4/5、右列 6/7）。
          // 2026-09-14 4v4 实测：粉队占左两列 [0,1,2,3]；旧值 [0,1,4,5]
          // 配行优先会把粉队铺成上排左二+下排左二，用户报 2↔5。
          // 2026-09-15 春虫虫房 7v1 实测：单人队占右上=byCell 6（列优先
          // 几何下 visual 右上是 (3,0)=cell 6，不是行优先的 cell 3！），
          // 多数队填其余 7 格 [0,1,2,3,4,5,7]；对齐 4 人局 (3,1) 单人右上先例
          aCells = switch ((teamA.length, teamB.length)) {
            (3, 5) => const [0, 1, 2],
            (5, 3) => const [0, 1, 2, 3, 4],
            (7, 1) => const [0, 1, 2, 3, 4, 5, 7],
            (1, 7) => const [0],
            _ => const [0, 1, 2, 3], // 4v4
          };
          break;
        case 9:
          // 3x3 列优先（左列 0/1/2、中列 3/4/5、右列 6/7/8）。
          // 2026-09-14 桁菜房 4v5 实测：粉队=左列+中上 [0,1,2,3]
          // （桁菜/赵俊杰/光天翌/Li敖），蓝队占剩余。
          // 2026-09-15 KONGCAKE 房 1v8：本房单人占 TL [0]，8 人填其余；
          // (8,1) 单人队按右上惯例占 byCell 6（列优先 visual 右上）。
          aCells = switch ((teamA.length, teamB.length)) {
            (5, 4) => const [0, 1, 2, 3, 4],
            (3, 6) => const [0, 1, 2],
            (6, 3) => const [0, 1, 2, 3, 4, 5],
            (1, 8) => const [0],
            (8, 1) => const [0, 1, 2, 3, 4, 5, 7, 8],
            _ => const [0, 1, 2, 3], // 4v5 默认
          };
          break;
        default:
          aCells = [
            for (var i = 0; i < teamA.length && i < n; i++) i,
          ];
      }
      // 对方队填剩余格的顺序：
      //   4 人 2v2（行优先 2x2）：右列从下往上 [3,1]
      //     2026-09-14 辰曦房实测蓝队 2↔4（右上↔右下）
      //   6 人：从右列下往上绕 [5,4,3,…]（桁菜房第二轮 3↔6）
      //   8 人 4v4 列优先 4x2：右两列"蛇形"填——col=2 从上往下 (cell 4,5)，
      //     col=3 从下往上 (cell 7,6)；tB 按参与者顺序填 → queue=[4,6,7,5]
      //     2026-09-15 春虫虫房 4v4 实测：3↔8、4↔7 互换（视觉编号）=
      //     queue 改后视觉 [3=艾,4=Unii,7=刘,8=11不] 才匹配抖音实际
      //   其余：格子号升序
      final queue = (n == 4 && teamA.length == 2 && teamB.length == 2)
          ? const [3, 1]
          : n == 6
              ? [
                  for (final i in const [5, 4, 3, 2, 1, 0])
                    if (!aCells.contains(i)) i,
                ]
              : (n == 8 && teamA.length == 4 && teamB.length == 4)
                  ? const [4, 6, 7, 5]
                  : [
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
      final ordered = [
        for (var i = 0; i < n; i++)
          if (byCell[i] != null) byCell[i]!,
      ];
      if (n == 5) return _fiveCells(ordered);
      final cols2 = _columnsFor(n);
      final rows2 = (n / cols2).ceil();
      // 6/8/9 人列优先：cell i → 列 i~/rows、行 i%rows
      // （8 人 4v4 2026-09-14：行优先粉队占上排左二，官方是左两列）
      if (n == 6 || n == 8 || n == 9) {
        return [
          for (var i = 0; i < n; i++)
            if (byCell[i] != null)
              _PkCell(
                byCell[i]!,
                left: (i ~/ rows2) / cols2,
                top: (i % rows2) / rows2,
                width: 1 / cols2,
                height: 1 / rows2,
              ),
        ];
      }
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
  }
  final cols = _columnsFor(n);
  final rows = (n / cols).ceil();
  // 4/8 人乱斗：行优先，不按名次重排（participants 已是本房提前或 8 人旋转）。
  // 4 人 2026-09-14 辰曦房 3↔4：列优先+名次把右下/左下放反，行优先+加入序即对。
  // 8 人 2026-09-14：4x2 行优先 + 从本房旋转加入序。
  if (n == 4 || n == 8) {
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
  // 乱斗（无队伍分）：本房固定 idx0，其余保持加入序（首见序）。
  // 不按名次排序：官方乱斗布局=加入序，名次序与网页版不符且会随分数
  // 变化整局重排（2026-09-15 9 人乱斗实测：网页版顺序对应名次
  // [2,4,5,6,1,7,8,3,9]，非名次序；2026-09-14 4 人局的"名次契合"是
  // 名次恰与加入序重合的巧合）。中途进房加入序不可恢复，但稳定不跳。
  final list = s.participants.toList();
  LivePkSide? local;
  final rest = <LivePkSide>[];
  for (final p in list) {
    if (p.userId == s.localUserId && local == null) {
      local = p;
    } else {
      rest.add(p);
    }
  }
  local ??= list.isNotEmpty ? list.first : null;
  final ordered = [if (local != null) local, ...rest];
  if (n == 5) return _fiveCells(ordered);
  return [
    for (var i = 0; i < n; i++)
      _PkCell(
        ordered[i],
        left: (i ~/ rows) / cols,
        top: (i % rows) / rows,
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

  /// PK 全程结束（含 60s 惩罚读完）：分值徽章不显示（只留名字）
  final bool pkOver;

  final double scale;
  final String localNickname;

  /// 手动交换模式：格子可点击、选中格高亮
  final bool swapMode;
  final int? selectedUid;
  final void Function(int uid)? onCellTap;

  const DouyinPkGridOverlay({
    super.key,
    required this.state,
    required this.width,
    required this.height,
    required this.hasBattle,
    required this.pkOver,
    this.scale = 1.0,
    this.localNickname = '',
    this.swapMode = false,
    this.selectedUid,
    this.onCellTap,
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
        ((c.width * width) / 175).clamp(0.55, 1.1).toDouble();
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
            child: GestureDetector(
              onTap: swapMode && onCellTap != null
                  ? () => onCellTap!(cell.side.userId)
                  : null,
              child: _PkCellBadge(
                side: cell.side,
                // 分数药丸：PK 中显示战局分；普通连线/PK 结束后显示礼物
                // 分（网页版同款常驻，含 0）。不挂 !pkOver——PK 结束后
                // 过期 battleEnd 会让 pkOver 永真，把连线礼物分永久压住
                //（2026-09-19 实测：PK 后回到连线，网页有 78/6810 等礼物
                // 分而客户端全无）
                showScore: showScoresInBattle ||
                    (!hasBattle &&
                        (cell.side.score > 0 || state.hasScoreFlow)),
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
                selected: swapMode && selectedUid == cell.side.userId,
              ),
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

  /// 交换模式下被选中（高亮描边）
  final bool selected;

  const _PkCellBadge({
    required this.side,
    required this.showScore,
    this.scale = 1.0,
    this.isOpponent = false,
    this.ffa = false,
    this.displayName,
    this.nameScale = 1.0,
    this.selected = false,
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
        // 粉/蓝队色底，50% 不透明（2026-09-14 用户口径，透出画面）
        color: (isOpponent ? const Color(0xFF378ADD) : const Color(0xFFE24B8A))
            .withValues(alpha: 0.5),
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
      child: Container(
        decoration: selected
            ? BoxDecoration(
                border: Border.all(
                  color: const Color(0xFFFFC53D),
                  width: 2 * ds,
                ),
                borderRadius: BorderRadius.circular(8 * ds),
              )
            : null,
        padding: selected ? EdgeInsets.all(2 * ds) : null,
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
        // 用户调参：底 (15,16,19) 不透明度 30%（2026-09-14）
        color: const Color(0x4D0F1013),
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
