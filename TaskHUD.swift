//
//  TaskHUD.swift
//  A single-file, always-on-top macOS HUD that shows the clock, your current
//  time-blocked task, and a live countdown to the end of that block.
//
//  Build:   swiftc -O TaskHUD.swift -o taskhud
//  Run:     ./taskhud
//
//  Schedule lives at ~/.taskhud/schedule.json and hot-reloads on save.
//
//  No dependencies. No Xcode project. No app bundle required.
//

import AppKit
import Foundation

// ============================================================================
// MARK: - Logging
// ============================================================================

enum Log {
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; return f
    }()
    private static func write(_ tag: String, _ msg: String) {
        let line = "\(stamp.string(from: Date())) [taskhud]\(tag) \(msg)\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
    }
    static func info(_ msg: String)  { write("", msg) }
    static func error(_ msg: String) { write("[ERROR]", msg) }
}

// ============================================================================
// MARK: - Model
// ============================================================================

/// A block as written by the user in schedule.json.
struct RawBlock: Codable {
    let title: String
    let start: String          // "HH:mm" (24h) — also accepts "H:mm" and "HH:mm:ss"
    let end: String            // "HH:mm" — if <= start, the block is treated as crossing midnight
    var days: [String]?        // ["mon","tue"] | ["weekdays"] | ["weekends"] | ["daily"] | nil == daily
    var note: String?
    var color: String?         // "#RRGGBB" or "#RRGGBBAA"

    enum CodingKeys: String, CodingKey { case title, start, end, days, note, color }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        start = try c.decode(String.self, forKey: .start)
        end   = try c.decode(String.self, forKey: .end)
        note  = try c.decodeIfPresent(String.self, forKey: .note)
        color = try c.decodeIfPresent(String.self, forKey: .color)

        // `days` may be [String], [Int] (1=Sun...7=Sat), or a bare String.
        if let strings = try? c.decodeIfPresent([String].self, forKey: .days) {
            days = strings
        } else if let ints = try? c.decodeIfPresent([Int].self, forKey: .days) {
            let map = [1: "sun", 2: "mon", 3: "tue", 4: "wed", 5: "thu", 6: "fri", 7: "sat"]
            days = ints.compactMap { map[$0] }
        } else if let one = try? c.decodeIfPresent(String.self, forKey: .days) {
            days = [one]
        } else {
            days = nil
        }
    }

    init(title: String, start: String, end: String, days: [String]? = nil,
         note: String? = nil, color: String? = nil) {
        self.title = title; self.start = start; self.end = end
        self.days = days; self.note = note; self.color = color
    }
}

struct Settings: Codable {
    var warnMinutes: [Int]?      // e.g. [10, 5, 1] — chime + colour shift at these marks
    var sound: Bool?             // play chimes at all
    var startSound: String?      // NSSound name for block start, default "Glass"
    var warnSound: String?       // NSSound name for warnings, default "Tink"
    var opacity: Double?         // 0.30...1.00
    var compact: Bool?           // one-line mode
    var showSeconds: Bool?       // seconds in the countdown
    var windowLevel: String?     // "screenSaver" (default) | "status" | "float"
    var clickThrough: Bool?      // ignore mouse events entirely
    var scale: Double?           // 0.75...1.75 UI scale
    var distractions: Distractions?

    static let `default` = Settings(
        warnMinutes: [10, 5, 1], sound: true, startSound: "Glass", warnSound: "Tink",
        opacity: 0.96, compact: false, showSeconds: true,
        windowLevel: "screenSaver", clickThrough: false, scale: 1.0,
        distractions: nil
    )

    func merged(over base: Settings) -> Settings {
        Settings(
            warnMinutes: warnMinutes ?? base.warnMinutes,
            sound:       sound       ?? base.sound,
            startSound:  startSound  ?? base.startSound,
            warnSound:   warnSound   ?? base.warnSound,
            opacity:     opacity     ?? base.opacity,
            compact:     compact     ?? base.compact,
            showSeconds: showSeconds ?? base.showSeconds,
            windowLevel: windowLevel ?? base.windowLevel,
            clickThrough: clickThrough ?? base.clickThrough,
            scale:       scale       ?? base.scale,
            distractions: distractions ?? base.distractions
        )
    }
}

/// Top level file. Supports BOTH shapes:
///   [ {block}, {block} ]                          (bare array)
///   { "settings": {...}, "blocks": [ {block} ] }  (object)
struct ScheduleFile: Codable {
    var settings: Settings?
    var blocks: [RawBlock]

    init(from decoder: Decoder) throws {
        if let array = try? decoder.singleValueContainer().decode([RawBlock].self) {
            self.blocks = array
            self.settings = nil
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.settings = try c.decodeIfPresent(Settings.self, forKey: .settings)
        self.blocks   = try c.decode([RawBlock].self, forKey: .blocks)
    }

    init(settings: Settings?, blocks: [RawBlock]) { self.settings = settings; self.blocks = blocks }
    enum CodingKeys: String, CodingKey { case settings, blocks }
}

/// A block resolved onto concrete wall-clock dates for a specific calendar day.
struct ResolvedBlock {
    let title: String
    let note: String?
    let color: NSColor?
    let start: Date
    let end: Date

    var duration: TimeInterval { max(1, end.timeIntervalSince(start)) }
    /// Stable identity for alert de-duplication (title + exact start instant).
    var key: String { "\(title)|\(Int(start.timeIntervalSince1970))" }

    func progress(at now: Date) -> Double {
        let p = now.timeIntervalSince(start) / duration
        return min(1, max(0, p))
    }
    func contains(_ now: Date) -> Bool { now >= start && now < end }
}

// ============================================================================
// MARK: - Schedule resolution
// ============================================================================

enum ScheduleError: Error, LocalizedError {
    case badTime(String)
    var errorDescription: String? {
        switch self { case .badTime(let s): return "Unparseable time: \"\(s)\"" }
    }
}

final class ScheduleEngine {

    private(set) var raw: [RawBlock] = []
    private(set) var settings: Settings = .default
    /// Non-nil when the last load failed; the previous good schedule is retained.
    private(set) var loadError: String?
    private(set) var lastLoaded: Date?

    private var cacheDayKey: String = ""
    private var cache: [ResolvedBlock] = []

    private let calendar: Calendar = {
        var c = Calendar.current
        c.timeZone = TimeZone.current
        return c
    }()

    // ---- Loading -----------------------------------------------------------

    func load(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else { throw NSError(domain: "taskhud", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "schedule.json is empty"]) }
            let file = try JSONDecoder().decode(ScheduleFile.self, from: data)

            // Validate every time string up front so we fail loudly, not silently.
            for b in file.blocks {
                guard parseHM(b.start) != nil else { throw ScheduleError.badTime(b.start) }
                guard parseHM(b.end)   != nil else { throw ScheduleError.badTime(b.end) }
            }
            guard !file.blocks.isEmpty else { throw NSError(domain: "taskhud", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "schedule has zero blocks"]) }

            raw = file.blocks
            settings = (file.settings ?? Settings.default).merged(over: .default)
            loadError = nil
            lastLoaded = Date()
            invalidate()
            Log.info("loaded \(raw.count) blocks from \(url.path)")
        } catch {
            let ns = error as NSError
            // 256 / 260 = the file vanished mid-read, which is what an editor's
            // atomic save looks like from the outside. Say so in plain words.
            loadError = (ns.domain == NSCocoaErrorDomain && (ns.code == 256 || ns.code == 260))
                ? "schedule.json was busy — retrying"
                : error.localizedDescription
            Log.error("load failed: \(error.localizedDescription) (keeping previous schedule)")
        }
    }

    func invalidate() { cacheDayKey = ""; cache = [] }

    // ---- Parsing -----------------------------------------------------------

    /// "9:5" -> (9,5,0); "09:05" -> (9,5,0); "09:05:30" -> (9,5,30). Returns nil if invalid.
    private func parseHM(_ s: String) -> (Int, Int, Int)? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ":").map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        let sec = parts.count == 3 ? (Int(parts[2]) ?? -1) : 0
        // "24:00" is a legal way to say end-of-day.
        guard (0...24).contains(h), (0...59).contains(m), (0...59).contains(sec) else { return nil }
        if h == 24 && (m != 0 || sec != 0) { return nil }
        return (h, m, sec)
    }

    private static let dayTokens: [String: Int] = [
        "sun": 1, "sunday": 1, "mon": 2, "monday": 2, "tue": 3, "tues": 3, "tuesday": 3,
        "wed": 4, "weds": 4, "wednesday": 4, "thu": 5, "thur": 5, "thurs": 5, "thursday": 5,
        "fri": 6, "friday": 6, "sat": 7, "saturday": 7
    ]

    private func matches(days: [String]?, weekday: Int) -> Bool {
        guard let days, !days.isEmpty else { return true }
        for tokenRaw in days {
            let t = tokenRaw.lowercased().trimmingCharacters(in: .whitespaces)
            switch t {
            case "daily", "everyday", "all", "*": return true
            case "weekdays", "weekday": if (2...6).contains(weekday) { return true }
            case "weekends", "weekend": if weekday == 1 || weekday == 7 { return true }
            default: if ScheduleEngine.dayTokens[t] == weekday { return true }
            }
        }
        return false
    }

    // ---- Resolution --------------------------------------------------------

    /// Concrete date for (day + HH:mm). Handles DST gaps by nudging forward.
    private func date(on day: Date, h: Int, m: Int, s: Int) -> Date? {
        if h == 24 {
            guard let midnight = calendar.startOfDay(for: day) as Date?,
                  let next = calendar.date(byAdding: .day, value: 1, to: midnight) else { return nil }
            return next
        }
        var comps = calendar.dateComponents([.year, .month, .day], from: day)
        comps.hour = h; comps.minute = m; comps.second = s
        if let d = calendar.date(from: comps) { return d }
        // DST spring-forward: the wall-clock time does not exist. Use next valid instant.
        comps.hour = h; comps.minute = m; comps.second = 0
        return calendar.nextDate(after: calendar.startOfDay(for: day),
                                 matching: DateComponents(hour: h, minute: m),
                                 matchingPolicy: .nextTime)
    }

    /// All blocks resolved for yesterday / today / tomorrow, sorted by start.
    /// Three days are needed so that (a) midnight-crossing blocks from yesterday are
    /// still "current", and (b) "next up" works across the day boundary.
    func resolved(around now: Date, useCache: Bool = true) -> [ResolvedBlock] {
        let key = dayKey(now)
        if useCache, key == cacheDayKey, !cache.isEmpty { return cache }

        var out: [ResolvedBlock] = []
        for offset in -1...1 {
            guard let day = calendar.date(byAdding: .day, value: offset,
                                          to: calendar.startOfDay(for: now)) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            for b in raw {
                guard matches(days: b.days, weekday: weekday) else { continue }
                guard let (sh, sm, ss) = parseHM(b.start), let (eh, em, es) = parseHM(b.end) else { continue }
                guard let startD = date(on: day, h: sh, m: sm, s: ss),
                      var endD   = date(on: day, h: eh, m: em, s: es) else { continue }

                // End at or before start => block crosses midnight.
                if endD <= startD {
                    guard let bumped = calendar.date(byAdding: .day, value: 1, to: endD) else { continue }
                    endD = bumped
                }
                // Zero/negative safety net.
                if endD <= startD { endD = startD.addingTimeInterval(60) }

                out.append(ResolvedBlock(title: b.title,
                                         note: b.note,
                                         color: b.color.flatMap(NSColor.fromHex),
                                         start: startD, end: endD))
            }
        }
        out.sort { $0.start == $1.start ? $0.duration < $1.duration : $0.start < $1.start }

        // De-duplicate exact repeats (can occur if a block matches via two day tokens).
        var seen = Set<String>()
        let deduped = out.filter { seen.insert($0.key).inserted }
        if useCache { cache = deduped; cacheDayKey = key }
        return deduped
    }

    /// Every block scheduled on a given calendar day, uncached so that
    /// browsing history never poisons the hot path's cache.
    func blocks(on day: Date) -> [ResolvedBlock] {
        let start = calendar.startOfDay(for: day)
        guard let next = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return resolved(around: start.addingTimeInterval(12 * 3600), useCache: false)
            .filter { $0.start >= start && $0.start < next }
            .sorted { $0.start < $1.start }
    }

    private func dayKey(_ d: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)|\(TimeZone.current.identifier)|\(lastLoaded?.timeIntervalSince1970 ?? 0)"
    }

    /// Look up an already-resolved block instance by its stable key.
    func block(key: String, at now: Date) -> ResolvedBlock? {
        resolved(around: now).first { $0.key == key }
    }

    /// Active block at `now`. With overlaps, the most recently started wins;
    /// ties broken by the shorter block (the more specific one).
    func current(at now: Date) -> ResolvedBlock? {
        resolved(around: now).filter { $0.contains(now) }
            .max { a, b in
                a.start == b.start ? a.duration > b.duration : a.start < b.start
            }
    }

    func isOverlapping(at now: Date) -> Bool {
        resolved(around: now).filter { $0.contains(now) }.count > 1
    }

    func next(after now: Date) -> ResolvedBlock? {
        resolved(around: now).first { $0.start > now }
    }

    /// Today's blocks only (for the status menu preview).
    func today(_ now: Date) -> [ResolvedBlock] {
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return resolved(around: now).filter { $0.start >= start && $0.start < end }
    }
}

