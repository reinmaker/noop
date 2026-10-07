import SwiftUI
import Charts
import StrandDesign

extension View {
    /// WHOOP-style scrubbing on a chart: press and hold, then drag, to pick the x value under the finger;
    /// lifting the finger clears it. A quick swipe still scrolls the page, and a plain tap still reaches a
    /// surrounding button, because the hold has to land before the drag starts.
    func whoopScrub<X: Plottable>(_ selection: Binding<X?>) -> some View {
        chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        LongPressGesture(minimumDuration: 0.2)
                            .sequenced(before: DragGesture(minimumDistance: 0))
                            .onChanged { value in
                                guard case .second(true, let drag?) = value else { return }
                                let plot = proxy.plotRectCompat(in: geo)
                                let x = min(max(drag.location.x, plot.minX), plot.maxX) - plot.minX
                                selection.wrappedValue = proxy.value(atX: x, as: X.self)
                            }
                            .onEnded { _ in selection.wrappedValue = nil }
                    )
            }
        }
    }
}
