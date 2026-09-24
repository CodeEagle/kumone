#if os(macOS)
import AppKit
#else
import UIKit
#endif

public enum PasteboardAdapter {
    public static let client = PasteboardClient(
        setString: { string in
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
            #elseif os(iOS) || os(visionOS)
            UIPasteboard.general.string = string
            #else
            _ = string // tvOS has no pasteboard; copy is a no-op
            #endif
        }
    )
}
