// Tessera/Settings/FilesSettingsView.swift
// Remote Files settings.

import SwiftUI

struct FilesSettingsView: View {
    @Environment(AppearancePreferences.self) private var appearance
    @Environment(\.designTokens) private var T

    private let cleanupOptions: [(value: Int, label: LocalizedStringResource)] = [
        (0, "off"),
        (1, "1 d"),
        (7, "7 d"),
        (30, "30 d")
    ]
    private let destinationOptions: [(value: String, label: LocalizedStringResource)] = [
        ("cwd", "session cwd"),
        ("temp", "temp folder")
    ]

    var body: some View {
        @Bindable var appearance = appearance

        VStack(alignment: .leading, spacing: 0) {
            SettingsH("files")

            Field(
                label: "temp file cleanup",
                sub: "how many days paste/temp files survive on hosts before the reaper deletes them on connect"
            ) {
                HStack(alignment: .center, spacing: 12) {
                    FilesSegmentedPicker(
                        options: cleanupOptions,
                        selection: $appearance.filesReaperDays
                    )

                    Text(verbatim: cleanupDisplay(appearance.filesReaperDays))
                        .font(Typography.tesseraMono(size: 12, weight: .medium))
                        .foregroundStyle(T.fg)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 10)
                        .background(T.panelBg)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(T.border, lineWidth: 1)
                        )
                }
            }

            Field(
                label: "default upload destination",
                sub: "where the upload sheet starts for each host"
            ) {
                FilesSegmentedPicker(
                    options: destinationOptions,
                    selection: $appearance.filesDefaultDestination
                )
            }

            footnoteRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cleanupDisplay(_ days: Int) -> String {
        days == 0
            ? String(localized: "off", comment: "Temp-file cleanup is disabled")
            : String(localized: "\(days) d", comment: "Temp-file retention, in days")
    }

    private var footnoteRow: some View {
        Text("cwd-follow shell integration lives in the Files panel. when no directory signal exists, the panel shows an Install button there.")
            .font(Typography.tesseraMono(size: 11))
            .foregroundStyle(T.fgDim)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(T.panelBg)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(T.border, lineWidth: 1)
            )
    }
}

private struct FilesSegmentedPicker<Value: Hashable>: View {
    let options: [(value: Value, label: LocalizedStringResource)]
    @Binding var selection: Value

    @Environment(\.designTokens) private var T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                segment(option.label, value: option.value)
            }
        }
        .padding(3)
        .background(T.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(T.border, lineWidth: 1)
        )
    }

    private func segment(_ label: LocalizedStringResource, value: Value) -> some View {
        let active = selection == value

        return Button {
            selection = value
        } label: {
            Text(label)
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(active ? T.accent : T.fgMuted)
                .padding(.vertical, 7)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .background(active ? T.accentSoft : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}
