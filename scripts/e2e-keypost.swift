// scripts/e2e-keypost.swift
//
// Posts keyboard events at the HID tap point (`.cghidEventTap`) so they are visible to
// session-level CGEvent taps — i.e. to Cotabby's InputMonitor. AppleScript's
// `System Events keystroke` injects events that reach the focused app but are NOT delivered
// to other processes' event taps on modern macOS, which makes it useless for end-to-end
// testing of a tap-driven product. This helper is the test suite's keyboard.
//
// Build:  swiftc -O scripts/e2e-keypost.swift -o /tmp/cotabby-e2e-keypost
// Usage:  cotabby-e2e-keypost type "git ch" [delayMs]     # per-character keystrokes
//         cotabby-e2e-keypost key 124 [ctrl] [cmd] [shift] [opt]   # one key code press
//
// Requires Accessibility permission for the invoking context (same grant osascript needs).

import CoreGraphics
import Foundation

// US-ANSI virtual key codes for the characters the E2E types. Typing through real
// per-character key codes (rather than one event with a unicode payload) matters because
// shells and TUIs differ in how they treat unicode-only synthetic events.
let keyCodeMap: [Character: (code: CGKeyCode, shift: Bool)] = [
    "a": (0, false), "b": (11, false), "c": (8, false), "d": (2, false), "e": (14, false),
    "f": (3, false), "g": (5, false), "h": (4, false), "i": (34, false), "j": (38, false),
    "k": (40, false), "l": (37, false), "m": (46, false), "n": (45, false), "o": (31, false),
    "p": (35, false), "q": (12, false), "r": (15, false), "s": (1, false), "t": (17, false),
    "u": (32, false), "v": (9, false), "w": (13, false), "x": (7, false), "y": (16, false),
    "z": (6, false),
    "0": (29, false), "1": (18, false), "2": (19, false), "3": (20, false), "4": (21, false),
    "5": (23, false), "6": (22, false), "7": (26, false), "8": (28, false), "9": (25, false),
    " ": (49, false), "-": (27, false), "=": (24, false), "[": (33, false), "]": (30, false),
    ";": (41, false), "'": (39, false), ",": (43, false), ".": (47, false), "/": (44, false),
    "\\": (42, false), "`": (50, false),
    "A": (0, true), "B": (11, true), "C": (8, true), "D": (2, true), "E": (14, true),
    "F": (3, true), "G": (5, true), "H": (4, true), "I": (34, true), "J": (38, true),
    "K": (40, true), "L": (37, true), "M": (46, true), "N": (45, true), "O": (31, true),
    "P": (35, true), "Q": (12, true), "R": (15, true), "S": (1, true), "T": (17, true),
    "U": (32, true), "V": (9, true), "W": (13, true), "X": (7, true), "Y": (16, true),
    "Z": (6, true),
    "!": (18, true), "@": (19, true), "#": (20, true), "$": (21, true), "%": (23, true),
    "^": (22, true), "&": (26, true), "*": (28, true), "(": (25, true), ")": (29, true),
    "_": (27, true), "+": (24, true), "{": (33, true), "}": (30, true), ":": (41, true),
    "\"": (39, true), "<": (43, true), ">": (47, true), "?": (44, true), "|": (42, true),
    "~": (50, true)
]

func post(code: CGKeyCode, flags: CGEventFlags) {
    guard let source = CGEventSource(stateID: .hidSystemState),
          let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
    else {
        FileHandle.standardError.write("event creation failed\n".data(using: .utf8)!)
        exit(2)
    }
    down.flags = flags
    up.flags = flags
    down.post(tap: .cghidEventTap)
    // A few ms between down and up mirrors real key travel; some TUIs debounce 0-width presses.
    usleep(8_000)
    up.post(tap: .cghidEventTap)
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: e2e-keypost type <text> [delayMs] | key <code> [ctrl|cmd|shift|opt ...]\n".data(using: .utf8)!)
    exit(1)
}

switch args[1] {
case "type":
    let text = args[2]
    let delayMs = args.count > 3 ? (UInt32(args[3]) ?? 80) : 80
    for ch in text {
        guard let mapped = keyCodeMap[ch] else {
            FileHandle.standardError.write("unmapped character: \(ch)\n".data(using: .utf8)!)
            exit(2)
        }
        post(code: mapped.code, flags: mapped.shift ? .maskShift : [])
        usleep(delayMs * 1_000)
    }
case "key":
    guard let code = UInt16(args[2]) else {
        FileHandle.standardError.write("bad key code\n".data(using: .utf8)!)
        exit(1)
    }
    var flags: CGEventFlags = []
    for modifier in args.dropFirst(3) {
        switch modifier {
        case "ctrl": flags.insert(.maskControl)
        case "cmd": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "opt": flags.insert(.maskAlternate)
        default: break
        }
    }
    post(code: CGKeyCode(code), flags: flags)
default:
    FileHandle.standardError.write("unknown command \(args[1])\n".data(using: .utf8)!)
    exit(1)
}
