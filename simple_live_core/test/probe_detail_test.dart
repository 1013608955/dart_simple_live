import 'dart:io';
import 'dart:typed_data';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

/// 探测抖音房间详情三条路径（API/HTML/公共入口）实际返回的
/// ownerId / linkerMapJson / enlargeGuest，定位 linker_map 为空的层级。
/// 运行：flutter test test/probe_detail_test.dart --plain-name "probe"
void main() {
  test('probe', () async {
    final site = DouyinSite();
    final webRids = [
      '60829777', // 春虫虫（本房）
    ];
    for (final webRid in webRids) {
      try {
        final d = await site.getRoomDetailByWebRid(webRid);
        stdout.writeln(
            '[$webRid] owner=${d.ownerId} nick=${d.userName} '
            'enlarge=${d.enlargeGuest} linker=${d.linkerMapJson}');
      } catch (e) {
        stdout.writeln('[$webRid] getRoomDetailByWebRid 失败: $e');
      }

      // 原始页面 HTML 对照：linker_map 是否真实出现在 SSR 数据里
      try {
        final html = await _fetchPage(webRid);
        final m = RegExp(r'"linker_map":\{[^}]*\}').firstMatch(html);
        stdout.writeln(
            '[$webRid] pageHtml linker_map=${m?.group(0) ?? "(无)"} '
            'ownerIdStr=${RegExp(r'"id_str":"(\d+)"').firstMatch(html)?.group(1)}');
        final idx = html.indexOf('"anchor"');
        if (idx > 0) {
          stdout.writeln('[$webRid] anchor 段: '
              '${html.substring(idx, idx + 200).replaceAll("\n", " ")}');
        }
      } catch (e) {
        stdout.writeln('[$webRid] 页面抓取失败: $e');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}

Future<String> _fetchPage(String webRid) async {
  final client = HttpClient();
  final req = await client.getUrl(Uri.parse('https://live.douyin.com/$webRid'));
  req.headers.set('User-Agent',
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36');
  final resp = await req.close();
  final body = await resp.fold(
      BytesBuilder(), (b, chunk) => b..add(chunk)).then((b) => b.takeBytes());
  return systemEncoding.decode(body);
}
