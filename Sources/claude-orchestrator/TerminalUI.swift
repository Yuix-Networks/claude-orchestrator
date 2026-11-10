import OrchestratorCore
import Foundation

/// Minimal terminal layer for the interactive screens: raw mode, key reading,
/// drawing on the alternate screen. Input and output go through `/dev/tty`,
/// so the screens show up in the terminal even when stdout is piped.
final class TerminalUI {
    private let fd: Int32
    private var original = termios()
    private var raw = termios()
    private var pending: [UInt8] = []
    private var restored = false

    /// `nil` when there is no terminal.
    init?() {
        guard isatty(STDIN_FILENO) != 0 else { return nil }
        let tty = open("/dev/tty", O_RDWR)
        guard tty >= 0 else { return nil }
        fd = tty
        guard tcgetattr(fd, &original) == 0 else {
            close(fd)
            return nil
        }
        raw = original
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
        withUnsafeMutableBytes(of: &raw.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }
        tcsetattr(fd, TCSAFLUSH, &raw)
        write("\u{1B}[?1049h\u{1B}[H")
    }

    /// Leaves raw mode and restores the main screen. Safe to call more than once.
    func restore() {
        guard !restored else { return }
        restored = true
        write("\u{1B}[?25h\u{1B}[?1049l")
        tcsetattr(fd, TCSAFLUSH, &original)
    }

    deinit {
        restore()
        close(fd)
    }

    var size: (rows: Int, columns: Int) {
        var window = winsize()
        guard ioctl(fd, TIOCGWINSZ, &window) == 0, window.ws_row > 0, window.ws_col > 0 else { return (24, 80) }
        return (Int(window.ws_row), Int(window.ws_col))
    }

    // MARK: - Drawing

    /// Clears the screen and writes the lines; the cursor goes to the given
    /// row/column (`nil` hides the cursor).
    func draw(_ lines: [String], cursor: (row: Int, column: Int)? = nil) {
        var output = "\u{1B}[?25l\u{1B}[H\u{1B}[2J"
        output += lines.joined(separator: "\r\n")
        if let cursor {
            output += "\u{1B}[\(cursor.row + 1);\(cursor.column + 1)H\u{1B}[?25h"
        }
        write(output)
    }

    private func write(_ text: String) {
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    // MARK: - Input

    /// Waits for the next key.
    func readKey() -> PickerKey {
        while true {
            if let key = decode() { return key }
            guard fill(timeoutMs: -1) else { return .interrupt }
        }
    }

    /// Fills the input buffer. `timeoutMs < 0` waits until a byte arrives.
    ///
    /// The timeout uses termios `VMIN=0/VTIME`, not `poll`: on macOS `poll()`
    /// does not work on tty devices (a lone Esc used to hang until the next
    /// key press).
    private func fill(timeoutMs: Int32) -> Bool {
        if timeoutMs >= 0 {
            var timed = raw
            withUnsafeMutableBytes(of: &timed.c_cc) { cc in
                cc[Int(VMIN)] = 0
                cc[Int(VTIME)] = cc_t(max(1, (timeoutMs + 99) / 100))
            }
            tcsetattr(fd, TCSANOW, &timed)
        }
        defer { if timeoutMs >= 0 { tcsetattr(fd, TCSANOW, &raw) } }
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else { return false }
        pending.append(contentsOf: buffer[0..<count])
        return true
    }

    private func take(_ count: Int) { pending.removeFirst(min(count, pending.count)) }

    private func decode() -> PickerKey? {
        guard let first = pending.first else { return nil }
        switch first {
        case 0x1B:
            // A lone Esc or an escape sequence? Wait briefly for more bytes.
            if pending.count == 1, !fill(timeoutMs: 100) {
                take(1)
                return .escape
            }
            guard pending.count >= 2 else { take(1); return .escape }
            let second = pending[1]
            guard second == UInt8(ascii: "[") || second == UInt8(ascii: "O") else {
                take(1)
                return .escape
            }
            if pending.count < 3, !fill(timeoutMs: 100) { take(2); return .escape }
            // CSI: parameter bytes (0x30–0x3F) + final byte (0x40–0x7E).
            var end = 2
            while end < pending.count, (0x30...0x3F).contains(pending[end]) { end += 1 }
            guard end < pending.count else { take(pending.count); return nil }
            let final = pending[end]
            let parameters = String(decoding: pending[2..<end], as: UTF8.self)
            take(end + 1)
            switch (final, parameters) {
            case (UInt8(ascii: "A"), _): return .up
            case (UInt8(ascii: "B"), _): return .down
            case (UInt8(ascii: "~"), "5"): return .pageUp
            case (UInt8(ascii: "~"), "6"): return .pageDown
            default: return nil
            }
        case 0x03, 0x04:
            take(1); return .interrupt
        case 0x0D, 0x0A:
            take(1); return .enter
        case 0x7F, 0x08:
            take(1); return .backspace
        case 0x15:
            take(1); return .clearQuery
        case 0x10:
            take(1); return .up      // Ctrl-P
        case 0x0E:
            take(1); return .down    // Ctrl-N
        case 0x00...0x1F:
            take(1); return nil
        default:
            // UTF-8 character: work out the length from the lead byte.
            let length = first >= 0xF0 ? 4 : first >= 0xE0 ? 3 : first >= 0xC0 ? 2 : 1
            while pending.count < length {
                guard fill(timeoutMs: 100) else { take(pending.count); return nil }
            }
            let text = String(decoding: pending[0..<length], as: UTF8.self)
            take(length)
            return text.first.map(PickerKey.character)
        }
    }
}

// MARK: - Text helpers

enum Style {
    static let reset = "\u{1B}[0m"
    static let bold = "\u{1B}[1m"
    static let dim = "\u{1B}[2m"
    static let inverse = "\u{1B}[7m"
    static let accent = "\u{1B}[36m"
    static let highlight = "\u{1B}[1;33m"
    static let warning = "\u{1B}[33m"
}

extension String {
    /// Truncates/pads to a visible width (for text without escape sequences).
    func fitted(_ width: Int) -> String {
        guard width > 0 else { return "" }
        if count > width { return String(prefix(width - 1)) + "…" }
        return self + String(repeating: " ", count: width - count)
    }

    /// Highlights the matched positions; truncates and pads to `width`.
    func highlighted(_ positions: [Int], width: Int, base: String = "") -> String {
        let fitted = self.fitted(width)
        let marks = Set(positions)
        var output = base
        for (offset, character) in fitted.enumerated() {
            if marks.contains(offset), character != "…" || count <= width {
                output += Style.highlight + String(character) + Style.reset + base
            } else {
                output.append(character)
            }
        }
        return output + Style.reset
    }

    /// Wraps long text into lines at word boundaries.
    func wrapped(_ width: Int) -> [String] {
        var lines: [String] = []
        for paragraph in components(separatedBy: "\n") {
            var line = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: false) {
                if !line.isEmpty, line.count + 1 + word.count > width {
                    lines.append(line)
                    line = String(word)
                } else {
                    line += line.isEmpty ? String(word) : " " + word
                }
            }
            lines.append(line)
        }
        return lines
    }
}
