# Ring 默认 Option 轮询监听（免输入监控权限）

## 当前验证范围

2026-11-18：用户已在 Intel Mac（macOS 26.5.1）关闭「输入监控」授权后，验证左右 Option 双击、第二次长按、鼠标选择、松开启动等操作正常。日志记录过无授权状态和实体左右 Option 被读取到。

Ring 现在仅保留轮询实现；不再编译旧事件监听、请求输入监控授权，也不维护本机自签名授权迁移机制。其他 macOS/键盘型号仍需独立验证。

## 构建与验证

- 在项目根目录直接执行 `RING_ARCHS=x86_64 scripts/build.sh`，最新 App 位于 `build/Ring.app`。
- 运行前退出所有旧版 Ring，避免多个进程同时响应 Option 双击。
- 不进行权限授权，直接测试左右 Option 连按、长按、鼠标选择、松开执行、Esc、普通按键干扰以及多屏切换。
- 运行诊断在 `data/listen-diagnostics.log`；其中只记录 `polling started`、`Option side observed` 和状态不一致的抑制原因，不采集文字。

## 具体实现与局限

- 每秒约 120 次读取 `NSEvent.modifierFlags`、`CGEventSource.keyState` 和全局 keyDown 计数；状态异常时忽略当前手势而不是猜测左右 Option。
- 只注册鼠标事件的 `NSEvent.addGlobalMonitorForEvents`，键盘由状态采样识别，不安装键盘事件监听，也不请求输入监控授权。
- `NSEvent.mouseLocation` 仅在按键变化或圆环显示期间读取，降低空闲开销。
- 极短按键可能错过采样时隙，松开位置是采样时点而非物理事件原子快照。睡眠唤醒、其他键盘布局和 macOS 版本仍需验证。
- ad-hoc 签名不等于 Developer ID 公证，首次打开可能仍需要 Gatekeeper 放行。

## 维护建议

正式发布前，在 Intel 和 Apple Silicon 上验证首次启动、无输入监控授权、左右 Option、长按、Esc、普通按键干扰、长时间空闲、睡眠唤醒、跨屏及更新后启动。
