import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/scripts/douyin_sign.dart';
import 'package:test/test.dart';

/// dump enter 接口完整响应的键结构：找战斗名单（user_infos/battle）字段
void main() {
  test('probe-enter-keys', () async {
    final site = DouyinSite();
    // 复用内部请求：直接 HTTP 调 enter（默认 ttwid）
    const webRid = '152093002398';
    final uri = Uri.parse('https://live.douyin.com/webcast/room/web/enter/')
        .replace(queryParameters: {
      "aid": "6383",
      "app_name": "douyin_web",
      "live_id": "1",
      "device_platform": "web",
      "language": "zh-CN",
      "browser_language": "zh-CN",
      "browser_platform": "Win32",
      "browser_name": "Chrome",
      "browser_version": "125.0.0.0",
      "web_rid": webRid,
      "msToken": "",
    });
    final signed = DouyinSign.getAbogusUrl(uri.toString(), DouyinSite.kDefaultUserAgent);
    // 先访问页面拿新鲜 cookie（模拟浏览器），再调 enter
    final headReq = await HttpClient().openUrl('HEAD', Uri.parse('https://live.douyin.com/$webRid'));
    headReq.headers.set('User-Agent', DouyinSite.kDefaultUserAgent);
    final headResp = await headReq.close();
    var cookie = '';
    headResp.headers['set-cookie']?.forEach((c) {
      final pair = c.split(';').first;
      if (pair.contains('ttwid') ||
          pair.contains('__ac_nonce') ||
          pair.contains('msToken')) {
        cookie = cookie.isEmpty ? pair : '$cookie; $pair';
      }
    });
    stdout.writeln('cookie=$cookie');
    final req = await HttpClient().getUrl(Uri.parse(signed));
    req.headers.set('User-Agent', DouyinSite.kDefaultUserAgent);
    req.headers.set('Cookie', cookie);
    req.headers.set('Referer', 'https://live.douyin.com/$webRid');
    final resp = await req.close();
    final body = await resp.fold(BytesBuilder(), (b, c) => b..add(c))
        .then((b) => b.takeBytes());
    final obj = jsonDecode(utf8.decode(body)) as Map;
    final data = obj['data'] as Map;
    stdout.writeln('data 顶层键: ${data.keys.toList()}');
    final rooms = data['data'];
    if (rooms is List && rooms.isNotEmpty) {
      final room = rooms.first as Map;
      stdout.writeln('room 顶层键: ${room.keys.toList()}');
      for (final k in room.keys) {
        final v = room[k];
        if (v is Map && v.isNotEmpty) {
          stdout.writeln('  room.$k: ${v.keys.take(12).toList()}');
        } else if (v is List && v.isNotEmpty) {
          stdout.writeln('  room.$k: list(${v.length})');
        }
      }
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
