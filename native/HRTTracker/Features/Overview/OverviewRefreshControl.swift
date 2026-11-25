import SwiftUI
import UIKit

enum OverviewRefreshPhase {
    case pulling, refreshing, finishing

    static let fadeOutDuration = 0.22
}

struct OverviewRefreshControl: UIViewRepresentable {
    let phase: OverviewRefreshPhase

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> Anchor {
        let view = Anchor()
        view.isUserInteractionEnabled = false
        view.attach = { [weak coordinator = context.coordinator] view in coordinator?.attachAfterUpdate(from: view) }
        return view
    }

    func updateUIView(_ view: Anchor, context: Context) {
        context.coordinator.setPhase(phase)
        context.coordinator.attachAfterUpdate(from: view)
    }

    static func dismantleUIView(_ view: Anchor, coordinator: Coordinator) {
        view.attach = nil
        coordinator.detach()
    }

    final class Anchor: UIView {
        var attach: ((Anchor) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { attach?(self) }
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        private let indicator = Coordinator.configuration(isRefreshing: false).makeContentView()
        private var phase: OverviewRefreshPhase = .pulling
        private var waitsForNewPull = false
        private weak var scrollView: UIScrollView?
        private weak var control: UIRefreshControl?
        private var pullObservation: NSKeyValueObservation?
        private var originalTint: UIColor?

        override init() {
            super.init()
            indicator.backgroundColor = .clear
            indicator.isUserInteractionEnabled = false
            indicator.translatesAutoresizingMaskIntoConstraints = false
            setAppearance(progress: 0)
        }

        func setPhase(_ phase: OverviewRefreshPhase) {
            guard phase != self.phase else { return }
            self.phase = phase
            switch phase {
            case .pulling:
                indicator.isHidden = waitsForNewPull
                indicator.configuration = Self.configuration(isRefreshing: false)
                updatePull()
            case .refreshing:
                waitsForNewPull = true
                indicator.isHidden = false
                indicator.configuration = Self.configuration(isRefreshing: true)
                UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
                    self.setAppearance(progress: 1)
                }
            case .finishing:
                // Fade before the native refresh control closes its overscroll area.
                UIView.animate(withDuration: OverviewRefreshPhase.fadeOutDuration, delay: 0,
                               options: [.beginFromCurrentState, .curveEaseIn]) {
                    self.setAppearance(progress: 0)
                }
            }
        }

        func attachAfterUpdate(from view: Anchor) {
            // SwiftUI can install its refresh control after updating the scroll content.
            DispatchQueue.main.async { [weak self, weak view] in
                guard let view, view.window != nil, view.attach != nil else { return }
                self?.attach(from: view)
            }
        }

        private func attach(from view: UIView) {
            var ancestor = view.superview
            while let current = ancestor, !(current is UIScrollView) {
                ancestor = current.superview
            }
            guard let scrollView = ancestor as? UIScrollView else { return }
            attach(to: scrollView)
        }

        func attach(to scrollView: UIScrollView) {
            guard let control = scrollView.refreshControl else { return }
            if control !== self.control {
                detach()
                self.scrollView = scrollView
                self.control = control
                originalTint = control.tintColor
                control.addSubview(indicator)
                NSLayoutConstraint.activate([
                    indicator.centerXAnchor.constraint(equalTo: control.centerXAnchor),
                    indicator.centerYAnchor.constraint(equalTo: control.centerYAnchor)
                ])
                pullObservation = scrollView.observe(\.contentOffset) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.updatePull() }
                }
                scrollView.panGestureRecognizer.addTarget(self, action: #selector(panChanged(_:)))
                updatePull()
            }
            control.tintColor = .clear
        }

        func detach() {
            pullObservation?.invalidate()
            pullObservation = nil
            scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(panChanged(_:)))
            indicator.removeFromSuperview()
            control?.tintColor = originalTint
            control = nil
            scrollView = nil
            originalTint = nil
        }

        private func updatePull() {
            guard phase == .pulling, !waitsForNewPull, let scrollView else { return }
            let distance = max(0, -scrollView.contentOffset.y - scrollView.adjustedContentInset.top)
            let progress = min(1, max(0, (distance - 8) / 52))
            setAppearance(progress: progress)
        }

        @objc private func panChanged(_ pan: UIPanGestureRecognizer) {
            // UIKit can still move the content offset as the refresh inset closes.
            guard pan.state == .began, phase == .pulling, waitsForNewPull else { return }
            waitsForNewPull = false
            updatePull()
            indicator.isHidden = false
        }

        private func setAppearance(progress: CGFloat) {
            indicator.alpha = progress * progress * (3 - 2 * progress)
            let remaining = 1 - progress
            indicator.transform = UIAccessibility.isReduceMotionEnabled
                ? .identity
                : CGAffineTransform(translationX: 0, y: -6 * remaining)
                    .scaledBy(x: 1 - 0.14 * remaining, y: 1 - 0.14 * remaining)
        }

        private static func configuration(isRefreshing: Bool) -> some UIContentConfiguration {
            UIHostingConfiguration {
                OverviewRefreshIndicator(isRefreshing: isRefreshing)
            }
            .margins(.all, 0)
        }
    }
}

private struct OverviewRefreshIndicator: View {
    let isRefreshing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !isRefreshing)) { context in
            let cat = OverviewPixelCats(hasDoses: false, hasLabs: true, width: 48)
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.15) / 1.15
            cat
                .background {
                    if isRefreshing {
                        Ellipse()
                            .fill(TrackerTheme.accent.opacity(0.38))
                            .frame(width: 40, height: 11)
                            .blur(radius: 7)
                            .offset(y: 7)
                    }
                }
                .overlay {
                    if isRefreshing {
                        LinearGradient(colors: [.clear, .white.opacity(0.9), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: 16)
                            .rotationEffect(.degrees(20))
                            .offset(x: reduceMotion ? 0 : (phase - 0.5) * 72)
                            .mask { cat }
                    }
                }
        }
        .frame(width: 48, height: 28)
    }
}
