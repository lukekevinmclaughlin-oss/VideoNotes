import Foundation
import SketchnoteEngine

// Dev tool: render a sample document (or analyze a media file) to PNG pages.
// Usage:
//   sketchnote-cli <output-dir>                      — render built-in sample
//   sketchnote-cli <output-dir> <media-file> [transcript.txt]  — full pipeline

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: sketchnote-cli <output-dir> [media-file] [injected-transcript.txt]")
    exit(1)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

enum CLIError: LocalizedError {
    case ungroundedIllustration

    var errorDescription: String? {
        "A note illustration failed exact source-scene provenance validation."
    }
}

// register bundled fonts if present next to the repo
let fontsDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("App/Resources/Fonts")
if let fonts = try? FileManager.default.contentsOfDirectory(at: fontsDir, includingPropertiesForKeys: nil) {
    FontBook.register(fontURLs: fonts.filter { $0.pathExtension == "ttf" })
}

func sampleDocument() -> NoteDocument {
    NoteDocument(
        title: "Transform Your Content Into an Interactive AI",
        subtitle: "3 no-code methods to turn assets into AI products",
        sections: [
            .concept(heading: "Your Content Becomes the Brain of the AI",
                     body: "You ground a powerful AI model in your specific knowledge. Uploading your documents gives the AI its unique expertise, limited to the content you provide.",
                     points: ["Answers are limited to your content", "Passive information becomes an active tool", "Your expertise is the moat"],
                     iconHints: ["document", "brain"],
                     quote: "Basically what you have done is you have created an AI for them and limited it to the information you uploaded.",
                     sourceTime: 45),
            .methods(heading: "3 No-Code Methods to Create Your AI Product",
                     columns: [
                        MethodColumn(title: "NotebookLM", tagline: "Create a private Q&A bot",
                                     summary: "A focused, private chat experience where users get answers based only on your content.",
                                     steps: ["Load docs into a notebook", "Set to anyone with the link", "Restrict access to chat only", "Copy and share the link"],
                                     iconHints: ["upload", "link", "lock", "share"]),
                        MethodColumn(title: "Custom GPT", tagline: "Build a custom AI assistant",
                                     summary: "A configurable AI with a unique personality, ideal for a branded tool.",
                                     steps: ["Create a new GPT", "Upload files to its knowledge base", "Configure its instructions", "Share the GPT link"],
                                     iconHints: ["gear", "folder", "pencil", "link"]),
                        MethodColumn(title: "Gemini Gem", tagline: "Launch a shareable AI agent",
                                     summary: "A flexible AI that leverages your content via Google Drive.",
                                     steps: ["Create a new Gem", "Add files from Drive", "Set sharing to anyone", "Copy and share the link"],
                                     iconHints: ["sparkleRing", "cloud", "globe", "share"])
                     ], sourceTime: 130),
            .process(heading: "From Upload to Product in 4 Steps",
                     steps: ["Collect your best documents", "Ground the model in them", "Test the answers yourself", "Share the link with customers"],
                     iconHints: ["folder", "brain", "check", "rocket"], sourceTime: 300),
            .definition(term: "Grounding", meaning: "Tying a model's answers to a fixed body of source material so it cannot wander beyond it.", sourceTime: 350),
            .quote(text: "The product is not the model. The product is your knowledge, made interactive.", attribution: "Workshop host", sourceTime: 400),
            .summary(heading: "Key Takeaways",
                     points: ["Your documents are the differentiator", "No code is required for v1", "Ship the link, gather feedback, iterate"],
                     sourceTime: nil)
        ])
}

let semaphore = DispatchSemaphore(value: 0)
Task {
    do {
        let document: NoteDocument
        let seed: UInt64
        let groundingAudit: GroundingAuditReport?
        if args.count >= 3 {
            let media = URL(fileURLWithPath: args[2])
            var injected: [TranscriptSegment]?
            if args.count >= 4, let raw = try? String(contentsOfFile: args[3], encoding: .utf8) {
                injected = Transcriber.parseInjected(raw)
            }
            let result = try await SketchnotePipeline.analyze(url: media, injectedTranscript: injected) { _, message in
                print("· \(message)")
            }
            document = result.document
            seed = result.seed
            groundingAudit = GroundingAuditor.audit(
                document: result.document, content: result.content)
            let json = try JSONEncoder().encode(result.document)
            try json.write(to: outDir.appendingPathComponent("snm.json"))
        } else {
            document = sampleDocument()
            seed = 42
            groundingAudit = nil
        }
        if let groundingAudit {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(groundingAudit).write(
                to: outDir.appendingPathComponent("grounding-audit.json"))
            guard groundingAudit.illustrationsAreStrictlyGrounded else {
                throw CLIError.ungroundedIllustration
            }
        }
        let style = RenderStyle(palette: .paperAndInk, seed: seed)
        let renderer = PlainNotesRenderer()
        let images = renderer.renderImages(document: document, style: style)
        for (i, image) in images.enumerated() {
            let data = PageRenderer.pngData(image)
            try data.write(to: outDir.appendingPathComponent("page-\(i + 1).png"))
        }
        try renderer.renderPDF(document: document, style: style)
            .write(to: outDir.appendingPathComponent("notes.pdf"))
        print("rendered \(images.count) pages → \(outDir.path)")
    } catch {
        print("FAILED: \(error.localizedDescription)")
        exit(2)
    }
    semaphore.signal()
}
semaphore.wait()
