import XCTest
@testable import RingCore
import CoreGraphics

final class RingHighlightAnimationTests: XCTestCase {

    // MARK: - 1. 槽位目标角度映射

    func testSlotAngleCanonicalPositions() {
        // 12 槽（时钟表盘映射）
        // 0 位（12 点）：0 rad
        XCTAssertEqual(RingLaunchAnimation.slotAngle(slot: 0, count: 12), 0, accuracy: 1e-9)
        // 1 位（1 点）：顺时针 -30° (-pi/6)
        XCTAssertEqual(RingLaunchAnimation.slotAngle(slot: 1, count: 12), -Double.pi / 6, accuracy: 1e-9)
        // 3 位（3 点）：顺时针 -90° (-pi/2)
        XCTAssertEqual(RingLaunchAnimation.slotAngle(slot: 3, count: 12), -Double.pi / 2, accuracy: 1e-9)
        // 6 位（6 点）：顺时针 -180° (-pi)
        XCTAssertEqual(RingLaunchAnimation.slotAngle(slot: 6, count: 12), -Double.pi, accuracy: 1e-9)
        // 9 位（9 点）：顺时针 -270° (-3pi/2)
        XCTAssertEqual(RingLaunchAnimation.slotAngle(slot: 9, count: 12), -3 * Double.pi / 2, accuracy: 1e-9)
        // 11 位（11 点）：顺时针 -330° (-11pi/6)
        XCTAssertEqual(RingLaunchAnimation.slotAngle(slot: 11, count: 12), -11 * Double.pi / 6, accuracy: 1e-9)

        // 8 槽
        XCTAssertEqual(RingLaunchAnimation.slotAngle(slot: 0, count: 8), 0, accuracy: 1e-9)
        XCTAssertEqual(RingLaunchAnimation.slotAngle(slot: 2, count: 8), -Double.pi / 2, accuracy: 1e-9)
        XCTAssertEqual(RingLaunchAnimation.slotAngle(slot: 4, count: 8), -Double.pi, accuracy: 1e-9)
        XCTAssertEqual(RingLaunchAnimation.slotAngle(slot: 6, count: 8), -3 * Double.pi / 2, accuracy: 1e-9)

        // 边界安全
        XCTAssertEqual(RingLaunchAnimation.slotAngle(slot: 0, count: 0), 0)
        XCTAssertEqual(RingLaunchAnimation.slotAngle(slot: 12, count: 12), 0, accuracy: 1e-9)
    }

    // MARK: - 2. 最短圆弧跨越 12 点（11点与1点顺逆时针）

    func testShortestArcAcrossTwelveOClockClockwiseAndCounterClockwise() {
        // 12 槽时钟场景：
        // 11 点（slot 11, 角度 -11pi/6 等效于 +pi/6）
        // 1 点（slot 1, 角度 -pi/6）

        let angle11 = RingLaunchAnimation.slotAngle(slot: 11, count: 12)
        let angle1 = RingLaunchAnimation.slotAngle(slot: 1, count: 12)

        // 11 点 -> 1 点：顺时针跨越 12 点，短弧为 60° (pi/3) 顺时针（delta 为负）
        let delta11To1 = RingLaunchAnimation.shortestArcDelta(from: angle11, to: angle1)
        XCTAssertLessThan(delta11To1, 0, "11点至1点必须为顺时针移动（delta < 0）")
        XCTAssertEqual(delta11To1, -Double.pi / 3, accuracy: 1e-9, "11点至1点跨越12点最短距离为顺时针 60°")

        let target11To1 = RingLaunchAnimation.shortestArcTarget(from: angle11, targetSlot: 1, count: 12)
        XCTAssertEqual(target11To1, angle11 + delta11To1, accuracy: 1e-9)

        // 1 点 -> 11 点：逆时针跨越 12 点，短弧为 60° (pi/3) 逆时针（delta 为正）
        let delta1To11 = RingLaunchAnimation.shortestArcDelta(from: angle1, to: angle11)
        XCTAssertGreaterThan(delta1To11, 0, "1点至11点必须为逆时针移动（delta > 0）")
        XCTAssertEqual(delta1To11, Double.pi / 3, accuracy: 1e-9, "1点至11点跨越12点最短距离为逆时针 60°")

        let target1To11 = RingLaunchAnimation.shortestArcTarget(from: angle1, targetSlot: 11, count: 12)
        XCTAssertEqual(target1To11, angle1 + delta1To11, accuracy: 1e-9)

        // 8 槽场景：
        // 7 位（10:30）与 1 位（1:30）
        let angle7 = RingLaunchAnimation.slotAngle(slot: 7, count: 8)
        let angleSlot1 = RingLaunchAnimation.slotAngle(slot: 1, count: 8)

        let delta7To1 = RingLaunchAnimation.shortestArcDelta(from: angle7, to: angleSlot1)
        XCTAssertEqual(delta7To1, -Double.pi / 2, accuracy: 1e-9, "8槽下7位至1位顺时针 90°")

        let delta1To7 = RingLaunchAnimation.shortestArcDelta(from: angleSlot1, to: angle7)
        XCTAssertEqual(delta1To7, Double.pi / 2, accuracy: 1e-9, "8槽下1位至7位逆时针 90°")
    }

