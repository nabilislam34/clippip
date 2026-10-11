import UIKit

/// ClipPiP keyboard. Layout follows the "clip list" style: coloured tab chips on top, one card per clip
/// (text or image thumbnail, date badge on the right), a toolbar at the bottom. The magnifier opens a
/// small typing keyboard to search. Tapping a text clip types it; tapping an image clip puts the image on
/// the clipboard (a keyboard cannot insert images), then paste it in the app.
final class KeyboardViewController: UIInputViewController, UITableViewDataSource, UITableViewDelegate {

    private struct Item: Decodable {
        let key: String
        let kind: String?
        let text: String
        let name: String?
        let note: String?
        let tags: [String]?
        let thumb: String?
        let img: String?
        let ts: String?
    }
    private struct ItemsReply: Decodable { let total: Int; let items: [Item] }
    private struct Tab: Decodable { let id: String; let label: String }
    private struct TabsReply: Decodable { let tabs: [Tab] }

    private static let setupPrefix = "clippip-setup:"
    private static let letters = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    private static let symbols = ["1234567890", "-_/:;()&@", ".,?!'#*+="]
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private static let dotColors: [UIColor] = [.systemTeal, .systemRed, .systemIndigo, .systemOrange,
                                               .systemGreen, .systemPink, .systemPurple, .systemYellow]
    private static let imageCache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 60
        return c
    }()

    private let defaults = UserDefaults.standard
    private let session = URLSession(configuration: .ephemeral)
    private var tabs: [Tab] = []
    private var items: [Item] = []
    private var selectedTab = ""
    private var query = ""
    private var searching = false
    private var showSymbols = false
    private var generation = 0
    private var pending: DispatchWorkItem?
    private var built = false
    private var heightConstraint: NSLayoutConstraint?

    private let root = UIStackView()
    private let tabScroll = UIScrollView()
    private let tabStack = UIStackView()
    private let table = UITableView(frame: .zero, style: .plain)
    private let statusLabel = UILabel()
    private let searchPanel = UIStackView()
    private let queryLabel = UILabel()
    private let keyRows = UIStackView()
    private let globeButton = UIButton(type: .system)

    // MARK: lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        selectedTab = defaults.string(forKey: "kbTab") ?? ""
        buildLayout()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The height is set here, not in viewDidLoad: a constraint added too early can leave the keyboard
        // with no height, so it never appears.
        if heightConstraint == nil {
            let h = view.heightAnchor.constraint(equalToConstant: 300)
            h.priority = UILayoutPriority(999)
            h.isActive = true
            heightConstraint = h
        }
        applyHeight()
        globeButton.isHidden = !needsInputModeSwitchKey
        takeSetupFromClipboard()
        if !hasFullAccess {
            status("Turn on Allow Full Access for ClipPiP in Settings > Keyboards")
        } else if server.isEmpty {
            status("Open ClipPiP and tap Link the ClipPiP keyboard, then come back")
        } else {
            if tabs.isEmpty { loadTabs() }
            search()
        }
    }

    private func applyHeight() {
        heightConstraint?.constant = searching ? 470 : 300
    }

    // MARK: settings

    private var server: String { defaults.string(forKey: "server") ?? "" }
    private var token: String { defaults.string(forKey: "token") ?? "" }

    /// The app hands over the server URL and token through the clipboard (needs Full Access).
    private func takeSetupFromClipboard() {
        guard hasFullAccess, UIPasteboard.general.hasStrings,
              let s = UIPasteboard.general.string, s.hasPrefix(Self.setupPrefix),
              let data = Data(base64Encoded: String(s.dropFirst(Self.setupPrefix.count))),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
              let srv = obj["server"], !srv.isEmpty else { return }
        defaults.set(srv, forKey: "server")
        defaults.set(obj["token"] ?? "", forKey: "token")
        UIPasteboard.general.string = ""
        tabs = []
    }

    private func url(_ path: String) -> URL? {
        var base = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        let t = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return URL(string: base + path + (path.contains("?") ? "&" : "?") + "token=" + t)
    }

    private static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }

    // MARK: network

    private func loadTabs() {
        guard let u = url("/lib/tabs") else { return }
        session.dataTask(with: URLRequest(url: u, timeoutInterval: 20)) { [weak self] data, _, _ in
            guard let data = data, let r = try? JSONDecoder().decode(TabsReply.self, from: data) else { return }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.tabs = r.tabs
                if self.selectedTab.isEmpty || !r.tabs.contains(where: { $0.id == self.selectedTab }) {
                    self.selectedTab = r.tabs.first?.id ?? "*"
                }
                self.rebuildTabs()
                self.search()
            }
        }.resume()
    }

    private func search() {
        generation += 1
        let gen = generation
        let tab = selectedTab.isEmpty ? "*" : selectedTab
        let path = "/lib/items?tab=\(Self.enc(tab))&q=\(Self.enc(query))&limit=40"
        guard let u = url(path) else { return }
        status("Searching...")
        session.dataTask(with: URLRequest(url: u, timeoutInterval: 60)) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self = self, gen == self.generation else { return }
                if let data = data, (resp as? HTTPURLResponse)?.statusCode == 200,
                   let r = try? JSONDecoder().decode(ItemsReply.self, from: data) {
                    self.items = r.items
                    self.status("\(r.total) clips")
                } else {
                    self.items = []
                    self.status(err?.localizedDescription ?? "PC server did not answer")
                }
                self.table.reloadData()
            }
        }.resume()
    }

    private func scheduleSearch() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.search() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func status(_ s: String) {
        statusLabel.text = s
    }

    private func fetchImage(_ path: String, done: @escaping (UIImage?) -> Void) {
        if let hit = Self.imageCache.object(forKey: path as NSString) {
            done(hit)
            return
        }
        guard let u = url(path) else {
            done(nil)
            return
        }
        session.dataTask(with: URLRequest(url: u, timeoutInterval: 30)) { data, _, _ in
            let img = data.flatMap { UIImage(data: $0) }
            if let img = img { Self.imageCache.setObject(img, forKey: path as NSString) }
            DispatchQueue.main.async { done(img) }
        }.resume()
    }

    // MARK: layout

    private func iconButton(_ symbol: String, _ action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: symbol), for: .normal)
        b.tintColor = .label
        b.backgroundColor = .systemGray5
        b.layer.cornerRadius = 8
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }

    private func buildLayout() {
        guard !built else { return }
        built = true

        root.axis = .vertical
        root.spacing = 4
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
        ])

        // tab chips (scroll sideways)
        tabStack.axis = .horizontal
        tabStack.spacing = 6
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        tabScroll.showsHorizontalScrollIndicator = false
        tabScroll.addSubview(tabStack)
        NSLayoutConstraint.activate([
            tabStack.leadingAnchor.constraint(equalTo: tabScroll.contentLayoutGuide.leadingAnchor),
            tabStack.trailingAnchor.constraint(equalTo: tabScroll.contentLayoutGuide.trailingAnchor),
            tabStack.topAnchor.constraint(equalTo: tabScroll.contentLayoutGuide.topAnchor),
            tabStack.bottomAnchor.constraint(equalTo: tabScroll.contentLayoutGuide.bottomAnchor),
            tabStack.heightAnchor.constraint(equalTo: tabScroll.frameLayoutGuide.heightAnchor),
            tabScroll.heightAnchor.constraint(equalToConstant: 36),
        ])
        root.addArrangedSubview(tabScroll)

        // clip cards
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 68
        table.separatorStyle = .none
        table.backgroundColor = .clear
        table.register(ClipCell.self, forCellReuseIdentifier: ClipCell.reuseId)
        root.addArrangedSubview(table)

        // status line
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.heightAnchor.constraint(equalToConstant: 14).isActive = true
        root.addArrangedSubview(statusLabel)

        // search panel (hidden until the magnifier is tapped)
        queryLabel.font = .systemFont(ofSize: 15)
        queryLabel.lineBreakMode = .byTruncatingHead
        queryLabel.heightAnchor.constraint(equalToConstant: 24).isActive = true
        keyRows.axis = .vertical
        keyRows.spacing = 5
        keyRows.distribution = .fillEqually
        keyRows.heightAnchor.constraint(equalToConstant: 168).isActive = true
        searchPanel.axis = .vertical
        searchPanel.spacing = 4
        searchPanel.addArrangedSubview(queryLabel)
        searchPanel.addArrangedSubview(keyRows)
        searchPanel.isHidden = true
        root.addArrangedSubview(searchPanel)

        // toolbar: left, right, delete, return, paste clipboard, search, globe, hide
        globeButton.setImage(UIImage(systemName: "globe"), for: .normal)
        globeButton.tintColor = .label
        globeButton.backgroundColor = .systemGray5
        globeButton.layer.cornerRadius = 8
        globeButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        let bar = UIStackView(arrangedSubviews: [
            iconButton("arrow.left") { [weak self] in self?.textDocumentProxy.adjustTextPosition(byCharacterOffset: -1) },
            iconButton("arrow.right") { [weak self] in self?.textDocumentProxy.adjustTextPosition(byCharacterOffset: 1) },
            iconButton("delete.left") { [weak self] in self?.backspace() },
            iconButton("return") { [weak self] in self?.textDocumentProxy.insertText("\n") },
            iconButton("doc.on.clipboard") { [weak self] in self?.pasteClipboard() },
            iconButton("magnifyingglass") { [weak self] in self?.toggleSearch() },
            globeButton,
            iconButton("keyboard.chevron.compact.down") { [weak self] in self?.dismissKeyboard() },
        ])
        bar.axis = .horizontal
        bar.spacing = 6
        bar.distribution = .fillEqually
        bar.heightAnchor.constraint(equalToConstant: 42).isActive = true
        root.addArrangedSubview(bar)

        rebuildTabs()
        rebuildKeys()
        showQuery()
    }

    private func rebuildTabs() {
        tabStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let shown = tabs.isEmpty ? [Tab(id: "*", label: "all copyq")] : tabs
        let current = selectedTab.isEmpty ? shown[0].id : selectedTab
        for (n, tab) in shown.enumerated() {
            let b = UIButton(type: .custom)
            let dot = Self.dotColors[n % Self.dotColors.count]
            let text = NSMutableAttributedString(string: "\u{25CF} ", attributes: [
                .foregroundColor: dot, .font: UIFont.systemFont(ofSize: 14)])
            text.append(NSAttributedString(string: tab.label, attributes: [
                .foregroundColor: UIColor.label,
                .font: UIFont.systemFont(ofSize: 14, weight: tab.id == current ? .semibold : .regular)]))
            b.setAttributedTitle(text, for: .normal)
            b.backgroundColor = tab.id == current ? UIColor.systemGray3 : UIColor.systemGray5
            b.layer.cornerRadius = 12
            b.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 12)
            b.addAction(UIAction { [weak self] _ in self?.pick(tab.id) }, for: .touchUpInside)
            tabStack.addArrangedSubview(b)
        }
    }

    private func pick(_ id: String) {
        selectedTab = id
        defaults.set(id, forKey: "kbTab")
        rebuildTabs()
        search()
    }

    private func toggleSearch() {
        searching.toggle()
        searchPanel.isHidden = !searching
        if !searching && !query.isEmpty {
            query = ""
            showQuery()
            search()
        }
        applyHeight()
    }

    // MARK: typing keys (search)

    private func key(_ title: String, weight: CGFloat = 1, action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 17)
        b.setTitleColor(.label, for: .normal)
        b.backgroundColor = .systemGray4
        b.layer.cornerRadius = 5
        b.tag = Int(weight * 10)
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }

    private func row(_ keys: [UIButton]) -> UIStackView {
        let r = UIStackView(arrangedSubviews: keys)
        r.axis = .horizontal
        r.spacing = 4
        r.distribution = .fill
        // every key is as wide as the first one, times its own weight
        if let first = keys.first {
            let unit = CGFloat(max(first.tag, 1))
            for k in keys.dropFirst() {
                k.widthAnchor.constraint(equalTo: first.widthAnchor, multiplier: CGFloat(max(k.tag, 1)) / unit).isActive = true
            }
        }
        return r
    }

    private func rebuildKeys() {
        keyRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for line in (showSymbols ? Self.symbols : Self.letters) {
            keyRows.addArrangedSubview(row(line.map { ch in
                key(String(ch)) { [weak self] in self?.type(String(ch)) }
            }))
        }
        let bottom = [
            key(showSymbols ? "abc" : "123", weight: 1.5) { [weak self] in
                guard let self = self else { return }
                self.showSymbols.toggle()
                self.rebuildKeys()
            },
            key("space", weight: 4) { [weak self] in self?.type(" ") },
            key("\u{232B}", weight: 1.5) { [weak self] in self?.backspace() },
        ]
        keyRows.addArrangedSubview(row(bottom))
    }

    private func type(_ s: String) {
        query += s
        showQuery()
        scheduleSearch()
    }

    /// Erases the search first; with an empty search it erases in the app's text field.
    private func backspace() {
        if searching && !query.isEmpty {
            query.removeLast()
            showQuery()
            scheduleSearch()
        } else {
            textDocumentProxy.deleteBackward()
        }
    }

    private func showQuery() {
        queryLabel.text = "\u{1F50D} " + (query.isEmpty ? "type to search clips" : query + "|")
        queryLabel.textColor = query.isEmpty ? .secondaryLabel : .label
    }

    private func pasteClipboard() {
        guard hasFullAccess else {
            status("Allow Full Access to paste the clipboard")
            return
        }
        if let s = UIPasteboard.general.string, !s.isEmpty {
            textDocumentProxy.insertText(s)
        } else {
            status("Clipboard has no text")
        }
    }

    // MARK: results

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: ClipCell.reuseId, for: indexPath) as! ClipCell
        let item = items[indexPath.row]
        let isImage = (item.kind ?? "text") == "image"
        let name = item.name ?? ""
        if isImage {
            cell.titleLabel.text = name.isEmpty ? "Image clip (tap to copy it)" : name
        } else {
            let oneLine = String(item.text.prefix(240)).replacingOccurrences(of: "\n", with: " ")
            cell.titleLabel.text = name.isEmpty ? oneLine : name + "\n" + oneLine
        }
        // date badge: "2026-10-11 08:00:00 ..." -> 11 / Oct
        let parts = (item.note ?? "").prefix(10).split(separator: "-")
        if parts.count == 3, let m = Int(parts[1]), m >= 1, m <= 12 {
            cell.dayLabel.text = String(Int(parts[2]) ?? 0)
            cell.monthLabel.text = Self.months[m - 1]
            cell.badge.isHidden = false
        } else {
            cell.badge.isHidden = true
        }
        cell.imageKey = ""
        cell.thumb.image = nil
        cell.setThumbVisible(isImage)
        if isImage, let path = item.thumb ?? item.img {
            cell.imageKey = path
            fetchImage(path) { [weak cell] img in
                guard let cell = cell, cell.imageKey == path else { return }
                cell.thumb.image = img
            }
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < items.count else { return }
        let item = items[indexPath.row]
        if (item.kind ?? "text") == "image" {
            copyImage(item)
        } else {
            textDocumentProxy.insertText(item.text)
            status("Inserted")
        }
    }

    /// Puts the raw image bytes on the clipboard (no decoding, a keyboard has very little memory).
    private func copyImage(_ item: Item) {
        guard hasFullAccess else {
            status("Allow Full Access to copy images")
            return
        }
        guard let path = item.img, let u = url(path) else { return }
        status("Loading image...")
        session.dataTask(with: URLRequest(url: u, timeoutInterval: 60)) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let data = data, data.count > 8 else {
                    self.status("Could not load the image")
                    return
                }
                let isPNG = data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47])
                UIPasteboard.general.setData(data, forPasteboardType: isPNG ? "public.png" : "public.jpeg")
                self.status("Image copied - paste it in the app")
            }
        }.resume()
    }
}

