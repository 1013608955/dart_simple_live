import 'dart:io';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

/// 模拟应用的 10s 级轮询：同一房间连续拉详情，观察
/// (a) 降级（owner 缺失/linker 空）何时出现 (b) 页面 cookie 重试是否救回。
/// 复现"战斗期间 seatRoom 始终为空"的环境因素。
void main() {
  test('probe-polling', () async {
    final site = DouyinSite();
    const webRid = '152093002398'; // 博哥文化传媒（此前探测有 linker 数据）
    for (var i = 1; i <= 25; i++) {
      String owner = '?';
      String linker = '?';
      try {
        final d = await site.getRoomDetailByWebRid(webRid);
        owner = d.ownerId.isEmpty ? '(空)' : d.ownerId;
        linker = d.linkerMapJson;
      } catch (e) {
        owner = '失败:${e.toString().substring(0, 40)}';
        linker = '-';
      }
      stdout.writeln(
          '#$i ${DateTime.now().toString().substring(11, 19)} owner=$owner linker=$linker');
      if (i < 25) await Future.delayed(const Duration(seconds: 12));
    }
  }, timeout: const Timeout(Duration(minutes: 8)));
}
