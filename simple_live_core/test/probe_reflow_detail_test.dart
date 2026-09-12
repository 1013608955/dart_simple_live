import 'dart:io';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

/// 对比两条详情路径的返回：webRid 路径 vs reflow(19位roomId) 路径。
/// 用户进房入口若携带 19 位 roomId，详情会走 getRoomDetailByRoomId。
void main() {
  test('probe-reflow-detail', () async {
    final site = DouyinSite();
    // 同一个房间（博哥文化传媒）分别用两种 id 拉
    const webRid = '152093002398';
    const internalId = '7684679029449870115';
    try {
      final d = await site.getRoomDetailByWebRid(webRid);
      stdout.writeln('[webRid路径] owner=${d.ownerId} linker=${d.linkerMapJson}');
    } catch (e) {
      stdout.writeln('[webRid路径] 失败: ${e.toString().substring(0, 60)}');
    }
    try {
      final d = await site.getRoomDetailByRoomId(internalId);
      stdout.writeln(
          '[reflow路径] owner=${d.ownerId} linker=${d.linkerMapJson} nick=${d.userName}');
    } catch (e) {
      stdout.writeln('[reflow路径] 失败: ${e.toString().substring(0, 60)}');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