// ============================================================================
// MARK: - Small helpers
// ============================================================================

extension NSColor {
    static func fromHex(_ hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let r = CGFloat((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(v & 0xFF) / 255 : 1
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

enum Fmt {
    static func hms(_ interval: TimeInterval, showSeconds: Bool) -> String {
        let t = max(0, Int(interval.rounded(.up)))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        if showSeconds {
            return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                         : String(format: "%02d:%02d", m, s)
        }
        // Minute resolution, always rounding up so "1m" never reads as done.
        let totalMin = (t + 59) / 60
        return totalMin >= 60 ? String(format: "%dh %02dm", totalMin / 60, totalMin % 60)
                              : String(format: "%dm", totalMin)
    }

    static func compactRemaining(_ interval: TimeInterval) -> String {
        let t = max(0, Int(interval.rounded(.up)))
        if t >= 3600 { return String(format: "%dh%02dm", t / 3600, (t % 3600) / 60) }
        if t >= 60   { return String(format: "%dm", (t + 59) / 60) }
        return "\(t)s"
    }

    static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    static let clockNoSec: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    static let hm: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
}

// ============================================================================
// MARK: - Theme
// ============================================================================

/// A deliberately narrow palette: warm off-white on near-black, one accent,
/// two escalation tones. No saturated colour anywhere.
enum Theme {
    static let text      = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1.00)
    static let secondary = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 0.55)
    static let tertiary  = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 0.34)
    static let rule      = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 0.11)
    static let hairline  = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 0.14)
    /// Warm paper laid over the blur. High alpha keeps it bright over any desktop.
    static let scrim     = NSColor(srgbRed: 0.992, green: 0.984, blue: 0.965, alpha: 0.88)

    /// Ink blue. The default accent — saturated enough to read on paper.
    static let accent = NSColor(srgbRed: 0.161, green: 0.353, blue: 0.549, alpha: 1)
    /// Ochre. First warning threshold.
    static let warn   = NSColor(srgbRed: 0.780, green: 0.529, blue: 0.106, alpha: 1)
    /// Clay red. Final threshold.
    static let urgent = NSColor(srgbRed: 0.729, green: 0.239, blue: 0.176, alpha: 1)
    /// Soft red paper, washed over the card while drifting.
    static let alarmScrim = NSColor(srgbRed: 0.996, green: 0.925, blue: 0.906, alpha: 0.94)
    /// Nothing scheduled / free time.
    static let idle   = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 0.30)

    static func attributed(_ s: String, size: CGFloat, weight: NSFont.Weight,
                           color: NSColor, kern: CGFloat = 0,
                           monospaced: Bool = false) -> NSAttributedString {
        let font = monospaced
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        return NSAttributedString(string: s, attributes: [
            .font: font, .foregroundColor: color, .kern: kern
        ])
    }
}

// ============================================================================
// MARK: - Hairline progress rule
// ============================================================================

/// A 1.5pt square-ended rule, not a pill. Reads as a typographic underline.
final class ProgressBar: NSView {
    var progress: Double = 0 {
        didSet { if abs(progress - oldValue) > 0.0004 { needsDisplay = true } }
    }
    var tint: NSColor = Theme.accent {
        didSet { if tint != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0 else { return }
        Theme.rule.setFill()
        bounds.fill()
        let w = bounds.width * CGFloat(min(1, max(0, progress)))
        guard w > 0.5 else { return }
        tint.setFill()
        NSRect(x: 0, y: 0, width: w, height: bounds.height).fill()
    }
}

// ============================================================================
// MARK: - HUD state
// ============================================================================

struct HUDState {
    var clock: String = "--:--"
    var range: String = ""
    var title: String = "No task"
    var countdown: String = "--:--"
    var caption: String = ""
    var next: String = ""
    var progress: Double = 0
    var tint: NSColor = Theme.accent
    var warning: Bool = false
    var errorText: String? = nil
    var nudge: String? = nil
    var distracted: Bool = false
}

// ============================================================================
// MARK: - HUD content view
// ============================================================================

final class HUDContentView: NSView {

    private let effect = NSVisualEffectView()
    private let scrim  = NSView()

    private let rangeLabel     = NSTextField(labelWithString: "")
    private let clockLabel     = NSTextField(labelWithString: "")
    private let titleLabel     = NSTextField(labelWithString: "")
    private let countdownLabel = NSTextField(labelWithString: "")
    private let captionLabel   = NSTextField(labelWithString: "")
    private let nextLabel      = NSTextField(labelWithString: "")
    private let bar            = ProgressBar()

    private let compactTitle     = NSTextField(labelWithString: "")
    private let compactCountdown = NSTextField(labelWithString: "")
    private let compactBar       = ProgressBar()

    private let errorLabel = NSTextField(labelWithString: "")

    private var outer: NSStackView!
    private var fullBox: NSStackView!
    private var compactBox: NSStackView!

    private let scale: CGFloat
    private(set) var compact: Bool = false

    override var isFlipped: Bool { true }
    var onDoubleClick: (() -> Void)?
    var onReviewTap: (() -> Void)?
    private let reviewButton = NSButton()

