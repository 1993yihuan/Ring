# Ring

macOS 桌面演示：双击同一侧 Option，第二次按下即在鼠标处弹出环形启动器。按住时移动鼠标选择，松开时按松开的位置启动该槽位的应用。

<img width="2012" height="1150" alt="双击 Option，即刻启动" src="https://github.com/1993yihuan/Ring/releases/download/v0.1.3/preview.png" />

网站：https://1993yihuan.github.io/Ring/ （静态页面在 `website/`，推送到 `main` 后由 GitHub Actions 发布到 GitHub Pages）。

本目录是项目交付物的唯一位置：源码、测试、脚本、构建产物、运行数据、日志都在这里，不使用 Application Support，不在其他目录保存项目副本。

构建工具自身的缓存可能写到项目外。`scripts/*.sh` 已把 SwiftPM 与模块缓存显式指向 `build/`，所以用脚本构建时缓存留在项目内；直接手动执行 `swift build` 不受此约束。

## 当前状态

- 已完成：触发识别、环形显示与命中、可见位置数可配置（3–8，默认 8，收缩只隐藏后缀、调大恢复）、槽位配置与持久化、应用启动与错误反馈、菜单栏与设置窗口、权限状态与显式请求、Universal 2 本地构建。GitHub Release 按架构各发布一个 DMG。
- 已完成（按住选择、松开启动）：第二次按下就显示环形，按住时鼠标方向决定高亮的槽位，环心显示该槽位的应用名。松开时按松开事件所在的位置决定结果，不看之前的悬停。图标按圆形范围命中，命中就启动该图标；圆盘之外任意距离都按角度选槽，跨到别的屏幕也算，落在哪个方向就启动哪个槽位；环心、空槽与图标之间的间隙取消。按 Esc、监听失效或中途按下鼠标会立刻取消，取消后覆盖层保留到这次按键的松开被消费，松开不会落到后面的应用。菜单栏「手动打开环形」仍用旧的点选模式，且只作用于环形所在屏幕。
- 已完成（界面）：圆形浅色磨砂环、唯一悬停项青蓝强调、设置窗口左侧环形预览加右侧槽位列表（按可见位置数显示 N 行 / N 个方向，可选 3–8）、独立权限卡。槽位编号统一为顶部 1、顺时针到 N。
- 未验证：真实双击 Option、按住移动与松开投递在真实 WindowServer 下的表现、跨屏角度选择、输入监控权限授予、缩放。这些都必须在真实 macOS 上用键鼠完成，自动测试无法替代。

## 下载

