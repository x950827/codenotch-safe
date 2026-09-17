import AppKit
import SwiftUI

struct AboutView: View {
    let openLicense: () -> Void

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "Unknown"
        return "Version \(version) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 88, height: 88)

                VStack(spacing: 4) {
                    Text("Codenotch Safe")
                        .font(.title.bold())
                    Text(versionText)
                        .foregroundStyle(.secondary)
                }

                Text(AboutMetadata.attribution)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 9) {
                    Text("Safe fork changes")
                        .font(.headline)
                    ForEach(AboutMetadata.safeChanges, id: \.self) { change in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•")
                            Text(change)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 14) {
                    Link("Original", destination: AboutMetadata.originalSourceURL)
                    Link("Safe source", destination: AboutMetadata.safeSourceURL)
                    Link("Security audit", destination: AboutMetadata.auditURL)
                }

                Button("View MIT License", action: openLicense)
                Text(AboutMetadata.copyright)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
        }
        .frame(width: 560, height: 620)
    }
}
