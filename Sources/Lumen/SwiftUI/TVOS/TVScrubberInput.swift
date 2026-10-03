//
//  TVScrubberInput.swift
//  Lumen
//
import SwiftUI

#if os(tvOS)
import UIKit

@available(tvOS 16.0, *)
struct TVScrubberInput: UIViewRepresentable {
    let value: Binding<Float>
    let bounds: ClosedRange<Float>
    var isFocusable = true
    var isSeekEnabled = true
    let onEditingChanged: (Bool) -> Void
    var onCancel: (() -> Void)?
    var onDownArrow: (() -> Void)?
    var onFocusChanged: ((Bool) -> Void)?

    func makeUIView(context _: Context) -> TVScrubberControl {
        let control = TVScrubberControl(value: value, bounds: bounds)
        update(control)
        return control
    }

    func updateUIView(_ control: TVScrubberControl, context _: Context) {
        control.value = value
        control.boundsRange = bounds
        update(control)
        control.synchronizeExternalValue()
    }

    private func update(_ control: TVScrubberControl) {
        control.onEditingChanged = onEditingChanged
        control.onCancel = onCancel
        control.onDownArrow = onDownArrow
        control.onFocusChanged = onFocusChanged
        control.isUserInteractionEnabled = isSeekEnabled
        control.canFocus = isFocusable && isSeekEnabled
    }
}

@available(tvOS 16.0, *)
final class TVScrubberControl: UIControl, UIGestureRecognizerDelegate {
    var value: Binding<Float>
    var boundsRange: ClosedRange<Float>
    var onEditingChanged: ((Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onDownArrow: (() -> Void)?
    var onFocusChanged: ((Bool) -> Void)?
    var canFocus = true {
        didSet {
            guard canFocus != oldValue else { return }
            setNeedsFocusUpdate()
        }
    }

    private var workingValue: TimeInterval
    private var isEditingSession = false
    private var lastPanX: CGFloat = 0
    private var arrowDirection: TimeInterval = 0
    private var arrowStartedAt: CFTimeInterval = 0
    private var repeatDelayTimer: Timer?
    private var repeatTimer: Timer?
    private var autoCommitTimer: Timer?

    override var canBecomeFocused: Bool {
        canFocus
    }

    init(value: Binding<Float>, bounds: ClosedRange<Float>) {
        self.value = value
        boundsRange = bounds
        workingValue = TimeInterval(value.wrappedValue)
        super.init(frame: .zero)

        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = [.adjustable]
        accessibilityLabel = "Posição de reprodução"

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)
        updateAccessibilityValue()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            invalidateTimers()
        }
    }

