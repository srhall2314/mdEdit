//
//  Theme.swift
//  mdEdit
//
//  Layout constants for the writing surface. Typography itself is
//  user-configurable and lives in EditorStyle (see Settings.swift); this file
//  holds only the geometry that gives the iA Writer-style centered measure.
//

import CoreGraphics

enum Theme {
    /// Maximum width of the text column. Beyond this the margins grow, keeping
    /// a comfortable line length (measure) no matter how wide the window is.
    static let maxMeasure: CGFloat = 700

    /// Minimum horizontal breathing room when the window is narrower than the measure.
    static let minHorizontalInset: CGFloat = 28
    static let verticalInset: CGFloat = 36
}