当前应用版本是 0.1.3。推送标签 `v0.1.3` 后，[GitHub Releases](https://github.com/1993yihuan/Ring/releases) 上该版本的附件是两个压缩 DMG，没有 zip。磁盘卷顶层是 `Ring.app`：

- `Ring-0.1.3-intel.dmg`：Intel Mac，可执行文件只有 x86_64。
- `Ring-0.1.3-apple-silicon.dmg`：Apple Silicon / M 系列 Mac，可执行文件只有 arm64。

文件名里的版本来自标签（`v0.1.3` → `0.1.3`），不是写死的旧版本号。查看机型：苹果菜单 → 关于本机。芯片显示 Apple M1、M2、M3、M4 或更新时，下载 Apple Silicon 那个 DMG。处理器显示 Intel 时，下载 Intel 那个 DMG。arm64 包不能在 Intel Mac 上运行。

签名是 ad-hoc（`codesign --sign -`）：可以下载安装，没有 Developer ID，也没有公证。macOS Gatekeeper 会在第一次打开时拦截，需要下载者自己放行。放行 Gatekeeper 之后，输入监控权限还要单独授予，两者不是同一项授权。

1. 从 Releases 下载与本机匹配的 DMG。
2. 在访达中双击该 DMG，打开磁盘映像。卷内顶层就是 `Ring.app`，不是 zip。
3. 把 `Ring.app` 拖到「应用程序」（也可以直接从磁盘映像里打开）。
4. 第一次打开时系统可能直接阻止。然后任选一种方式放行：
   - 打开「系统设置 → 隐私与安全性」，点「仍要打开」（System Settings → Privacy & Security → Open Anyway）；或
   - 在访达中右键 `Ring.app`（或按住 Control 点按），选择「打开」，并在对话框里确认打开（right-click the app and choose Open）。
5. 菜单栏 → 请求输入监控权限，再到「系统设置 → 隐私与安全性 → 输入监控」勾选 Ring。若系统要求重开，退出后再次打开。这一步与上面的 Gatekeeper 放行无关，装好之后仍然需要。

已有的 `v0.1.0` Release 和它的 `Ring-0.1.0-macos.zip` 保持原样，本流程不重打、不移动、不删除那个 Release。已有的 `v0.1.2` Release 和它的两个 DMG（`Ring-0.1.2-intel.dmg`、`Ring-0.1.2-apple-silicon.dmg`）同样保持原样，不重打标签、不修改。那个 zip 是更早提交打的 Universal 2 包，不包含下面「当前状态」里的按角度选择、环外单击启动和权限状态修复。

发布：把要发布的提交合并进 `main` 后，在该提交上推送形如 `v0.1.3` 的标签（`v` 加主版本、次版本、修订号）。GitHub Actions 用标签名去掉前缀 `v` 作为版本，运行 `./scripts/test.sh` 和 `./scripts/test-output-guard.sh`，再由 `scripts/package-dmg.sh` 分别以 `RING_ARCHS=x86_64` 与 `RING_ARCHS=arm64` 调用 `./scripts/build.sh`。每次都是 ad-hoc 签名。脚本用 `ditto` 把 `Ring.app` 拷进临时目录，再执行 `hdiutil create -volname Ring -srcfolder <该目录> -format UDZO`，因此卷内顶层是完整的 `Ring.app`，而不是把 zip 再包进 DMG。随后单独挂载每个 DMG，执行 `codesign --verify --strict`，确认输出里有 `Signature=adhoc`，并用 `lipo -archs` 确认可执行文件恰好是这一种架构；多出来的切片或签名不符都会让任务失败。上传文件只有 `Ring-<version>-intel.dmg` 和 `Ring-<version>-apple-silicon.dmg`。若这个标签自己已经有 Release，会用 `--clobber` 覆盖同名 DMG，并删掉该标签上其余附件（包括 `Ring-<version>-macos.zip`）。不会改其他标签。要重跑同一次发布时，在 Actions 的 Release 工作流里选中这个标签再手动运行。

发布 runner 是 GitHub 托管的 `macos-26`（Apple Silicon，当前的 `macos-latest`）。2026-11 的镜像软件清单包含 Xcode 26.3（`/Applications/Xcode_26.3.app`），默认 Xcode 则是 26.6。工作流把 `DEVELOPER_DIR` 指到 26.3，与下面已验证的 Xcode 26.3 / Swift 6.2.4 对齐。`Package.swift` 要求 Swift tools 6.0，部署目标是 macOS 13.0，公开 runner 上的这个 Xcode 可以编译。本机记录仍是 Intel 上的 macOS 26.5.1；Actions 在 Apple Silicon 上按架构分别编译，挂载 DMG 后核对 `lipo -archs`，不启动应用。

Finder 里的版本号来自 `Packaging/Info.plist` 的 `CFBundleShortVersionString`（目前是 0.1.3，`CFBundleVersion` 是 3）。标签名不会自动写进这个字段；希望两者一致时，推送标签前先改 plist。

## 环境要求

- macOS 13.0 或更高（部署下限，LC_BUILD_VERSION minos 13.0）。实际只在 macOS 26.5.1 / Intel 上构建，更早系统未实测。
- Xcode 26.3 与 Swift 6.2.4（本机已验证），无第三方依赖。

## 构建

在项目根目录执行：

```bash
./scripts/test.sh          # 137 个单元测试，日志写 build/test.log
./scripts/test-output-guard.sh   # 构建输出目录校验（项目外路径必须被拒绝）
./scripts/build.sh         # Universal 2 产物：build/Ring.app
```

拉取请求上的 CI 运行 `./scripts/test.sh`。推送版本标签时，发布流程会运行 `./scripts/test.sh`、`./scripts/test-output-guard.sh`，并对 x86_64 与 arm64 各运行一次 `./scripts/package-dmg.sh`（内部调用 `./scripts/build.sh`）。

scripts/build.sh 分别以 x86_64-apple-macos13.0 与 arm64-apple-macos13.0 编译，用 lipo 合并，随后 ad-hoc 签名并核对每个自带可执行文件的 slice。使用脚本构建时，缓存与输出都指向 build/ 下（CLANG_MODULE_CACHE_PATH、SWIFT_MODULE_CACHE_PATH，以及 SwiftPM 的 cache/config/security 路径）。这是脚本的配置目标，需要走脚本才成立；直接手动跑 swift build 仍可能写项目外目录。

测试数据：实测设置 TMPDIR 后 `FileManager.temporaryDirectory` 仍返回系统临时目录，故本项目不依赖 TMPDIR 定位。测试默认把数据放在 `build/test-data`（由测试文件自身的 `#filePath` 定位项目根），目录不可用时直接失败，**不回退系统临时目录**；目录不存在时自动创建。scripts/test.sh 另以 RING_TEST_DATA_DIR 显式固定同一位置。测试用后自行删除子目录。

输出路径：RING_OUTPUT_DIR 可改构建产物落点（默认 build/），例如 RING_OUTPUT_DIR=$PWD/build/verification ./scripts/build.sh 这样独立复跑不会覆盖已交付的 build/Ring.app。**只接受项目内路径**：build.sh 在删除任何内容之前先校验物理路径，指向项目外（含经符号链接指向外部）会被拒绝并退出 2。校验脚本：./scripts/test-output-guard.sh。

可用环境变量覆盖：RING_ARCHS（默认 x86_64 arm64）、RING_DEPLOYMENT_TARGET（默认 13.0）。

发布不使用默认的双架构合并。`scripts/package-dmg.sh` 把 `RING_ARCHS` 设成单独的 `x86_64` 或 `arm64`，再把该次的 `Ring.app` 打成 DMG。本地直接运行 `./scripts/build.sh` 时默认仍是 Universal 2。这条打包命令依赖 macOS 的 `hdiutil`，不能在 Linux 上执行。

## 最短试用步骤

1. 运行 ./scripts/build.sh，确认 build/Ring.app 存在。
2. 打开一次：open build/Ring.app。菜单栏出现虚线圆图标。
3. 菜单栏 → 请求输入监控权限。设置窗口显示当前结果；监听未启动时可点「重试监听」。若没看到系统弹窗，打开「系统设置 → 隐私与安全性 → 输入监控」勾选 Ring，回到 Ring 会自动刷新并重试监听。
4. 菜单栏 → 设置…，在右侧八行列表里点「添加…／替换…」挑选一个 .app（改动立即保存到 data/configuration.json，「保存」可再写一次）。左侧预览与列表编号同序：顶部为 1，顺时针到 8。
5. 切到任意其他应用，快速双击同一侧 Option（左或右，两侧不能混）。第二次按下时环形就在鼠标处出现。
6. 保持按住不放，移动鼠标改变方向：对应槽位局部青蓝强调，环心显示该应用名。
7. 松开 Option 启动：松开时鼠标在哪个方向就启动哪个槽位，移到另一块屏幕也算。也可以把鼠标停在图标上再松开，图标按圆形范围命中。
8. 取消：松开前按 Esc、松开时停在环心或图标之间的间隙、或者中途按一下鼠标键。
9. 未取得权限时，用菜单栏「手动打开环形（布局验证）」检查布局与启动；这不算核心链路通过。

## 数据与日志位置

- 配置：data/configuration.json（首次运行自动创建 8 个空槽位；`visibleSlotCount` 记录可见位置数 3–8，缺省为 8，隐藏的槽仍保留在文件里）。
- 构建日志与缓存：build/。
- 运行期错误通过 NSLog 输出到系统统一日志（log stream --predicate 'process == "Ring"'），本项目不写自有日志文件。

## 已知限制

- **Apple Silicon 原生运行未验证**：发布用的 Apple Silicon DMG 只含 arm64，会在打包后用 `lipo -archs` 核对，但本机是 Intel，无法运行它。不得用 Rosetta 或切片检查代替实机验收。
- 真实键鼠行为未验证：双击 Option、按住保持、松开坐标投递、按角度选槽、松开是否落后台应用、Esc 取消、普通 Option 组合键不误触、焦点不夺走。
- 透明区域命中与整屏覆盖未验证：覆盖层接管输入，圆外的鼠标移动与松开能否稳定到达、覆盖层是否影响其他窗口与应用，都需要真实设备确认。
- 本轮界面的观感未目视验收：毛玻璃材质、青蓝悬停、中心文案与设置弹窗 N 行是否全可见，都只在离屏编译与纯函数层面确认，未在真实屏幕上查看。
- 可见位置数控件未在真实 GUI 里操作过：3–8 分段控件的点击、隐藏后缀与调大恢复后的列表、预览与真实环，只有纯函数与单元测试覆盖。
- 小窗口高度只做了离屏测量：可见位置数从 8 降到 3 时设置窗口按内容收窄高度，未在真实屏幕上确认遮挡与裁切。
- 输入监控权限的授予、拒绝与恢复未在本机实测；设置里的「打开系统设置」只验证到 URL 与目标面板标识符存在，真实跳转未验证。
- 多显示器、负坐标、混合缩放、全屏 Space 与 Stage Manager 未实测；跨屏按角度选槽只由纯函数规则保证，未在真实双屏上验证。
- 睡眠/唤醒、Secure Input、远程键盘未实测。
- 签名只有 ad-hoc。可以从 Releases 下载，Gatekeeper 会拦截，直到按「下载」一节自行放行。发布流程按此限制，只使用 ad-hoc 签名。

## 目录

```
Sources/RingCore/     纯逻辑：双击识别、布局命中、配置与存储、会话状态、路径解析
Sources/RingApp/      AppKit/SwiftUI：全局监听、面板、设置、菜单栏、启动器
Tests/RingCoreTests/  137 个单元测试
Packaging/Info.plist  bundle 元数据
scripts/              test.sh、build.sh、package-dmg.sh、make-icon.sh
.github/workflows/    拉取请求跑测试；推送 vX.Y.Z 标签时打包并发布；网站变更时发布 Pages
assets/icon/          应用图标源图
website/              产品页（GitHub Pages）
build/                构建产物与缓存（可再生）
data/                 运行期配置
```
