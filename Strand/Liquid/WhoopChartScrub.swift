import SwiftUI
import Charts
import StrandDesign
#if os(iOS)
import UIKit
#endif

extension View {
    /// WHOOP-style scrubbing on a chart: press and hold, then drag, to pick the x value under the finger;
    /// lifting the finger clears it. On iOS the hold is a UIKit long press, which yields to the page's
    /// scroll when the finger moves first, so swiping across a graph still scrolls; a SwiftUI gesture
    /// here took the touch and blocked the scroll.
    func whoopScrub<X: Plottable>(_ selection: Binding<X?>) -> some View {
        chartOverlay { proxy in
            GeometryReader { geo in
                #if os(iOS)
                WhoopLongPressTracker { point in
                    guard let point else {
                        selection.wrappedValue = nil
                        return
                    }
                    let plot = proxy.plotRectCompat(in: geo)
                    let x = min(max(point.x, plot.minX), plot.maxX) - plot.minX
                    selection.wrappedValue = proxy.value(atX: x, as: X.self)
                }
                #else
                Color.clear
                #endif
            }
        }
    }
}

#if os(iOS)
/// A transparent view with a long-press recogniser that reports where the finger is while held (nil on
/// release). UIKit lets the scroll view's pan win when the finger moves before the press is held.
private struct WhoopLongPressTracker: UIViewRepresentable {
    let onChange: (CGPoint?) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let press = UILongPressGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coordinator.handle(_:)))
        press.minimumPressDuration = 0.25
        press.cancelsTouchesInView = false
        view.addGestureRecognizer(press)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onChange = onChange
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    final class Coordinator: NSObject {
        var onChange: (CGPoint?) -> Void

        init(onChange: @escaping (CGPoint?) -> Void) { self.onChange = onChange }

        @objc func handle(_ press: UILongPressGestureRecognizer) {
            switch press.state {
            case .began, .changed: onChange(press.location(in: press.view))
            default: onChange(nil)
            }
        }
    }
}
#endif
