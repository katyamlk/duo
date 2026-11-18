// Duo — Telegram и Instagram в одном окне.
import AppKit
import WebKit
import UserNotifications
import Network

struct Service {
    let name: String
    let url: URL
    let allowedHosts: [String]
}

let services: [Service] = [
    Service(name: "Telegram", url: URL(string: "https://web.telegram.org/a/")!,
            allowedHosts: ["telegram.org", "t.me"]),
    Service(name: "Instagram", url: URL(string: "https://www.instagram.com/")!,
            allowedHosts: ["instagram.com", "facebook.com", "fbcdn.net", "cdninstagram.com", "accountscenter.instagram.com"]),
    Service(name: "Slack", url: URL(string: "https://app.slack.com/client")!,
            allowedHosts: ["slack.com", "slack-edge.com", "slack-files.com", "slack-imgs.com", "slackb.com",
                           "accounts.google.com", "google.com", "gstatic.com", "googleusercontent.com"])
]

// Представляемся текущей версией Safari, установленной на Mac, иначе Slack считает браузер устаревшим
let safariUA: String = {
    let plist = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")
    let version = plist?["CFBundleShortVersionString"] as? String ?? "26.0"
    return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Safari/605.1.15"
}()

// Язык интерфейса: украинский или английский
func uiLanguage() -> String {
    if let saved = UserDefaults.standard.string(forKey: "uiLanguage") { return saved }
    let preferred = Locale.preferredLanguages.first ?? "en"
    return preferred.hasPrefix("uk") ? "uk" : "en"
}

func tr(_ uk: String, _ en: String) -> String { uiLanguage() == "uk" ? uk : en }

// Подменяем веб-уведомления, чтобы они приходили как обычные уведомления macOS
// Плавная прокрутка: без «пружины» страницы и без случайных свайпов вбок
let smoothScrollFix = """
(function() {
  var style = document.createElement('style');
  style.textContent = 'html, body { overscroll-behavior: none !important; }';
  (document.head || document.documentElement).appendChild(style);
})();
"""

// Не даём сайтам висеть в «Сейчас играет» (островок / Now Playing), когда ничего не играет
let mediaSessionShim = """
(function() {
  function clearSession() {
    try {
      var playing = Array.prototype.some.call(document.querySelectorAll('video, audio'), function(m) { return !m.paused && !m.ended; });
      if (!playing && navigator.mediaSession) {
        navigator.mediaSession.metadata = null;
        navigator.mediaSession.playbackState = 'none';
      }
    } catch (e) {}
  }
  ['pause', 'ended', 'emptied'].forEach(function(ev) { document.addEventListener(ev, function() { setTimeout(clearSession, 300); }, true); });
  // Короткие звуки (например, звук уведомления) не регистрируем как медиаплеер
  var origPlay = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function() {
    var el = this;
    var p = origPlay.apply(el, arguments);
    if (!el.isConnected && el.tagName === 'AUDIO') {
      el.addEventListener('ended', function() { try { el.removeAttribute('src'); el.load(); } catch (e) {} }, { once: true });
    }
    return p;
  };
})();
// Web Audio: Slack и другие держат AudioContext «играющим» постоянно — усыпляем его, когда звуков нет
(function() {
  var Ctx = window.AudioContext || window.webkitAudioContext;
  if (!Ctx || !window.AudioScheduledSourceNode) return;
  var active = new WeakMap();
  var live = new WeakSet();
  function idle(ctx) {
    setTimeout(function() {
      if ((active.get(ctx) || 0) === 0 && !live.has(ctx) && ctx.state === 'running') { ctx.suspend().catch(function() {}); }
    }, 1500);
  }
  var origStart = AudioScheduledSourceNode.prototype.start;
  AudioScheduledSourceNode.prototype.start = function() {
    var ctx = this.context;
    active.set(ctx, (active.get(ctx) || 0) + 1);
    if (ctx.state === 'suspended') { ctx.resume().catch(function() {}); }
    this.addEventListener('ended', function() {
      active.set(ctx, Math.max(0, (active.get(ctx) || 1) - 1));
      idle(ctx);
    }, { once: true });
    return origStart.apply(this, arguments);
  };
  ['createMediaElementSource', 'createMediaStreamSource', 'createMediaStreamDestination'].forEach(function(name) {
    var orig = Ctx.prototype[name];
    if (!orig) return;
    Ctx.prototype[name] = function() { live.add(this); return orig.apply(this, arguments); };
  });
  var origResume = Ctx.prototype.resume;
  Ctx.prototype.resume = function() {
    var c = this;
    var p = origResume.apply(c, arguments);
    Promise.resolve(p).then(function() { idle(c); }).catch(function() {});
    return p;
  };
  var Wrapped = function(opts) {
    var c = opts === undefined ? new Ctx() : new Ctx(opts);
    idle(c);
    return c;
  };
  Wrapped.prototype = Ctx.prototype;
  try { window.AudioContext = Wrapped; } catch (e) {}
  try { if (window.webkitAudioContext) window.webkitAudioContext = Wrapped; } catch (e) {}
})();
"""