    @objc private func reviewTapped() { onReviewTap?() }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?(); return }
        super.mouseDown(with: event)
    }

    init(scale: CGFloat) {
        self.scale = max(0.75, min(1.75, scale))
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 150))
        wantsLayer = true
        layer?.cornerRadius = 13 * self.scale
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = Theme.hairline.cgColor
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return v
    }

    private func build() {
        effect.material = .popover
        effect.appearance = NSAppearance(named: .aqua)
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = Theme.scrim.cgColor
        scrim.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrim)

        for v in [effect, scrim] {
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: leadingAnchor),
                v.trailingAnchor.constraint(equalTo: trailingAnchor),
                v.topAnchor.constraint(equalTo: topAnchor),
                v.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        for l in [rangeLabel, clockLabel, titleLabel, countdownLabel,
                  captionLabel, nextLabel, errorLabel,
                  compactTitle, compactCountdown] {
            l.lineBreakMode = .byTruncatingTail
            l.usesSingleLineMode = true
            l.maximumNumberOfLines = 1
            l.isSelectable = false
        }
        titleLabel.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        compactTitle.setContentCompressionResistancePriority(.init(200), for: .horizontal)

        reviewButton.title = "\u{2713}"
        reviewButton.isBordered = false
        reviewButton.bezelStyle = .inline
        reviewButton.target = self
        reviewButton.action = #selector(reviewTapped)
        reviewButton.toolTip = "Mark today's blocks"
        reviewButton.attributedTitle = NSAttributedString(string: "\u{2713}", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: Theme.secondary])
        reviewButton.translatesAutoresizingMaskIntoConstraints = false
        reviewButton.widthAnchor.constraint(equalToConstant: 18).isActive = true
        reviewButton.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let topRow = NSStackView(views: [rangeLabel, spacer(), clockLabel, reviewButton])
        topRow.orientation = .horizontal
        topRow.spacing = 8 * scale
        topRow.alignment = .firstBaseline
        topRow.distribution = .fill

        let countRow = NSStackView(views: [countdownLabel, captionLabel])
        countRow.orientation = .horizontal
        countRow.spacing = 7 * scale
        countRow.alignment = .lastBaseline

        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 1.5 * scale).isActive = true

        fullBox = NSStackView(views: [topRow, titleLabel, countRow, bar, nextLabel])
        fullBox.orientation = .vertical
        fullBox.alignment = .leading
        fullBox.spacing = 4 * scale
        fullBox.setCustomSpacing(11 * scale, after: topRow)
        fullBox.setCustomSpacing(7 * scale, after: titleLabel)
        fullBox.setCustomSpacing(12 * scale, after: countRow)
        fullBox.setCustomSpacing(10 * scale, after: bar)

        let compactRow = NSStackView(views: [compactTitle, spacer(), compactCountdown])
        compactRow.orientation = .horizontal
        compactRow.spacing = 10 * scale
        compactRow.alignment = .firstBaseline
        compactRow.distribution = .fill

        compactBar.translatesAutoresizingMaskIntoConstraints = false
        compactBar.heightAnchor.constraint(equalToConstant: 1.5 * scale).isActive = true

        compactBox = NSStackView(views: [compactRow, compactBar])
        compactBox.orientation = .vertical
        compactBox.alignment = .leading
        compactBox.spacing = 9 * scale
        compactBox.isHidden = true

        errorLabel.isHidden = true

        outer = NSStackView(views: [fullBox, compactBox, errorLabel])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 9 * scale
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)

        let padX = 17 * scale
        let padY = 15 * scale
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padX),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padX),
            outer.topAnchor.constraint(equalTo: topAnchor, constant: padY),
            outer.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -padY),
            fullBox.widthAnchor.constraint(equalTo: outer.widthAnchor),
            compactBox.widthAnchor.constraint(equalTo: outer.widthAnchor),
            topRow.widthAnchor.constraint(equalTo: fullBox.widthAnchor),
            bar.widthAnchor.constraint(equalTo: fullBox.widthAnchor),
            nextLabel.widthAnchor.constraint(lessThanOrEqualTo: fullBox.widthAnchor),
            compactRow.widthAnchor.constraint(equalTo: compactBox.widthAnchor),
            compactBar.widthAnchor.constraint(equalTo: compactBox.widthAnchor),
            errorLabel.widthAnchor.constraint(lessThanOrEqualTo: outer.widthAnchor)
        ])
    }

    func setCompact(_ on: Bool) {
        guard compact != on else { return }
        compact = on
        fullBox.isHidden = on
        compactBox.isHidden = !on
        needsLayout = true
    }

    /// Sets BOTH the control font and the attributed string. Setting only the
    /// attributed string leaves intrinsicContentSize computed from the control's
    /// default 13pt font, which makes large text draw outside its own frame and
    /// collide with neighbours in the stack.
    private func setLabel(_ l: NSTextField, _ s: String, size: CGFloat,
                          weight: NSFont.Weight, color: NSColor,
                          kern: CGFloat = 0, monospaced: Bool = false) {
        let f = monospaced
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        l.font = f
        l.attributedStringValue = NSAttributedString(string: s, attributes: [
            .font: f, .foregroundColor: color, .kern: kern
        ])
        l.invalidateIntrinsicContentSize()
    }

    func apply(_ s: HUDState) {
        // A drift washes the whole card, so it reads from across the room.
        scrim.layer?.backgroundColor = (s.distracted ? Theme.alarmScrim : Theme.scrim).cgColor
        layer?.borderColor = (s.distracted ? Theme.urgent.withAlphaComponent(0.5) : Theme.hairline).cgColor
        if compact {
            setLabel(compactTitle, s.title, size: 12.5 * scale, weight: .medium,
                     color: Theme.text, kern: -0.1)
            setLabel(compactCountdown, s.countdown, size: 12.5 * scale, weight: .regular,
                     color: s.warning ? s.tint : Theme.secondary, kern: 0.2, monospaced: true)
            compactBar.progress = s.progress
            compactBar.tint = s.tint
        } else {
            setLabel(rangeLabel, s.range.uppercased(), size: 9.5 * scale, weight: .medium,
                     color: Theme.secondary, kern: 1.1)
            setLabel(clockLabel, s.clock, size: 9.5 * scale, weight: .medium,
                     color: Theme.tertiary, kern: 0.9, monospaced: true)
            setLabel(titleLabel, s.title, size: 15 * scale, weight: .medium,
                     color: Theme.text, kern: -0.2)
            setLabel(countdownLabel, s.countdown, size: 34 * scale, weight: .ultraLight,
                     color: s.warning ? s.tint : Theme.text, kern: 0.5, monospaced: true)
            setLabel(captionLabel, s.caption.uppercased(), size: 8.5 * scale, weight: .semibold,
                     color: Theme.tertiary, kern: 1.2)
            if let n = s.nudge {
                setLabel(nextLabel, n.uppercased(), size: 9 * scale, weight: .semibold,
                         color: Theme.urgent, kern: 1.0)
                nextLabel.isHidden = false
            } else {
                setLabel(nextLabel, s.next.uppercased(), size: 9 * scale, weight: .medium,
                         color: Theme.tertiary, kern: 1.0)
                nextLabel.isHidden = s.next.isEmpty
            }

            bar.progress = s.progress
            bar.tint = s.tint
        }

        if let e = s.errorText {
            setLabel(errorLabel, "\u{26A0} " + e, size: 9.5 * scale, weight: .medium,
                     color: Theme.warn, kern: 0.3)
            errorLabel.isHidden = false
        } else {
            errorLabel.isHidden = true
        }
    }

    func desiredSize() -> NSSize {
        let width: CGFloat = (compact ? 236 : 296) * scale
        layoutSubtreeIfNeeded()
        let fitting = outer.fittingSize.height + 30 * scale
        let floorH: CGFloat = (compact ? 52 : 148) * scale
        return NSSize(width: width, height: max(floorH, ceil(fitting)))
    }
}

// ============================================================================
// MARK: - Panel
// ============================================================================

final class HUDPanel: NSPanel {
    init(contentView view: NSView, level: NSWindow.Level) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 150),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        self.contentView = view
        self.level = level
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        animationBehavior = .none
        // Follow across every Space, sit above other apps' full-screen windows,
        // don't participate in Cmd-Tab / Exposé cycling.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }   // needed for right-click menus
    override var canBecomeMain: Bool { false }
}

// ============================================================================
// MARK: - Schedule file watching
// ============================================================================

final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var pollTimer: Timer?
    private var lastMTime: Date?
    private var debounce: DispatchWorkItem?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        start()
        // Safety net: many editors replace the file atomically (rename), which kills
        // the vnode source. Poll mtime every 3s regardless.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        lastMTime = modTime()
    }

    private func modTime() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private func poll() {
        guard let m = modTime() else { return }
        if lastMTime == nil || m > lastMTime! {
            lastMTime = m
            fire()
        }
        if source == nil { start() }   // re-arm after atomic replace
    }

    private func start() {
        stopSource()
        fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        s.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = s.data
            self.fire()
            if flags.contains(.rename) || flags.contains(.delete) {
                self.stopSource()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.start() }
            }
        }
        s.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
            self?.fd = -1
        }
        s.resume()
        source = s
    }

    private func fire() {
        debounce?.cancel()
        let w = DispatchWorkItem { [weak self] in
            self?.lastMTime = self?.modTime()
            self?.onChange()
        }
        debounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    private func stopSource() { source?.cancel(); source = nil }
    deinit { stopSource(); pollTimer?.invalidate() }
}

// ============================================================================
// MARK: - Pause / resume / skip
// ============================================================================

/// A transient, user-driven deviation from the wall-clock schedule.
///
/// Exactly one block instance can be paused or extended at a time; any number
/// can be skipped. Persisted to UserDefaults so a relaunch mid-pause is not
/// silently lost, but discarded if it is stale (paused overnight, etc).
struct OverrideState: Codable {
    /// The block instance being paused / extended. Nil means none.
    var blockKey: String? = nil
    /// Pause time already banked against this block (seconds).
    var shift: TimeInterval = 0
    /// Non-nil while the clock is actually frozen.
    var pausedAt: Date? = nil
    /// Block instances the user dismissed. Stable keys, not titles.
    var skipped: [String] = []
    /// Last write, used to discard stale state on launch.
    var savedAt: Date = Date()

    /// Ceiling on how far one block may be pushed. Past this the pause is
    /// abandoned and the HUD snaps back to real time rather than drifting
    /// arbitrarily far from the schedule.
    static let maxShift: TimeInterval = 4 * 3600
    /// Persisted state older than this is thrown away.
    static let staleAfter: TimeInterval = 12 * 3600
    /// Cap on remembered skips so the list cannot grow without bound.
    static let maxSkipped = 200

    var isPaused: Bool { pausedAt != nil }
    var isActive: Bool { blockKey != nil || !skipped.isEmpty }

    /// Banked shift plus the pause currently in progress, clamped to maxShift.
    func liveShift(at now: Date) -> TimeInterval {
        let live = pausedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
        return min(OverrideState.maxShift, shift + live)
    }

    /// How long the current pause has been running (0 if not paused).
    func pauseElapsed(at now: Date) -> TimeInterval {
        pausedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
    }

    mutating func clearHold() { blockKey = nil; shift = 0; pausedAt = nil }
    mutating func clearAll()  { clearHold(); skipped.removeAll() }

    mutating func skip(_ key: String) {
        guard !skipped.contains(key) else { return }
        skipped.append(key)
        if skipped.count > OverrideState.maxSkipped {
            skipped.removeFirst(skipped.count - OverrideState.maxSkipped)
        }
    }
}

// ============================================================================
// MARK: - Distraction monitor
// ============================================================================

