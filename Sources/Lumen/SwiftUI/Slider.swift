//
//  Slider.swift
//  Lumen
//
//  Created by kintan on 2023/5/4.
//

import SwiftUI

#if os(tvOS)
import Combine

@available(tvOS 15.0, *)
public struct Slider: View {
    private let value: Binding<Float>
    private let bounds: ClosedRange<Float>
    private let onEditingChanged: (Bool) -> Void
    @FocusState
    private var isFocused: Bool
    public init(value: Binding<Float>, in bounds: ClosedRange<Float> = 0 ... 1, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.value = value
        self.bounds = bounds
        self.onEditingChanged = onEditingChanged
    }

    public var body: some View {
        TVOSSlide(value: value, bounds: bounds, isFocused: _isFocused, onEditingChanged: onEditingChanged)
            .focused($isFocused)
    }
}

@available(tvOS 15.0, *)
public struct TVOSSlide: UIViewRepresentable {
    fileprivate let value: Binding<Float>
    fileprivate let bounds: ClosedRange<Float>
    @FocusState
    public var isFocused: Bool
    public let onEditingChanged: (Bool) -> Void
    public typealias UIViewType = TVSlide
    public func makeUIView(context _: Context) -> UIViewType {
        TVSlide(value: value, bounds: bounds, onEditingChanged: onEditingChanged)
    }

    public func updateUIView(_ view: UIViewType, context _: Context) {
        // 要加这个才会触发进度条更新
        let process = (value.wrappedValue - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound)
        if process != view.processView.progress {
            view.processView.progress = process
        }
    }
}

public class TVSlide: UIControl {
    let processView = UIProgressView()
    private var beganValue = Float(0.0)
    private var lastPanX = CGFloat(0)
    private var isEditingSession = false
    var onEditingChanged: (Bool) -> Void
    var onDownArrow: (() -> Void)?
    var onCancel: (() -> Void)?
    var canFocus = true {
        didSet {
            if canFocus != oldValue {
                setNeedsFocusUpdate()
            }
        }
    }

    var value: Binding<Float>
    var ranges: ClosedRange<Float>
    private var moveDirection: UISwipeGestureRecognizer.Direction?
    private var pressTime = CACurrentMediaTime()
    private var delayItem: DispatchWorkItem?

    override public var canBecomeFocused: Bool {
        canFocus
    }

    private lazy var timer: Timer = .scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
        guard let self, let moveDirection = self.moveDirection else {
            return
        }
        let rate = min(10, Int((CACurrentMediaTime() - self.pressTime) / 2) + 1)
        let wrappedValue = self.value.wrappedValue + Float((moveDirection == .right ? 10 : -10) * rate)
        if wrappedValue >= self.ranges.lowerBound, wrappedValue <= self.ranges.upperBound {
            self.value.wrappedValue = wrappedValue
        }
        self.onEditingChanged(true)
    }

    public init(value: Binding<Float>, bounds: ClosedRange<Float>, onEditingChanged: @escaping (Bool) -> Void) {
        self.value = value
        ranges = bounds
        self.onEditingChanged = onEditingChanged
        super.init(frame: .zero)
        processView.translatesAutoresizingMaskIntoConstraints = false
        processView.tintColor = .white
        addSubview(processView)
        NSLayoutConstraint.activate([
            processView.topAnchor.constraint(equalTo: topAnchor),
            processView.leadingAnchor.constraint(equalTo: leadingAnchor),
            processView.trailingAnchor.constraint(equalTo: trailingAnchor),
            processView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let panGestureRecognizer = UIPanGestureRecognizer(target: self, action: #selector(actionPanGesture(sender:)))
        addGestureRecognizer(panGestureRecognizer)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override open func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let presse = presses.first else {
            return
        }
        delayItem?.cancel()
        delayItem = nil
        switch presse.type {
        case .leftArrow, .rightArrow:
            beginSessionIfNeeded()
            moveDirection = presse.type == .leftArrow ? .left : .right
            pressTime = CACurrentMediaTime()
            timer.fireDate = Date.distantPast
        case .select:
            if isEditingSession {
                commitSession()
            } else {
                beginSessionIfNeeded()
            }
        case .playPause:
            if isEditingSession {
                commitSession()
            } else {
                super.pressesBegan(presses, with: event)
            }
        case .menu:
            if isEditingSession {
                cancelSession()
            } else {
                super.pressesBegan(presses, with: event)
            }
        case .downArrow:
            if isEditingSession {
                break
            } else if let onDownArrow {
                onDownArrow()
            } else {
                super.pressesBegan(presses, with: event)
            }
        default: super.pressesBegan(presses, with: event)
        }
    }

    override open func pressesEnded(_ presses: Set<UIPress>, with _: UIPressesEvent?) {
        timer.fireDate = Date.distantFuture
        guard let presse = presses.first, presse.type == .leftArrow || presse.type == .rightArrow else {
            return
        }
        scheduleAutoCommit()
    }

    private func beginSessionIfNeeded() {
        guard !isEditingSession else {
            return
        }
        isEditingSession = true
        onEditingChanged(true)
    }

    private func commitSession() {
        guard isEditingSession else {
            return
        }
        isEditingSession = false
        timer.fireDate = Date.distantFuture
        moveDirection = nil
        delayItem?.cancel()
        delayItem = nil
        onEditingChanged(false)
    }

    private func cancelSession() {
        guard isEditingSession else {
            return
        }
        isEditingSession = false
        timer.fireDate = Date.distantFuture
        moveDirection = nil
        delayItem?.cancel()
        delayItem = nil
        if let onCancel {
            onCancel()
        } else {
            onEditingChanged(false)
        }
    }

    private func scheduleAutoCommit() {
        delayItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.commitSession()
        }
        delayItem = item
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 1.5,
                                      execute: item)
    }

    @objc private func actionPanGesture(sender: UIPanGestureRecognizer) {
        let translation = sender.translation(in: self)
        if abs(translation.y) > abs(translation.x) {
            return
        }
        switch sender.state {
        case .began, .possible:
            delayItem?.cancel()
            delayItem = nil
            beganValue = value.wrappedValue
            lastPanX = translation.x
            beginSessionIfNeeded()
        case .changed:
            let deltaX = translation.x - lastPanX
            lastPanX = translation.x
            let range = ranges.upperBound - ranges.lowerBound
            let speed = Float(min(2.5, max(0.15, abs(sender.velocity(in: self).x) / 1200)))
            let width = Float(max(1, frame.size.width))
            let wrappedValue = value.wrappedValue + Float(deltaX) / width * range * 0.35 * speed
            value.wrappedValue = min(ranges.upperBound, max(ranges.lowerBound, wrappedValue))
            onEditingChanged(true)
        case .ended:
            scheduleAutoCommit()
        case .cancelled, .failed:
            value.wrappedValue = beganValue
            cancelSession()
        @unknown default:
            break
        }
    }
}
#endif