let notificationShim = """
(function() {
  function send(title, opts) {
    opts = opts || {};
    try { window.webkit.messageHandlers.notify.postMessage({ title: String(title || ''), body: String(opts.body || '') }); } catch (e) {}
  }
  class DuoNotification extends EventTarget {
    constructor(title, opts) {
      super();
      opts = opts || {};
      this.title = String(title || '');
      this.body = opts.body || '';
      this.tag = opts.tag || '';
      this.icon = opts.icon || '';
      this.data = opts.data;
      this.onclick = null; this.onclose = null; this.onerror = null; this.onshow = null;
      send(title, opts);
    }
    close() {}
    static requestPermission(cb) { if (cb) cb('granted'); return Promise.resolve('granted'); }
  }
  DuoNotification.permission = 'granted';
  DuoNotification.maxActions = 2;
  try { Object.defineProperty(window, 'Notification', { value: DuoNotification, writable: true, configurable: true }); } catch (e) { window.Notification = DuoNotification; }
  if (window.ServiceWorkerRegistration) {
    ServiceWorkerRegistration.prototype.showNotification = function(t, o) { send(t, o); return Promise.resolve(); };
    ServiceWorkerRegistration.prototype.getNotifications = function() { return Promise.resolve([]); };
  }
  if (navigator.permissions && navigator.permissions.query) {
    var q = navigator.permissions.query.bind(navigator.permissions);
    navigator.permissions.query = function(p) {
      if (p && p.name === 'notifications') {
        var status = new EventTarget();
        status.state = 'granted';
        status.name = 'notifications';
        status.onchange = null;
        return Promise.resolve(status);
      }
      return q(p);
    };
  }
})();
"""

