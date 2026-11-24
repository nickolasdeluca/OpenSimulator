import Foundation

/// macOS virtual key codes (Carbon `kVK_*`) to USB HID keyboard usages (page 0x07), which is what
/// the simulator's hardware keyboard path takes. These are layout-independent physical keys, so the
/// device's own keyboard layout decides which character each one produces, as on a real keyboard.
public enum KeyboardMap {
    public static let usageByKeyCode: [UInt16: UInt32] = [
        // Letters
        0x00: 0x04, 0x0B: 0x05, 0x08: 0x06, 0x02: 0x07, 0x0E: 0x08, 0x03: 0x09, 0x05: 0x0A,
        0x04: 0x0B, 0x22: 0x0C, 0x26: 0x0D, 0x28: 0x0E, 0x25: 0x0F, 0x2E: 0x10, 0x2D: 0x11,
        0x1F: 0x12, 0x23: 0x13, 0x0C: 0x14, 0x0F: 0x15, 0x01: 0x16, 0x11: 0x17, 0x20: 0x18,
        0x09: 0x19, 0x0D: 0x1A, 0x07: 0x1B, 0x10: 0x1C, 0x06: 0x1D,
        // Digits
        0x12: 0x1E, 0x13: 0x1F, 0x14: 0x20, 0x15: 0x21, 0x17: 0x22, 0x16: 0x23, 0x1A: 0x24,
        0x1C: 0x25, 0x19: 0x26, 0x1D: 0x27,
        // Editing and punctuation
        0x24: 0x28, 0x35: 0x29, 0x33: 0x2A, 0x30: 0x2B, 0x31: 0x2C, 0x1B: 0x2D, 0x18: 0x2E,
        0x21: 0x2F, 0x1E: 0x30, 0x2A: 0x31, 0x29: 0x33, 0x27: 0x34, 0x32: 0x35, 0x2B: 0x36,
        0x2F: 0x37, 0x2C: 0x38, 0x0A: 0x64,
        // Navigation
        0x7B: 0x50, 0x7C: 0x4F, 0x7D: 0x51, 0x7E: 0x52,
        0x75: 0x4C, 0x73: 0x4A, 0x77: 0x4D, 0x74: 0x4B, 0x79: 0x4E,
        // Function keys
        0x7A: 0x3A, 0x78: 0x3B, 0x63: 0x3C, 0x76: 0x3D, 0x60: 0x3E, 0x61: 0x3F,
        0x62: 0x40, 0x64: 0x41, 0x65: 0x42, 0x6D: 0x43, 0x67: 0x44, 0x6F: 0x45,
        // Keypad
        0x52: 0x62, 0x53: 0x59, 0x54: 0x5A, 0x55: 0x5B, 0x56: 0x5C, 0x57: 0x5D, 0x58: 0x5E,
        0x59: 0x5F, 0x5B: 0x60, 0x5C: 0x61, 0x41: 0x63, 0x45: 0x57, 0x4E: 0x56, 0x43: 0x55,
        0x4B: 0x54, 0x4C: 0x58, 0x51: 0x67, 0x47: 0x53,
    ]

    /// Modifier keys arrive as flag changes rather than key downs.
    public static let modifierUsageByKeyCode: [UInt16: UInt32] = [
        0x3B: 0xE0, // control
        0x38: 0xE1, // shift
        0x3A: 0xE2, // option
        0x37: 0xE3, // command
        0x3E: 0xE4, // right control
        0x3C: 0xE5, // right shift
        0x3D: 0xE6, // right option
        0x36: 0xE7, // right command
        0x39: 0x39, // caps lock
    ]

    public static let leftShift: UInt32 = 0xE1
    public static let leftCommand: UInt32 = 0xE3

    public static func usage(forKeyCode keyCode: UInt16) -> UInt32? {
        usageByKeyCode[keyCode]
    }

    public struct Stroke: Equatable, Sendable {
        public let usage: UInt32
        public let shift: Bool
    }

    /// Key strokes that type `text` on a US layout, or nil if any character has no key. Used to
    /// type text straight into the device.
    public static func strokes(forTyping text: String) -> [Stroke]? {
        var strokes: [Stroke] = []
        for character in text {
            guard let stroke = strokeByCharacter[character] else { return nil }
            strokes.append(stroke)
        }
        return strokes
    }

    /// A key pressed while holding modifiers, which are usages too, e.g. `leftCommand`.
    public struct Chord: Equatable, Sendable {
        public let usage: UInt32
        public let modifiers: [UInt32]

        public init(usage: UInt32, modifiers: [UInt32] = []) {
            self.usage = usage
            self.modifiers = modifiers
        }
    }

    public struct Untypeable: LocalizedError, Equatable {
        public let character: Character
        public var errorDescription: String? {
            "\"\(character)\" has no key on a US keyboard. Use --paste to type it through the pasteboard."
        }
    }

    public static let leftControl: UInt32 = 0xE0
    public static let leftOption: UInt32 = 0xE2

