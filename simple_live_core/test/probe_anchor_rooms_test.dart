import 'dart:io';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

/// 搜索今晚 PK 主播的房间并拉详情：验证"用户实际观看的房间"
/// 是否天然返回降级数据（缺 owner/linker）。
void main() {
  test('probe-anchor-rooms', () async {
    final site = DouyinSite();
    for (final kw in ['星软', '月神', '扶摇']) {
      try {
        final r = await site.searchRooms(kw);
        stdout.writeln('搜索[$kw] ${r.items.length} 个结果');
        for (final item in r.items.take(3)) {
          try {
            final d = await site.getRoomDetailByWebRid(item.roomId);
            stdout.writeln('  [${item.roomId}] ${item.userName} '
                'owner=${d.ownerId.isEmpty ? "(空)" : "有"} '
                'linker=${d.linkerMapJson}');
          } catch (e) {
            stdout.writeln(
                '  [${item.roomId}] 详情失败: ${e.toString().substring(0, 50)}');
          }
        }
      } catch (e) {
        stdout.writeln('搜索[$kw] 失败: ${e.toString().substring(0, 60)}');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