struct Distractions: Codable {
    var enabled: Bool?
    /// Substrings matched against the frontmost app's name or bundle id.
    var apps: [String]?
    /// Substrings matched against the frontmost browser's active tab URL.
    var sites: [String]?
    /// Seconds of continuous drift before the HUD reacts. A quick glance is fine.
    var graceSeconds: Double?
    /// Minutes before the nudge firms up and chimes once.
    var escalateAfterMinutes: Double?
    /// Only nudge while a block is actually running (never during free time).
    var onlyDuringBlocks: Bool?
    /// Block titles where these sites are legitimate work. Substring match.
    var allowDuringTitles: [String]?
    var chimeOnEscalate: Bool?
    /// Tail of the nudge line, e.g. "back to it?"
    var message: String?
    /// Log every poll to taskhud.log while tuning.
    var debug: Bool?
}

/// Notices when the frontmost app — or the frontmost browser's active tab —
/// matches something the user called a distraction.
///
/// App matching needs no permission. Tab URLs need Automation permission, which
/// macOS only grants to a real .app bundle; if it is denied the monitor silently
/// degrades to app-only matching rather than nagging about permissions.
final class DistractionMonitor {

    private(set) var label: String?          // what matched, e.g. "instagram.com"
    private(set) var since: Date?            // when the current drift began
    private(set) var automationDenied = false

    private var cfg = Distractions()
    private var lastAppPoll = Date.distantPast
    private var lastURLPoll = Date.distantPast
    private var cachedURL: String?
    private var scriptInFlight = false
    private var retryAutomationAt = Date.distantPast
    private var locked = false

    private let queue = DispatchQueue(label: "taskhud.distraction", qos: .utility)

    /// bundle id -> (application name, uses Chromium's AppleScript vocabulary)
    private static let browsers: [String: (String, Bool)] = [
        "com.apple.Safari":              ("Safari", false),
        "com.apple.SafariTechnologyPreview": ("Safari Technology Preview", false),
        "com.google.Chrome":             ("Google Chrome", true),
        "com.google.Chrome.beta":        ("Google Chrome Beta", true),
        "com.brave.Browser":             ("Brave Browser", true),
        "com.microsoft.edgemac":         ("Microsoft Edge", true),
        "company.thebrowser.Browser":    ("Arc", true),
        "com.vivaldi.Vivaldi":           ("Vivaldi", true),
        "com.operasoftware.Opera":       ("Opera", true)
        // Firefox exposes no scriptable tab URL; it falls back to app matching.
    ]

    init() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"),
                        object: nil, queue: .main) { [weak self] _ in
            self?.locked = true; self?.reset()
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"),
                        object: nil, queue: .main) { [weak self] _ in self?.locked = false }
    }

    func configure(_ d: Distractions?) {
        cfg = d ?? Distractions()
        if !(cfg.enabled ?? false) { reset() }
    }

    var isEnabled: Bool {
        (cfg.enabled ?? false) && !((cfg.apps ?? []).isEmpty && (cfg.sites ?? []).isEmpty)
    }
    var graceSeconds: Double { cfg.graceSeconds ?? 20 }
    var escalateAfter: Double { (cfg.escalateAfterMinutes ?? 5) * 60 }
    var onlyDuringBlocks: Bool { cfg.onlyDuringBlocks ?? true }
    var chimeOnEscalate: Bool { cfg.chimeOnEscalate ?? true }
    var debug: Bool { cfg.debug ?? false }

    /// True if the currently-running block legitimises these sites.
    func isAllowed(blockTitle: String?) -> Bool {
        guard let t = blockTitle?.lowercased() else { return false }
        return (cfg.allowDuringTitles ?? []).contains { t.contains($0.lowercased()) }
    }

    func reset() { label = nil; since = nil; cachedURL = nil }

    /// Seconds spent continuously on the current distraction (0 if none).
    func elapsed(at now: Date) -> Double {
        guard let s = since else { return 0 }
        return max(0, now.timeIntervalSince(s))
    }

    /// Past grace, so the HUD should be showing the nudge.
    func isNudging(at now: Date) -> Bool {
        label != nil && elapsed(at: now) >= graceSeconds
    }

    // ---- polling -----------------------------------------------------------

    func poll(now: Date) {
        guard isEnabled, !locked else { reset(); return }
        guard now.timeIntervalSince(lastAppPoll) >= 2 else { return }
        lastAppPoll = now

        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        let name = front.localizedName ?? ""
        let bid  = front.bundleIdentifier ?? ""
        if debug {
            let u = cachedURL ?? "-"
            let l = label ?? "-"
            let isBrowser = DistractionMonitor.browsers[bid] != nil
            Log.info("front=\(name) [\(bid)] browser=\(isBrowser) url=\(u) label=\(l) elapsed=\(Int(elapsed(at: now)))s")
        }

        // App-level match needs no permission and wins immediately.
        if let hit = (cfg.apps ?? []).first(where: {
            name.localizedCaseInsensitiveContains($0) || bid.localizedCaseInsensitiveContains($0)
        }) {
            note(hit, now: now)
            return
        }

        // Browser: ask for the active tab, asynchronously.
        if let (appName, chromium) = DistractionMonitor.browsers[bid],
           !(cfg.sites ?? []).isEmpty {
            if now.timeIntervalSince(lastURLPoll) >= 3, !scriptInFlight, now >= retryAutomationAt {
                lastURLPoll = now
                fetchURL(appName: appName, chromium: chromium)
            }
            if let url = cachedURL,
               let hit = (cfg.sites ?? []).first(where: { url.localizedCaseInsensitiveContains($0) }) {
                note(hit, now: now)
                return
            }
            clear()
            return
        }

        cachedURL = nil
        clear()
    }

    private func note(_ hit: String, now: Date) {
        if label != hit {
            label = hit
            since = now          // switching distractions restarts the grace period
        }
    }

    private func clear() {
        if label != nil { reset() }
    }

    // ---- AppleScript -------------------------------------------------------

    /// Runs `osascript` as a subprocess rather than NSAppleScript in-process.
    /// NSAppleScript needs a run loop on its thread to receive the Apple Event
    /// reply, which a bare DispatchQueue does not have — it silently returns
    /// nothing. A subprocess is attributed to this app for permission purposes,
    /// so the existing Automation grant still applies, and a wedged browser can
    /// be killed on a timeout instead of stalling the HUD.
    private func fetchURL(appName: String, chromium: Bool) {
        scriptInFlight = true
        let source = chromium
            ? "tell application \"\(appName)\" to return URL of active tab of front window"
            : "tell application \"\(appName)\" to return URL of front document"

        queue.async { [weak self] in
            var url: String?
            var errText = ""

            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", source]
            let out = Pipe(), errPipe = Pipe()
            p.standardOutput = out
            p.standardError = errPipe

            do {
                try p.run()
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.global(qos: .utility).async { p.waitUntilExit(); sem.signal() }
                if sem.wait(timeout: .now() + 4) == .timedOut {
                    p.terminate()
                    errText = "timeout"
                }
                let o = out.fileHandleForReading.readDataToEndOfFile()
                let e = errPipe.fileHandleForReading.readDataToEndOfFile()
                url = String(data: o, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if errText.isEmpty { errText = String(data: e, encoding: .utf8) ?? "" }
            } catch {
                errText = error.localizedDescription
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.scriptInFlight = false

                if let u = url, !u.isEmpty, u.contains("://") {
                    self.cachedURL = u
                    self.automationDenied = false
                    if self.debug { Log.info("tab url: \(u)") }
                    return
                }
                self.cachedURL = nil
                if errText.contains("-1743") || errText.contains("Not authorized")
                    || errText.contains("-1744") {
                    if !self.automationDenied {
                        Log.error("Automation permission missing for \(appName). Allow it under "
                                + "System Settings > Privacy & Security > Automation > TaskHUD.")
                    }
                    self.automationDenied = true
                    self.retryAutomationAt = Date().addingTimeInterval(300)
                } else if !errText.isEmpty, self.debug {
                    Log.info("osascript(\(appName)): \(errText.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }
        }
    }
}

// ============================================================================
// MARK: - Adherence store
// ============================================================================

enum Mark: String, Codable {
    case done, missed
    var glyph: String { self == .done ? "✓" : "✗" }
}

/// One marked block instance. Title/start/end are denormalised on purpose so
/// history survives later edits to schedule.json.
struct MarkRecord: Codable {
    var day: String        // "2026-08-02"
    var title: String
    var start: String      // "HH:mm"
    var end: String        // "HH:mm"
    var status: String     // Mark.rawValue
    var markedAt: Date

    var mark: Mark? { Mark(rawValue: status) }
}

/// How many blocks the schedule held on a given day, captured at mark time so
/// coverage can still be computed after the schedule changes.
struct DayMeta: Codable { var planned: Int }

struct AdherenceDB: Codable {
    var records: [String: MarkRecord] = [:]
    var days: [String: DayMeta] = [:]
}

/// Local, file-backed adherence log. Written atomically so a crash mid-write
/// cannot truncate the history.
final class AdherenceStore {

    private(set) var db = AdherenceDB()
    private let url: URL
    private(set) var lastError: String?

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    static let prettyDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f
    }()

    init(url: URL) {
        self.url = url
        load()
    }

    static func id(day: String, start: String, title: String) -> String {
        "\(day)|\(start)|\(title)"
    }

    static func id(for block: ResolvedBlock) -> String {
        id(day: dayFormatter.string(from: block.start),
           start: Fmt.hm.string(from: block.start),
           title: block.title)
    }

    // ---- persistence -------------------------------------------------------

    private func load() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else { return }
            db = try JSONDecoder().decode(AdherenceDB.self, from: data)
            lastError = nil
            Log.info("adherence: \(db.records.count) records loaded")
        } catch {
            lastError = error.localizedDescription
            Log.error("adherence load failed: \(error.localizedDescription)")
            // Keep a copy of whatever could not be parsed rather than clobbering it.
            let backup = url.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: url, to: backup)
        }
    }

    private func save() {
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(db)
            let tmp = url.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
            if FileManager.default.fileExists(atPath: tmp.path) {
                try? FileManager.default.removeItem(at: tmp)
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            Log.error("adherence save failed: \(error.localizedDescription)")
        }
    }

    // ---- mutation ----------------------------------------------------------

    func mark(_ block: ResolvedBlock, as m: Mark?, plannedThatDay: Int?) {
        let day = AdherenceStore.dayFormatter.string(from: block.start)
        let key = AdherenceStore.id(for: block)
        if let m {
            db.records[key] = MarkRecord(
                day: day, title: block.title,
                start: Fmt.hm.string(from: block.start),
                end: Fmt.hm.string(from: block.end),
                status: m.rawValue, markedAt: Date())
        } else {
            db.records.removeValue(forKey: key)
        }
        if let p = plannedThatDay, p > 0 { db.days[day] = DayMeta(planned: p) }
        save()
    }

    func mark(for block: ResolvedBlock) -> Mark? {
        db.records[AdherenceStore.id(for: block)]?.mark
    }

    // ---- queries -----------------------------------------------------------

    func records(on day: String) -> [MarkRecord] {
        db.records.values.filter { $0.day == day }.sorted { $0.start < $1.start }
    }

    struct DayStat {
        let day: String
        let done: Int
        let missed: Int
        let planned: Int
        var marked: Int { done + missed }
        /// nil when the day has no marks at all — an unrecorded day is not a
        /// zero-adherence day, and must not be drawn as one.
        var rate: Double? { marked == 0 ? nil : Double(done) / Double(marked) }
        var coverage: Double? { planned == 0 ? nil : Double(marked) / Double(planned) }
    }

    func stat(for day: String) -> DayStat {
        let recs = records(on: day)
        return DayStat(day: day,
                       done: recs.filter { $0.status == Mark.done.rawValue }.count,
                       missed: recs.filter { $0.status == Mark.missed.rawValue }.count,
                       planned: db.days[day]?.planned ?? 0)
    }

    /// Last `n` days ending today, oldest first.
    func recentStats(_ n: Int) -> [DayStat] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<n).reversed().compactMap { off -> DayStat? in
            guard let d = cal.date(byAdding: .day, value: -off, to: today) else { return nil }
            return stat(for: AdherenceStore.dayFormatter.string(from: d))
        }
    }

    /// Consecutive days at or above `threshold`, walking back from today.
    /// Today is skipped rather than breaking the streak if nothing is marked yet.
    func streak(threshold: Double = 0.8) -> Int {
        let cal = Calendar.current
        var day = cal.startOfDay(for: Date())
        var count = 0
        var first = true
        for _ in 0..<400 {
            let s = stat(for: AdherenceStore.dayFormatter.string(from: day))
            if let r = s.rate {
                if r >= threshold { count += 1 } else { break }
            } else if !first {
                break
            }
            first = false
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return count
    }

    /// Per-activity totals across the whole log, best performers first.
    func byActivity(lastDays: Int? = nil) -> [(title: String, done: Int, missed: Int)] {
        var cutoff: String? = nil
        if let lastDays, let d = Calendar.current.date(byAdding: .day, value: -lastDays, to: Date()) {
            cutoff = AdherenceStore.dayFormatter.string(from: d)
        }
        var agg: [String: (Int, Int)] = [:]
        for r in db.records.values {
            if let c = cutoff, r.day < c { continue }
            var e = agg[r.title] ?? (0, 0)
            if r.status == Mark.done.rawValue { e.0 += 1 } else { e.1 += 1 }
            agg[r.title] = e
        }
        return agg.map { (title: $0.key, done: $0.value.0, missed: $0.value.1) }
            .sorted {
                let a = $0.done + $0.missed == 0 ? 0 : Double($0.done) / Double($0.done + $0.missed)
                let b = $1.done + $1.missed == 0 ? 0 : Double($1.done) / Double($1.done + $1.missed)
                return a == b ? $0.title < $1.title : a > b
            }
    }
}

