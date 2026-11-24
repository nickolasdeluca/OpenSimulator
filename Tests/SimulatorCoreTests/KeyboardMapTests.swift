import Testing
@testable import SimulatorCore

struct KeyboardMapTests {
    @Test func lettersAndControlKeysMapToHIDUsages() {
        #expect(KeyboardMap.usage(forKeyCode: 0x00) == 0x04) // A
        #expect(KeyboardMap.usage(forKeyCode: 0x06) == 0x1D) // Z
        #expect(KeyboardMap.usage(forKeyCode: 0x24) == 0x28) // Return
        #expect(KeyboardMap.usage(forKeyCode: 0x33) == 0x2A) // Delete
        #expect(KeyboardMap.usage(forKeyCode: 0x7E) == 0x52) // Up arrow
        #expect(KeyboardMap.modifierUsageByKeyCode[0x38] == 0xE1) // Shift
    }

    @Test func noTwoKeysShareAUsage() {
        let usages = Array(KeyboardMap.usageByKeyCode.values)
        #expect(Set(usages).count == usages.count)
    }

    @Test func typingUsesShiftForCapitalsAndSymbols() {
        let strokes = KeyboardMap.strokes(forTyping: "Hi!")
        #expect(strokes == [
            .init(usage: 0x0B, shift: true),
            .init(usage: 0x0C, shift: false),
            .init(usage: 0x1E, shift: true),
        ])
    }

    @Test func untypeableTextIsRefused() {
        #expect(KeyboardMap.strokes(forTyping: "café") == nil)
    }

    @Test func accentsTypeThroughOptionDeadKeys() throws {
        let option = KeyboardMap.leftOption
        let chords = try KeyboardMap.chords(forTyping: "Oé")
        #expect(chords == [
            .init(usage: 0x12, modifiers: [KeyboardMap.leftShift]),
            .init(usage: 0x08, modifiers: [option]),
            .init(usage: 0x08),
        ])
        #expect(try KeyboardMap.chords(forTyping: "ã") == [.init(usage: 0x11, modifiers: [option]), .init(usage: 0x04)])
        #expect(try KeyboardMap.chords(forTyping: "Ü") == [
            .init(usage: 0x18, modifiers: [option]), .init(usage: 0x18, modifiers: [KeyboardMap.leftShift]),
        ])
        #expect(try KeyboardMap.chords(forTyping: "Ç") == [.init(usage: 0x06, modifiers: [option, KeyboardMap.leftShift])])
    }

    @Test func charactersWithoutAKeyAreNamed() {
        #expect(throws: KeyboardMap.Untypeable(character: "€")) { try KeyboardMap.chords(forTyping: "a€") }
        #expect(throws: KeyboardMap.Untypeable(character: "😀")) { try KeyboardMap.chords(forTyping: "😀") }
    }
}