    // MARK: - 3. 180° 等长场景确定稳定方向

    func testExactOneEightyDegreesIsDeterministicAndStable() {
        // 6 槽场景：0 位（12点）与 3 位（6点）相对 180°
        let angle0 = RingLaunchAnimation.slotAngle(slot: 0, count: 6)
        let angle3 = RingLaunchAnimation.slotAngle(slot: 3, count: 6)

        // 0 -> 3: 距离恰好 180° (pi)，稳定解析为顺时针 (-pi)
        let delta0To3 = RingLaunchAnimation.shortestArcDelta(from: angle0, to: angle3)
        XCTAssertEqual(delta0To3, -Double.pi, accuracy: 1e-9, "0至3相对180度稳定解析为顺时针 -pi")

        // 3 -> 0: 距离恰好 180° (pi)，同样稳定解析为顺时针 (-pi)
        let delta3To0 = RingLaunchAnimation.shortestArcDelta(from: angle3, to: angle0)
        XCTAssertEqual(delta3To0, -Double.pi, accuracy: 1e-9, "3至0相对180度稳定解析为顺时针 -pi")

        // 6 槽场景：1 位 (-60°) 与 4 位 (-240° = +120°) 相对 180°
        let angle1 = RingLaunchAnimation.slotAngle(slot: 1, count: 6)
        let angle4 = RingLaunchAnimation.slotAngle(slot: 4, count: 6)

        let delta1To4 = RingLaunchAnimation.shortestArcDelta(from: angle1, to: angle4)
        XCTAssertEqual(delta1To4, -Double.pi, accuracy: 1e-9, "1至4相对180度稳定解析为顺时针 -pi")

        let delta4To1 = RingLaunchAnimation.shortestArcDelta(from: angle4, to: angle1)
        XCTAssertEqual(delta4To1, -Double.pi, accuracy: 1e-9, "4至1相对180度稳定解析为顺时针 -pi")

        // 任意垂直角度对
        XCTAssertEqual(RingLaunchAnimation.shortestArcDelta(from: Double.pi / 2, to: -Double.pi / 2), -Double.pi, accuracy: 1e-9)
        XCTAssertEqual(RingLaunchAnimation.shortestArcDelta(from: -Double.pi / 2, to: Double.pi / 2), -Double.pi, accuracy: 1e-9)
    }

    // MARK: - 4. 动画途中重定向与连续平滑过渡

