import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

/// 验证 reflow 接口按 room_id 查房主：data.room.owner.id_str/nickname。
/// 这是 linker_map（座位->房间号）解析成 uid 的桥。
void main() {
  test('probe-reflow', () async {
    const roomIds = [
      '7684679029449870115', // 博哥文化传媒（收徒）
      '7684717678589692712', // 康康辩是非
    ];
    for (final roomId in roomIds) {
      final url = 'https://webcast.amemv.com/webcast/room/reflow/info/'
          '?type_id=0&live_id=1&room_id=$roomId&sec_user_id='
          '&version_code=99.99.99&app_id=6383';
      final req = await HttpClient().getUrl(Uri.parse(url));
      req.headers.set('User-Agent', DouyinSite.kDefaultUserAgent);
      req.headers.set('Cookie',
          DouyinCookieHelper.extractTtwid(DouyinSite.kDefaultCookie) ?? '');
      req.headers.set('Referer', 'https://live.douyin.com/');
      final resp = await req.close();
      final bytes = await resp.fold(BytesBuilder(),
          (b, chunk) => b..add(chunk)).then((b) => b.takeBytes());
      stdout.writeln('[$roomId] status=${resp.statusCode} bytes=${bytes.length}');
      if (bytes.isEmpty) continue;
      final obj = jsonDecode(utf8.decode(bytes));
      final data = obj is Map ? obj["data"] : null;
      final room = data is Map ? data["room"] : null;
      final owner = room is Map ? room["owner"] : null;
      stdout.writeln('[$roomId] status=${obj is Map ? obj["status_code"] : "?"} '
          'owner=${owner is Map ? owner["id_str"] : null} '
          'nick=${owner is Map ? owner["nickname"] : null}');
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
