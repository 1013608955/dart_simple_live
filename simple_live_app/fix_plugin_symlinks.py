#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
修复 Flutter Windows 构建的 .plugin_symlinks 问题（沙箱环境下无法创建符号链接）

问题链条：
  1. 本机沙箱里 Dart 的 Link.createSync() 造不出真符号链接，退化为「断链」或「空目录」
  2. flutter_plugins.dart 的 _createPlatformPluginSymlinks() 逻辑是：
         if (link.existsSync()) continue;      // 已存在则跳过
         link.createSync(path);
     - 若是「断链」：existsSync() 在 Windows 上返回 false → 走到 createSync → errno=183（已存在）
     - 若是「空目录」：existsSync() 返回 true，跳过，但 CMake 找不到 <plugin>/windows
  3. 于是 build 要么 183 报错，要么 CMake 报 "not an existing directory"

解法：
  预先把 .plugin_symlinks/<plugin> 造成【真实目录】，并把插件源码的对应平台子目录复制进去。
  - existsSync() == true  → Flutter 跳过创建，不再 183
  - 复制了真实内容       → CMake 能 add_subdirectory(<plugin>/windows)

用法：python fix_plugin_symlinks.py
"""
import json
import os
import shutil
import sys

APP_DIR = os.path.dirname(os.path.abspath(__file__))


def load_package_roots():
    """从 .dart_tool/package_config.json 读出 包名 -> 绝对路径

    注意：相对 rootUri（如 '../../third_party/xxx'）是相对于 **.dart_tool/ 目录**
    解析的，不是相对于 app 目录。搞错基准会导致路径依赖找不到。
    """
    cfg = os.path.join(APP_DIR, ".dart_tool", "package_config.json")
    if not os.path.exists(cfg):
        print("[!] 找不到 .dart_tool/package_config.json，请先 flutter pub get")
        sys.exit(1)
    base = os.path.dirname(cfg)  # .dart_tool
    with open(cfg, encoding="utf-8") as f:
        data = json.load(f)
    roots = {}
    for pkg in data.get("packages", []):
        name = pkg.get("name")
        uri = pkg.get("rootUri", "")
        if uri.startswith("file:///"):
            path = uri[len("file:///"):]
        elif uri.startswith("file://"):
            path = uri[len("file://"):]
        elif uri.startswith("..") or uri.startswith("."):
            path = os.path.normpath(os.path.join(base, uri))
        else:
            path = uri
        path = path.replace("/", os.sep)
        roots[name] = os.path.normpath(path)
    return roots


def parse_cmake_plugin_list(cmake_path):
    """从 generated_plugins.cmake 里取出插件名列表"""
    if not os.path.exists(cmake_path):
        return []
    names, in_block = [], False
    with open(cmake_path, encoding="utf-8", errors="ignore") as f:
        for line in f:
            s = line.strip()
            if s.startswith("list(APPEND FLUTTER_PLUGIN_LIST") or \
               s.startswith("list(APPEND FLUTTER_FFI_PLUGIN_LIST"):
                in_block = True
                # 单行形式 list(APPEND ... a b c)
                if ")" in s:
                    body = s[s.index("(") + 1:s.rindex(")")]
                    parts = body.split()
                    names.extend(parts[3:])
                    in_block = False
                continue
            if in_block:
                if s == ")":
                    in_block = False
                    continue
                names.append(s)
    return names


def fix(platform, subdir, symlink_root, roots, copy_content=True):
    print("=== 处理 %s -> %s" % (platform, symlink_root))
    full_root = os.path.join(APP_DIR, symlink_root)

    if os.path.exists(full_root):
        shutil.rmtree(full_root, ignore_errors=True)
    os.makedirs(full_root, exist_ok=True)

    cmake = os.path.join(APP_DIR, platform, "flutter", "generated_plugins.cmake")
    names = parse_cmake_plugin_list(cmake)
    if not names:
        print("    (未找到插件清单，跳过)")
        return 0

    done = 0
    for name in names:
        src = roots.get(name)
        target = os.path.join(full_root, name)

        if copy_content and src and os.path.isdir(src):
            # 必须拷贝【整个插件目录】，不能只拷平台子目录：
            # 有些插件的 CMakeLists 会引用同级目录，例如 jni 的
            #   add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src")
            # 即 <plugin>/src。只拷 windows/ 会导致该目录不存在。
            if os.path.exists(target):
                shutil.rmtree(target, ignore_errors=True)
            shutil.copytree(src, target)
            done += 1
            continue

        os.makedirs(target, exist_ok=True)
        if src is None:
            print("      [!] 在 package_config 里找不到包 %s" % name)

    print("    已预置 %d 个插件（共 %d 个）" % (done, len(names)))
    return done


def place_mpv_archive(symlink_root):
    """为 media_kit_libs_windows_video 预置 mpv-dev 归档。

    该插件的 windows/CMakeLists.txt 用
        ${CMAKE_CURRENT_LIST_DIR}/../../${LIBMPV}
    定位预取的 mpv-dev-*.7z。原本插件在 third_party/media_kit_libs_windows_video/windows，
    '../../' 正好是 third_party/（.gitignore 也忽略这个路径）。

    但本方案把插件【拷贝】到了 .plugin_symlinks/，于是 '../../' 变成 .plugin_symlinks/ 自身，
    预取文件必须同时放到那里，否则 CMake 会去联网下载（本机下载会失败）。
    """
    repo_root = os.path.dirname(APP_DIR)
    tp = os.path.join(repo_root, "third_party")
    archives = []
    if os.path.isdir(tp):
        for name in os.listdir(tp):
            if name.startswith("mpv-dev-") and name.endswith(".7z"):
                archives.append(os.path.join(tp, name))

    if not archives:
        print("      [!] third_party/ 下没有 mpv-dev-*.7z")
        print("          CMake 将尝试联网下载，本机网络下会失败。")
        print("          下载地址见 media_kit_libs_windows_video/windows/CMakeLists.txt 的 LIBMPV_URL")
        return

    dst_root = os.path.join(APP_DIR, symlink_root)
    for a in archives:
        shutil.copy2(a, os.path.join(dst_root, os.path.basename(a)))
        print("      已放置 %s" % os.path.basename(a))


def main():
    roots = load_package_roots()
    print("已读取 %d 个包的路径\n" % len(roots))

    fix("windows", "windows", "windows/flutter/ephemeral/.plugin_symlinks", roots, True)
    place_mpv_archive("windows/flutter/ephemeral/.plugin_symlinks")
    print()
    # linux 不需要真实内容（windows 构建不会跑 linux 的 CMake），但目录必须存在，
    # 否则 Flutter 会去 createSync 触发 183
    fix("linux", "linux", "linux/flutter/ephemeral/.plugin_symlinks", roots, False)

    print("\n[OK] 完成。现在可以运行：flutter build windows --release")


if __name__ == "__main__":
    main()
