import Foundation

/// Something written over the picture for a while: a caption, or the keys of a shortcut.
/// Times are those of the finished video.
public struct Overlay: Codable, Equatable {
    public var kind: String          // "caption" | "keys"
    public var text: String
    public var start: Double
    public var end: Double

    public init(kind: String, text: String, start: Double, end: Double) {
        self.kind = kind; self.text = text; self.start = start; self.end = end
    }

    /// 0 while absent, 1 while fully there, in between while it comes and goes.
    public func presence(at t: Double) -> Double {
        guard t > start, t < end else { return 0 }
        let fade = min(0.22, (end - start) / 2)
        return min((t - start) / fade, (end - t) / fade, 1)
    }
}

public enum Overlays {
    /// How long a shortcut stays on screen.
    public static let keysHold = 1.6
    /// A caption on an action stays at least this long after the action.
    public static let afterAction = 1.0

    /// How long a line takes to read. A wide character, as in Chinese or Japanese, carries
    /// about as much as three letters.
    public static func readingTime(_ text: String) -> Double {
        let letters = text.unicodeScalars.reduce(0.0) { $0 + (isWide($1) ? 3 : 1) }
        return min(max(0.9 + letters * 0.055, 1.8), 7)
    }

    static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    /// The captions and shortcuts of a timeline, in the order they show. A caption gives way
    /// to the next one, and one without text only clears what is there.
    public static func build(timeline: Timeline, lead: Double) -> [Overlay] {
        var captions: [Overlay] = []
        var keys: [Overlay] = []
        for item in timeline.marks {
            let mark = item.mark
            let text = (mark.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            switch mark.kind {
            case "speed":
                continue
            case "keys":
                guard !keycaps(text).isEmpty else { continue }
                keys.append(Overlay(kind: "keys", text: text, start: item.t, end: item.t + (mark.hold ?? keysHold)))
            case "caption":
                captions.append(Overlay(kind: "caption", text: text, start: item.t,
                                        end: item.t + (mark.hold ?? readingTime(text))))
            default:
                // Words about an action arrive with the camera, before the action itself.
                guard !text.isEmpty else { continue }
                let start = max(item.t - lead, 0)
                captions.append(Overlay(kind: "caption", text: text, start: start,
                                        end: max(start + readingTime(text), item.t + afterAction)))
            }
        }
        return (giving(way: captions) + giving(way: keys)).sorted { $0.start < $1.start }
    }

    private static func giving(way overlays: [Overlay]) -> [Overlay] {
        var sorted = overlays.sorted { $0.start < $1.start }
        for index in sorted.indices.dropLast() {
            sorted[index].end = min(sorted[index].end, sorted[index + 1].start)
        }
        return sorted.filter { !$0.text.isEmpty && $0.end - $0.start > 0.15 }
    }

    // MARK: Keys

    private static let modifiers: [String: (symbol: String, order: Int)] = [
        "ctrl": ("⌃", 0), "control": ("⌃", 0),
        "alt": ("⌥", 1), "opt": ("⌥", 1), "option": ("⌥", 1),
        "shift": ("⇧", 2),
        "cmd": ("⌘", 3), "command": ("⌘", 3), "meta": ("⌘", 3), "super": ("⌘", 3), "win": ("⌘", 3),
        "controlormeta": ("⌘", 3), "cmdorctrl": ("⌘", 3), "commandorcontrol": ("⌘", 3), "mod": ("⌘", 3),
    ]

    private static let named: [String: String] = [
        "enter": "↩", "return": "↩", "tab": "⇥", "backspace": "⌫", "delete": "⌫", "del": "⌦", "forwarddelete": "⌦",
        "esc": "esc", "escape": "esc", "space": "space", "spacebar": "space", "fn": "fn", "capslock": "⇪",
        "up": "↑", "down": "↓", "left": "←", "right": "→",
        "arrowup": "↑", "arrowdown": "↓", "arrowleft": "←", "arrowright": "→",
        "pageup": "⇞", "pagedown": "⇟", "home": "↖", "end": "↘", "plus": "+", "minus": "−",
    ]

    /// What is written on the keys of a shortcut such as "cmd+shift+p" or "Control+ArrowDown":
    /// the modifiers first, in the order the system writes them, then the rest as given.
    public static func keycaps(_ text: String) -> [String] {
        var held: [(symbol: String, order: Int)] = []
        var rest: [String] = []
        var parts = text.split(whereSeparator: { $0 == "+" || $0 == " " }).map(String.init)
        // "cmd++" asks for the plus key itself.
        if text.hasSuffix("++") || text.trimmingCharacters(in: .whitespaces) == "+" { parts.append("+") }
        for part in parts {
            let name = part.lowercased()
            if let modifier = modifiers[name] {
                if !held.contains(where: { $0.symbol == modifier.symbol }) { held.append(modifier) }
            } else if let symbol = named[name] {
                rest.append(symbol)
            } else if part.count == 1 || (name.hasPrefix("f") && Int(name.dropFirst()) != nil) {
                rest.append(part.uppercased())
            } else {
                rest.append(part)
            }
        }
        return held.sorted { $0.order < $1.order }.map(\.symbol) + rest
    }

    /// How a pace is written: "4×", "1.5×".
    public static func paceLabel(_ rate: Double) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%.1f×", rate)
    }
}
