import 'dart:io';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

/// 批量探测：找正在多人连麦的聊天房，验证 enter 接口的 linker_map
/// 是否非空、位置语义是什么（0-8 格子序？）。
void main() {
  test('probe-chat-rooms', () async {
    final site = DouyinSite();
    final cats = await site.getCategores();
    // 找聊天/连麦相关分类
    LiveSubCategory? target;
    for (final c in cats) {
      for (final s in c.children) {
        stdout.writeln('cat ${c.name} / ${s.name} id=${s.id}');
        if (target == null && (s.name.contains('聊天') || s.name.contains('交友'))) {
          target = s;
        }
      }
    }
    if (target == null) {
      stdout.writeln('未找到聊天分类，用推荐流');
    }
    final rooms = <LiveRoomItem>[];
    if (target != null) {
      for (var page = 1; page <= 2; page++) {
        final r = await site.getCategoryRooms(target, page: page);
        rooms.addAll(r.items);
      }
    } else {
      final r = await site.getRecommendRooms();
      rooms.addAll(r.items);
    }
    stdout.writeln('候选房间 ${rooms.length} 个');
    var hits = 0;
    for (final room in rooms.take(14)) {
      try {
        final d = await site.getRoomDetailByWebRid(room.roomId);
        final linker = d.linkerMapJson;
        final interesting =
            linker.isNotEmpty && linker != '{}';
        if (interesting) hits++;
        stdout.writeln(
            '[${room.roomId}] ${room.userName.replaceAll("\n", " ")} '
            'owner=${d.ownerId} linker=$linker');
      } catch (e) {
        stdout.writeln('[${room.roomId}] 失败: ${e.toString().substring(0, 60)}');
      }
    }
    stdout.writeln('非空 linker_map 房间数: $hits');
  }, timeout: const Timeout(Duration(minutes: 8)));
}