/// One clip card: optional thumbnail, up to three lines of text, date badge on the right.
private final class ClipCell: UITableViewCell {
    static let reuseId = "clipcell"

    let card = UIView()
    let thumb = UIImageView()
    let titleLabel = UILabel()
    let badge = UIView()
    let dayLabel = UILabel()
    let monthLabel = UILabel()
    var imageKey = ""
    private var thumbWidth: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none

        card.backgroundColor = .systemGray5
        card.layer.cornerRadius = 10
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        thumb.contentMode = .scaleAspectFill
        thumb.clipsToBounds = true
        thumb.layer.cornerRadius = 6
        thumb.backgroundColor = .systemGray4
        thumb.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 14)
        titleLabel.numberOfLines = 3
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        badge.backgroundColor = .systemGray3
        badge.layer.cornerRadius = 8
        badge.translatesAutoresizingMaskIntoConstraints = false
        dayLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        dayLabel.textAlignment = .center
        monthLabel.font = .systemFont(ofSize: 12)
        monthLabel.textAlignment = .center
        let badgeStack = UIStackView(arrangedSubviews: [dayLabel, monthLabel])
        badgeStack.axis = .vertical
        badgeStack.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(badgeStack)

        card.addSubview(thumb)
        card.addSubview(titleLabel)
        card.addSubview(badge)

        thumbWidth = thumb.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 3),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),

            thumb.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            thumb.topAnchor.constraint(equalTo: card.topAnchor, constant: 6),
            thumb.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -6),
            thumbWidth,

            badge.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            badge.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 46),
            badge.heightAnchor.constraint(equalToConstant: 40),
            badgeStack.leadingAnchor.constraint(equalTo: badge.leadingAnchor),
            badgeStack.trailingAnchor.constraint(equalTo: badge.trailingAnchor),
            badgeStack.centerYAnchor.constraint(equalTo: badge.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func setThumbVisible(_ visible: Bool) {
        thumbWidth.constant = visible ? 52 : 0
        thumb.isHidden = !visible
    }
}
