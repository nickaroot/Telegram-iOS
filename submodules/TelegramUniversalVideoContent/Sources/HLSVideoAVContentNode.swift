import Foundation
import SwiftSignalKit
import UniversalMediaPlayer
import Postbox
import TelegramCore
import AsyncDisplayKit
import AccountContext
import TelegramAudio
import RangeSet
import AVFoundation
import Display
import PhotoResources
import TelegramVoip

final class HLSVideoAVContentNode: ASDisplayNode, UniversalVideoContentNode {
    private let postbox: Postbox
    private let userLocation: MediaResourceUserLocation
    private let fileReference: FileMediaReference
    private let approximateDuration: Double
    private let intrinsicDimensions: CGSize

    private let audioSessionManager: ManagedAudioSession
    private let audioSessionDisposable = MetaDisposable()
    private var hasAudioSession = false
    
    private let playbackCompletedListeners = Bag<() -> Void>()
    
    private var initializedStatus = false
    private var statusValue = MediaPlayerStatus(generationTimestamp: 0.0, duration: 0.0, dimensions: CGSize(), timestamp: 0.0, baseRate: 1.0, seekId: 0, status: .paused, soundEnabled: true)
    private var baseRate: Double = 1.0
    private var isBuffering = false
    private var seekId: Int = 0
    private let _status = ValuePromise<MediaPlayerStatus>()
    var status: Signal<MediaPlayerStatus, NoError> {
        return self._status.get()
    }
    
    private let _bufferingStatus = Promise<(RangeSet<Int64>, Int64)?>()
    var bufferingStatus: Signal<(RangeSet<Int64>, Int64)?, NoError> {
        return self._bufferingStatus.get()
    }
    
    var isNativePictureInPictureActive: Signal<Bool, NoError> {
        return .single(false)
    }
    
    private let _ready = Promise<Void>()
    var ready: Signal<Void, NoError> {
        return self._ready.get()
    }
    
    private let _preloadCompleted = ValuePromise<Bool>()
    var preloadCompleted: Signal<Bool, NoError> {
        return self._preloadCompleted.get()
    }
    
    private var playerSource: HLSServerSource?
    private var serverDisposable: Disposable?
    
    private let imageNode: TransformImageNode
    
    private var playerItem: AVPlayerItem?
    private var player: AVPlayer?
    private let playerNode: ASDisplayNode
    
    private var loadProgressDisposable: Disposable?
    private var statusDisposable: Disposable?
    
    private var didPlayToEndTimeObserver: NSObjectProtocol?
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var willResignActiveObserver: NSObjectProtocol?
    private var failureObserverId: NSObjectProtocol?
    private var errorObserverId: NSObjectProtocol?
    private var playerItemFailedToPlayToEndTimeObserver: NSObjectProtocol?
    
    private let fetchDisposable = MetaDisposable()
    
    private var dimensions: CGSize?
    private let dimensionsPromise = ValuePromise<CGSize>(CGSize())
    
    private var validLayout: (size: CGSize, actualSize: CGSize)?
    
    private var statusTimer: Foundation.Timer?
    
    private var preferredVideoQuality: UniversalVideoContentVideoQuality = .auto
    
    init(accountId: AccountRecordId, postbox: Postbox, audioSessionManager: ManagedAudioSession, userLocation: MediaResourceUserLocation, fileReference: FileMediaReference, streamVideo: Bool, loopVideo: Bool, enableSound: Bool, baseRate: Double, fetchAutomatically: Bool) {
        self.postbox = postbox
        self.fileReference = fileReference
        self.approximateDuration = fileReference.media.duration ?? 0.0
        self.audioSessionManager = audioSessionManager
        self.userLocation = userLocation
        self.baseRate = baseRate
        
        if var dimensions = fileReference.media.dimensions {
            if let thumbnail = fileReference.media.previewRepresentations.first {
                let dimensionsVertical = dimensions.width < dimensions.height
                let thumbnailVertical = thumbnail.dimensions.width < thumbnail.dimensions.height
                if dimensionsVertical != thumbnailVertical {
                    dimensions = PixelDimensions(width: dimensions.height, height: dimensions.width)
                }
            }
            self.dimensions = dimensions.cgSize
        } else {
            self.dimensions = CGSize(width: 128.0, height: 128.0)
        }
        
        self.imageNode = TransformImageNode()
        
        var player: AVPlayer?
        player = AVPlayer(playerItem: nil)
        self.player = player
        if #available(iOS 16.0, *) {
            player?.defaultRate = Float(baseRate)
        }
        if !enableSound {
            player?.volume = 0.0
        }
        
