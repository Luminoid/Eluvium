import EluviumCore
import LumiKitUI
import SnapKit
import UIKit
import WebKit

/// One feed item in full: the summary row's counterpart. Renders the
/// item's body HTML — full `content`, else a markup-bearing `summary`, since
/// many feeds ship the whole post in `description` — in a script-disabled
/// web view (feed bodies are third-party markup; they get typography, never
/// execution), falling back to a plain-text label when the summary carries
/// no markup. Episodes get a Play button and the shared player bar; items
/// with a link get "Load full text", which resolves the post's page through
/// the pipeline and swaps in the readability `content` the floor extracts
/// (the truncated-feed escape hatch).
final class FeedItemDetailViewController: UIViewController {
    // MARK: - Properties

    private let item: ELVRecord
    private var fullTextTask: Task<Void, Never>?
    /// The base URL of the body the reader last loaded (the post's link,
    /// nil for none): the one main-frame navigation the reader itself starts.
    private var bodyBaseURL: URL?

    // MARK: - UI

    /// Holds whichever body view is active (web or plain text), so the
    /// full-text swap never re-plumbs the outer constraints.
    private let bodyContainer = UIView()

    private lazy var navigationBar: LMKNavigationBar = {
        let bar = LMKNavigationBar()
        bar.title = item.displayTitle ?? "Post"
        bar.showsBackButton = true
        return bar
    }()

    private lazy var metaLabel: UILabel = {
        let label = UILabel.lmk_make(.caption, text: RecordBrowsing.rowSecondary(for: item), color: LMKColor.textSecondary)
        label.isHidden = label.text?.isEmpty != false
        return label
    }()

