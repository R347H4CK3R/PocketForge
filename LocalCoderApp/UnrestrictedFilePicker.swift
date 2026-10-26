import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A UIKit document picker that deliberately accepts any file, including files
/// whose providers do not advertise the IPA extension as a ZIP UTI.
struct UnrestrictedFilePicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void
    var onFailure: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onFailure: onFailure) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onFailure: (String) -> Void
        init(onPick: @escaping (URL) -> Void, onFailure: @escaping (String) -> Void) {
            self.onPick = onPick
            self.onFailure = onFailure
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let selected = urls.first else {
                onFailure("The Files picker returned no file.")
                return
            }
            onPick(selected)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            // Nothing is wrong when the user closes the picker.
        }
    }
}
