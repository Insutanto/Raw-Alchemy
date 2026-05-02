import SwiftUI
import UniformTypeIdentifiers
import RawAlchemyKit

// MARK: - Main settings screen

struct ContentView: View {

    // MARK: File selection

    @State private var selectedURL: URL?
    @State private var showFilePicker = false

    // MARK: Pipeline options

    @State private var logSpace: LogSpace = .sLog3
    @State private var meteringMode: MeteringMode = .matrix
    @State private var useManualExposure = false
    @State private var exposureEV: Float = 0.0

    // MARK: Navigation

    @State private var navigateToConvert = false

    // Assemble the current RawToLogOptions from the UI state.
    private var currentOptions: RawToLogOptions {
        var opts = RawToLogOptions()
        opts.logSpace     = logSpace
        opts.meteringMode = meteringMode
        opts.exposureEV   = useManualExposure ? exposureEV : nil
        return opts
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Form {

                // ── Input file ──────────────────────────────────────────────
                Section {
                    if let url = selectedURL {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.fill")
                                .font(.title2)
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.lastPathComponent)
                                    .font(.headline)
                                    .lineLimit(1)
                                Text(url.pathExtension.uppercased() + " RAW file")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Change") { showFilePicker = true }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.blue)
                        }
                        .padding(.vertical, 4)
                    } else {
                        Button {
                            showFilePicker = true
                        } label: {
                            Label("Select RAW File…", systemImage: "photo.badge.plus")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } header: {
                    Text("Input")
                } footer: {
                    Text("Supported formats: DNG, CR2, CR3, ARW, NEF, RAF, RW2, and more.")
                }

                // ── Output log space ────────────────────────────────────────
                Section {
                    Picker("Log Space", selection: $logSpace) {
                        ForEach(LogSpace.allCases, id: \.self) { space in
                            Text(space.rawValue).tag(space)
                        }
                    }
                } header: {
                    Text("Output")
                } footer: {
                    Text("Choose the log encoding that matches your camera or target NLE/colour-grading workflow.")
                }

                // ── Exposure ────────────────────────────────────────────────
                Section {
                    Toggle("Manual Exposure", isOn: $useManualExposure.animation())

                    if useManualExposure {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Exposure Offset")
                                Spacer()
                                Text(String(format: "%+.1f EV", exposureEV))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: $exposureEV, in: -5 ... 5, step: 0.1)
                        }
                        .padding(.vertical, 4)
                    } else {
                        Picker("Metering Mode", selection: $meteringMode) {
                            ForEach(MeteringMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                    }
                } header: {
                    Text("Exposure")
                } footer: {
                    if useManualExposure {
                        Text("Manual offset in EV stops applied to all pixels before log encoding.")
                    } else {
                        Text("Automatic metering analyses the image and sets exposure so that the scene key-grey maps to 18%.")
                    }
                }
            }
            .navigationTitle("Raw Alchemy")
            .navigationDestination(isPresented: $navigateToConvert) {
                if let url = selectedURL {
                    ConvertView(url: url, options: currentOptions)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        navigateToConvert = true
                    } label: {
                        Label("Process", systemImage: "wand.and.rays")
                    }
                    .disabled(selectedURL == nil)
                }
            }
            // Accept all image types; RAW files appear under "Files" in the picker.
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.image, .data],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    selectedURL = url
                }
            }
        }
    }
}

// MARK: - MeteringMode display name

extension MeteringMode {
    var displayName: String {
        switch self {
        case .average:        return "Average"
        case .centerWeighted: return "Center Weighted"
        case .highlightSafe:  return "Highlight Safe"
        case .hybrid:         return "Hybrid"
        case .matrix:         return "Matrix (Evaluative)"
        }
    }
}
