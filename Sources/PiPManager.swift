import AVFoundation
import AVKit
import Combine

final class PiPManager: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    let playerLayer = AVPlayerLayer()
    @Published var pipActive = false
    @Published var pipPossible = false
    @Published var status = "preparing video..."

    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var pip: AVPictureInPictureController?
    private var bag = Set<AnyCancellable>()

    func prepare() {
        guard player == nil else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? session.setActive(true)

        VideoMaker.make { [weak self] url in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let url = url else { self.status = "video generation failed"; return }
                let item = AVPlayerItem(url: url)
                let q = AVQueuePlayer()
                q.isMuted = true
                self.looper = AVPlayerLooper(player: q, templateItem: item)
                self.player = q
                self.playerLayer.player = q
                self.playerLayer.videoGravity = .resizeAspect
                q.play()

                guard AVPictureInPictureController.isPictureInPictureSupported(),
                      let c = AVPictureInPictureController(playerLayer: self.playerLayer) else {
                    self.status = "PiP not supported"; return
                }
                c.delegate = self
                if #available(iOS 14.2, *) { c.canStartPictureInPictureAutomaticallyFromInline = true }
                self.pip = c
                c.publisher(for: \.isPictureInPicturePossible)
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] ok in
                        self?.pipPossible = ok
                        if ok, self?.pipActive == false { self?.status = "ready, tap Start PiP" }
                        if ok, self?.pendingStart == true {
                            self?.pendingStart = false
                            self?.startIfNeeded()
                        }
                    }
                    .store(in: &self.bag)
            }
        }
    }

    static let shared = PiPManager()
    private var pendingStart = false

    /// Used by the URL scheme and the Shortcuts action: starts PiP now, or as soon as it is ready.
    func requestStart() {
        prepare()
        if pip?.isPictureInPicturePossible == true { startIfNeeded() } else { pendingStart = true }
    }

    func startIfNeeded() {
        guard let p = pip, p.isPictureInPicturePossible, !p.isPictureInPictureActive else { return }
        p.startPictureInPicture()
    }

    func stop() { pip?.stopPictureInPicture() }

    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        pipActive = true; status = "PiP running: monitoring in background"
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        pipActive = false; status = "PiP stopped: monitoring pauses when app is backgrounded"
    }
    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        pipActive = false; status = "PiP failed: \(error.localizedDescription)"
    }
    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler done: @escaping (Bool) -> Void) {
        done(true)
    }
}