        self.playerNode = ASDisplayNode()
        self.playerNode.setLayerBlock({
            return AVPlayerLayer(player: player)
        })
        
        self.intrinsicDimensions = fileReference.media.dimensions?.cgSize ?? CGSize(width: 480.0, height: 320.0)
        
        self.playerNode.frame = CGRect(origin: CGPoint(), size: self.intrinsicDimensions)
        
        if let qualitySet = HLSQualitySet(baseFile: fileReference) {
            self.playerSource = HLSServerSource(accountId: accountId.int64, fileId: fileReference.media.fileId.id, postbox: postbox, userLocation: userLocation, playlistFiles: qualitySet.playlistFiles, qualityFiles: qualitySet.qualityFiles)
        }
        
        super.init()

        self.imageNode.setSignal(internalMediaGridMessageVideo(postbox: postbox, userLocation: self.userLocation, videoReference: fileReference) |> map { [weak self] getSize, getData in
            Queue.mainQueue().async {
                if let strongSelf = self, strongSelf.dimensions == nil {
                    if let dimensions = getSize() {
                        strongSelf.dimensions = dimensions
                        strongSelf.dimensionsPromise.set(dimensions)
                        if let validLayout = strongSelf.validLayout {
                            strongSelf.updateLayout(size: validLayout.size, actualSize: validLayout.actualSize, transition: .immediate)
                        }
                    }
                }
            }
            return getData
        })
        
        self.addSubnode(self.imageNode)
        self.addSubnode(self.playerNode)
        self.player?.actionAtItemEnd = .pause
        
        self.imageNode.imageUpdated = { [weak self] _ in
            self?._ready.set(.single(Void()))
        }
        
        self.player?.addObserver(self, forKeyPath: "rate", options: [], context: nil)
        
        self._bufferingStatus.set(.single(nil))
        
