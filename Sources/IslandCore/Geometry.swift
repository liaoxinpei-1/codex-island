import Foundation
import CoreGraphics

public struct ScreenGeometry {
    public var frame: CGRect
    public var visibleFrame: CGRect
    public var safeTop: CGFloat
    public var notchWidth: CGFloat
    public var notchCenterX: CGFloat

    public init(frame: CGRect, visibleFrame: CGRect, safeTop: CGFloat,
                notchWidth: CGFloat = 0, notchCenterX: CGFloat? = nil) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeTop = safeTop
        self.notchWidth = notchWidth
        self.notchCenterX = notchCenterX ?? frame.midX
    }
}

public struct IslandLayout: Equatable {
    public let frame: CGRect
    public let headerHeight: CGFloat
    public let notchReservation: CGFloat
    public let attached: Bool
    /// All expanded controls must be confined to this rectangle (screen coordinates).
    public let bodyFrame: CGRect

    public static func calculate(screen: ScreenGeometry, expanded: Bool, floating: Bool,
                                 bodyHeight: CGFloat = 300) -> IslandLayout {
        let attached = screen.safeTop > 0 && screen.notchWidth > 0 && !floating
        let reserve = attached ? screen.notchWidth + 16 : 0
        let menuBarHeight = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        // Screen values are logical points and already reflect the current display scaling.
        // Keep the same header in both states so expanding never moves the notch boundary.
        let header = attached ? max(screen.safeTop, menuBarHeight) : max(32, min(38, menuBarHeight))
        let idealWidth: CGFloat = attached ? max(expanded ? 460 : 0, reserve + 112) : (expanded ? 440 : 268)
        let width = min(idealWidth, screen.visibleFrame.width - 24)
        let top = attached ? screen.frame.maxY : screen.visibleFrame.maxY - 8
        let usableBody = max(0, min(bodyHeight, top - header - screen.visibleFrame.minY - 16))
        let height = header + (expanded ? usableBody : 0)
        let center = attached ? screen.notchCenterX : screen.visibleFrame.midX
        let x = max(screen.visibleFrame.minX + 12,
                    min(center - width / 2, screen.visibleFrame.maxX - width - 12))
        let frame = CGRect(x: x, y: top - height, width: width, height: height)
        return IslandLayout(frame: frame, headerHeight: header,
                            notchReservation: reserve, attached: attached,
                            bodyFrame: CGRect(x: x, y: frame.minY, width: width,
                                              height: expanded ? usableBody : 0))
    }
}
