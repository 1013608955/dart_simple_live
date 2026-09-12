# PK 修改版 · 上游跟进手册

本仓库 = June6699/dart_simple_live（origin）+ 抖音 PK/连麦 修改。
基线：upstream 7104fc3 + PK 功能基线（4b2d785）。

## 日常跟进（上游更新时）

```bash
cd simple_live_pk
git fetch origin
git log HEAD..origin/master --oneline   # 看上游更新了什么
git merge origin/master                 # 合并
```

## 冲突处理

**会冲突的文件只有这几类**（我们的改动面，`git diff 7104fc3 --stat` 可复核）：

| 文件 | 我们改了什么 |
|---|---|
| simple_live_core/lib/src/douyin_site.dart | linker_map/enlarge/owner 提取、cookie 回退 |
| simple_live_core/lib/src/danmaku/douyin_danmaku.dart | PK 消息分发、STATE 日志、座位解析 |
| simple_live_core/lib/src/model/live_room_detail.dart | +ownerId/linkerMapJson/enlargeGuest 三字段 |
| simple_live_app/lib/modules/live_room/live_room_controller.dart | PK 接线（_sanitizeRoomDetail 三字段透传！） |
| simple_live_app/lib/modules/live_room/live_room_page.dart | PK 层挂载 |
| simple_live_app/lib/modules/live_room/widgets/pk_bar.dart | 全新文件（不会冲突） |
| simple_live_core/lib/src/danmaku/douyin_pk.dart | 全新文件（不会冲突） |

- `simple_live_tv_app/**` 冲突（上游改了它、我们已删除）：一律 `git rm -r simple_live_tv_app` 后继续。
- 其余文件上游自己的改动会自动合入。

## 合并后必做（回归三件套）

```bash
cd simple_live_core && D:/flutter_sdk/flutter/bin/flutter.bat analyze && D:/flutter_sdk/flutter/bin/flutter.bat test
cd ../simple_live_app && D:/flutter_sdk/flutter/bin/flutter.bat analyze && D:/flutter_sdk/flutter/bin/flutter.bat build windows --release
```

构建产物：`simple_live_app/build/windows/x64/runner/Release/simple_live_app-xiugaiban.exe`
（改的是 Dart 代码时看 `data/app.so` 时间戳确认生效。）

## 版本约定

- 每修一个问题就 `git commit`（不要攒）；发版打 tag：`git tag v-pk-YYYYMMDD`。
- 回滚：`git log --oneline` 找好提交 → `git checkout <tag/commit>` 或 `git revert`。

## 注意事项

- `_sanitizeRoomDetail`（live_room_controller.dart）必须透传
  ownerId/linkerMapJson/enlargeGuest——历史上漏过，导致座位表/本房识别全废。
- PK 局 linker_map 值 = 战斗频道号（≠房间号）；普通连麦 = 房间号（reflow 可解析）。
- 组队局格子按队伍分块（我队 [0,1,3]@3v3 / [0,2]@2v2）；乱斗局=本房优先+加入序。
- 诊断日志：%TEMP%/simple_live_pk_debug.log（STATE/SEATMAP/ROOMRES/DETAIL 行）。