final class NotifyHandler: NSObject, WKScriptMessageHandler {
    let tab: Int
    weak var app: AppDelegate?
    init(tab: Int) { self.tab = tab }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any] else { return }
        let title = dict["title"] as? String ?? ""
        let body = dict["body"] as? String ?? ""
        app?.notify(tab: tab, title: title, body: body)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate,
                         WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, UNUserNotificationCenterDelegate {
    var window: NSWindow!
    var webViews: [WKWebView] = []
    var segmented: NSSegmentedControl!
    var selected = 0
    var unread: [Int] = Array(repeating: 0, count: services.count)
    var titleObservers: [NSKeyValueObservation] = []
    let switcherID = NSToolbarItem.Identifier("switcher")
    let reloadID = NSToolbarItem.Identifier("reload")
    var lastWebNotification: [Int: Date] = [:]
    var reloadItem: NSToolbarItem?
    let backID = NSToolbarItem.Identifier("back")
    let forwardID = NSToolbarItem.Identifier("forward")
    let homeID = NSToolbarItem.Identifier("home")
    var popupWindows: [NSWindow] = []
    var popupTab: [ObjectIdentifier: Int] = [:]
    var downloadTargets: [ObjectIdentifier: URL] = [:]
    var sleptAt: Date?
    let pathMonitor = NWPathMonitor()
    var networkReady = true
    var pendingWake = false
    var appearanceObserver: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupWakeHandling()
        buildMenu()
        buildWindow()
        updateAppIcon()
        appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateAppIcon() } }
        }
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if !granted {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.askToEnableNotifications() } }
            }
        }
        select(UserDefaults.standard.integer(forKey: "selectedTab"))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Иконка в Доке: белая в светлой теме, чёрная в тёмной
    func updateAppIcon() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if let url = Bundle.main.url(forResource: dark ? "IconDark" : "IconLight", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = img
        }
        updateBadges()
    }

    // Окно
    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Duo"
        window.titleVisibility = .hidden
        window.delegate = self
        window.minSize = NSSize(width: 480, height: 400)
        window.center()
        window.setFrameAutosaveName("DuoMainWindow")

        let toolbar = NSToolbar(identifier: "DuoToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.centeredItemIdentifiers = [switcherID]
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact

        let container = NSView()
        window.contentView = container

        for (i, s) in services.enumerated() {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .default()
            config.preferences.isElementFullscreenEnabled = true
            config.mediaTypesRequiringUserActionForPlayback = .all
            config.userContentController.addUserScript(
                WKUserScript(source: mediaSessionShim, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            config.userContentController.addUserScript(
                WKUserScript(source: smoothScrollFix, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            let handler = NotifyHandler(tab: i)
            handler.app = self
            config.userContentController.add(handler, name: "notify")
            config.userContentController.addUserScript(
                WKUserScript(source: notificationShim, injectionTime: .atDocumentStart, forMainFrameOnly: true))

            let wv = WKWebView(frame: .zero, configuration: config)
            wv.customUserAgent = safariUA
            wv.navigationDelegate = self
            wv.uiDelegate = self
            wv.allowsBackForwardNavigationGestures = false
            if #available(macOS 13.3, *) { wv.isInspectable = true }
            wv.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(wv)
            NSLayoutConstraint.activate([
                wv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                wv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                wv.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
                wv.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
            wv.load(URLRequest(url: s.url))
            webViews.append(wv)

            titleObservers.append(wv.observe(\.title, options: [.new]) { [weak self] view, _ in
                let t = view.title ?? ""
                MainActor.assumeIsolated { self?.titleChanged(tab: i, title: t) }
            })
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [backID, forwardID, homeID, switcherID, reloadID, .flexibleSpace] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [backID, forwardID, homeID, .flexibleSpace, switcherID, .flexibleSpace, reloadID] }

    func navButton(_ id: NSToolbarItem.Identifier, symbol: String, label: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.toolTip = label
        item.isBordered = true
        item.target = self
        item.action = action
        return item
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == backID { return navButton(id, symbol: "chevron.left", label: tr("Назад", "Back") + " (Cmd+[)", action: #selector(goBack)) }
        if id == forwardID { return navButton(id, symbol: "chevron.right", label: tr("Вперед", "Forward") + " (Cmd+])", action: #selector(goForward)) }
        if id == homeID { return navButton(id, symbol: "house", label: tr("На головну", "Home") + " (Cmd+0)", action: #selector(goHome)) }
        if id == reloadID {
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: tr("Оновити", "Reload"))
            item.label = tr("Оновити", "Reload")
            item.toolTip = tr("Оновити цю вкладку (Cmd+R). З Option — оновити всі", "Reload this tab (Cmd+R). Option-click to reload all")
            item.isBordered = true
            item.target = self
            item.action = #selector(reloadButton)
            reloadItem = item
            return item
        }
        guard id == switcherID else { return nil }
        segmented = NSSegmentedControl(labels: services.map { $0.name }, trackingMode: .selectOne,
                                       target: self, action: #selector(segmentChanged))
        segmented.segmentStyle = .automatic
        segmented.controlSize = .small
        segmented.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        for i in 0..<services.count { segmented.setWidth(96, forSegment: i) }
        segmented.selectedSegment = selected
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = segmented
        item.label = tr("Розділ", "Section")
        return item
    }

    @objc func segmentChanged() { select(segmented.selectedSegment) }
    @objc func showTelegram() { select(0) }
    @objc func showInstagram() { select(1) }
    @objc func showSlack() { select(2) }
    @objc func reload() { webViews[selected].reload() }
    @objc func reloadAll() { webViews.forEach { $0.reload() } }
    @objc func reloadButton() {
        if NSEvent.modifierFlags.contains(.option) { reloadAll() } else { reload() }
    }
    @objc func goBack() { webViews[selected].goBack() }
    @objc func goHome() { webViews[selected].load(URLRequest(url: services[selected].url)) }
    @objc func goForward() { webViews[selected].goForward() }

    func select(_ tab: Int) {
        let t = (0..<services.count).contains(tab) ? tab : 0
        selected = t
        UserDefaults.standard.set(t, forKey: "selectedTab")
        for (i, wv) in webViews.enumerated() {
            wv.isHidden = i != t
            if i != t { wv.pauseAllMediaPlayback(completionHandler: nil) }
        }
        segmented?.selectedSegment = t
        window.makeFirstResponder(webViews[t])
    }

    // Счётчики непрочитанных
    func titleChanged(tab: Int, title: String) {
        var count = 0
        if let r = title.range(of: #"\((\d+)\)"#, options: .regularExpression) {
            count = Int(title[r].filter(\.isNumber)) ?? 0
        } else if let r = title.range(of: #"^\d+\s"#, options: .regularExpression) {
            count = Int(title[r].filter(\.isNumber)) ?? 0
        } else if title.hasPrefix("*") || title.hasPrefix("!") || title.hasPrefix("●") {
            // Slack помечает непрочитанное звёздочкой или восклицательным знаком в заголовке
            count = 1
        }
        let previous = unread[tab]
        unread[tab] = count
        updateBadges()
        // Запасной вариант для всех: если счётчик вырос, а сам сайт уведомление не прислал
        if count > previous {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                if let last = self.lastWebNotification[tab], Date().timeIntervalSince(last) < 15 { return }
                self.notify(tab: tab, title: services[tab].name,
                            body: count == 1 ? tr("Нове повідомлення", "New message") : tr("Непрочитаних: \(count)", "Unread: \(count)"), fromWeb: false)
            }
        }
    }

    func updateBadges() {
        for i in 0..<services.count {
            let label = unread[i] > 0 ? "\(services[i].name)  \(unread[i])" : services[i].name
            segmented?.setLabel(label, forSegment: i)
        }
        let total = unread.reduce(0, +)
        NSApp.dockTile.badgeLabel = total > 0 ? "\(total)" : nil
    }

    // Уведомления macOS
    func isNotifyEnabled(_ tab: Int) -> Bool {
        UserDefaults.standard.object(forKey: "notify_\(tab)") as? Bool ?? true
    }

    func notify(tab: Int, title: String, body: String, fromWeb: Bool = true) {
        if fromWeb { lastWebNotification[tab] = Date() }
        guard isNotifyEnabled(tab) else { return }
        if NSApp.isActive && window.isVisible && selected == tab { return }
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? services[tab].name : title
        content.subtitle = title.isEmpty ? "" : services[tab].name
        content.body = body
        content.sound = .default
        content.userInfo = ["tab": tab]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    func askToEnableNotifications() {
        let alert = NSAlert()
        alert.messageText = tr("Сповіщення Duo вимкнені", "Duo notifications are off")
        alert.informativeText = tr("Щоб отримувати повідомлення з Telegram, Instagram і Slack, увімкни сповіщення для Duo в Системних параметрах.", "To get messages from Telegram, Instagram and Slack, turn on notifications for Duo in System Settings.")
        alert.addButton(withTitle: tr("Відкрити параметри", "Open Settings"))
        alert.addButton(withTitle: tr("Пізніше", "Later"))
        if alert.runModal() == .alertFirstButtonReturn { openNotificationSettings() }
    }

    @objc func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.kate.duo") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func toggleNotify(_ sender: NSMenuItem) {
        let tab = sender.tag
        UserDefaults.standard.set(!isNotifyEnabled(tab), forKey: "notify_\(tab)")
        sender.state = isNotifyEnabled(tab) ? .on : .off
    }

    @objc func setLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        UserDefaults.standard.set(code, forKey: "uiLanguage")
        buildMenu()
        reloadItem?.label = tr("Оновити", "Reload")
        reloadItem?.toolTip = tr("Оновити цю вкладку (Cmd+R). З Option — оновити всі", "Reload this tab (Cmd+R). Option-click to reload all")
    }

    @objc func testNotification() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let ok = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if !ok { self.askToEnableNotifications(); return }
                    let content = UNMutableNotificationContent()
                    content.title = "Duo"
                    content.body = tr("Сповіщення працюють", "Notifications are working")
                    content.sound = .default
                    UNUserNotificationCenter.current().add(
                        UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
                }
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let tab = response.notification.request.content.userInfo["tab"] as? Int ?? 0
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                self.select(tab)
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // Ссылки на другие сайты — в браузер
    func isAllowed(_ url: URL, tab: Int) -> Bool {
        guard let host = url.host?.lowercased() else { return true }
        return services[tab].allowedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func tabIndex(of webView: WKWebView) -> Int {
        webViews.firstIndex(of: webView) ?? popupTab[ObjectIdentifier(webView)] ?? selected
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let scheme = action.request.url?.scheme?.lowercased(), !["http", "https", "about", "blob", "data"].contains(scheme) {
            decisionHandler(.cancel)
            return
        }
        if action.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        if let url = action.request.url, action.navigationType == .linkActivated,
           ["http", "https"].contains(url.scheme ?? ""), !isAllowed(url, tab: tabIndex(of: webView)) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // Быстрое восстановление после сна ноутбука
    func setupWakeHandling() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleptAt = Date() }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let wasReady = self.networkReady
                    self.networkReady = ok
                    if ok && !wasReady {
                        // Сеть пропадала (сон, смена Wi-Fi) — старые соединения мёртвые, перезагружаем вкладки
                        if self.sleptAt == nil { self.sleptAt = .distantPast }
                        self.pendingWake = true
                        self.refreshAfterWake()
                    }
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "duo.network"))
    }

    func didWake() {
        pendingWake = true
        if networkReady {
            // Даём Wi-Fi пару секунд переподключиться
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                self.refreshAfterWake()
            }
        }
    }

    func refreshAfterWake() {
        guard pendingWake || sleptAt != nil else { return }
        let longSleep = sleptAt.map { Date().timeIntervalSince($0) > 2 * 60 } ?? true
        pendingWake = false
        sleptAt = nil
        for wv in webViews {
            if longSleep {
                // После долгого сна просто перезагружаем: так быстрее, чем ждать, пока сайт сам переподключится
                wv.reload()
            } else {
                // После короткого сна подсказываем странице, что сеть вернулась: она сразу переподключается без перезагрузки
                wv.evaluateJavaScript("""
                    window.dispatchEvent(new Event('online'));
                    window.dispatchEvent(new Event('focus'));
                    document.dispatchEvent(new Event('visibilitychange'));
                    """, completionHandler: nil)
            }
        }
    }

    // Если macOS выгрузила страницу из памяти, пока ноутбук спал, — сразу загружаем её заново
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // Ссылки «в новом окне» (картинки, файлы, превью) открываем в отдельном окне Duo,
    // чтобы основная вкладка оставалась на месте
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let tab = tabIndex(of: webView)
        if let url = action.request.url, ["http", "https"].contains(url.scheme ?? ""), !isAllowed(url, tab: tab) {
            NSWorkspace.shared.open(url)
            return nil
        }
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.customUserAgent = safariUA
        popup.navigationDelegate = self
        popup.uiDelegate = self
        popupTab[ObjectIdentifier(popup)] = tab

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.title = services[tab].name
        w.contentView = popup
        if let main = window { w.setFrameTopLeftPoint(NSPoint(x: main.frame.minX + 40, y: main.frame.maxY - 40)) } else { w.center() }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let closed = note.object as? NSWindow else { return }
                if let wv = closed.contentView as? WKWebView {
                    self.popupTab[ObjectIdentifier(wv)] = nil
                    wv.pauseAllMediaPlayback(completionHandler: nil)
                }
                self.popupWindows.removeAll { $0 === closed }
            }
        }
        popupWindows.append(w)
        w.makeKeyAndOrderFront(nil)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        popupWindows.first { $0.contentView === webView }?.close()
    }

    // Скачивание файлов в «Загрузки»
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        if let http = navigationResponse.response as? HTTPURLResponse,
           let cd = http.value(forHTTPHeaderField: "Content-Disposition"), cd.lowercased().hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = (suggestedFilename as NSString).deletingPathExtension
        let ext = (suggestedFilename as NSString).pathExtension
        var url = dir.appendingPathComponent(suggestedFilename)
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        downloadTargets[ObjectIdentifier(download)] = url
        completionHandler(url)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = downloadTargets.removeValue(forKey: ObjectIdentifier(download)) else { return }
        let content = UNMutableNotificationContent()
        content.title = tr("Файл завантажено", "Download complete")
        content.body = url.lastPathComponent
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadTargets.removeValue(forKey: ObjectIdentifier(download))
        NSSound.beep()
    }

    // Отправка фото и файлов
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { result in
            completionHandler(result == .OK ? panel.urls : nil)
        }
    }

    // Голосовые и видеосообщения
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }

    // Закрытие окна не выключает приложение, чтобы уведомления продолжали приходить
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        window.orderOut(nil)
        webViews.forEach { $0.pauseAllMediaPlayback(completionHandler: nil) }
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Меню
    func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: tr("Сховати Duo", "Hide Duo"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("Вийти з Duo", "Quit Duo"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: tr("Редагування", "Edit"))
        edit.addItem(withTitle: tr("Скасувати", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: tr("Повторити", "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: tr("Вирізати", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: tr("Копіювати", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: tr("Вставити", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: tr("Вибрати все", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: tr("Вигляд", "View"))
        view.addItem(withTitle: "Telegram", action: #selector(showTelegram), keyEquivalent: "1").target = self
        view.addItem(withTitle: "Instagram", action: #selector(showInstagram), keyEquivalent: "2").target = self
        view.addItem(withTitle: "Slack", action: #selector(showSlack), keyEquivalent: "3").target = self
        view.addItem(.separator())
        view.addItem(withTitle: tr("Назад", "Back"), action: #selector(goBack), keyEquivalent: "[").target = self
        view.addItem(withTitle: tr("Вперед", "Forward"), action: #selector(goForward), keyEquivalent: "]").target = self
        view.addItem(withTitle: tr("На головну", "Home"), action: #selector(goHome), keyEquivalent: "0").target = self
        view.addItem(withTitle: tr("Оновити вкладку", "Reload Tab"), action: #selector(reload), keyEquivalent: "r").target = self
        let all = view.addItem(withTitle: tr("Оновити всі вкладки", "Reload All Tabs"), action: #selector(reloadAll), keyEquivalent: "r")
        all.keyEquivalentModifierMask = [.command, .shift]
        all.target = self
        viewItem.submenu = view
        main.addItem(viewItem)

        let notifyItem = NSMenuItem()
        let notifyMenu = NSMenu(title: tr("Сповіщення", "Notifications"))
        for (i, svc) in services.enumerated() {
            let item = NSMenuItem(title: tr("Сповіщення від \(svc.name)", "Notifications from \(svc.name)"), action: #selector(toggleNotify(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            item.state = isNotifyEnabled(i) ? .on : .off
            notifyMenu.addItem(item)
        }
        notifyMenu.addItem(.separator())
        notifyMenu.addItem(withTitle: tr("Надіслати тестове сповіщення", "Send Test Notification"), action: #selector(testNotification), keyEquivalent: "").target = self
        notifyMenu.addItem(withTitle: tr("Параметри сповіщень macOS…", "macOS Notification Settings…"), action: #selector(openNotificationSettings), keyEquivalent: "").target = self
        notifyItem.submenu = notifyMenu
        main.addItem(notifyItem)

        let langItem = NSMenuItem()
        let langMenu = NSMenu(title: tr("Мова", "Language"))
        for (code, name) in [("uk", "Українська"), ("en", "English")] {
            let item = NSMenuItem(title: name, action: #selector(setLanguage(_:)), keyEquivalent: "")
            item.representedObject = code
            item.target = self
            item.state = uiLanguage() == code ? .on : .off
            langMenu.addItem(item)
        }
        langItem.submenu = langMenu
        main.addItem(langItem)

        let windowItem = NSMenuItem()
        let win = NSMenu(title: tr("Вікно", "Window"))
        win.addItem(withTitle: tr("Згорнути", "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: tr("Закрити", "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = win
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = win
    }
}

@main
enum Main {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.regular)
            app.run()
            _ = delegate
        }
    }
}