    func testInFlightRetargetingFromIntermediateVisibleAngle() {
        // 模拟动画从 11 点 (+30° = pi/6) 走向 1 点 (-30° = -pi/6)
        // 途中刚过 12 点处（当前可见角度为 0.0）
        let visibleMidpoint = 0.0

        // 用户突然转向 10 点（slot 10, 对应 +60° = pi/3）
        let target10 = RingLaunchAnimation.shortestArcTarget(from: visibleMidpoint, targetSlot: 10, count: 12)
        let deltaTo10 = RingLaunchAnimation.shortestArcDelta(from: visibleMidpoint, to: RingLaunchAnimation.slotAngle(slot: 10, count: 12))
        XCTAssertEqual(deltaTo10, Double.pi / 3, accuracy: 1e-9, "从0度途中重定向至10点应立即逆时针旋转 60°")
        XCTAssertEqual(target10, visibleMidpoint + deltaTo10, accuracy: 1e-9)

        // 用户突然转向 2 点（slot 2, 对应 -60° = -pi/3）
        let target2 = RingLaunchAnimation.shortestArcTarget(from: visibleMidpoint, targetSlot: 2, count: 12)
        let deltaTo2 = RingLaunchAnimation.shortestArcDelta(from: visibleMidpoint, to: RingLaunchAnimation.slotAngle(slot: 2, count: 12))
        XCTAssertEqual(deltaTo2, -Double.pi / 3, accuracy: 1e-9, "从0度途中重定向至2点应继续顺时针旋转 60°")
        XCTAssertEqual(target2, visibleMidpoint + deltaTo2, accuracy: 1e-9)

        // 浮点任意中间角度 +0.15 rad 重定向至 4 点（-120° = -2pi/3）
        let intermediateAngle = 0.15
        let target4 = RingLaunchAnimation.shortestArcTarget(from: intermediateAngle, targetSlot: 4, count: 12)
        let deltaTo4 = RingLaunchAnimation.shortestArcDelta(from: intermediateAngle, to: RingLaunchAnimation.slotAngle(slot: 4, count: 12))
        XCTAssertLessThan(deltaTo4, 0, "向4点顺时针转动")
        XCTAssertEqual(target4, intermediateAngle + deltaTo4, accuracy: 1e-9)
    }

    // MARK: - 5. 减弱动态效果与高亮时长

    func testReduceMotionCollapsesHighlightDuration() {
        XCTAssertEqual(RingLaunchAnimation.highlightDuration(reduceMotion: true), 0, "减弱动态开启时动画时长必须为0")
        XCTAssertEqual(RingLaunchAnimation.highlightDuration(reduceMotion: false), 0.05, accuracy: 1e-6, "标准动态时长为 50ms")
    }

    // MARK: - 6. 输入命中与即时目标解耦

    func testPointerDecisionIsInstantaneousAndUncoupledFromVisualRotation() {
        // 构造 6 槽几何结构
        let geometry = RingLayout.geometry(slotCount: 6, side: 344)
        let filled = [true, true, true, false, true, true]

        // 验证位于 slot 1 图标中心时立即返回 slot 1 决策，无论当前视觉高亮在何处
        let slot1Frame = geometry.iconFrames[1]
        let slot1Center = CGPoint(x: slot1Frame.midX, y: slot1Frame.midY)
        let screenPoint = CGPoint(x: geometry.panelFrame.minX + slot1Center.x,
                                  y: geometry.panelFrame.minY + slot1Center.y)

        let decision = RingPointer.holdSelection(screenPoint, geometry: geometry, filled: filled)
        XCTAssertEqual(decision.slot, 1, "命中必须即时返回实际位置槽位")
        XCTAssertTrue(decision.launches, "已填充槽位决策应当可启动")

        // 空槽（slot 3）
        let slot3Frame = geometry.iconFrames[3]
        let slot3Center = CGPoint(x: slot3Frame.midX, y: slot3Frame.midY)
        let screenPoint3 = CGPoint(x: geometry.panelFrame.minX + slot3Center.x,
                                   y: geometry.panelFrame.minY + slot3Center.y)
        let decision3 = RingPointer.holdSelection(screenPoint3, geometry: geometry, filled: filled)
        XCTAssertEqual(decision3.slot, 3, "空槽依然即时返回实际位置槽位")
        XCTAssertFalse(decision3.launches, "空槽不触发启动")
    }
}
