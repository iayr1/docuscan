# DocuScan

**DocuScan** is a private, on-device document scanner and manager built with Flutter. Scan physical documents with automatic edge detection, import images from your photo gallery, perform on-device OCR (Optical Character Recognition), and generate multi-page PDF documents without sending your data to external servers.

## Features

- 📸 **Camera Scan:** Capture multi-page documents with automatic page edge detection.
- 🖼️ **Image Import:** Import existing photos from your gallery and convert them into organized documents.
- 🔍 **On-Device OCR:** Extract text from document images privately using Google ML Kit.
- 📄 **PDF Generation:** Merge single or multi-page scans into clean, shareable PDF files.
- 🔒 **Privacy First:** All documents, images, and text extractions are stored locally on your device.
- 📤 **Organize & Share:** Easily search, preview, share, and delete your saved documents.

## Tech Stack

- **Framework:** [Flutter](https://flutter.dev/) (Material 3)
- **Scanning:** `flutter_doc_scanner`
- **Text Recognition (OCR):** `google_mlkit_text_recognition`
- **PDF Creation:** `pdf`
- **File Management:** `path_provider`
- **Sharing:** `share_plus`
- **Media Picker:** `image_picker`

## Getting Started

### Prerequisites

- [Flutter SDK](https://docs.flutter.dev/get-started/install) (3.12.2 or later)
- Android Studio / Xcode (depending on target platform)

### Installation

1. Clone this repository:
   ```bash
   git clone https://github.com/iayr1/docuscan.git
   cd docuscan
   ```

2. Install dependencies:
   ```bash
   flutter pub get
   ```

3. Run the app:
   ```bash
   flutter run
   ```

## License

This project is licensed under the [MIT License](LICENSE) (or see repository settings).
