//
//  KSVideoPlayer.swift
//  Lumen
//
//  Created by kintan on 2023/2/11.
//

import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#else
import AppKit

public typealias UIViewRepresentable = NSViewRepresentable
#endif

public struct KSVideoPlayer {
    public private(set) var coordinator: Coordinator
    public let url: URL
    public let options: KSOptions
    public init(coordinator: Coordinator, url: URL, options: KSOptions) {
        self.coordinator = coordinator
        self.url = url
        self.options = options
    }
}

extension KSVideoPlayer: UIViewRepresentable {
    public func makeCoordinator() -> Coordinator {
        coordinator
    }

    #if canImport(UIKit)
    public typealias UIViewType = UIView
    public func makeUIView(context: Context) -> UIViewType {
        context.coordinator.makeView(url: url, options: options)
    }

    public func updateUIView(_ view: UIViewType, context: Context) {
        updateView(view, context: context)
    }

    // iOS tvOS真机先调用onDisappear在调用dismantleUIView，但是模拟器就反过来了。
    public static func dismantleUIView(_: UIViewType, coordinator: Coordinator) {
        coordinator.resetPlayerIfViewDetached()
    }
    #else
    public typealias NSViewType = UIView
    public func makeNSView(context: Context) -> NSViewType {
        context.coordinator.makeView(url: url, options: options)
    }

    public func updateNSView(_ view: NSViewType, context: Context) {
        updateView(view, context: context)
    }

    // macOS先调用onDisappear在调用dismantleNSView
    public static func dismantleNSView(_ view: NSViewType, coordinator: Coordinator) {
        coordinator.resetPlayerIfViewDetached()
        view.window?.aspectRatio = CGSize(width: 16, height: 9)
    }
    #endif

    @MainActor
    private func updateView(_: UIView, context: Context) {
        guard let playerLayer = context.coordinator.playerLayer else {
            _ = context.coordinator.makeView(url: url, options: options)
            return
        }
        guard (playerLayer.pendingSourceSwitchURL ?? playerLayer.url) != url else { return }
        if options.isSourceSwitchEnabled {
            context.coordinator.switchSource(url: url, options: options)
        } else {
            _ = context.coordinator.makeView(url: url, options: options)
        }
    }

    @MainActor
    public final class Coordinator: ObservableObject {
        @Published
        public private(set) var state: KSPlayerState = .initialized

        @Published
        public private(set) var isSeeking = false

        @Published
        public var isMuted: Bool = false {
            didSet {
                playerLayer?.player.isMuted = isMuted
            }
        }

        @Published
        public var playbackVolume: Float = 1.0 {
            didSet {
                playerLayer?.player.playbackVolume = playbackVolume
            }
        }

        @Published
        public var isScaleAspectFill = false {
            didSet {
                playerLayer?.player.contentMode = isScaleAspectFill ? .scaleAspectFill : .scaleAspectFit
            }
        }

        @Published
        public var playbackRate: Float = 1.0 {
            didSet {
                playerLayer?.player.playbackRate = playbackRate
            }
        }

        @Published
        @MainActor
        public var isMaskShow = true {
            didSet {
                if isMaskShow != oldValue {
                    mask(show: isMaskShow)
                }
            }
        }

        public var subtitleModel = SubtitleModel()
        public var timemodel = ControllerTimeModel()
        #if os(tvOS)
        let scrubThumbnails = ScrubThumbnailProvider()
        #endif
        // 在SplitView模式下，第二次进入会先调用makeUIView。然后在调用之前的dismantleUIView.所以如果进入的是同一个View的话，就会导致playerLayer被清空了。最准确的方式是在onDisappear清空playerLayer
        public var playerLayer: KSPlayerLayer? {
            didSet {
                oldValue?.delegate = nil
                oldValue?.pause()
            }
        }

