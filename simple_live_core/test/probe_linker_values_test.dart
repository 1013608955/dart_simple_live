import 'dart:io';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

/// 验证 linker_map 值的语义：是嘉宾 uid 还是房间 id？
/// 对比 internal roomId 与 linker 值是否同空间。
void main() {
  test('probe-linker-values', () async {
    final site = DouyinSite();
    for (final webRid in ['152093002398', '447867258756', '685455435279']) {
      try {
        final d = await site.getRoomDetailByWebRid(webRid);
        final args = d.danmakuData as dynamic;
        stdout.writeln('[${webRid}] owner=${d.ownerId} '
            'internalRoomId=${args.roomId} linker=${d.linkerMapJson}');
      } catch (e) {
        stdout.writeln('[$webRid] 失败: ${e.toString().substring(0, 80)}');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
