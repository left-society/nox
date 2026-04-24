import AppKit

enum ClipboardService {
    static func copy(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func copy(images: [NSImage], fileURLs: [URL] = []) {
        let pb = NSPasteboard.general
        pb.clearContents()
        var items: [NSPasteboardItem] = []
        for (idx, image) in images.enumerated() {
            let item = NSPasteboardItem()
            if let tiff = image.tiffRepresentation {
                item.setData(tiff, forType: .tiff)
            }
            if let rep = image.representations.first as? NSBitmapImageRep,
               let png = rep.representation(using: .png, properties: [:]) {
                item.setData(png, forType: .png)
            }
            if idx < fileURLs.count {
                item.setString(fileURLs[idx].absoluteString, forType: .fileURL)
            }
            items.append(item)
        }
        pb.writeObjects(items)
    }

    static func copy(note: Note, attachedImages: [(NSImage, URL)]) {
        if attachedImages.isEmpty {
            copy(text: note.body)
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        var items: [NSPasteboardItem] = []

        let textItem = NSPasteboardItem()
        textItem.setString(note.body, forType: .string)
        items.append(textItem)

        for (image, url) in attachedImages {
            let item = NSPasteboardItem()
            if let tiff = image.tiffRepresentation {
                item.setData(tiff, forType: .tiff)
            }
            item.setString(url.absoluteString, forType: .fileURL)
            items.append(item)
        }
        pb.writeObjects(items)
    }
}