    func synchronizeExternalValue() {
        guard !isEditingSession else { return }
        workingValue = TimeInterval(value.wrappedValue)
        updateAccessibilityValue()
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let press = presses.first else {
            super.pressesBegan(presses, with: event)
            return
        }

        switch press.type {
        case .leftArrow, .rightArrow:
            beginSessionIfNeeded()
            cancelAutoCommit()
            arrowDirection = press.type == .leftArrow ? -1 : 1
            arrowStartedAt = CACurrentMediaTime()
            adjust(by: arrowDirection * TVScrubberTuning.arrowStep)
            scheduleArrowRepeat()
        case .select:
            isEditingSession ? commitSession() : beginSessionIfNeeded()
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
            if !isEditingSession, let onDownArrow {
                onDownArrow()
            } else if !isEditingSession {
                super.pressesBegan(presses, with: event)
            }
        default:
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .leftArrow || $0.type == .rightArrow }) {
            stopArrowRepeat()
            scheduleAutoCommit()
            return
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .leftArrow || $0.type == .rightArrow }) {
            stopArrowRepeat()
            scheduleAutoCommit()
            return
        }
        super.pressesCancelled(presses, with: event)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        onFocusChanged?(focused)
        if !focused, isEditingSession {
            commitSession()
        }
    }

    override func accessibilityIncrement() {
        beginSessionIfNeeded()
        adjust(by: TVScrubberTuning.arrowStep)
        commitSession()
    }

    override func accessibilityDecrement() {
        beginSessionIfNeeded()
        adjust(by: -TVScrubberTuning.arrowStep)
        commitSession()
    }

    @objc
    private func handlePan(_ sender: UIPanGestureRecognizer) {
        let translation = sender.translation(in: self)

        switch sender.state {
        case .began:
            beginSessionIfNeeded()
            cancelAutoCommit()
            lastPanX = translation.x
        case .changed:
            beginSessionIfNeeded()
            cancelAutoCommit()
            let deltaX = translation.x - lastPanX
            lastPanX = translation.x
            let seconds = TVScrubberTuning.panDelta(
                points: deltaX,
                trackWidth: max(1, bounds.width),
                duration: TimeInterval(boundsRange.upperBound - boundsRange.lowerBound),
                velocity: sender.velocity(in: self).x
            )
            adjust(by: seconds)
        case .ended:
            scheduleAutoCommit()
        case .cancelled, .failed:
            cancelSession()
        default:
            break
        }
    }

    private func beginSessionIfNeeded() {
        guard !isEditingSession else { return }
        isEditingSession = true
        workingValue = TimeInterval(value.wrappedValue)
        onEditingChanged?(true)
    }

    private func adjust(by delta: TimeInterval) {
        let lowerBound = TimeInterval(boundsRange.lowerBound)
        let upperBound = TimeInterval(boundsRange.upperBound)
        workingValue = min(upperBound, max(lowerBound, workingValue + delta))
        value.wrappedValue = Float(workingValue)
        updateAccessibilityValue()
        sendActions(for: .valueChanged)
    }

    private func commitSession() {
        guard isEditingSession else { return }
        isEditingSession = false
        stopArrowRepeat()
        cancelAutoCommit()
        onEditingChanged?(false)
    }

    private func cancelSession() {
        guard isEditingSession else { return }
        isEditingSession = false
        stopArrowRepeat()
        cancelAutoCommit()
        if let onCancel {
            onCancel()
        } else {
            onEditingChanged?(false)
        }
    }

    private func scheduleArrowRepeat() {
        repeatDelayTimer?.invalidate()
        let timer = Timer(timeInterval: TVScrubberTuning.repeatDelay,
                          target: self,
                          selector: #selector(beginArrowRepeat),
                          userInfo: nil,
                          repeats: false)
        repeatDelayTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc
    private func beginArrowRepeat() {
        repeatDelayTimer = nil
        let timer = Timer(timeInterval: TVScrubberTuning.repeatInterval,
                          target: self,
                          selector: #selector(repeatArrowStep),
                          userInfo: nil,
                          repeats: true)
        repeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        repeatArrowStep()
    }

    @objc
    private func repeatArrowStep() {
        guard arrowDirection != 0 else { return }
        let heldFor = CACurrentMediaTime() - arrowStartedAt
        adjust(by: arrowDirection * TVScrubberTuning.repeatedArrowStep(heldFor: heldFor))
    }

    private func stopArrowRepeat() {
        repeatDelayTimer?.invalidate()
        repeatDelayTimer = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
        arrowDirection = 0
    }

    private func scheduleAutoCommit() {
        cancelAutoCommit()
        let timer = Timer(timeInterval: TVScrubberTuning.autoCommitDelay,
                          target: self,
                          selector: #selector(autoCommit),
                          userInfo: nil,
                          repeats: false)
        autoCommitTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc
    private func autoCommit() {
        autoCommitTimer = nil
        commitSession()
    }

    private func cancelAutoCommit() {
        autoCommitTimer?.invalidate()
        autoCommitTimer = nil
    }

    private func invalidateTimers() {
        stopArrowRepeat()
        cancelAutoCommit()
    }

    private func updateAccessibilityValue() {
        let elapsed = Self.formattedTime(workingValue)
        let total = Self.formattedTime(TimeInterval(boundsRange.upperBound))
        accessibilityValue = "\(elapsed) de \(total)"
    }

    private static func formattedTime(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time.rounded()))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }
}
#endif