    private lazy var playButton = LMKButton(title: "Play", style: .filled(.primary), target: self, action: #selector(playTapped))
    private lazy var fullTextButton = LMKButton(title: "Load full text", style: .outlined(.primary), target: self, action: #selector(loadFullText))
    private let statusLabel = LMKStatusLabel()

    /// JavaScript stays off: the body is third-party feed markup, and the
    /// detail view is a reader, not a browser. Images and CSS still load so
    /// posts look like posts. The navigation delegate keeps it a reader:
    /// only the body load itself renders here; tapped web links leave for
    /// the system browser and every other navigation answers to the egress
    /// policy or is refused. Subresources answer to the wrapper's content
    /// security policy (HTTPS only), and the data store is non-persistent, so
    /// a tracking pixel's cookies never outlive the item.
    private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = LMKColor.backgroundPrimary
        webView.navigationDelegate = self
        return webView
    }()

    private lazy var summaryScrollView: UIScrollView = {
        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        return scrollView
    }()

    private lazy var summaryLabel = UILabel.lmk_make(.body, color: LMKColor.textPrimary)

    private lazy var playerBar = AudioPlayerBar()

    // MARK: - Init

    init(item: ELVRecord) {
        self.item = item
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        fullTextTask?.cancel()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LMKColor.backgroundPrimary
        setupLayout()
        loadBody()
    }

    // MARK: - Setup

    private func setupLayout() {
        let header = ListHeaderScaffold.makeHeaderStack([metaLabel, playButton, fullTextButton, statusLabel], spacing: LMKSpacing.small, bottomMargin: LMKSpacing.small, alignment: .leading)

        view.addSubview(navigationBar)
        navigationBar.install(in: view)
        ListHeaderScaffold.install(header: header, in: view, below: navigationBar)

        let usesWebView = RecordBrowsing.detailHTML(of: item) != nil
        let body: UIView = usesWebView ? webView : summaryScrollView
        view.addSubview(bodyContainer)
        view.addSubview(playerBar)
        bodyContainer.snp.makeConstraints { make in
            make.top.equalTo(header.snp.bottom).offset(LMKSpacing.small)
            make.leading.trailing.equalToSuperview()
        }
        bodyContainer.addSubview(body)
        body.snp.makeConstraints { $0.edges.equalToSuperview() }
        // The bar collapses to zero height while nothing plays, so no
        // bottom inset here: collapsed means the body reaches the safe area.
        // Full screen width with padding, matching the item browser's bar.
        playerBar.snp.makeConstraints { make in
            make.top.equalTo(bodyContainer.snp.bottom)
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(LMKSpacing.large)
            make.bottom.equalTo(view.safeAreaLayoutGuide)
        }
        if !usesWebView {
            summaryScrollView.addSubview(summaryLabel)
            summaryLabel.snp.makeConstraints { make in
                make.top.bottom.equalToSuperview().inset(LMKSpacing.small)
                // The root's readable-width guide stays still through the
                // interactive swipe back; its `readableContentGuide` does not.
                make.leading.trailing.equalTo(view.lmk_readableWidthGuide)
            }
        }

        playButton.isHidden = RecordBrowsing.audioURL(of: item) == nil
        fullTextButton.isHidden = RecordBrowsing.memberURL(of: item) == nil
    }

    private func loadBody() {
        if let body = RecordBrowsing.detailHTML(of: item) {
            // Base URL = the post's own link so relative images resolve.
            loadReader(body, baseURL: RecordBrowsing.memberURL(of: item))
        } else if case let .text(summary)? = item.fields["summary"] {
            summaryLabel.lmk_setText(RecordBrowsing.snippet(summary, limit: .max))
        }
    }

    /// Every body the reader shows goes through here, so the navigation
    /// delegate knows which main-frame load is the reader's own.
    private func loadReader(_ content: String, baseURL: URL?) {
        bodyBaseURL = baseURL
        webView.loadHTMLString(Self.wrapped(content), baseURL: baseURL)
    }

    /// System typography, fluid images, and both color schemes around the
    /// feed's own markup; the page margin is the design system's large
    /// spacing so the reader lines up with the native header above it. The
    /// content security policy comes first, so the feed's markup can only
    /// tighten it: images, media, styles, and fonts over HTTPS (or inline
    /// `data:` images), nothing else.
    private static func wrapped(_ content: String) -> String {
        """
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data:; media-src https:; style-src 'unsafe-inline' https:; font-src https:">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: light dark; }
          body { font: -apple-system-body; font-family: -apple-system, sans-serif;
                 margin: \(Int(LMKSpacing.large))px; line-height: 1.5; }
          img, video { max-width: 100%; height: auto; }
          pre { overflow-x: auto; }
        </style>
        \(content)
        """
    }

    // MARK: - Actions

    /// Resolves the post's own page through the live pipeline and swaps
    /// the readability-extracted `content` into the reader. Cancel-first,
    /// like every resolve entry point.
    @objc private func loadFullText() {
        guard let link = RecordBrowsing.memberURL(of: item) else { return }
        fullTextTask?.cancel()
        // The tapped button carries the busy state (spinner plus blocked
        // taps), the same affordance every other resolve uses.
        fullTextButton.isLoading = true
        fullTextTask = ResolveFlow.run(.url(link, example: nil), status: statusLabel, onRecord: { [weak self] record in
            guard let self else { return }
            guard case let .text(content)? = record.fields["content"], !content.isEmpty else {
                statusLabel.showOutcome("The page offered no readable body.", status: .warning)
                return
            }
            statusLabel.show("Full text loaded.", status: .neutral)
            if webView.superview == nil {
                summaryScrollView.removeFromSuperview()
                bodyContainer.addSubview(webView)
                webView.snp.makeConstraints { $0.edges.equalToSuperview() }
            }
            loadReader(content, baseURL: link)
        }, completion: { [weak self] _ in
            self?.fullTextButton.isLoading = false
        })
    }

    @objc private func playTapped() {
        AudioPlayer.shared.play(item: item)
    }

    // MARK: - Helpers

    /// What the reader does with one navigation. Pure and static so the
    /// policy is testable without a web view: the reader's own body load
    /// renders; any other load the markup starts by itself (an iframe, a
    /// `<meta http-equiv=refresh>`) is a device egress like every fetch, so
    /// subframes must pass `ELVEgressPolicy` and the main frame never leaves
    /// the reader; a tapped link opens in the system browser when it is a
    /// web link and goes nowhere otherwise (`tel:`, `sms:`, app schemes).
    enum ReaderDecision: Equatable {
        case allow
        case cancel
        case openExternally(URL)
    }

    static func readerDecision(for url: URL?, type: WKNavigationType, isMainFrame: Bool, bodyBaseURL: URL?) -> ReaderDecision {
        guard let url else { return .cancel }
        switch type {
        case .other:
            if isMainFrame {
                let bodyURL = bodyBaseURL?.absoluteString ?? "about:blank"
                return url.absoluteString == bodyURL ? .allow : .cancel
            }
            return ELVEgressPolicy.violation(url) == nil ? .allow : .cancel
        case .linkActivated:
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return .cancel }
            return .openExternally(url)
        default:
            return .cancel
        }
    }
}

// MARK: - WKNavigationDelegate

extension FeedItemDetailViewController: WKNavigationDelegate {
    func webView(_: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let decision = Self.readerDecision(
            for: navigationAction.request.url,
            type: navigationAction.navigationType,
            // A nil target frame is a new-window request: never the reader's.
            isMainFrame: navigationAction.targetFrame?.isMainFrame ?? false,
            bodyBaseURL: bodyBaseURL
        )
        switch decision {
        case .allow:
            return .allow
        case .cancel:
            return .cancel
        case let .openExternally(url):
            // The completion-handler overload: the async one would hold the
            // policy decision until the browser has opened.
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            return .cancel
        }
    }
}
