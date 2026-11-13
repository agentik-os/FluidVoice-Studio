//
//  RemoteMicHotkeyMatch.swift
//  FluidVoice Studio
//
//  Screen Sharing and iPad keyboards deliver Ctrl+Opt+D with an extra Fn/globe
//  flag, and sometimes a non-ANSI key code whose unicode is still "d".
//  Modifier-only shortcuts, including Fn tap-to-toggle / hold-to-talk, do not
//  use this exception.
//

import Foundation

nonisolated enum RemoteMicHotkeyMatch {
    static let functionFlag: UInt = 1 << 23
    static let shiftFlag: UInt = 1 << 17
    static let controlFlag: UInt = 1 << 18
    static let optionFlag: UInt = 1 << 19
    static let commandFlag: UInt = 1 << 20
    static let remoteControlKeyCode: UInt16 = 2
    static let relevantMask: UInt = functionFlag | shiftFlag | controlFlag | optionFlag | commandFlag

    static func flagsMatch(
        eventFlags: UInt,
        shortcutFlags: UInt,
        relevantMask: UInt,
        shortcutIsModifierOnly: Bool
    ) -> Bool {
        var event = eventFlags & relevantMask
        let shortcut = shortcutFlags & relevantMask
        let shortcutWantsFunction = self.contains(shortcut, self.functionFlag)
        if shortcutIsModifierOnly == false, shortcutWantsFunction == false {
            event &= ~self.functionFlag
        }
        return event == shortcut
    }

    static func keyCodesMatch(
        shortcutKeyCode: UInt16,
        eventKeyCode: UInt16,
        unicode: String?,
        eventFlags: UInt
    ) -> Bool {
        if shortcutKeyCode == eventKeyCode { return true }
        guard shortcutKeyCode == self.remoteControlKeyCode else { return false }
        guard self.hasControlAndOption(eventFlags) else { return false }
        return self.normalizedLetter(unicode) == "d"
    }

    static func canonicalEventKeyCode(
        rawKeyCode: UInt16,
        unicode: String?,
        eventFlags: UInt,
        activeRemotePress: Bool
    ) -> UInt16 {
        if rawKeyCode == self.remoteControlKeyCode { return rawKeyCode }
        guard self.normalizedLetter(unicode) == "d" else { return rawKeyCode }
        if activeRemotePress || self.hasControlAndOption(eventFlags) {
            return self.remoteControlKeyCode
        }
        return rawKeyCode
    }

    static func hasControlAndOption(_ flags: UInt) -> Bool {
        self.contains(flags, self.controlFlag) && self.contains(flags, self.optionFlag)
    }

    static func normalizedLetter(_ unicode: String?) -> String? {
        guard let unicode else { return nil }
        let trimmed = unicode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count == 1 else { return nil }
        return trimmed
    }

    private static func contains(_ flags: UInt, _ bit: UInt) -> Bool {
        flags & bit != 0
    }
}
