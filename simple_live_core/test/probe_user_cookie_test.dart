import 'dart:io';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

/// 决定性对比：用户收藏的真实观看房间，分别用
/// (a) 默认 ttwid  (b) 用户手填的旧 ttwid（app 内实际首发请求）
/// 拉详情，看 (b) 是否就是"降级无 owner/linker"的元凶。
void main() {
  test('probe-user-cookie', () async {
    final staleTtwid = File(
            r'C:/Users/Admin/.openclaw/workspace/simple_live/_scratch/stale_ttwid.txt')
        .readAsStringSync()
        .trim();
    const rooms = [
      '344726105554',
      '102482717623',
      '335123546834',
      '341807637682',
    ];
    for (final webRid in rooms) {
      // (a) 默认 ttwid
      final freshSite = DouyinSite();
      String a = '?', al = '?';
      try {
        final d = await freshSite.getRoomDetailByWebRid(webRid);
        a = d.ownerId.isEmpty ? '(空)' : '有';
        al = d.linkerMapJson.length > 2 ? '有' : '空';
      } catch (e) {
        a = '失败:${e.toString().substring(0, 30)}';
      }
      // (b) 用户旧 ttwid
      final userSite = DouyinSite();
      userSite.cookie = staleTtwid;
      String b = '?', bl = '?';
      try {
        final d = await userSite.getRoomDetailByWebRid(webRid);
        b = d.ownerId.isEmpty ? '(空)' : '有';
        bl = d.linkerMapJson.length > 2 ? '有' : '空';
      } catch (e) {
        b = '失败:${e.toString().substring(0, 30)}';
      }
      stdout.writeln('[$webRid] 默认ttwid: owner=$a linker=$al | '
          '用户旧ttwid: owner=$b linker=$bl');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