// ============================================================================
// MARK: - Review panel — day list
// ============================================================================

/// One row: time, title, and a two-button tri-state control.
/// Clicking the already-selected button clears the mark.
final class ReviewRow: NSView {
    private let timeLabel  = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let doneBtn    = NSButton()
    private let missBtn    = NSButton()

    let block: ResolvedBlock
    private var current: Mark?
    private let onChange: (ResolvedBlock, Mark?) -> Void
    private let isFuture: Bool

    override var isFlipped: Bool { true }

    init(block: ResolvedBlock, mark: Mark?, isFuture: Bool,
         onChange: @escaping (ResolvedBlock, Mark?) -> Void) {
        self.block = block
        self.current = mark
        self.onChange = onChange
        self.isFuture = isFuture
        super.init(frame: .zero)
        build()
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func styleButton(_ b: NSButton, _ glyph: String) {
        b.title = glyph
        b.bezelStyle = .inline
        b.isBordered = false
        b.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        b.target = self
        b.wantsLayer = true
        b.layer?.cornerRadius = 5
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 30).isActive = true
        b.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    private func build() {
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        timeLabel.textColor = Theme.secondary
        timeLabel.stringValue = "\(Fmt.hm.string(from: block.start))–\(Fmt.hm.string(from: block.end))"
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.widthAnchor.constraint(equalToConstant: 92).isActive = true

        titleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        titleLabel.textColor = isFuture ? Theme.tertiary : Theme.text
        titleLabel.stringValue = block.title
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.usesSingleLineMode = true
        titleLabel.setContentCompressionResistancePriority(.init(200), for: .horizontal)

        styleButton(doneBtn, "✓"); doneBtn.action = #selector(tapDone)
        styleButton(missBtn, "✗"); missBtn.action = #selector(tapMiss)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let row = NSStackView(views: [timeLabel, titleLabel, spacer, doneBtn, missBtn])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            heightAnchor.constraint(equalToConstant: 34)
        ])
    }

    private func refresh() {
        func paint(_ b: NSButton, active: Bool, color: NSColor) {
            b.layer?.backgroundColor = active ? color.withAlphaComponent(0.22).cgColor
                                              : NSColor.clear.cgColor
            b.contentTintColor = active ? color : Theme.tertiary
            b.attributedTitle = NSAttributedString(
                string: b.title,
                attributes: [.foregroundColor: active ? color : Theme.tertiary,
                             .font: NSFont.systemFont(ofSize: 14, weight: active ? .bold : .medium)])
        }
        paint(doneBtn, active: current == .done,   color: Theme.accent)
        paint(missBtn, active: current == .missed, color: Theme.urgent)
    }

    @objc private func tapDone() { set(current == .done ? nil : .done) }
    @objc private func tapMiss() { set(current == .missed ? nil : .missed) }

    private func set(_ m: Mark?) {
        current = m
        refresh()
        onChange(block, m)
    }
}

// ============================================================================
// MARK: - Dashboard views
// ============================================================================

/// One bar per day. Days with no marks are drawn as a faint stub so a gap in
/// the record never reads as a zero-adherence day.
final class BarChart: NSView {
    var stats: [AdherenceStore.DayStat] = [] { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard !stats.isEmpty, bounds.width > 0 else { return }
        let n = CGFloat(stats.count)
        let gap: CGFloat = 3
        let w = max(2, (bounds.width - gap * (n - 1)) / n)
        let base = bounds.height - 14
        let cal = Calendar.current

        for (i, s) in stats.enumerated() {
            let x = CGFloat(i) * (w + gap)
            if let r = s.rate {
                let h = max(2, base * CGFloat(r))
                let color: NSColor = r >= 0.8 ? Theme.accent : (r >= 0.5 ? Theme.warn : Theme.urgent)
                color.setFill()
                NSRect(x: x, y: base - h, width: w, height: h).fill()
            } else {
                Theme.rule.setFill()
                NSRect(x: x, y: base - 2, width: w, height: 2).fill()
            }
            // Label the first day of each week.
            if let d = AdherenceStore.dayFormatter.date(from: s.day),
               cal.component(.weekday, from: d) == 2 {
                let t = NSAttributedString(string: "\(cal.component(.day, from: d))", attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium),
                    .foregroundColor: Theme.tertiary])
                t.draw(at: NSPoint(x: x, y: base + 3))
            }
        }
        Theme.rule.setFill()
        NSRect(x: 0, y: base, width: bounds.width, height: 1).fill()
    }
}

/// One activity's lifetime record with an inline proportion bar.
final class ActivityRow: NSView {
    override var isFlipped: Bool { true }
    private let title: String
    private let done: Int
    private let missed: Int

    init(title: String, done: Int, missed: Int) {
        self.title = title; self.done = done; self.missed = missed
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 32).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let total = done + missed
        let rate = total == 0 ? 0 : Double(done) / Double(total)

        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
            .foregroundColor: Theme.text
        ]).draw(in: NSRect(x: 0, y: 2, width: bounds.width - 96, height: 15))

        let right = String(format: "%d/%d  ·  %.0f%%", done, total, rate * 100)
        let a = NSAttributedString(string: right, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: Theme.secondary])
        a.draw(at: NSPoint(x: bounds.width - a.size().width, y: 3))

        let y = bounds.height - 11
        Theme.rule.setFill()
        NSRect(x: 0, y: y, width: bounds.width, height: 2).fill()
        let color: NSColor = rate >= 0.8 ? Theme.accent : (rate >= 0.5 ? Theme.warn : Theme.urgent)
        color.setFill()
        NSRect(x: 0, y: y, width: bounds.width * CGFloat(rate), height: 2).fill()
    }
}

/// A large number with a caption beneath it.
final class StatTile: NSView {
    override var isFlipped: Bool { true }
    init(value: String, caption: String, tint: NSColor) {
        super.init(frame: .zero)
        let v = NSTextField(labelWithString: "")
        v.font = NSFont.monospacedDigitSystemFont(ofSize: 26, weight: .ultraLight)
        v.attributedStringValue = NSAttributedString(string: value, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 26, weight: .ultraLight),
            .foregroundColor: tint])
        let c = NSTextField(labelWithString: "")
        c.font = NSFont.systemFont(ofSize: 8.5, weight: .semibold)
        c.attributedStringValue = NSAttributedString(string: caption.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 8.5, weight: .semibold),
            .foregroundColor: Theme.tertiary, .kern: 1.2])
        let s = NSStackView(views: [v, c])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 1
        s.translatesAutoresizingMaskIntoConstraints = false
        addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: leadingAnchor),
            s.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            s.topAnchor.constraint(equalTo: topAnchor),
            s.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

// ============================================================================
// MARK: - Review window
// ============================================================================

final class ReviewWindow: NSWindow {

    private let store: AdherenceStore
    private let engine: ScheduleEngine

