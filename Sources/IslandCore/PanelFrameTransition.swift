import Foundation
import CoreGraphics

/// A single interpolation drives both window placement and content layout.
public struct PanelFrameTransition: Sendable {
    public let from: CGRect
    public let to: CGRect
    public init(from: CGRect, to: CGRect) { self.from = from; self.to = to }

    public func frame(at progress: Double) -> CGRect {
        let t = CGFloat(min(1, max(0, progress)))
        let eased = t * t * (3 - 2 * t)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * eased }
        let width = mix(from.width, to.width)
        let height = mix(from.height, to.height)
        return CGRect(x: mix(from.midX, to.midX) - width / 2,
                      y: mix(from.maxY, to.maxY) - height, width: width, height: height)
    }
}
