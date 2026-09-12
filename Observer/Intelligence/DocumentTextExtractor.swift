import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

enum DocumentTextExtractorError: LocalizedError {
    case unsupportedType(String)
    case unreadable
    case empty

    var errorDescription: String? {
        switch self {
        case .unsupportedType(let ext):
            return "Unsupported document type.\(ext.isEmpty ? "" : " (.\(ext))")"
        case .unreadable:
            return "Could not read document text."
        case .empty:
            return "Document contained no extractable text."
        }
    }
}

enum DocumentTextExtractor {
    static let supportedContentTypes: [UTType] = [
        .pdf,
        .plainText,
        .utf8PlainText,
        .text,
        .rtf,
        UTType(filenameExtension: "md") ?? .plainText,
        UTType(filenameExtension: "markdown") ?? .plainText
    ]

    static func extract(url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        let text: String
        switch ext {
        case "pdf":
            text = try extractPDF(url)
        case "rtf":
            text = try extractRTF(url)
        case "txt", "md", "markdown", "text":
            text = try extractPlainText(url)
        default:
            if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
                if type.conforms(to: .pdf) {
                    text = try extractPDF(url)
                } else if type.conforms(to: .rtf) {
                    text = try extractRTF(url)
                } else if type.conforms(to: .plainText) || type.conforms(to: .text) {
                    text = try extractPlainText(url)
                } else {
                    throw DocumentTextExtractorError.unsupportedType(ext)
                }
            } else {
                throw DocumentTextExtractorError.unsupportedType(ext)
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DocumentTextExtractorError.empty }
        return trimmed
    }

    private static func extractPlainText(_ url: URL) throws -> String {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            return utf8
        }
        if let utf16 = try? String(contentsOf: url, encoding: .utf16) {
            return utf16
        }
        if let ascii = try? String(contentsOf: url, encoding: .ascii) {
            return ascii
        }
        throw DocumentTextExtractorError.unreadable
    }

    private static func extractRTF(_ url: URL) throws -> String {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.rtf
        ]
        guard let attributed = try? NSAttributedString(
            url: url,
            options: options,
            documentAttributes: nil
        ) else {
            throw DocumentTextExtractorError.unreadable
        }
        return attributed.string
    }

    private static func extractPDF(_ url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw DocumentTextExtractorError.unreadable
        }
        var pages: [String] = []
        pages.reserveCapacity(document.pageCount)
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index),
                  let string = page.string,
                  !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            pages.append(string)
        }
        guard !pages.isEmpty else { throw DocumentTextExtractorError.empty }
        return pages.joined(separator: "\n\n")
    }
}
