import Cocoa
import UniformTypeIdentifiers
import ImageIO
import WebP

/// Shared image encoding with user-configurable format, quality, and resolution.
enum ImageEncoder {

    enum Format: String {
        case png = "png"
        case jpeg = "jpeg"
        case heic = "heic"
        case webp = "webp"
    }

    static var format: Format {
        if let raw = UserDefaults.standard.string(forKey: "imageFormat"),
           let fmt = Format(rawValue: raw) {
            return fmt
        }
        return .png
    }

    /// Lossy quality 0.0–1.0 (used for JPEG, HEIC, and WebP)
    static var quality: CGFloat {
        if let q = UserDefaults.standard.object(forKey: "imageQuality") as? Double {
            return CGFloat(max(0.1, min(1.0, q)))
        }
        return 0.85
    }

    /// Whether to downscale Retina (2x) screenshots to standard (1x) resolution.
    static var downscaleRetina: Bool {
        UserDefaults.standard.bool(forKey: "downscaleRetina")
    }

    static var fileExtension: String {
        switch format {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .webp: return "webp"
        }
    }

    static var utType: UTType {
        switch format {
        case .png: return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        case .webp: return .webP
        }
    }

    // MARK: - Shared bitmap creation

    /// Create a bitmap representation from an NSImage, optionally downscaling from Retina.
    /// This is the single conversion point — all encode paths go through here.
    /// Uses cgImage(forProposedRect:) instead of tiffRepresentation to preserve
    /// exact pixel data regardless of the current display's backing scale factor.
    private static func makeBitmap(_ image: NSImage) -> NSBitmapImageRep? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            // Fallback for images without a CGImage backing (e.g. PDF/EPS vectors)
            guard let tiffData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
            return bitmap
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)

        if downscaleRetina {
            let logicalW = Int(image.size.width)
            let logicalH = Int(image.size.height)
            let pixelW = bitmap.pixelsWide
            let pixelH = bitmap.pixelsHigh

            if pixelW > logicalW && pixelH > logicalH {
                let cs = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
                let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
                guard let ctx = CGContext(
                    data: nil,
                    width: logicalW, height: logicalH,
                    bitsPerComponent: 8,
                    bytesPerRow: logicalW * 4,
                    space: cs,
                    bitmapInfo: bitmapInfo
                ) else { return bitmap }
                ctx.interpolationQuality = .high
                ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: logicalW, height: logicalH))
                guard let downscaled = ctx.makeImage() else { return bitmap }
                return NSBitmapImageRep(cgImage: downscaled)
            }
        }

        return bitmap
    }

    // MARK: - Encoding

    /// Encode an NSImage to Data in the configured format.
    static func encode(_ image: NSImage) -> Data? {
        guard let bitmap = makeBitmap(image) else { return nil }

        switch format {
        case .png:
            return encodePNG(bitmap: bitmap)
        case .jpeg:
            return encodeJPEG(bitmap: bitmap, quality: quality)
        case .heic:
            return encodeHEIC(bitmap: bitmap, quality: quality)
        case .webp:
            return encodeWebP(bitmap: bitmap, quality: quality)
        }
    }

    /// Encode PNG with native color profile embedded.
    private static func encodePNG(bitmap: NSBitmapImageRep) -> Data? {
        guard let cgImage = bitmap.cgImage else {
            return bitmap.representation(using: .png, properties: [:])
        }
        return encodeWithCGImageDestination(cgImage: cgImage, type: "public.png", lossyQuality: nil)
    }

    /// Encode JPEG with native color profile embedded.
    private static func encodeJPEG(bitmap: NSBitmapImageRep, quality: CGFloat) -> Data? {
        guard let cgImage = bitmap.cgImage else {
            return bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
        }
        return encodeWithCGImageDestination(cgImage: cgImage, type: "public.jpeg", lossyQuality: quality)
    }

    /// Encode HEIC via CGImageDestination (NSBitmapImageRep doesn't support HEIC).
    private static func encodeHEIC(bitmap: NSBitmapImageRep, quality: CGFloat) -> Data? {
        guard let cgImage = bitmap.cgImage else { return nil }
        return encodeWithCGImageDestination(cgImage: cgImage, type: "public.heic", lossyQuality: quality)
    }

    /// Encode WebP via Swift-WebP (libwebp).
    /// Uses the CGImage RGBA path directly — the library's NSImage path has a bug
    /// (assumes RGB stride and logical size instead of pixel size).
    private static func encodeWebP(bitmap: NSBitmapImageRep, quality: CGFloat) -> Data? {
        guard let srcImage = bitmap.cgImage else { return nil }
        let w = srcImage.width
        let h = srcImage.height
        // Re-render into a known premultipliedLast RGBA context (preserving source color space)
        let cs = srcImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(srcImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let rgbaImage = ctx.makeImage() else { return nil }

        let encoder = WebPEncoder()
        let config = WebPEncoderConfig.preset(.picture, quality: Float(quality * 100))
        return try? encoder.encode(RGBA: rgbaImage, config: config)
    }

    /// Generic CGImageDestination encoder — embeds the source color profile.
    /// The CGImage already carries its display's ICC profile (e.g. Display P3).
    /// CGImageDestination embeds it automatically — no pixel conversion needed.
    private static func encodeWithCGImageDestination(cgImage: CGImage, type: String, lossyQuality: CGFloat?) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type as CFString, 1, nil) else { return nil }

        var properties: [String: Any] = [:]
        if let q = lossyQuality {
            properties[kCGImageDestinationLossyCompressionQuality as String] = q
        }

        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    // MARK: - Clipboard

    /// Dedicated subfolder for the clipboard-paste temp file. Isolated so
    /// we can sweep it without worrying about matching user-configured
    /// filename templates. Created lazily by `clipboardTmpDirectory`.
    private static let clipboardTmpSubfolder = "macshot-clipboard"

    /// Path to the clipboard temp subfolder. Always exists after first
    /// access — created on demand with `createDirectory(withIntermediateDirectories: true)`.
    static let clipboardTmpDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(clipboardTmpSubfolder)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }()

    /// Maximum age for clipboard image files that external apps may still reference.
    private static let clipboardFileTTL: TimeInterval = 24 * 60 * 60

    /// Removes old clipboard image files while preserving recent paste targets.
    private static func sweepExpiredClipboardFiles() {
        let cutoff = Date().addingTimeInterval(-clipboardFileTTL)
        let fm = FileManager.default

        // Read only direct child files so unrelated temporary directories are untouched.
        guard let contents = try? fm.contentsOfDirectory(
            at: clipboardTmpDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return }

        for url in contents {
            // Skip active or malformed entries unless they are known regular files.
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }

            // Deletion is best-effort; launch cleanup will retry later if needed.
            try? fm.removeItem(at: url)
        }
    }

    /// Copy image to pasteboard as PNG.
    /// Explicitly sets PNG data so receiving apps (browsers, editors) get
    /// a lossless PNG instead of the TIFF that NSImage.writeObjects provides.
    /// Also writes a temp file so Finder paste (Cmd+V in a folder) works
    /// and the pasted file has a nice date-stamped filename instead of
    /// something like `macshot-clipboard.png`.
    ///
    /// Disk hygiene:
    ///   - Each copy gets its own short-lived file because chat apps may
    ///     keep the file URL after paste and only read it when the message
    ///     is sent. Deleting the previous file during the next screenshot
    ///     makes earlier pasted images fail with "file not found".
    ///   - Files live in `tmp/macshot-clipboard/` and are swept after 24
    ///     hours, which keeps multi-image paste reliable without letting
    ///     abandoned temporary files accumulate indefinitely.
    static func copyToClipboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        DispatchQueue.global(qos: .userInitiated).async {
            guard let bitmap = makeBitmap(image),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else { return }

            // Keep recent files for pasted-but-not-yet-sent chat drafts, then prune old leftovers.
            sweepExpiredClipboardFiles()

            // Compute the new file path with a date-stamped filename so
            // Finder pastes land as a nicely named file. A counter suffix
            // keeps rapid repeated captures from colliding within the same second.
            let dir = clipboardTmpDirectory
            var candidate = dir.appendingPathComponent(FilenameFormatter.defaultImageFilename())
            var counter = 2
            while FileManager.default.fileExists(atPath: candidate.path) {
                let base = FilenameFormatter.defaultImageFilename()
                    .replacingOccurrences(of: ".\(ImageEncoder.fileExtension)", with: "")
                candidate = dir.appendingPathComponent("\(base) (\(counter)).\(ImageEncoder.fileExtension)")
                counter += 1
                if counter > 1000 { break }  // sanity
            }
            let newURL = candidate

            // Write atomically so receiving apps never observe a partially written image file.
            let writeOK = (try? pngData.write(to: newURL, options: .atomic)) != nil

            let fileURL = writeOK ? newURL : nil
            DispatchQueue.main.async {
                var types: [NSPasteboard.PasteboardType] = [.png]
                if fileURL != nil { types.append(.fileURL) }
                pasteboard.declareTypes(types, owner: nil)
                pasteboard.setData(pngData, forType: .png)
                if let url = fileURL {
                    pasteboard.setString(url.absoluteString, forType: .fileURL)
                }
            }
        }
    }
}
