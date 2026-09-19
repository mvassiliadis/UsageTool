import SwiftUI

enum DesignTokens {
    enum Space {
        static let x2: CGFloat = 2
        static let x4: CGFloat = 4
        static let x6: CGFloat = 6
        static let x8: CGFloat = 8
        static let x10: CGFloat = 10
        static let x12: CGFloat = 12
        static let x16: CGFloat = 16
    }

    enum Radius {
        static let tile: CGFloat = 6
        static let bar: CGFloat = 3
        static let preview: CGFloat = 8
    }

    /// `MenuBarPanel` sizes itself from its hosting controller's `preferredContentSize`, which
    /// comes from the root view's *definite* height and falls back to the minimum whenever that
    /// root is height-flexible. A root `.frame(minHeight:)` therefore pins the popover to that
    /// minimum and clips anything taller, so `PopoverView` keeps both of its branches definite
    /// instead: each is sized to its own content, and the provider list is capped at
    /// `maxContentHeight`.
    enum Popover {
        static let width: CGFloat = 340

        /// Header, footer and the surrounding padding, i.e. everything outside the content area.
        static let chromeHeight: CGFloat = 86

        /// Overall ceiling for the popover window; the provider list scrolls beyond it.
        static let maxHeight: CGFloat = 560

        static var maxContentHeight: CGFloat { maxHeight - chromeHeight }
    }

    enum Settings {
        static let width: CGFloat = 560
        static let minHeight: CGFloat = 420
    }
}