    private var day: Date = Calendar.current.startOfDay(for: Date())
    private var mode = 0                       // 0 = day list, 1 = dashboard

    private let modeControl = NSSegmentedControl(
        labels: ["Day", "Dashboard"], trackingMode: .selectOne, target: nil, action: nil)
    private let dayLabel = NSTextField(labelWithString: "")
    private let summary  = NSTextField(labelWithString: "")
    private let prevBtn  = NSButton(title: "‹", target: nil, action: nil)
    private let nextBtn  = NSButton(title: "›", target: nil, action: nil)
    private let todayBtn = NSButton(title: "Today", target: nil, action: nil)
    private var navRow: NSStackView!
    private let scroll = NSScrollView()
    private let body = NSStackView()

    init(store: AdherenceStore, engine: ScheduleEngine) {
        self.store = store
        self.engine = engine
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                   styleMask: [.titled, .closable, .utilityWindow, .resizable],
                   backing: .buffered, defer: false)
        title = "Adherence"
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        minSize = NSSize(width: 380, height: 320)
        appearance = NSAppearance(named: .aqua)
        build()
        reload()
    }

    // ---- chrome ------------------------------------------------------------

    private func build() {
        let root = NSView()
        root.wantsLayer = true
        contentView = root

        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.translatesAutoresizingMaskIntoConstraints = false

        for b in [prevBtn, nextBtn, todayBtn] {
            b.bezelStyle = .rounded
            b.target = self
            b.font = NSFont.systemFont(ofSize: 11)
        }
        prevBtn.action  = #selector(prevDay)
        nextBtn.action  = #selector(nextDay)
        todayBtn.action = #selector(goToday)
        prevBtn.translatesAutoresizingMaskIntoConstraints = false
        nextBtn.translatesAutoresizingMaskIntoConstraints = false
        prevBtn.widthAnchor.constraint(equalToConstant: 28).isActive = true
        nextBtn.widthAnchor.constraint(equalToConstant: 28).isActive = true

        dayLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        dayLabel.textColor = Theme.text
        summary.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        summary.textColor = Theme.secondary

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        navRow = NSStackView(views: [prevBtn, nextBtn, dayLabel, spacer, summary, todayBtn])
        navRow.orientation = .horizontal
        navRow.spacing = 8
        navRow.alignment = .centerY

        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 2
        body.translatesAutoresizingMaskIntoConstraints = false

        scroll.documentView = body
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [modeControl, navRow, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            modeControl.widthAnchor.constraint(equalTo: stack.widthAnchor),
            navRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            body.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -4)
        ])
    }

    // ---- actions -----------------------------------------------------------

    @objc private func modeChanged() { mode = modeControl.selectedSegment; reload() }
    @objc private func prevDay() { shiftDay(-1) }
    @objc private func nextDay() { shiftDay(1) }
    @objc private func goToday() { day = Calendar.current.startOfDay(for: Date()); reload() }

    private func shiftDay(_ n: Int) {
        guard let d = Calendar.current.date(byAdding: .day, value: n, to: day) else { return }
        // Never navigate into the future beyond today: nothing there to mark.
        let today = Calendar.current.startOfDay(for: Date())
        day = min(d, today)
        reload()
    }

    /// Called by the controller when the schedule or a mark changes elsewhere.
    func reload() {
        body.arrangedSubviews.forEach { $0.removeFromSuperview() }
        navRow.isHidden = (mode == 1)
        if mode == 0 { buildDayList() } else { buildDashboard() }
    }

    // ---- day list ----------------------------------------------------------

    private func buildDayList() {
        let cal = Calendar.current
        let isToday = cal.isDateInToday(day)
        dayLabel.stringValue = isToday ? "Today" : AdherenceStore.prettyDay.string(from: day)
        nextBtn.isEnabled = !isToday

        let blocks = engine.blocks(on: day)
        let dayStr = AdherenceStore.dayFormatter.string(from: day)
        let now = Date()

        guard !blocks.isEmpty else {
            summary.stringValue = ""
            body.addArrangedSubview(hint("No blocks scheduled on this day."))
            return
        }

        let s = store.stat(for: dayStr)
        summary.stringValue = s.marked == 0
            ? "\(blocks.count) blocks · unmarked"
            : String(format: "%d/%d done · %.0f%%", s.done, s.marked, (s.rate ?? 0) * 100)

        for b in blocks {
            let future = b.end > now
            let row = ReviewRow(block: b, mark: store.mark(for: b), isFuture: future) { [weak self] blk, m in
                guard let self else { return }
                self.store.mark(blk, as: m, plannedThatDay: blocks.count)
                self.refreshSummary(dayStr, total: blocks.count)
            }
            body.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        body.addArrangedSubview(hint("Blocks still to come are dimmed — you can mark them anyway."))
    }

    private func refreshSummary(_ dayStr: String, total: Int) {
        let s = store.stat(for: dayStr)
        summary.stringValue = s.marked == 0
            ? "\(total) blocks · unmarked"
            : String(format: "%d/%d done · %.0f%%", s.done, s.marked, (s.rate ?? 0) * 100)
    }

    private func hint(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = NSFont.systemFont(ofSize: 10)
        l.textColor = Theme.tertiary
        return l
    }

    private func heading(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.attributedStringValue = NSAttributedString(string: t.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 8.5, weight: .semibold),
            .foregroundColor: Theme.tertiary, .kern: 1.3])
        return l
    }

    // ---- dashboard ---------------------------------------------------------

    private func buildDashboard() {
        let stats = store.recentStats(30)
        let done = stats.reduce(0) { $0 + $1.done }
        let missed = stats.reduce(0) { $0 + $1.missed }
        let rate = (done + missed) == 0 ? 0 : Double(done) / Double(done + missed)
        let activeDays = stats.filter { $0.marked > 0 }.count

        let tiles = NSStackView(views: [
            StatTile(value: (done + missed) == 0 ? "—" : String(format: "%.0f%%", rate * 100),
                     caption: "30-day adherence",
                     tint: rate >= 0.8 ? Theme.accent : (rate >= 0.5 ? Theme.warn : Theme.urgent)),
            StatTile(value: "\(store.streak())", caption: "day streak", tint: Theme.accent),
            StatTile(value: "\(done)", caption: "blocks done", tint: Theme.text),
            StatTile(value: "\(activeDays)", caption: "days logged", tint: Theme.secondary)
        ])
        tiles.orientation = .horizontal
        tiles.distribution = .fillEqually
        tiles.spacing = 12
        body.addArrangedSubview(tiles)
        tiles.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true

        body.setCustomSpacing(18, after: tiles)
        let h1 = heading("Last 30 days")
        body.addArrangedSubview(h1)

        let chart = BarChart()
        chart.stats = stats
        chart.translatesAutoresizingMaskIntoConstraints = false
        chart.heightAnchor.constraint(equalToConstant: 110).isActive = true
        body.addArrangedSubview(chart)
        chart.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        body.setCustomSpacing(18, after: chart)

        body.addArrangedSubview(heading("By activity — last 30 days"))
        let rows = store.byActivity(lastDays: 30)
        if rows.isEmpty {
            body.addArrangedSubview(hint("Nothing marked yet. Mark a few blocks on the Day tab."))
        }
        for r in rows {
            let row = ActivityRow(title: r.title, done: r.done, missed: r.missed)
            body.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        body.setCustomSpacing(16, after: body.arrangedSubviews.last ?? chart)
        body.addArrangedSubview(hint("Adherence counts done ÷ marked. Unmarked blocks are ignored, never counted as missed."))
    }
}

// ============================================================================
// MARK: - App controller
// ============================================================================

final class AppController: NSObject, NSWindowDelegate {

    private let engine = ScheduleEngine()
    private var panel: HUDPanel!
    private var content: HUDContentView!
    private var statusItem: NSStatusItem!
    private var tick: Timer?
    private var watcher: FileWatcher?
    private var sound: NSSound?

    private var firedAlerts = Set<String>()
    private var lastCurrentKey: String?
    private var hidden = false

    private var store: AdherenceStore!
    private let distraction = DistractionMonitor()
    private var nudgeChimed = false
    private var reloadRetries = 0
    private var review: ReviewWindow?

    private var override = OverrideState()
    private let overrideKey = "taskhud.override"

    // ---- Override persistence ---------------------------------------------

    private func loadOverride() {
        guard let data = UserDefaults.standard.data(forKey: overrideKey),
              let o = try? JSONDecoder().decode(OverrideState.self, from: data) else { return }
        guard Date().timeIntervalSince(o.savedAt) < OverrideState.staleAfter else {
            Log.info("discarding stale override state")
            UserDefaults.standard.removeObject(forKey: overrideKey)
            return
        }
        override = o
        if override.isPaused { Log.info("restored a paused session") }
    }

    private func saveOverride() {
        override.savedAt = Date()
        if let d = try? JSONEncoder().encode(override) {
            UserDefaults.standard.set(d, forKey: overrideKey)
        }
    }

    // ---- Override-aware schedule resolution --------------------------------

    /// The block the HUD should show, honouring pause / extend / skip.
    /// Returns the block plus its effective end (real end + accumulated shift).
    private func activeBlock(at now: Date) -> (block: ResolvedBlock, end: Date)? {
        if let key = override.blockKey {
            // A pause that ran past the cap is abandoned rather than drifting.
            if override.isPaused, override.liveShift(at: now) >= OverrideState.maxShift {
                Log.info("pause exceeded \(Int(OverrideState.maxShift / 3600))h cap — snapping back")
                override.clearHold(); saveOverride()
            } else if override.skipped.contains(key) {
                override.clearHold(); saveOverride()
            } else if let b = engine.block(key: key, at: now) {
                if now >= b.start && now < b.end { return (b, b.end) }
                // The block reached its real end. A pause freezes the display,
                // it never pushes a wall-clock block into the next one, so the
                // schedule takes back over here and the next block chimes.
                Log.info("held block ended — auto-resuming")
                override.clearHold(); saveOverride()
            } else {
                // Key no longer resolves: schedule was edited, day rolled over,
                // or the timezone changed. Drop the hold.
                Log.info("held block no longer exists — clearing hold")
                override.clearHold(); saveOverride()
            }
        }
        if let b = engine.current(at: now), !override.skipped.contains(b.key) {
            return (b, b.end)
        }
        return nil
    }

