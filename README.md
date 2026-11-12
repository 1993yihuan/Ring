# Ring

macOS 桌面演示：双击同一侧 Option，第二次松键后在鼠标位置弹出环形启动器，点击图标在前台打开配置的应用。

本目录是项目交付物的唯一位置：源码、测试、脚本、构建产物、运行数据、日志都在这里，不使用 Application Support，不在其他目录保存项目副本。

构建工具自身的缓存可能写到项目外。`scripts/*.sh` 已把 SwiftPM 与模块缓存显式指向 `build/`，所以用脚本构建时缓存留在项目内；直接手动执行 `swift build` 不受此约束。

## 当前状态

- 已完成：触发识别、环形显示与命中、8 槽位配置与持久化、应用启动与错误反馈、菜单栏与设置窗口、权限状态与显式请求、Universal 2 构建。
- 未验证：真实双击 Option、环形焦点与点击穿透、输入监控权限授予、Esc 与外部点击透传、多屏与缩放。这些都必须在真实 macOS 上用键鼠完成，自动测试无法替代。

## 环境要求

- macOS 13.0 或更高（部署下限，LC_BUILD_VERSION minos 13.0）。实际只在 macOS 26.5.1 / Intel 上构建，更早系统未实测。
- Xcode 26.3 与 Swift 6.2.4（本机已验证），无第三方依赖。

## 构建

在项目根目录执行：

```bash
./scripts/test.sh          # 55 个单元测试，日志写 build/test.log
./scripts/test-output-guard.sh   # 构建输出目录校验（项目外路径必须被拒绝）
./scripts/build.sh         # Universal 2 产物：build/Ring.app
```

scripts/build.sh 分别以 x86_64-apple-macos13.0 与 arm64-apple-macos13.0 编译，用 lipo 合并，随后 ad-hoc 签名并核对每个自带可执行文件的 slice。使用脚本构建时，缓存与输出都指向 build/ 下（CLANG_MODULE_CACHE_PATH、SWIFT_MODULE_CACHE_PATH，以及 SwiftPM 的 cache/config/security 路径）。这是脚本的配置目标，需要走脚本才成立；直接手动跑 swift build 仍可能写项目外目录。

测试数据：实测设置 TMPDIR 后 `FileManager.temporaryDirectory` 仍返回系统临时目录，故本项目不依赖 TMPDIR 定位。测试默认把数据放在 `build/test-data`（由测试文件自身的 `#filePath` 定位项目根），目录不可用时直接失败，**不回退系统临时目录**；目录不存在时自动创建。scripts/test.sh 另以 RING_TEST_DATA_DIR 显式固定同一位置。测试用后自行删除子目录。

输出路径：RING_OUTPUT_DIR 可改构建产物落点（默认 build/），例如 RING_OUTPUT_DIR=$PWD/build/verification ./scripts/build.sh 这样独立复跑不会覆盖已交付的 build/Ring.app。**只接受项目内路径**：build.sh 在删除任何内容之前先校验物理路径，指向项目外（含经符号链接指向外部）会被拒绝并退出 2。校验脚本：./scripts/test-output-guard.sh。

可用环境变量覆盖：RING_ARCHS（默认 x86_64 arm64）、RING_DEPLOYMENT_TARGET（默认 13.0）。

## 最短试用步骤

1. 运行 ./scripts/build.sh，确认 build/Ring.app 存在。
2. 打开一次：open build/Ring.app。菜单栏出现虚线圆图标。
3. 菜单栏 → 请求输入监控权限。系统提示后到「系统设置 → 隐私与安全性 → 输入监控」勾选 Ring；若提示需重开，退出后再次执行 open build/Ring.app。
4. 菜单栏 → 设置…，点任意槽位的「选择…」挑选一个 .app，关闭窗口（改动立即保存到 data/configuration.json）。
5. 切到任意其他应用，快速双击同一侧 Option（左或右，两侧不能混），在第二次松键后环形出现在鼠标处并保持。
6. 移动鼠标到图标上（显示名称），点击一次打开该应用，环形关闭。
7. 取消：Esc、点击环形中心的空白、或点击面板外部。
8. 未取得权限时，用菜单栏「手动打开环形（布局验证）」检查布局与启动；这不算核心链路通过。

## 数据与日志位置

- 配置：data/configuration.json（首次运行自动创建 8 个空槽位）。
- 构建日志与缓存：build/。
- 运行期错误通过 NSLog 输出到系统统一日志（log stream --predicate 'process == "Ring"'），本项目不写自有日志文件。

## 已知限制

- **Apple Silicon 原生运行未验证**：arm64 slice 已编译、链接并通过 lipo 核对，但本机是 Intel，无法运行该 slice。不得用 Rosetta 或切片检查代替实机验收。
- 真实键鼠行为未验证：双击 Option、松键保持、环形命中、Esc 与外部点击透传、普通 Option 组合键不误触、焦点不夺走。
- 输入监控权限的授予、拒绝与恢复未在本机实测。
- 多显示器、负坐标、混合缩放、全屏 Space 与 Stage Manager 未实测；纯函数布局测试只覆盖几何计算。
- 睡眠/唤醒、Secure Input、远程键盘未实测。
- 未做 Developer ID 签名与公证，仅 ad-hoc；公开分发前需另行处理。

## 目录

```
Sources/RingCore/     纯逻辑：双击识别、布局命中、配置与存储、会话状态、路径解析
Sources/RingApp/      AppKit/SwiftUI：全局监听、面板、设置、菜单栏、启动器
Tests/RingCoreTests/  55 个单元测试
Packaging/Info.plist  bundle 元数据
scripts/              test.sh、build.sh、make-icon.sh
assets/icon/          应用图标源图
build/                构建产物与缓存（可再生）
data/                 运行期配置
```
