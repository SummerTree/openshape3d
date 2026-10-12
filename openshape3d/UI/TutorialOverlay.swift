//
//  TutorialOverlay.swift
//  openshape3d
//
//  Settings ▸ Tutorial Mode: for recording tutorials, every touch or click
//  shows a fading ring where it landed, and every keyboard shortcut shows its
//  keys. The touch observer sits on the window and never claims a touch, so
//  it can't change what any gesture does.
//

import SwiftUI
import UIKit

struct TutorialOverlay: View {
    @Bindable var viewModel: EditorViewModel
    @State private var rings: [Ring] = []

    struct Ring: Identifiable {
        let id = UUID()
        let point: CGPoint
    }

    var body: some View {
        let settings = AppSettings.shared
        ZStack {
            if settings.showTouches {
                TouchObserver { point in
                    let ring = Ring(point: point)
                    rings.append(ring)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        rings.removeAll { $0.id == ring.id }
                    }
                }
                .allowsHitTesting(false)
                ForEach(rings) { ring in
                    RingView().position(ring.point).allowsHitTesting(false)
                }
            }
            if settings.showKeyPresses, let echo = viewModel.keyEcho {
                Text(echo.text)
                    .font(.title3.weight(.semibold).monospaced())
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(echo.text)
                    .accessibilityIdentifier("TutorialKeyEcho")
                    // Above the bottom bars (info strip + tool bar).
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 230)
                    .id(echo.id)
                    .transition(.opacity)
                    .task(id: echo.id) {
                        try? await Task.sleep(for: .seconds(2))
                        viewModel.clearKeyEcho(echo.id)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        // Keep the echo its own element (the a11y container-collapse gotcha).
        .accessibilityElement(children: .contain)
        .animation(.easeOut(duration: 0.2), value: viewModel.keyEcho?.id)
    }

    private struct RingView: View {
        @State private var faded = false
        var body: some View {
            Circle()
                .stroke(Color.blue.opacity(0.8), lineWidth: 3)
                .background(Circle().fill(Color.blue.opacity(0.18)))
                .frame(width: 44, height: 44)
                .scaleEffect(faded ? 1.5 : 1)
                .opacity(faded ? 0 : 1)
                .onAppear { withAnimation(.easeOut(duration: 0.55)) { faded = true } }
                .accessibilityHidden(true)
        }
    }
}

/// Reports where each touch begins, in window coordinates, without ever
/// recognizing — so it never cancels, delays or steals a touch.
private struct TouchObserver: UIViewRepresentable {
    let onTouch: (CGPoint) -> Void

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.onTouch = onTouch
        return view
    }

    func updateUIView(_ view: HostView, context: Context) {
        view.onTouch = onTouch
    }

    final class HostView: UIView {
        var onTouch: ((CGPoint) -> Void)?
        private var recognizer: Observer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
            guard let window else { return }
            let observer = Observer()
            observer.onTouch = { [weak self] point in self?.onTouch?(point) }
            window.addGestureRecognizer(observer)
            recognizer = observer
        }

        override func removeFromSuperview() {
            if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
            super.removeFromSuperview()
        }
    }

    final class Observer: UIGestureRecognizer {
        var onTouch: ((CGPoint) -> Void)?

        override init(target: Any? = nil, action: Selector? = nil) {
            super.init(target: target, action: action)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            for touch in touches { onTouch?(touch.location(in: view)) }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            state = .failed
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            state = .failed
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    }
}
