// Tessera/Design/Typography.swift
import SwiftUI
import CoreText

enum Typography {
    static func tesseraMono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom("JetBrainsMono-Regular", size: size, relativeTo: .body)
            .weight(weight)
    }

    static func tesseraSans(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.system(size: size, weight: weight, design: .default)
    }
}

/// Call once at app startup (e.g. from TesseraApp.init) to register any
/// embedded TTF fonts in the main bundle before SwiftUI tries to resolve them.
func registerEmbeddedFonts() {
    guard let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) else { return }
    CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
}