    /// Next upcoming block, ignoring anything the user skipped.
    private func nextBlock(after now: Date) -> ResolvedBlock? {
        engine.resolved(around: now).first { $0.start > now && !override.skipped.contains($0.key) }
    }


    private let dirURL  = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".taskhud")
    private var fileURL: URL { dirURL.appendingPathComponent("schedule.json") }

    private let posKey = "taskhud.origin"
    private let hiddenKey = "taskhud.hidden"

    // ---- Lifecycle ---------------------------------------------------------

    func start() {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon, no menu bar takeover
        ensureScheduleFile()
        engine.load(from: fileURL)
        store = AdherenceStore(url: dirURL.appendingPathComponent("adherence.json"))

        content = HUDContentView(scale: CGFloat(engine.settings.scale ?? 1.0))
        panel = HUDPanel(contentView: content, level: windowLevel())
        panel.delegate = self
        panel.alphaValue = CGFloat(engine.settings.opacity ?? 0.96)
        panel.ignoresMouseEvents = engine.settings.clickThrough ?? false
        content.setCompact(engine.settings.compact ?? false)
        distraction.configure(engine.settings.distractions)

        restorePosition()
        hidden = UserDefaults.standard.bool(forKey: hiddenKey)
        if !hidden { panel.orderFrontRegardless() }

        loadOverride()
        content.onDoubleClick = { [weak self] in self?.togglePause() }
        content.onReviewTap  = { [weak self] in self?.openReview() }
        buildStatusItem()

        watcher = FileWatcher(url: fileURL) { [weak self] in self?.reload(userInitiated: false) }

        tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.update() }
        tick?.tolerance = 0.1
        RunLoop.main.add(tick!, forMode: .common)   // keep ticking during window drags/menus

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.engine.invalidate(); self?.update(); self?.clampIntoScreens()
        }
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.hidden else { return }
            self.panel.orderFrontRegardless()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.clampIntoScreens()
        }
        // Timezone changes (travel, DST) must invalidate the resolved-day cache.
        NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.engine.invalidate(); self?.update()
        }

        update()
    }

    private func windowLevel() -> NSWindow.Level {
        switch (engine.settings.windowLevel ?? "screenSaver").lowercased() {
        case "float", "floating": return .floating
        case "status", "statusbar": return .statusBar
        default: return .screenSaver      // sits above other apps' full-screen windows
        }
    }

    // ---- Schedule file bootstrap ------------------------------------------

    private func ensureScheduleFile() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dirURL.path) {
            try? fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
        }
        guard !fm.fileExists(atPath: fileURL.path) else { return }
        let sample = """
        {
          "settings": {
            "warnMinutes": [10, 5, 1],
            "sound": true,
            "opacity": 0.96,
            "compact": false,
            "showSeconds": true,
            "windowLevel": "screenSaver",
            "clickThrough": false,
            "scale": 1.0
          },
          "blocks": [
            { "title": "Deep work — Family OS",  "start": "09:00", "end": "11:00", "days": ["weekdays"], "color": "#E6E1D7" },
            { "title": "Genopty — F82 fix",      "start": "11:00", "end": "12:00", "days": ["weekdays"], "color": "#B9C2C7" },
            { "title": "Lunch + walk",           "start": "12:00", "end": "13:00", "color": "#C7B08A" },
            { "title": "Shallow work / inbox",   "start": "13:00", "end": "14:30", "days": ["weekdays"], "color": "#AFAAB8" },
            { "title": "Deep work — block 2",    "start": "14:30", "end": "17:00", "days": ["weekdays"], "color": "#E6E1D7" },
            { "title": "Family time",            "start": "18:00", "end": "21:00", "color": "#C9A9A0" },
            { "title": "Wind down",              "start": "21:30", "end": "22:30", "color": "#8A8F94" }
          ]
        }
        """
        try? sample.data(using: .utf8)?.write(to: fileURL)
        Log.info("created sample schedule at \(fileURL.path)")
    }

    // ---- Per-tick update ---------------------------------------------------

    private func update() {
        let now = Date()
        let s = engine.settings
        let showSec = s.showSeconds ?? true
        var state = HUDState()
        state.clock = showSec ? Fmt.clock.string(from: now) : Fmt.clockNoSec.string(from: now)
        state.errorText = engine.loadError

        if let (cur, _) = activeBlock(at: now) {
            let held = (override.blockKey == cur.key)
            let banked = held ? override.shift : 0
            let endBase = cur.end.addingTimeInterval(banked)
            // While paused, every derived number freezes at the pause instant.
            let ref = (held && override.isPaused) ? (override.pausedAt ?? now) : now

            let remaining = endBase.timeIntervalSince(ref)
            let span = max(1, endBase.timeIntervalSince(cur.start))

            state.title = cur.title
            state.countdown = Fmt.hms(remaining, showSeconds: showSec)
            state.progress = min(1, max(0, ref.timeIntervalSince(cur.start) / span))

            var range = "\(Fmt.hm.string(from: cur.start))–\(Fmt.hm.string(from: cur.end))"
            if let n = cur.note, !n.isEmpty { range += "  ·  \(n)" }
            if engine.isOverlapping(at: now) { range += "  ·  overlap" }
            if banked > 30 { range += "  ·  +\(Fmt.compactRemaining(banked))" }
            state.range = range

            if let nxt = nextBlock(after: now) {
                state.next = "next  \(Fmt.hm.string(from: nxt.start))   \(truncate(nxt.title, 30))"
            }

            if held && override.isPaused {
                state.caption = "paused \(Fmt.compactRemaining(override.pauseElapsed(at: now)))"
                state.tint = Theme.secondary
                state.warning = false
                statusItem.button?.title = " ⏸ \(truncate(cur.title, 20))  \(Fmt.compactRemaining(remaining))"
            } else {
                state.caption = "remaining"
                let warnMins = (s.warnMinutes ?? [10, 5, 1]).sorted()
                let minutesLeft = remaining / 60
                if let smallest = warnMins.first, minutesLeft <= Double(smallest) {
                    state.tint = Theme.urgent; state.warning = true
                } else if let biggest = warnMins.last, minutesLeft <= Double(biggest) {
                    state.tint = Theme.warn; state.warning = true
                } else {
                    state.tint = cur.color ?? Theme.accent
                }
                handleAlerts(for: cur, remaining: remaining)
                statusItem.button?.title = " \(truncate(cur.title, 22))  \(Fmt.compactRemaining(remaining))"
            }

        } else if let nxt = nextBlock(after: now) {
            let until = nxt.start.timeIntervalSince(now)
            state.title = "Open"
            state.countdown = Fmt.hms(until, showSeconds: showSec)
            state.caption = "until next"
            state.progress = 0
            state.tint = Theme.idle
            state.range = override.skipped.isEmpty ? "unscheduled" : "unscheduled  ·  skipped"
            state.next = "next  \(Fmt.hm.string(from: nxt.start))   \(truncate(nxt.title, 30))"
            lastCurrentKey = nil
            statusItem.button?.title = " Open  \(Fmt.compactRemaining(until))"

        } else {
            state.title = "Nothing scheduled"
            state.countdown = "—"
            state.caption = ""
            state.tint = Theme.idle
            state.range = engine.loadError == nil ? "~/.taskhud/schedule.json" : ""
            state.next = ""
            lastCurrentKey = nil
            statusItem.button?.title = " —"
        }

        // ---- distraction nudge -------------------------------------------
        distraction.poll(now: now)
        let activeTitle = activeBlock(at: now)?.block.title
        let inBlock = activeTitle != nil
        let suppressed = override.isPaused
            || distraction.isAllowed(blockTitle: activeTitle)
            || (distraction.onlyDuringBlocks && !inBlock)

        if distraction.isNudging(at: now) && !suppressed {
            let mins = distraction.elapsed(at: now)
            state.distracted = true
            state.tint = Theme.urgent
            state.warning = true
            let what = distraction.label ?? "off task"
            let base = engine.settings.distractions?.message
                ?? (inBlock ? "back to it?" : "still here?")
            state.nudge = "\(what)  ·  \(Fmt.compactRemaining(mins))  ·  \(base)"
            if mins >= distraction.escalateAfter, !nudgeChimed {
                nudgeChimed = true
                if distraction.chimeOnEscalate, engine.settings.sound ?? true {
                    play(engine.settings.warnSound ?? "Tink")
                }
            }
        } else {
            nudgeChimed = false
        }

        content.apply(state)
        resizeToFit()
    }

    private func truncate(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }

    private func resizeToFit() {
        let size = content.desiredSize()
        guard abs(panel.frame.width - size.width) > 0.5 || abs(panel.frame.height - size.height) > 0.5 else { return }
        // Grow downward from the current top-left so the HUD doesn't jump around.
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        panel.setFrame(NSRect(x: topLeft.x, y: topLeft.y - size.height,
                              width: size.width, height: size.height), display: true)
        clampIntoScreens()
    }

    // ---- Alerts ------------------------------------------------------------

    private func handleAlerts(for block: ResolvedBlock, remaining: TimeInterval) {
        guard !override.isPaused else { return }
        let soundOn = engine.settings.sound ?? true

        // Block start (fires once, and only if we're within 3s of the start so a
        // relaunch mid-block doesn't chime).
        if lastCurrentKey != block.key {
            lastCurrentKey = block.key
            let sinceStart = Date().timeIntervalSince(block.start)
            let startKey = block.key + "|start"
            if sinceStart < 3, !firedAlerts.contains(startKey) {
                firedAlerts.insert(startKey)
                if soundOn { play(engine.settings.startSound ?? "Glass") }
                flash()
            }
        }

        // T-minus warnings.
        for m in (engine.settings.warnMinutes ?? []) {
            let key = block.key + "|warn\(m)"
            let threshold = Double(m) * 60
            if remaining <= threshold, remaining > threshold - 2, !firedAlerts.contains(key) {
                firedAlerts.insert(key)
                if soundOn { play(engine.settings.warnSound ?? "Tink") }
                flash()
            }
        }

        if firedAlerts.count > 500 { firedAlerts.removeAll() }   // unbounded-growth guard
    }

    private func play(_ name: String) {
        guard let s = NSSound(named: NSSound.Name(name)) ?? NSSound(named: NSSound.Name("Glass")) else { return }
        sound = s          // retain while playing
        s.stop(); s.play()
    }

    private func flash() {
        guard !hidden else { return }
        panel.orderFrontRegardless()
        let target = CGFloat(engine.settings.opacity ?? 0.96)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1.0
        }, completionHandler: {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.5
                self.panel.animator().alphaValue = target
            }
        })
    }

    // ---- Position ----------------------------------------------------------

    private func restorePosition() {
        let size = content.desiredSize()
        if let s = UserDefaults.standard.string(forKey: posKey) {
            let p = NSPointFromString(s)
            panel.setFrame(NSRect(origin: p, size: size), display: false)
        } else if let vf = NSScreen.main?.visibleFrame {
            panel.setFrame(NSRect(x: vf.maxX - size.width - 24,
                                  y: vf.maxY - size.height - 24,
                                  width: size.width, height: size.height), display: false)
        }
        clampIntoScreens()
    }

    func windowDidMove(_ notification: Notification) {
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: posKey)
    }

    /// Keep the HUD on a screen that actually exists (monitor unplugged, resolution change…).
    private func clampIntoScreens() {
        guard let screens = NSScreen.screens.isEmpty ? nil : NSScreen.screens else { return }
        let f = panel.frame
        let best = screens.max { a, b in
            a.visibleFrame.intersection(f).area < b.visibleFrame.intersection(f).area
        }
        let vf = (best?.visibleFrame.intersection(f).area ?? 0) > 40
            ? best!.visibleFrame
            : (NSScreen.main?.visibleFrame ?? screens[0].visibleFrame)

        var x = f.origin.x, y = f.origin.y
        x = min(max(x, vf.minX), vf.maxX - f.width)
        y = min(max(y, vf.minY), vf.maxY - f.height)
        if abs(x - f.origin.x) > 0.5 || abs(y - f.origin.y) > 0.5 {
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: posKey)
        }
    }

    // ---- Status bar menu ---------------------------------------------------

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusItem.button?.title = " …"
        rebuildMenu()
    }

    private func rebuildMenu() {
        statusItem.menu = makeMenu()
        content.menu = makeMenu()      // right-click on the HUD gets the same menu
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let now = Date()

        let title = override.isPaused ? "TaskHUD — paused" : "TaskHUD"
        let head = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())

        // ---- session controls ------------------------------------------------
        let hasActive = activeBlock(at: now) != nil
        let canSkip = hasActive || nextBlock(after: now) != nil

        let pauseItem = NSMenuItem(
            title: override.isPaused ? "Resume" : "Pause",
            action: #selector(togglePause), keyEquivalent: "p")
        pauseItem.target = self
        pauseItem.isEnabled = hasActive || override.isPaused
        menu.addItem(pauseItem)

        let skipItem = NSMenuItem(
            title: hasActive ? "Skip current block" : "Skip next block",
            action: #selector(skipCurrent), keyEquivalent: "s")
        skipItem.target = self
        skipItem.isEnabled = canSkip
        menu.addItem(skipItem)

        let restoreItem = NSMenuItem(title: "Back to schedule",
                                     action: #selector(clearOverride), keyEquivalent: "b")
        restoreItem.target = self
        restoreItem.isEnabled = override.isActive
        menu.addItem(restoreItem)
        menu.addItem(.separator())

        // ---- today -----------------------------------------------------------
        let today = engine.today(now)
        for b in today.prefix(10) {
            let mark: String
            if override.skipped.contains(b.key)          { mark = "⤫ " }
            else if override.blockKey == b.key           { mark = override.isPaused ? "⏸ " : "▶︎ " }
            else if b.contains(now)                      { mark = "▶︎ " }
            else if b.end <= now                         { mark = "✓ " }
            else                                         { mark = "   " }
            let item = NSMenuItem(
                title: "\(mark)\(Fmt.hm.string(from: b.start))–\(Fmt.hm.string(from: b.end))  \(truncate(b.title, 30))",
                action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if today.isEmpty {
            let item = NSMenuItem(title: "   (nothing scheduled today)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        // ---- appearance ------------------------------------------------------
        add(menu, hidden ? "Show HUD" : "Hide HUD", #selector(toggleHidden), "h")
        add(menu, (content.compact ? "Full size" : "Compact mode"), #selector(toggleCompact), "c")
        add(menu, (panel.ignoresMouseEvents ? "Enable clicks" : "Click-through"), #selector(toggleClickThrough), "t")

        let opacity = NSMenu()
        for v in [0.4, 0.6, 0.8, 0.96, 1.0] {
            let i = NSMenuItem(title: String(format: "%.0f%%", v * 100), action: #selector(setOpacity(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = v
            i.state = abs(Double(panel.alphaValue) - v) < 0.02 ? .on : .off
            opacity.addItem(i)
        }
        let opacityItem = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        menu.addItem(opacityItem); menu.setSubmenu(opacity, for: opacityItem)

        menu.addItem(.separator())
        add(menu, "Adherence & review…", #selector(openReview), "d")
        add(menu, "Mark current done", #selector(markCurrentDone), "1")
        add(menu, "Mark current missed", #selector(markCurrentMissed), "2")
        menu.addItem(.separator())
        add(menu, "Edit schedule…", #selector(editSchedule), "e")
        add(menu, "Reveal in Finder", #selector(revealSchedule), "")
        add(menu, "Reload schedule", #selector(reloadNow), "r")
        add(menu, "Reset position", #selector(resetPosition), "")
        menu.addItem(.separator())
        add(menu, "Quit TaskHUD", #selector(quit), "q")
        return menu
    }

    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, _ key: String) {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        menu.addItem(i)
    }

    // ---- Session actions ---------------------------------------------------

    /// Pause freezes the countdown; resuming pushes this block's end out by
    /// exactly the time spent paused. Later blocks are never moved — a long
    /// pause simply eats into the following block, which is the honest
    /// outcome for a wall-clock schedule.
    @objc func togglePause() {
        let now = Date()
        if override.isPaused {
            override.clearHold()
        } else {
            guard let (b, _) = activeBlock(at: now) else { NSSound.beep(); return }
            override.blockKey = b.key
            override.shift = (override.blockKey == b.key) ? override.shift : 0
            override.pausedAt = now
        }
        saveOverride(); update(); rebuildMenu(); flash()
    }

    /// Skip dismisses this block instance only. It never edits schedule.json,
    /// and the same block returns tomorrow.
    @objc private func skipCurrent() {
        let now = Date()
        let target = activeBlock(at: now)?.block ?? nextBlock(after: now)
        guard let t = target else { NSSound.beep(); return }
        override.skip(t.key)
        if override.blockKey == t.key { override.clearHold() }
        firedAlerts.remove(t.key + "|start")
        lastCurrentKey = nil
        saveOverride(); update(); rebuildMenu(); flash()
    }

    /// Drop every pause, extension and skip; snap back to the wall clock.
    @objc private func clearOverride() {
        override.clearAll()
        lastCurrentKey = nil
        saveOverride(); update(); rebuildMenu(); flash()
    }

    // ---- Adherence ---------------------------------------------------------

    @objc func openReview() {
        if review == nil { review = ReviewWindow(store: store, engine: engine) }
        review?.reload()
        review?.center()
        review?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func markCurrent(_ m: Mark) {
        let now = Date()
        guard let (b, _) = activeBlock(at: now) else { NSSound.beep(); return }
        let planned = engine.blocks(on: b.start).count
        // Tapping the same mark twice clears it.
        let next: Mark? = (store.mark(for: b) == m) ? nil : m
        store.mark(b, as: next, plannedThatDay: planned)
        review?.reload()
        flash()
    }

    @objc private func markCurrentDone()   { markCurrent(.done) }
    @objc private func markCurrentMissed() { markCurrent(.missed) }

    // ---- Actions -----------------------------------------------------------

    @objc private func toggleHidden() {
        hidden.toggle()
        UserDefaults.standard.set(hidden, forKey: hiddenKey)
        if hidden { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        rebuildMenu()
    }

    @objc private func toggleCompact() {
        content.setCompact(!content.compact)
        resizeToFit()
        rebuildMenu()
    }

    @objc private func toggleClickThrough() {
        panel.ignoresMouseEvents.toggle()
        rebuildMenu()
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        panel.alphaValue = CGFloat(v)
        rebuildMenu()
    }

    @objc private func editSchedule() {
        NSWorkspace.shared.open(fileURL)
    }

    @objc private func revealSchedule() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    @objc private func reloadNow() { reload(userInitiated: true) }

    private func reload(userInitiated: Bool) {
        ensureScheduleFile()
        engine.load(from: fileURL)
        override.clearHold()
        saveOverride()
        firedAlerts.removeAll()
        lastCurrentKey = nil
        panel.alphaValue = CGFloat(engine.settings.opacity ?? 0.96)
        panel.level = windowLevel()
        panel.ignoresMouseEvents = engine.settings.clickThrough ?? false
        content.setCompact(engine.settings.compact ?? false)
        distraction.configure(engine.settings.distractions)
        update()
        rebuildMenu()
        if userInitiated { flash() }

        // An editor's atomic save briefly unlinks the file, so a watcher event
        // can land on a moment when there is nothing to read. The watcher has
        // already banked the new mtime by then and will not fire again, so
        // without this the HUD would sit on a stale error indefinitely.
        if engine.loadError != nil {
            if reloadRetries < 6 {
                reloadRetries += 1
                let delay = min(6.0, 0.25 * pow(2.0, Double(reloadRetries)))
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.reload(userInitiated: false)
                }
            } else {
                Log.error("giving up reloading after 6 attempts — fix the JSON and use Reload schedule")
            }
        } else {
            reloadRetries = 0
        }
    }

    @objc private func resetPosition() {
        UserDefaults.standard.removeObject(forKey: posKey)
        restorePosition()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

private extension NSRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}

// ============================================================================
// MARK: - Entry point
// ============================================================================

let app = NSApplication.shared
let controller = AppController()
app.setActivationPolicy(.accessory)
controller.start()
app.run()
