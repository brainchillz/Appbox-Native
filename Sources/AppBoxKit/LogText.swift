import Foundation

/// Makes machine and container logs fit to read in a plain text view.
///
/// A machine's console is a real Linux boot log, and systemd writes it in
/// colour: the raw text is full of `ESC[0;1;31m` colour codes and `ESC]8;;`
/// hyperlink sequences. A terminal renders those; a SwiftUI `Text` prints them
/// literally, which buries the actual message in punctuation.
public enum LogText {

    /// Strip ANSI escape sequences, leaving the text they were decorating.
    ///
    /// Handles the two forms that appear in practice: CSI (`ESC[` … final byte
    /// in `@`–`~`), which covers colour and cursor movement, and OSC (`ESC]` …
    /// terminated by BEL or `ESC\`), which is how systemd emits clickable unit
    /// names. Anything else is left alone rather than guessed at.
    public static func plain(_ text: String) -> String {
        var output = String()
        output.reserveCapacity(text.count)

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "\u{1B}" else {
                output.append(character)
                index = text.index(after: index)
                continue
            }

            let next = text.index(after: index)
            guard next < text.endIndex else { break }  // trailing ESC: drop it

            switch text[next] {
            case "[":
                // CSI: parameters and intermediates, then one final byte.
                var scan = text.index(after: next)
                while scan < text.endIndex, !("@"..."~").contains(text[scan]) {
                    scan = text.index(after: scan)
                }
                index = scan < text.endIndex ? text.index(after: scan) : scan

            case "]":
                // OSC: runs until BEL, or until ESC \ (the string terminator).
                var scan = text.index(after: next)
                while scan < text.endIndex {
                    if text[scan] == "\u{07}" {
                        scan = text.index(after: scan)
                        break
                    }
                    if text[scan] == "\u{1B}",
                       text.index(after: scan) < text.endIndex,
                       text[text.index(after: scan)] == "\\" {
                        scan = text.index(scan, offsetBy: 2)
                        break
                    }
                    scan = text.index(after: scan)
                }
                index = scan

            default:
                // A two-character escape (ESC c, ESC =, …).
                index = text.index(after: next)
            }
        }

        return output
    }
}