        private var lastPlayURL: URL?
        private var lastPlayTime = TimeInterval(0)
        private var delayHide: DispatchWorkItem?
        private var isMaskPinned = false
        public var onPlay: ((TimeInterval, TimeInterval) -> Void)?
        public var onFinish: ((KSPlayerLayer, Error?) -> Void)?
        public var onStateChanged: ((KSPlayerLayer, KSPlayerState) -> Void)?
        public var onBufferChanged: ((Int, TimeInterval) -> Void)?
        #if canImport(UIKit)
        fileprivate var onSwipe: ((UISwipeGestureRecognizer.Direction) -> Void)?
        private weak var swipeGestureView: UIView?
        @objc fileprivate func swipeGestureAction(_ recognizer: UISwipeGestureRecognizer) {
            onSwipe?(recognizer.direction)
        }

        private func addSwipeGestures(to view: UIView) {
            guard swipeGestureView !== view else {
                return
            }
            swipeGestureView = view
            for direction in [UISwipeGestureRecognizer.Direction.down, .left, .right, .up] {
                let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swipeGestureAction(_:)))
                swipe.direction = direction
                view.addGestureRecognizer(swipe)
            }
        }
        #endif

        public init() {}

        public func makeView(url: URL, options: KSOptions) -> UIView {
            defer {
                DispatchQueue.main.async { [weak self] in
                    self?.subtitleModel.url = url
                }
            }
            let view: UIView
            if let playerLayer {
                if playerLayer.url == url {
                    view = playerLayer.player.view ?? UIView()
                } else {
                    playerLayer.delegate = nil
                    playerLayer.set(url: url, options: options)
                    playerLayer.delegate = self
                    view = playerLayer.player.view ?? UIView()
                }
            } else {
                if lastPlayURL == url, lastPlayTime > 0 {
                    options.startPlayTime = lastPlayTime
                }
                let playerLayer = KSPlayerLayer(url: url, options: options, delegate: self)
                self.playerLayer = playerLayer
                view = playerLayer.player.view ?? UIView()
            }
            #if canImport(UIKit)
            addSwipeGestures(to: view)
            #endif
            return view
        }

        public func switchSource(url: URL, options: KSOptions) {
            guard let playerLayer else {
                _ = makeView(url: url, options: options)
                return
            }
            playerLayer.switchSource(url: url, options: options) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.playerLayer?.url == url else { return }
                    #if os(tvOS)
                    self.scrubThumbnails.shutdown()
                    #endif
                    self.subtitleModel.url = url
                }
            }
        }

        public func resetPlayerIfViewDetached() {
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.playerLayer?.player.view?.window == nil else { return }
                self.resetPlayer()
            }
        }

        public func resetPlayer() {
            onStateChanged = nil
            onPlay = nil
            onFinish = nil
            onBufferChanged = nil
            #if canImport(UIKit)
            onSwipe = nil
            swipeGestureView = nil
            #endif
            playerLayer = nil
            delayHide?.cancel()
            delayHide = nil
            isMaskPinned = false
            state = .initialized
            isSeeking = false
            #if os(tvOS)
            scrubThumbnails.shutdown()
            #endif
            subtitleModel.selectedSubtitleInfo?.isEnabled = false
        }

        public func skip(interval: Int) {
            if let playerLayer {
                seek(time: playerLayer.player.currentPlaybackTime + TimeInterval(interval))
            }
        }

        public func seek(time: TimeInterval, autoPlay: Bool? = nil) {
            guard let playerLayer else { return }
            isSeeking = true
            playerLayer.seek(time: time, autoPlay: autoPlay ?? playerLayer.options.isSeekedAutoPlay) { [weak self] _ in
                Task { @MainActor in
                    self?.isSeeking = false
                }
            }
        }

        @MainActor
        public func mask(show: Bool, autoHide: Bool = true) {
            if show {
                isMaskPinned = !autoHide
            } else {
                isMaskPinned = false
            }
            isMaskShow = show
            if show {
                delayHide?.cancel()
                // 播放的时候才自动隐藏
                guard state == .bufferFinished else { return }
                if autoHide, !isMaskPinned {
                    delayHide = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        if self.state == .bufferFinished {
                            self.isMaskShow = false
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + KSOptions.animateDelayTimeInterval,
                                                  execute: delayHide!)
                }
            }
            #if os(macOS)
            show ? NSCursor.unhide() : NSCursor.setHiddenUntilMouseMoves(true)
            if let window = playerLayer?.player.view?.window {
                if !window.styleMask.contains(.fullScreen) {
                    window.standardWindowButton(.closeButton)?.superview?.superview?.isHidden = !show
                    //                    window.standardWindowButton(.zoomButton)?.isHidden = !show
                    //                    window.standardWindowButton(.closeButton)?.isHidden = !show
                    //                    window.standardWindowButton(.miniaturizeButton)?.isHidden = !show
                    //                    window.titleVisibility = show ? .visible : .hidden
                }
            }
            #endif
        }
    }
}

