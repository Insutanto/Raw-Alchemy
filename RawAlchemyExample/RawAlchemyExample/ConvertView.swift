import SwiftUI

// MARK: - Processing + Result screen

/// Displayed after the user taps "Process" in ContentView.
/// Starts the pipeline immediately via `.task { }` and shows progress,
/// a result preview, or an error message depending on the ViewModel state.
struct ConvertView: View {

    let url: URL
    let options: RawToLogOptions

    @StateObject private var vm = ProcessingViewModel()

    // MARK: Body

    var body: some View {
        Group {
            switch vm.state {

            // ── Processing in progress ──────────────────────────────────────
            case .idle, .processing:
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.6)
                    Text("Processing…")
                        .font(.headline)
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // ── Success ─────────────────────────────────────────────────────
            case let .success(preview, result, elapsed):
                SuccessView(
                    url: url,
                    preview: preview,
                    result: result,
                    elapsed: elapsed
                )

            // ── Error ────────────────────────────────────────────────────────
            case let .failure(error):
                ErrorView(error: error) {
                    Task { await vm.process(url: url, options: options) }
                }
            }
        }
        .navigationTitle(url.deletingPathExtension().lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await vm.process(url: url, options: options)
        }
    }
}

// MARK: - Success layout

private struct SuccessView: View {

    let url: URL
    let preview: UIImage
    let result: RawToLogResult
    let elapsed: TimeInterval

    @State private var showShareSheet = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {

                // ── Preview image ───────────────────────────────────────────
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .background(Color(white: 0.08))

                // ── Log-encoding notice ─────────────────────────────────────
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("Log-encoded images appear flat / low-contrast by design. Apply a viewing LUT or 1D display transform in your colour-grading software.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial)

                Divider()

                // ── Metadata ────────────────────────────────────────────────
                MetadataGrid(result: result, elapsed: elapsed)
                    .padding()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showShareSheet = true
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
        // UIActivityViewController wrapped for iOS 16 compatibility.
        .sheet(isPresented: $showShareSheet) {
            ActivityView(activityItems: [preview])
                .presentationDetents([.medium, .large])
        }
    }
}

// MARK: - Metadata grid

private struct MetadataGrid: View {

    let result: RawToLogResult
    let elapsed: TimeInterval

    private var evString: String {
        let ev = log2(Double(result.appliedGain))
        return String(format: "%.2f×  (%+.2f EV)", result.appliedGain, ev)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Result")
                .font(.headline)

            metaRow("Dimensions",      "\(result.width) × \(result.height) px")
            metaRow("Log Space",       result.logSpace.rawValue)
            metaRow("Exposure Gain",   evString)
            metaRow("Processing Time", String(format: "%.2f s", elapsed))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Error layout

private struct ErrorView: View {

    let error: Error
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.red)
            Text("Processing Failed")
                .font(.title2.bold())
            Text(error.localizedDescription)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try Again", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - UIActivityViewController wrapper

/// Wraps UIActivityViewController so it can be presented as a SwiftUI sheet.
struct ActivityView: UIViewControllerRepresentable {

    let activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: applicationActivities
        )
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController,
                                context: Context) {}
}
