//
//  RemoteMicHotkeyEvent.swift
//  FluidVoice Studio
//

import CoreGraphics
import Foundation

nonisolated enum RemoteMicHotkeyEvent {
    static func unicode(from event: CGEvent) -> String? {
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
        guard length > 0, length <= 8 else { return nil }
        var units = [UniChar](repeating: 0, count: length)
        var actual = 0
        event.keyboardGetUnicodeString(
            maxStringLength: length,
            actualStringLength: &actual,
            unicodeString: &units
        )
        guard actual > 0 else { return nil }
        return String(utf16CodeUnits: units, count: actual)
    }
}
