import Foundation

public enum CanvasDragGeometry {
    /// Screen-space delta and a fixed drag-start position avoid feedback from
    /// the moving card or a resizing canvas. Zoom is applied exactly once.
    public static func position(origin: CanvasPoint, dx: Double, dy: Double, zoom: Double) -> CanvasPoint {
        guard origin.x.isFinite, origin.y.isFinite, dx.isFinite, dy.isFinite,
              zoom.isFinite, zoom >= 0.01 else { return origin }
        return CanvasPoint(x: min(100_000, max(150, origin.x + dx / zoom)),
                           y: min(100_000, max(100, origin.y + dy / zoom)))
    }
}
