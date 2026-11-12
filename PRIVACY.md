# DocuScan privacy policy

_Last updated: 12 November 2026. Applies to DocuScan (package `online.athlorun.scan`)
version 1.0.0 and later, until this policy is updated._

## Summary

DocuScan scans, organises and converts your documents on your device. We don't
collect, upload or sell your documents or personal information. There are no
accounts, no ads and no analytics in the app.

## What stays on your device

- **Scans and imported files:** photos you capture, images and files you import, and
  the documents, PDFs and other files the app creates are stored in the app's private
  storage on your device. They're never uploaded by DocuScan. Deleting the app deletes
  them.
- **Recognised text (OCR):** text is recognised on your device and stored with your
  documents so you can search them.
- **Signatures, stamps and annotations:** saved privately on your device.
- **PIN and Secure Vault:** your PIN is stored only as a salted hash in your device's
  secure storage. Vault documents are encrypted on your device with AES-256. We can't
  see or recover your PIN or vault contents.
- **Biometrics:** fingerprint or face unlock is handled by Android. DocuScan only
  receives a yes/no result and never receives your biometric data.

## What goes online

DocuScan works offline. A few optional features use the internet:

- **Auto scan (document edge detection):** uses Google's ML Kit Document Scanner
  through Google Play services, which may download its components the first time you
  use it.
- **On-device text recognition:** uses Google ML Kit. Recognition runs on your device
  and your images aren't sent to Google. ML Kit may contact Google to get model updates
  and send anonymous performance and usage diagnostics.
- **"Improve text" (optional, Android):** the first time you choose it, the app
  downloads an open-source language model (Qwen2.5 0.5B, about 490 MB) from Hugging
  Face. After that it runs offline. Your text never leaves your device.

These requests come from your device, so those providers receive your IP address and
standard technical details. Their privacy policies apply:
https://policies.google.com/privacy and https://huggingface.co/privacy

- **Sharing and printing:** when you share, export or print a document, it goes to the
  app or printer you choose.

## Permissions

| Permission | Why |
| --- | --- |
| Camera | To scan documents and read QR codes, only while the scanner is open |
| Photos / storage | To import the images you choose |
| Biometrics | Optional fingerprint/face unlock for the app lock and vault |
| Internet | Only for the optional features listed above |

## Children

DocuScan isn't directed at children under 13 and doesn't knowingly collect their
information.

## Changes

If this policy changes, the updated version will be published at this address with a
new "Last updated" date.

## Contact

Questions about this policy or your privacy: mayurailead@gmail.com
