import Foundation
@testable import PodpisCore
import Testing

/// Where signed copies go and what the app knows about a file before signing it.
@Suite struct OutputNamingTests {
    let input = URL(fileURLWithPath: "/docs/umowa.pdf")

    @Test func nextToTheOriginal() {
        let plan = OutputNaming.plan(for: input, fileExists: { _ in false }, isWritableDirectory: { _ in true })
        #expect(plan.url.path == "/docs/umowa-podpisany.pdf")
        #expect(!plan.movedToFallback && !plan.plainNameTaken)
    }

    /// Overwriting an earlier signed copy would silently destroy a signed document.
    @Test func neverOverwritesAnExistingCopy() {
        let existing: Set = ["/docs/umowa-podpisany.pdf", "/docs/umowa-podpisany-2.pdf"]
        let plan = OutputNaming.plan(for: input, fileExists: { existing.contains($0.path) }, isWritableDirectory: { _ in true })
        #expect(plan.url.path == "/docs/umowa-podpisany-3.pdf")
        #expect(plan.plainNameTaken)
    }

    @Test func twoFilesInOneBatchDoNotCollide() {
        let plan = OutputNaming.plan(for: input, reserved: ["/docs/umowa-podpisany.pdf"],
                                     fileExists: { _ in false }, isWritableDirectory: { _ in true })
        #expect(plan.url.path == "/docs/umowa-podpisany-2.pdf")
    }

    @Test func signingASignedCopyAgainDoesNotStackSuffixes() {
        let signed = URL(fileURLWithPath: "/docs/umowa-podpisany.pdf")
        let plan = OutputNaming.plan(for: signed, fileExists: { $0.path == signed.path }, isWritableDirectory: { _ in true })
        #expect(plan.url.path == "/docs/umowa-podpisany-2.pdf")
    }

    @Test func readOnlyFolderFallsBackToDownloads() {
        let plan = OutputNaming.plan(for: input, fileExists: { _ in false }, isWritableDirectory: { _ in false },
                                     fallbackDirectory: URL(fileURLWithPath: "/Users/x/Downloads"))
        #expect(plan.url.path == "/Users/x/Downloads/umowa-podpisany.pdf")
        #expect(plan.movedToFallback)
    }
}

@Suite struct DocumentInspectorTests {
    @Test func recognisesFilesByContent() throws {
        #expect(DocumentInspector.kind(of: Paths.fixture("uchwala-zarzadu.pdf")) == .pdf)
        #expect(DocumentInspector.kind(of: Paths.fixture("zgloszenie.xml")) == .xml)
        let dir = try Paths.scratch()
        let fakePDF = dir.appendingPathComponent("notatka.pdf")
        try "to nie jest PDF".write(to: fakePDF, atomically: true, encoding: .utf8)
        #expect(DocumentInspector.kind(of: fakePDF) == nil)
    }

    @Test func plainPDFHasNoSignature() throws {
        #expect(!DocumentInspector.pdfHasSignature(try Data(contentsOf: Paths.fixture("uchwala-zarzadu.pdf"))))
    }

    /// Signs a fixture with the fake CLI (pyHanko and a test key) and checks the app sees it.
    @Test func signedPDFIsDetectedAndVerified() async throws {
        let dir = try Paths.scratch()
        let pdf = dir.appendingPathComponent("uchwala.pdf")
        try FileManager.default.copyItem(at: Paths.fixture("uchwala-zarzadu.pdf"), to: pdf)
        let client = PodpisClient(executable: Paths.fakeCLI, environment: Paths.fakeEnvironment(dir: dir))
        try JSONSerialization.data(withJSONObject: ["opoznienie": 0]).write(to: dir.appendingPathComponent("state.json"))
        let out = dir.appendingPathComponent("uchwala-podpisany.pdf")
        let signed = try await client.signPDF(pdf, page: 1, rect: CGRect(x: 339, y: 378, width: 140, height: 48),
                                              output: out,
                                              pin: try #require(PinSecret("1234")), allowLastTry: false)
        #expect(signed.originalIsPrefix == true)
        #expect(DocumentInspector.pdfHasSignature(try Data(contentsOf: out)))
        let check = try await client.verify(out)
        #expect(check.newestCoversWholeFile)
        #expect(DocumentInspector.signedBy("Jan Kowalski", in: check.signers))
    }

    @Test func xmlSignerComesFromTheCertificate() async throws {
        let dir = try Paths.scratch()
        let xml = dir.appendingPathComponent("z.xml")
        try FileManager.default.copyItem(at: Paths.fixture("zgloszenie.xml"), to: xml)
        #expect(DocumentInspector.xmlSigners(try String(contentsOf: xml, encoding: .utf8)) == nil)
        try JSONSerialization.data(withJSONObject: ["opoznienie": 0]).write(to: dir.appendingPathComponent("state.json"))
        let client = PodpisClient(executable: Paths.fakeCLI, environment: Paths.fakeEnvironment(dir: dir))
        let signed = try await client.signXML(xml, output: dir.appendingPathComponent("z-podpisany.xml"),
                                              pin: try #require(PinSecret("1234")), allowLastTry: false, addAnother: false)
        let signers = DocumentInspector.xmlSigners(try String(contentsOf: signed.url, encoding: .utf8))
        #expect(signers == ["Jan Kowalski (TEST)"])
    }

    @Test func pinFormat() {
        #expect(PinSecret.isValid("1234") && PinSecret.isValid("123456789012"))
        #expect(!PinSecret.isValid("123") && !PinSecret.isValid("1234567890123") && !PinSecret.isValid("12a4")
                && !PinSecret.isValid("１２３４"))
    }
}