    /// Chords that type `text` on a US layout. Accented Latin letters use the layout's Option dead
    /// keys, so "é" is Option-E then E, as on a Mac or an iPad with a hardware keyboard.
    public static func chords(forTyping text: String) throws -> [Chord] {
        var chords: [Chord] = []
        for character in text {
            if let stroke = strokeByCharacter[character] {
                chords.append(Chord(stroke))
                continue
            }
            if character == "ç" || character == "Ç" {
                chords.append(Chord(usage: 0x06, modifiers: character == "Ç" ? [leftOption, leftShift] : [leftOption]))
                continue
            }
            // "é" decomposes to "e" plus a combining acute accent, which is the dead key's job.
            let scalars = Array(String(character).decomposedStringWithCanonicalMapping.unicodeScalars)
            guard scalars.count == 2,
                  let deadKey = deadKeyUsageByMark[scalars[1].value],
                  let base = strokeByCharacter[Character(scalars[0])],
                  scalars[0].properties.isAlphabetic
            else { throw Untypeable(character: character) }
            chords.append(Chord(usage: deadKey, modifiers: [leftOption]))
            chords.append(Chord(base))
        }
        return chords
    }

    /// Combining marks to the key that, with Option, makes the matching dead key on a US layout.
    static let deadKeyUsageByMark: [UInt32: UInt32] = [
        0x0301: 0x08, // acute: E
        0x0300: 0x35, // grave: `
        0x0302: 0x0C, // circumflex: I
        0x0303: 0x11, // tilde: N
        0x0308: 0x18, // diaeresis: U
    ]

    /// Names a person or script would use for a key, for the command line tool.
    public static let usageByKeyName: [String: UInt32] = {
        var map: [String: UInt32] = [
            "return": 0x28, "enter": 0x28, "escape": 0x29, "esc": 0x29,
            "delete": 0x2A, "backspace": 0x2A, "tab": 0x2B, "space": 0x2C,
            "forwarddelete": 0x4C, "home": 0x4A, "end": 0x4D, "pageup": 0x4B, "pagedown": 0x4E,
            "right": 0x4F, "left": 0x50, "down": 0x51, "up": 0x52, "capslock": 0x39,
        ]
        for index in 1...12 { map["f\(index)"] = UInt32(0x3A + index - 1) }
        return map
    }()

    public static let modifierUsageByName: [String: UInt32] = [
        "cmd": leftCommand, "command": leftCommand,
        "shift": leftShift,
        "alt": leftOption, "option": leftOption, "opt": leftOption,
        "ctrl": leftControl, "control": leftControl,
    ]

    /// A named key or a single character, with the modifiers it needs. "B" is Shift-B.
    public static func chord(forKeyName name: String, modifiers: [UInt32] = []) -> Chord? {
        var base: Chord?
        if let usage = usageByKeyName[name.lowercased()] {
            base = Chord(usage: usage)
        } else if name.count == 1, let stroke = strokeByCharacter[Character(name)] {
            base = Chord(stroke)
        }
        guard let base else { return nil }
        var all = modifiers
        for modifier in base.modifiers where !all.contains(modifier) { all.append(modifier) }
        return Chord(usage: base.usage, modifiers: all)
    }

    static let strokeByCharacter: [Character: Stroke] = {
        var map: [Character: Stroke] = [:]
        for (index, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            map[letter] = Stroke(usage: UInt32(0x04 + index), shift: false)
            map[Character(letter.uppercased())] = Stroke(usage: UInt32(0x04 + index), shift: true)
        }
        let unshiftedDigits = Array("1234567890")
        let shiftedDigits = Array("!@#$%^&*()")
        for index in 0..<10 {
            map[unshiftedDigits[index]] = Stroke(usage: UInt32(0x1E + index), shift: false)
            map[shiftedDigits[index]] = Stroke(usage: UInt32(0x1E + index), shift: true)
        }
        let pairs: [(Character, Character, UInt32)] = [
            ("-", "_", 0x2D), ("=", "+", 0x2E), ("[", "{", 0x2F), ("]", "}", 0x30),
            ("\\", "|", 0x31), (";", ":", 0x33), ("'", "\"", 0x34), ("`", "~", 0x35),
            (",", "<", 0x36), (".", ">", 0x37), ("/", "?", 0x38),
        ]
        for (plain, shifted, usage) in pairs {
            map[plain] = Stroke(usage: usage, shift: false)
            map[shifted] = Stroke(usage: usage, shift: true)
        }
        map["\n"] = Stroke(usage: 0x28, shift: false)
        map["\t"] = Stroke(usage: 0x2B, shift: false)
        map[" "] = Stroke(usage: 0x2C, shift: false)
        return map
    }()
}

extension KeyboardMap.Chord {
    init(_ stroke: KeyboardMap.Stroke) {
        self.init(usage: stroke.usage, modifiers: stroke.shift ? [KeyboardMap.leftShift] : [])
    }
}
