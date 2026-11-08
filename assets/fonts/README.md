# Optional Unicode fonts

The PDF engine uses Helvetica by default, which only covers Latin-1 characters.
To render Hindi / Marathi (Devanagari) or other non-Latin text inside generated
PDFs (TXT → PDF, DOCX → PDF, searchable-PDF text layers, text stamps), place
these files here (both are SIL Open Font License, from https://fonts.google.com/noto):

- `NotoSans-Regular.ttf`
- `NotoSansDevanagari-Regular.ttf`

The app detects them at runtime (`PdfFonts.load()`); no code change is needed.
