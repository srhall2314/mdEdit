//
//  Settings.swift
//  mdEdit
//
//  User preferences (⌘,) and the settings-driven editor typography. iA Writer
//  keeps type fixed; we give a small, curated set of choices instead — a font
//  family, size, line spacing, and appearance — nothing that clutters the UI.
//

import SwiftUI
import AppKit

enum SettingsKeys {
    static let fontFamily = "editor.fontFamily"
    static let fontSize = "editor.fontSize"
    static let lineHeight = "editor.lineHeight"
    static let appearance = "app.appearance"
    static let focusMode = "editor.focusMode"
    static let showWordCount = "editor.showWordCount"

    static let defaultFontSize = 15.0
    static let defaultLineHeight = 1.5
}

enum EditorFontFamily: String, CaseIterable, Identifiable {
    case mono, serif, sans, rounded

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mono: "Monospaced"
        case .serif: "Serif"
        case .sans: "Sans Serif"
        case .rounded: "Rounded"
        }
    }

    func font(size: CGFloat) -> NSFont {
        switch self {
        case .mono:
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        case .sans:
            return .systemFont(ofSize: size)
        case .serif:
            return Self.systemFont(size: size, design: .serif)
        case .rounded:
            return Self.systemFont(size: size, design: .rounded)
        }
    }

    private static func systemFont(size: CGFloat, design: NSFontDescriptor.SystemDesign) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        if let descriptor = base.fontDescriptor.withDesign(design) {
            return NSFont(descriptor: descriptor, size: size) ?? base
        }
        return base
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// A resolved snapshot of the editor typography. Equatable so the editor can
/// cheaply detect when settings change and re-apply attributes.
struct EditorStyle: Equatable {
    var family: EditorFontFamily
    var size: CGFloat
    var lineHeight: CGFloat

    init(familyRaw: String, size: Double, lineHeight: Double) {
        self.family = EditorFontFamily(rawValue: familyRaw) ?? .mono
        self.size = size
        self.lineHeight = lineHeight
    }

    var nsFont: NSFont { family.font(size: size) }

    var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeight
        style.paragraphSpacing = size * 0.55
        return style
    }

    var typingAttributes: [NSAttributedString.Key: Any] {
        [
            .font: nsFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle,
        ]
    }
}

// MARK: - Settings UI

struct SettingsView: View {
    @AppStorage(SettingsKeys.fontFamily) private var fontFamily = EditorFontFamily.mono.rawValue
    @AppStorage(SettingsKeys.fontSize) private var fontSize = SettingsKeys.defaultFontSize
    @AppStorage(SettingsKeys.lineHeight) private var lineHeight = SettingsKeys.defaultLineHeight
    @AppStorage(SettingsKeys.appearance) private var appearance = AppAppearance.system.rawValue

    var body: some View {
        Form {
            Section("Typography") {
                Picker("Font", selection: $fontFamily) {
                    ForEach(EditorFontFamily.allCases) { family in
                        Text(family.label).tag(family.rawValue)
                    }
                }

                LabeledContent("Size") {
                    HStack {
                        Slider(value: $fontSize, in: 11...24, step: 1)
                        Text("\(Int(fontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }

                Picker("Line Spacing", selection: $lineHeight) {
                    Text("Tight").tag(1.2)
                    Text("Normal").tag(1.5)
                    Text("Relaxed").tag(1.8)
                }
            }

            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
