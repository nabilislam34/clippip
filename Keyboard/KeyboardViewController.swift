import UIKit

/// ClipPiP keyboard: its keys type into a search box, the results are clips that live on the PC,
/// and tapping a result types that clip into the app you are in.
final class KeyboardViewController: UIInputViewController, UITableViewDataSource, UITableViewDelegate {

    private struct Item: Decodable {
        let key: String
        let text: String
        let name: String?
        let note: String?
        let tags: [String]?
    }
    private struct ItemsReply: Decodable { let total: Int; let items: [Item] }
    private struct Tab: Decodable { let id: String; let label: String }
    private struct TabsReply: Decodable { let tabs: [Tab] }

    private static let setupPrefix = "clippip-setup:"
    private static let letters = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    private static let symbols = ["1234567890", "-_/:;()&@", ".,?!'#*+="]

    private let defaults = UserDefaults.standard
    private let session = URLSession(configuration: .ephemeral)
    private var tabs: [Tab] = []
    private var items: [Item] = []
    private var selectedTab = "*"
    private var query = ""
    private var showSymbols = false
    private var generation = 0
    private var pending: DispatchWorkItem?
    private var built = false

    private let root = UIStackView()
    private let tabScroll = UIScrollView()
    private let tabStack = UIStackView()
    private let queryLabel = UILabel()
    private let statusLabel = UILabel()
    private let table = UITableView(frame: .zero, style: .plain)
    private let keyRows = UIStackView()

    // MARK: lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        selectedTab = defaults.string(forKey: "kbTab") ?? "*"
        buildLayout()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        takeSetupFromClipboard()
        if !hasFullAccess {
            status("Turn on Allow Full Access for the ClipPiP keyboard in Settings")
        } else if server.isEmpty {
            status("Open ClipPiP, tap Link the ClipPiP keyboard, then come back")
        } else {
            if tabs.isEmpty { loadTabs() }
            search()
        }
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
                self?.tabs = r.tabs
                self?.rebuildTabs()
            }
        }.resume()
    }

    private func search() {
        generation += 1
        let gen = generation
        let path = "/lib/items?tab=\(Self.enc(selectedTab))&q=\(Self.enc(query))&limit=40&kind=text"
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

    // MARK: layout

    private func buildLayout() {
        guard !built else { return }
        built = true

        let height = view.heightAnchor.constraint(equalToConstant: 356)
        height.priority = UILayoutPriority(999)
        height.isActive = true

        root.axis = .vertical
        root.spacing = 4
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 3),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -3),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 3),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -3),
        ])

        // tabs (scrolls sideways)
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
            tabScroll.heightAnchor.constraint(equalToConstant: 30),
        ])
        root.addArrangedSubview(tabScroll)

        // search line
        queryLabel.font = .systemFont(ofSize: 15)
        queryLabel.lineBreakMode = .byTruncatingHead
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .right
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let searchLine = UIStackView(arrangedSubviews: [queryLabel, statusLabel])
        searchLine.axis = .horizontal
        searchLine.spacing = 6
        searchLine.heightAnchor.constraint(equalToConstant: 24).isActive = true
        root.addArrangedSubview(searchLine)

        // results
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 40
        table.backgroundColor = .clear
        table.layer.cornerRadius = 6
        root.addArrangedSubview(table)

        // keys
        keyRows.axis = .vertical
        keyRows.spacing = 5
        keyRows.heightAnchor.constraint(equalToConstant: 168).isActive = true
        root.addArrangedSubview(keyRows)

        rebuildTabs()
        rebuildKeys()
        showQuery()
    }

    private func rebuildTabs() {
        tabStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let shown = tabs.isEmpty ? [Tab(id: "*", label: "all copyq")] : tabs
        for tab in shown {
            let b = UIButton(type: .system, primaryAction: UIAction(title: tab.label) { [weak self] _ in
                self?.pick(tab.id)
            })
            b.titleLabel?.font = .systemFont(ofSize: 13, weight: tab.id == selectedTab ? .bold : .regular)
            b.backgroundColor = tab.id == selectedTab ? UIColor.systemBlue.withAlphaComponent(0.25) : UIColor.systemGray5
            b.layer.cornerRadius = 6
            b.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
            tabStack.addArrangedSubview(b)
        }
    }

    private func pick(_ id: String) {
        selectedTab = id
        defaults.set(id, forKey: "kbTab")
        rebuildTabs()
        search()
    }

    private func key(_ title: String, weight: CGFloat = 1, action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system, primaryAction: UIAction(title: title) { _ in action() })
        b.titleLabel?.font = .systemFont(ofSize: 17)
        b.setTitleColor(.label, for: .normal)
        b.backgroundColor = .systemGray4
        b.layer.cornerRadius = 5
        b.tag = Int(weight * 10)
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
        keyRows.distribution = .fillEqually
        for line in (showSymbols ? Self.symbols : Self.letters) {
            keyRows.addArrangedSubview(row(line.map { ch in
                key(String(ch)) { [weak self] in self?.type(String(ch)) }
            }))
        }
        let globe = key("\u{1F310}", weight: 1.2) {}
        globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        let bottom = [
            globe,
            key(showSymbols ? "abc" : "123", weight: 1.2) { [weak self] in
                guard let self = self else { return }
                self.showSymbols.toggle()
                self.rebuildKeys()
            },
            key("space", weight: 3) { [weak self] in self?.type(" ") },
            // erases the search first; with an empty search it erases in the app's text field
            key("\u{232B}", weight: 1.2) { [weak self] in self?.backspace() },
            key(",", weight: 1) { [weak self] in self?.textDocumentProxy.insertText(", ") },
            key("\u{23CE}", weight: 1.2) { [weak self] in self?.textDocumentProxy.insertText("\n") },
        ]
        keyRows.addArrangedSubview(row(bottom))
    }

    // MARK: typing

    private func type(_ s: String) {
        query += s
        showQuery()
        scheduleSearch()
    }

    private func backspace() {
        if query.isEmpty {
            textDocumentProxy.deleteBackward()
        } else {
            query.removeLast()
            showQuery()
            scheduleSearch()
        }
    }

    private func showQuery() {
        queryLabel.text = "\u{1F50D} " + (query.isEmpty ? "type to search clips" : query + "|")
        queryLabel.textColor = query.isEmpty ? .secondaryLabel : .label
    }

    // MARK: results

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "clip")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "clip")
        let item = items[indexPath.row]
        let oneLine = String(item.text.prefix(160)).replacingOccurrences(of: "\n", with: " ")
        let name = item.name ?? ""
        let extra = [(item.tags ?? []).map { "#" + $0 }.joined(separator: " "), item.note ?? ""]
            .filter { !$0.isEmpty }.joined(separator: "  ")
        cell.textLabel?.text = name.isEmpty ? oneLine : name
        cell.textLabel?.font = .systemFont(ofSize: 14, weight: name.isEmpty ? .regular : .semibold)
        cell.detailTextLabel?.text = name.isEmpty ? extra : (extra.isEmpty ? oneLine : oneLine + "  " + extra)
        cell.detailTextLabel?.font = .systemFont(ofSize: 11)
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.backgroundColor = .clear
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < items.count else { return }
        textDocumentProxy.insertText(items[indexPath.row].text)
        status("Inserted")
    }
}
