import 'dart:convert';

class LiveRoomDetail {
  /// 房间ID
  final String roomId;

  /// 房间标题
  final String title;

  /// 封面
  final String cover;

  /// 用户名
  final String userName;

  /// 主播用户 uid（抖音房间详情 owner.id_str；PK 本房格识别用，其他站点可能为空）
  final String ownerId;

  /// 连麦座位映射 JSON（position -> uid，抖音 linker_map；PK 格子顺序用）
  final String linkerMapJson;

  /// 是否处于放大（画中画）布局（linker_detail.enlarge_guest_turn_on_source）
  final bool enlargeGuest;

  /// 头像
  final String userAvatar;

  /// 在线
  final int online;

  /// 介绍
  final String? introduction;

  /// 公告
  final String? notice;

  /// 状态
  final bool status;

  /// 附加信息
  final dynamic data;

  /// 弹幕附加信息
  final dynamic danmakuData;

  /// 是否录播
  final bool isRecord;

  /// 链接
  final String url;

  /// 显示时间
  final String? showTime;

  /// 当前直播间所属分区 ID
  final String? categoryId;

  /// 当前直播间所属分区名称
  final String? categoryName;

  /// 当前直播间所属父分区 ID
  final String? categoryParentId;

  /// 当前直播间所属父分区名称
  final String? categoryParentName;

  /// 当前直播间所属分区图标
  final String? categoryPic;

  LiveRoomDetail({
    required this.roomId,
    required this.title,
    required this.cover,
    required this.userName,
    this.ownerId = '',
    this.linkerMapJson = '',
    this.enlargeGuest = false,
    required this.userAvatar,
    required this.online,
    this.introduction,
    this.notice,
    required this.status,
    this.data,
    this.danmakuData,
    required this.url,
    this.isRecord = false,
    this.showTime,
    this.categoryId,
    this.categoryName,
    this.categoryParentId,
    this.categoryParentName,
    this.categoryPic,
  });

  @override
  String toString() {
    return json.encode({
      "roomId": roomId,
      "title": title,
      "cover": cover,
      "userName": userName,
      "ownerId": ownerId,
      "userAvatar": userAvatar,
      "online": online,
      "introduction": introduction,
      "notice": notice,
      "status": status,
      "data": data.toString(),
      "danmakuData": danmakuData.toString(),
      "url": url,
      "isRecord": isRecord,
      "showTime": showTime,
      "categoryId": categoryId,
      "categoryName": categoryName,
      "categoryParentId": categoryParentId,
      "categoryParentName": categoryParentName,
      "categoryPic": categoryPic,
    });
  }
}
