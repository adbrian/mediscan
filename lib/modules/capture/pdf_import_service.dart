import 'dart:io';
import 'dart:typed_data';

import 'package:syncfusion_flutter_pdf/pdf.dart' as syncfusion;
import 'package:pdfx/pdfx.dart' as pdfx;

/// Result of extracting content from a PDF file.
///
/// Either [textLines] (text-layer path) or [pageImages] (rasterization path)
/// will be populated, depending on whether the PDF has an embedded text layer.
class PdfExtractionResult {
  /// Whether the PDF contained a usable embedded text layer.
  final bool hasTextLayer;

  /// Extracted text lines from the text layer, one entry per line of text.
  /// Populated only when [hasTextLayer] is `true`.
  final List<String>? textLines;

  /// Rasterized page images (PNG bytes), one entry per page.
  /// Populated only when [hasTextLayer] is `false` (fallback to OCR path).
  final List<Uint8List>? pageImages;

  const PdfExtractionResult({
    required this.hasTextLayer,
    this.textLines,
    this.pageImages,
  });
}

/// Service for importing and extracting content from PDF lab reports.
///
/// Implements the "PDF text-layer first" strategy described in the MediScan
/// spec: digitally generated PDFs (most Indian lab PDFs, e.g. DDRC Agilus)
/// yield perfect text via the embedded text layer, which is faster and more
/// accurate than OCR. Rasterization + OCR is the fallback for scanned /
/// image-only PDFs.
class PdfImportService {
  /// Minimum character count to consider a text layer as "present and usable".
  ///
  /// Some PDFs have a vestigial text layer with only a few whitespace or
  /// control characters. A threshold of 20 printable characters filters those
  /// out without rejecting genuinely short single-page reports.
  static const int _minTextLayerLength = 20;

  /// Extracts content from the PDF at [filePath].
  ///
  /// 1. Attempts text-layer extraction using Syncfusion Flutter PDF.
  /// 2. If the total extracted text is shorter than [_minTextLayerLength],
  ///    falls back to rasterizing every page at 300 DPI quality using pdfx.
  ///
  /// Returns a [PdfExtractionResult] with either [textLines] or [pageImages].
  Future<PdfExtractionResult> extractFromPdf(String filePath) async {
    // ------------------------------------------------------------------
    // Step 1: Try text-layer extraction (preferred — fast, pixel-perfect)
    // ------------------------------------------------------------------
    final textLines = await _extractTextLayer(filePath);
    if (textLines != null) {
      return PdfExtractionResult(
        hasTextLayer: true,
        textLines: textLines,
      );
    }

    // ------------------------------------------------------------------
    // Step 2: Fallback — rasterize pages to images for the OCR path
    // ------------------------------------------------------------------
    final pageImages = await _rasterizePages(filePath);
    return PdfExtractionResult(
      hasTextLayer: false,
      pageImages: pageImages,
    );
  }

  /// Attempts to extract text from the PDF's embedded text layer.
  ///
  /// Returns a list of non-empty text lines if the PDF has a meaningful text
  /// layer, or `null` if the text layer is absent or too sparse.
  Future<List<String>?> _extractTextLayer(String filePath) async {
    try {
      final fileBytes = await File(filePath).readAsBytes();
      final document = syncfusion.PdfDocument(inputBytes: fileBytes);

      // PdfTextExtractor takes the document, not a page; the page range is
      // selected per call below.
      final extractor = syncfusion.PdfTextExtractor(document);

      final allLines = <String>[];

      for (var i = 0; i < document.pages.count; i++) {
        // layoutText preserves the horizontal spacing between columns, which
        // the parameter-value-unit retain regex depends on. Without it the
        // extractor returns reading-order text and every table row collapses
        // into an unmatchable string.
        final pageText = extractor.extractText(
          startPageIndex: i,
          endPageIndex: i,
          layoutText: true,
        );

        if (pageText.isNotEmpty) {
          // Split into lines and keep only non-blank ones.
          final lines = pageText
              .split('\n')
              .map((line) => line.trim())
              .where((line) => line.isNotEmpty)
              .toList();
          allLines.addAll(lines);
        }
      }

      document.dispose();

      // Check if the total extracted text is substantial enough to be useful.
      final totalChars =
          allLines.fold<int>(0, (sum, line) => sum + line.length);
      if (totalChars >= _minTextLayerLength) {
        return allLines;
      }

      return null;
    } catch (_) {
      // Text-layer extraction failed — fall through to rasterization.
      return null;
    }
  }

  /// Rasterizes every page of the PDF to a PNG image.
  ///
  /// Uses the pdfx package to render each page at high quality (equivalent to
  /// ~300 DPI for standard page sizes). The resulting images are suitable for
  /// ML Kit OCR processing.
  Future<List<Uint8List>> _rasterizePages(String filePath) async {
    final document = await pdfx.PdfDocument.openFile(filePath);
    final pageImages = <Uint8List>[];

    try {
      for (var i = 1; i <= document.pagesCount; i++) {
        final page = await document.getPage(i);

        // Render at 3× the default resolution for ~300 DPI output on
        // standard letter/A4 pages. pdfx renders at 72 DPI by default,
        // so a width multiplier of ~3 gets us to ~216 DPI minimum; we
        // use the page's native width × 3 to ensure high quality OCR input.
        final pageImage = await page.render(
          width: page.width * 3,
          height: page.height * 3,
          format: pdfx.PdfPageImageFormat.png,
          backgroundColor: '#FFFFFF',
        );

        if (pageImage != null && pageImage.bytes.isNotEmpty) {
          pageImages.add(pageImage.bytes);
        }

        await page.close();
      }
    } finally {
      await document.close();
    }

    return pageImages;
  }
}