extension KSVideoPlayer.Coordinator: KSPlayerLayerDelegate {
    public func player(layer: KSPlayerLayer, state: KSPlayerState) {
        self.state = state
        onStateChanged?(layer, state)
        if state == .readyToPlay {
            playbackRate = layer.player.playbackRate
            if let subtitleDataSouce = layer.player.subtitleDataSouce {
                // 要延后增加内嵌字幕。因为有些内嵌字幕是放在视频流的。所以会比readyToPlay回调晚。
                DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 1) { [weak self] in
                    guard let self else { return }
                    self.subtitleModel.addSubtitle(dataSouce: subtitleDataSouce)
                    if self.subtitleModel.selectedSubtitleInfo == nil, layer.options.autoSelectEmbedSubtitle {
                        self.subtitleModel.selectedSubtitleInfo = subtitleDataSouce.infos.first { $0.isEnabled }
                    }
                }
            }
        } else if state == .bufferFinished {
            if !isMaskPinned {
                isMaskShow = false
            }
        } else {
            isMaskShow = true
        }
    }

    public func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        onPlay?(currentTime, totalTime)
        if currentTime >= Double(Int.max) || currentTime <= Double(Int.min) || totalTime >= Double(Int.max) || totalTime <= Double(Int.min) {
            return
        }
        if currentTime > 0 {
            lastPlayURL = layer.url
            lastPlayTime = currentTime
        }
        let current = Int(currentTime)
        let total = Int(max(0, totalTime))
        if timemodel.currentTime != current {
            timemodel.currentTime = current
        }
        if timemodel.totalTime != total {
            timemodel.totalTime = total
        }
        let playableTime = layer.player.playableTime
        if playableTime.isFinite, playableTime < Double(Int.max), playableTime > Double(Int.min) {
            let buffered = Int(playableTime)
            if timemodel.bufferTime != buffered {
                timemodel.bufferTime = buffered
            }
        }
        _ = subtitleModel.subtitle(currentTime: currentTime)
    }

    public func player(layer: KSPlayerLayer, finish error: Error?) {
        onFinish?(layer, error)
    }

    public func player(layer _: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {
        onBufferChanged?(bufferedCount, consumeTime)
    }
}

extension KSVideoPlayer: Equatable {
    public static func == (lhs: KSVideoPlayer, rhs: KSVideoPlayer) -> Bool {
        lhs.url == rhs.url
    }
}

@MainActor
public extension KSVideoPlayer {
    func onBufferChanged(_ handler: @escaping (Int, TimeInterval) -> Void) -> Self {
        coordinator.onBufferChanged = handler
        return self
    }

    /// Playing to the end.
    func onFinish(_ handler: @escaping (KSPlayerLayer, Error?) -> Void) -> Self {
        coordinator.onFinish = handler
        return self
    }

    func onPlay(_ handler: @escaping (TimeInterval, TimeInterval) -> Void) -> Self {
        coordinator.onPlay = handler
        return self
    }

    /// Playback status changes, such as from play to pause.
    func onStateChanged(_ handler: @escaping (KSPlayerLayer, KSPlayerState) -> Void) -> Self {
        coordinator.onStateChanged = handler
        return self
    }

    #if canImport(UIKit)
    func onSwipe(_ handler: @escaping (UISwipeGestureRecognizer.Direction) -> Void) -> Self {
        coordinator.onSwipe = handler
        return self
    }
    #endif
}

extension View {
    func then(_ body: (inout Self) -> Void) -> Self {
        var result = self
        body(&result)
        return result
    }
}

/// 这是一个频繁变化的model。View要少用这个
public class ControllerTimeModel: ObservableObject {
    // 改成int才不会频繁更新
    @Published
    public var currentTime = 0
    @Published
    public var totalTime = 1
    @Published
    public var bufferTime = 0
}