        if let playerSource = self.playerSource {
            self.serverDisposable = SharedHLSServer.shared.registerPlayer(source: playerSource, completion: { [weak self] in
                Queue.mainQueue().async {
                    guard let self else {
                        return
                    }
                    
                    let playerItem: AVPlayerItem
                    let assetUrl = "http://127.0.0.1:\(SharedHLSServer.shared.port)/\(playerSource.id)/master.m3u8"
                    #if DEBUG
                    print("HLSVideoAVContentNode: playing \(assetUrl)")
                    #endif
                    playerItem = AVPlayerItem(url: URL(string: assetUrl)!)
                    
                    if #available(iOS 14.0, *) {
                        playerItem.startsOnFirstEligibleVariant = true
                    }
                    
                    self.setPlayerItem(playerItem)
                }
            })
        }
        
        self.didBecomeActiveObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil, using: { [weak self] _ in
            guard let strongSelf = self, let layer = strongSelf.playerNode.layer as? AVPlayerLayer else {
                return
            }
            layer.player = strongSelf.player
        })
        self.willResignActiveObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil, using: { [weak self] _ in
            guard let strongSelf = self, let layer = strongSelf.playerNode.layer as? AVPlayerLayer else {
                return
            }
            layer.player = nil
        })
    }
    
    deinit {
        self.player?.removeObserver(self, forKeyPath: "rate")
        
        self.setPlayerItem(nil)
        
        self.audioSessionDisposable.dispose()
        
        self.loadProgressDisposable?.dispose()
        self.statusDisposable?.dispose()
        
        if let didBecomeActiveObserver = self.didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
        }
        if let willResignActiveObserver = self.willResignActiveObserver {
            NotificationCenter.default.removeObserver(willResignActiveObserver)
        }
        
        if let didPlayToEndTimeObserver = self.didPlayToEndTimeObserver {
            NotificationCenter.default.removeObserver(didPlayToEndTimeObserver)
        }
        if let failureObserverId = self.failureObserverId {
            NotificationCenter.default.removeObserver(failureObserverId)
        }
        if let errorObserverId = self.errorObserverId {
            NotificationCenter.default.removeObserver(errorObserverId)
        }
        
        self.serverDisposable?.dispose()
        
        self.statusTimer?.invalidate()
    }
    
    private func setPlayerItem(_ item: AVPlayerItem?) {
        if let playerItem = self.playerItem {
            playerItem.removeObserver(self, forKeyPath: "playbackBufferEmpty")
            playerItem.removeObserver(self, forKeyPath: "playbackLikelyToKeepUp")
            playerItem.removeObserver(self, forKeyPath: "playbackBufferFull")
            playerItem.removeObserver(self, forKeyPath: "status")
            playerItem.removeObserver(self, forKeyPath: "presentationSize")
        }
        
        if let playerItemFailedToPlayToEndTimeObserver = self.playerItemFailedToPlayToEndTimeObserver {
            self.playerItemFailedToPlayToEndTimeObserver = nil
            NotificationCenter.default.removeObserver(playerItemFailedToPlayToEndTimeObserver)
        }
        
        if let didPlayToEndTimeObserver = self.didPlayToEndTimeObserver {
            self.didPlayToEndTimeObserver = nil
            NotificationCenter.default.removeObserver(didPlayToEndTimeObserver)
        }
        if let failureObserverId = self.failureObserverId {
            self.failureObserverId = nil
            NotificationCenter.default.removeObserver(failureObserverId)
        }
        if let errorObserverId = self.errorObserverId {
            self.errorObserverId = nil
            NotificationCenter.default.removeObserver(errorObserverId)
        }
        
        self.playerItem = item
        
        if let item {
            self.didPlayToEndTimeObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: item, queue: nil, using: { [weak self] notification in
                self?.performActionAtEnd()
            })
            
            self.failureObserverId = NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main, using: { notification in
#if DEBUG
                print("Player Error: \(notification.description)")
#endif
            })
            self.errorObserverId = NotificationCenter.default.addObserver(forName: AVPlayerItem.newErrorLogEntryNotification, object: item, queue: .main, using: { [weak item] notification in
                if let item {
                    let event = item.errorLog()?.events.last
                    if let event {
                        let _ = event
#if DEBUG
                        print("Player Error: \(event.errorComment ?? "<no comment>")")
#endif
                    }
                }
            })
            item.addObserver(self, forKeyPath: "presentationSize", options: [], context: nil)
        }
        
        if let playerItem = self.playerItem {
            playerItem.addObserver(self, forKeyPath: "playbackBufferEmpty", options: .new, context: nil)
            playerItem.addObserver(self, forKeyPath: "playbackLikelyToKeepUp", options: .new, context: nil)
            playerItem.addObserver(self, forKeyPath: "playbackBufferFull", options: .new, context: nil)
            playerItem.addObserver(self, forKeyPath: "status", options: .new, context: nil)
            self.playerItemFailedToPlayToEndTimeObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name.AVPlayerItemFailedToPlayToEndTime, object: playerItem, queue: OperationQueue.main, using: { [weak self] _ in
                guard let self else {
                    return
                }
                let _ = self
            })
        }
        
        self.player?.replaceCurrentItem(with: self.playerItem)
    }
    
    private func updateStatus() {
        guard let player = self.player else {
            return
        }
        let isPlaying = !player.rate.isZero
        let status: MediaPlayerPlaybackStatus
        if self.isBuffering {
            status = .buffering(initial: false, whilePlaying: isPlaying, progress: 0.0, display: true)
        } else {
            status = isPlaying ? .playing : .paused
        }
        var timestamp = player.currentTime().seconds
        if timestamp.isFinite && !timestamp.isNaN {
        } else {
            timestamp = 0.0
        }
        self.statusValue = MediaPlayerStatus(generationTimestamp: CACurrentMediaTime(), duration: Double(self.approximateDuration), dimensions: CGSize(), timestamp: timestamp, baseRate: self.baseRate, seekId: self.seekId, status: status, soundEnabled: true)
        self._status.set(self.statusValue)
        
        if case .playing = status {
            if self.statusTimer == nil {
                self.statusTimer = Foundation.Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true, block: { [weak self] _ in
                    guard let self else {
                        return
                    }
                    self.updateStatus()
                })
            }
        } else if let statusTimer = self.statusTimer {
            self.statusTimer = nil
            statusTimer.invalidate()
        }
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "rate" {
            if let player = self.player {
                let isPlaying = !player.rate.isZero
                if isPlaying {
                    self.isBuffering = false
                }
            }
            self.updateStatus()
        } else if keyPath == "playbackBufferEmpty" {
            self.isBuffering = true
            self.updateStatus()
        } else if keyPath == "playbackLikelyToKeepUp" || keyPath == "playbackBufferFull" {
            self.isBuffering = false
            self.updateStatus()
        } else if keyPath == "presentationSize" {
            if let currentItem = self.player?.currentItem {
                print("Presentation size: \(Int(currentItem.presentationSize.height))")
            }
        }
    }
    
    private func performActionAtEnd() {
        for listener in self.playbackCompletedListeners.copyItems() {
            listener()
        }
    }
    
    func updateLayout(size: CGSize, actualSize: CGSize, transition: ContainedViewLayoutTransition) {
        transition.updatePosition(node: self.playerNode, position: CGPoint(x: size.width / 2.0, y: size.height / 2.0))
        transition.updateTransformScale(node: self.playerNode, scale: size.width / self.intrinsicDimensions.width)
        
        transition.updateFrame(node: self.imageNode, frame: CGRect(origin: CGPoint(), size: size))
        
        if let dimensions = self.dimensions {
            let imageSize = CGSize(width: floor(dimensions.width / 2.0), height: floor(dimensions.height / 2.0))
            let makeLayout = self.imageNode.asyncLayout()
            let applyLayout = makeLayout(TransformImageArguments(corners: ImageCorners(), imageSize: imageSize, boundingSize: imageSize, intrinsicInsets: UIEdgeInsets(), emptyColor: .clear))
            applyLayout()
        }
    }
    
    func play() {
        assert(Queue.mainQueue().isCurrent())
        if !self.initializedStatus {
            self._status.set(MediaPlayerStatus(generationTimestamp: 0.0, duration: Double(self.approximateDuration), dimensions: CGSize(), timestamp: 0.0, baseRate: self.baseRate, seekId: self.seekId, status: .buffering(initial: true, whilePlaying: true, progress: 0.0, display: true), soundEnabled: true))
        }
        if !self.hasAudioSession {
            if self.player?.volume != 0.0 {
                self.audioSessionDisposable.set(self.audioSessionManager.push(audioSessionType: .play(mixWithOthers: false), activate: { [weak self] _ in
                    guard let self else {
                        return
                    }
                    self.hasAudioSession = true
                    self.player?.play()
                }, deactivate: { [weak self] _ in
                    guard let self else {
                        return .complete()
                    }
                    self.hasAudioSession = false
                    self.player?.pause()
                    
                    return .complete()
                }))
            } else {
                self.player?.play()
            }
        } else {
            self.player?.play()
        }
    }
    
    func pause() {
        assert(Queue.mainQueue().isCurrent())
        self.player?.pause()
    }
    
    func togglePlayPause() {
        assert(Queue.mainQueue().isCurrent())
        
        guard let player = self.player else {
            return
        }
        
        if player.rate.isZero {
            self.play()
        } else {
            self.pause()
        }
    }
    
    func setSoundEnabled(_ value: Bool) {
        assert(Queue.mainQueue().isCurrent())
        if value {
            if !self.hasAudioSession {
                self.audioSessionDisposable.set(self.audioSessionManager.push(audioSessionType: .play(mixWithOthers: false), activate: { [weak self] _ in
                    self?.hasAudioSession = true
                    self?.player?.volume = 1.0
                }, deactivate: { [weak self] _ in
                    self?.hasAudioSession = false
                    self?.player?.pause()
                    return .complete()
                }))
            }
        } else {
            self.player?.volume = 0.0
            self.hasAudioSession = false
            self.audioSessionDisposable.set(nil)
        }
    }
    
    func seek(_ timestamp: Double) {
        assert(Queue.mainQueue().isCurrent())
        self.seekId += 1
        self.player?.seek(to: CMTime(seconds: timestamp, preferredTimescale: 30))
    }
    
    func playOnceWithSound(playAndRecord: Bool, seek: MediaPlayerSeek, actionAtEnd: MediaPlayerPlayOnceWithSoundActionAtEnd) {
        self.player?.volume = 1.0
        self.play()
    }
    
    func setSoundMuted(soundMuted: Bool) {
        self.player?.volume = soundMuted ? 0.0 : 1.0
    }
    
    func continueWithOverridingAmbientMode(isAmbient: Bool) {
    }
    
    func setForceAudioToSpeaker(_ forceAudioToSpeaker: Bool) {
    }
    
    func continuePlayingWithoutSound(actionAtEnd: MediaPlayerPlayOnceWithSoundActionAtEnd) {
        self.player?.volume = 0.0
        self.hasAudioSession = false
        self.audioSessionDisposable.set(nil)
    }
    
    func setContinuePlayingWithoutSoundOnLostAudioSession(_ value: Bool) {   
    }
    
    func setBaseRate(_ baseRate: Double) {
        guard let player = self.player else {
            return
        }
        self.baseRate = baseRate
        if #available(iOS 16.0, *) {
            player.defaultRate = Float(baseRate)
        }
        if player.rate != 0.0 {
            player.rate = Float(baseRate)
        }
        self.updateStatus()
    }
    
    func setVideoQuality(_ videoQuality: UniversalVideoContentVideoQuality) {
        self.preferredVideoQuality = videoQuality
        
        guard let currentItem = self.player?.currentItem else {
            return
        }
        guard let playerSource = self.playerSource else {
            return
        }
        
        switch videoQuality {
        case .auto:
            currentItem.preferredPeakBitRate = 0.0
        case let .quality(qualityValue):
            if let file = playerSource.qualityFiles[qualityValue] {
                if let size = file.media.size, let duration = file.media.duration, duration != 0.0 {
                    let bandwidth = Int(Double(size) / duration) * 8
                    currentItem.preferredPeakBitRate = Double(bandwidth)
                }
            }
        }
        
    }
    
    func videoQualityState() -> (current: Int, preferred: UniversalVideoContentVideoQuality, available: [Int])? {
        guard let currentItem = self.player?.currentItem else {
            return nil
        }
        guard let playerSource = self.playerSource else {
            return nil
        }
        let current = Int(currentItem.presentationSize.height)
        var available: [Int] = Array(playerSource.qualityFiles.keys)
        available.sort(by: { $0 > $1 })
        return (current, self.preferredVideoQuality, available)
    }
    
    func addPlaybackCompleted(_ f: @escaping () -> Void) -> Int {
        return self.playbackCompletedListeners.add(f)
    }
    
    func removePlaybackCompleted(_ index: Int) {
        self.playbackCompletedListeners.remove(index)
    }
    
    func fetchControl(_ control: UniversalVideoNodeFetchControl) {
    }
    
    func notifyPlaybackControlsHidden(_ hidden: Bool) {
    }

    func setCanPlaybackWithoutHierarchy(_ canPlaybackWithoutHierarchy: Bool) {
    }
    
    func enterNativePictureInPicture() -> Bool {
        return false
    }
    
    func exitNativePictureInPicture() {
    }
}
