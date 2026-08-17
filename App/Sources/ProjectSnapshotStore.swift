import CryptoKit
import Foundation
import Security
import SketchnoteEngine

/// The complete semantic state needed to reopen a generated project without
/// retaining a second copy of the user's source media.
struct ProjectSnapshot: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  struct Style: Codable, Equatable, Sendable {
    var paletteIndex: Int
    var compact: Bool
    var presentationFormat: String
    var pdfPageFormat: String
    var seedBump: UInt64
  }

  struct Content: Codable, Equatable, Sendable {
    var sourceName: String
    var duration: Double
    var transcript: [TranscriptSegment]
    var visuals: [VisualMoment]
    var transcriptUnavailableReason: String?

    init(_ content: ExtractedContent) {
      sourceName = content.sourceName
      duration = content.duration
      transcript = content.transcript
      visuals = content.visuals
      transcriptUnavailableReason = content.transcriptUnavailableReason
    }

    var extractedContent: ExtractedContent {
      ExtractedContent(
        sourceName: sourceName, duration: duration, transcript: transcript, visuals: visuals,
        transcriptUnavailableReason: transcriptUnavailableReason)
    }
  }

  var schemaVersion: Int
  var savedAt: Date
  var sourceName: String
  var sourceReference: ProjectSourceReference?
  var document: NoteDocument
  var content: Content
  var baseSeed: UInt64
  var style: Style
  var currentPage: Int

  init(
    savedAt: Date = Date(), sourceName: String, sourceReference: ProjectSourceReference?,
    document: NoteDocument, content: ExtractedContent, baseSeed: UInt64, style: Style,
    currentPage: Int
  ) {
    schemaVersion = Self.currentSchemaVersion
    self.savedAt = savedAt
    self.sourceName = sourceName
    self.sourceReference = sourceReference
    self.document = document
    self.content = Content(content)
    self.baseSeed = baseSeed
    self.style = style
    self.currentPage = currentPage
  }

  func validate() throws {
    guard schemaVersion == Self.currentSchemaVersion else {
      throw ProjectSnapshotError.unsupportedVersion(schemaVersion)
    }
    guard sourceName.utf8.count <= 4_096,
      !document.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !document.sections.isEmpty,
      document.sections.count <= 64,
      content.duration.isFinite,
      content.duration >= 0,
      content.transcript.count <= 20_000,
      content.visuals.count <= 20_000,
      currentPage >= 0,
      currentPage <= 10_000,
      (0..<Palette.all.count).contains(style.paletteIndex),
      NotePresentationFormat(rawValue: style.presentationFormat) != nil,
      PDFPageFormat(rawValue: style.pdfPageFormat) != nil
    else {
      throw ProjectSnapshotError.invalidContents
    }
    if let sourceReference {
      guard sourceReference.fallbackPath.utf8.count <= 32_768,
        (sourceReference.bookmarkData?.count ?? 0) <= 2 * 1_024 * 1_024
      else { throw ProjectSnapshotError.invalidContents }
    }

    let transcriptIsValid = content.transcript.allSatisfy { segment in
      segment.start.isFinite && segment.end.isFinite && segment.start >= 0
        && segment.end >= segment.start && segment.text.utf8.count <= 100_000
    }
    let visualsAreValid = content.visuals.allSatisfy { moment in
      moment.time.isFinite && moment.time >= 0 && moment.lines.count <= 1_000
        && moment.lines.allSatisfy { $0.utf8.count <= 100_000 }
        && (moment.sketch ?? []).count <= 10_000
        && (moment.sketch ?? []).allSatisfy { stroke in
          stroke.points.count <= 100_000
            && stroke.points.allSatisfy { $0.x.isFinite && $0.y.isFinite }
        }
    }
    guard transcriptIsValid, visualsAreValid else { throw ProjectSnapshotError.invalidContents }
  }
}

/// A bookmark plus a human-independent path fallback. No source bytes are
/// copied into the snapshot.
struct ProjectSourceReference: Codable, Equatable, Sendable {
  enum Resolution: Equatable {
    case available(URL, bookmarkWasStale: Bool)
    case unavailable
  }

  var bookmarkData: Data?
  var fallbackPath: String

  init(bookmarkData: Data?, fallbackPath: String) {
    self.bookmarkData = bookmarkData
    self.fallbackPath = fallbackPath
  }

  init(url: URL) {
    fallbackPath = url.standardizedFileURL.path
    #if os(macOS)
      bookmarkData = try? url.bookmarkData(
        options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    #else
      bookmarkData = try? url.bookmarkData(
        options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    #endif
  }

  func resolve(fileManager: FileManager = .default) -> Resolution {
    if let bookmarkData {
      var stale = false
      #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
      #else
        let options: URL.BookmarkResolutionOptions = [.withoutUI]
      #endif
      if let url = try? URL(
        resolvingBookmarkData: bookmarkData, options: options, relativeTo: nil,
        bookmarkDataIsStale: &stale),
        Self.isUsableFile(url, fileManager: fileManager)
      {
        return .available(url, bookmarkWasStale: stale)
      }
    }

    guard !fallbackPath.isEmpty else { return .unavailable }
    let fallback = URL(fileURLWithPath: fallbackPath).standardizedFileURL
    guard Self.isUsableFile(fallback, fileManager: fileManager) else { return .unavailable }
    return .available(fallback, bookmarkWasStale: true)
  }

  private static func isUsableFile(_ url: URL, fileManager: FileManager) -> Bool {
    var isDirectory: ObjCBool = false
    guard url.isFileURL,
      fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else { return false }

    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    return fileManager.isReadableFile(atPath: url.path)
  }
}

enum ProjectSnapshotError: LocalizedError, Equatable {
  case tooLarge
  case checksumMismatch
  case unsupportedVersion(Int)
  case unsupportedEncryptionAlgorithm(String)
  case invalidContents
  case encryptionKeyUnavailable(OSStatus)
  case encryptionKeyMissing
  case invalidEncryptionKey
  case encryptionKeyMismatch
  case authenticationFailed

  var errorDescription: String? {
    switch self {
    case .tooLarge:
      return String(localized: "The saved project exceeds the supported recovery size.")
    case .checksumMismatch:
      return String(localized: "The saved project did not pass its integrity check.")
    case .unsupportedVersion:
      return String(
        localized: "The saved project was created by an incompatible version of VideoNotes.")
    case .unsupportedEncryptionAlgorithm:
      return String(localized: "The saved project uses an unsupported encryption format.")
    case .invalidContents:
      return String(localized: "The saved project contains invalid data.")
    case .encryptionKeyUnavailable:
      return String(localized: "The private recovery key is temporarily unavailable.")
    case .encryptionKeyMissing:
      return String(localized: "The private recovery key could not be found.")
    case .invalidEncryptionKey:
      return String(localized: "The private recovery key is invalid.")
    case .encryptionKeyMismatch:
      return String(localized: "The saved project was encrypted with a different recovery key.")
    case .authenticationFailed:
      return String(localized: "The encrypted saved project did not pass its authenticity check.")
    }
  }

  /// Keychain availability can be transient (for example, before first unlock).
  /// The encrypted bytes must stay in place so a later launch can retry.
  var shouldQuarantineSnapshot: Bool {
    switch self {
    case .encryptionKeyUnavailable, .encryptionKeyMissing, .invalidEncryptionKey:
      return false
    default:
      return true
    }
  }
}

protocol ProjectSnapshotKeyProvider: Sendable {
  func loadKey() throws -> Data?
  func loadOrCreateKey() throws -> Data
  func deleteKey() throws
}

enum ProjectSnapshotKeyProviderError: Error, Equatable {
  case unavailable(OSStatus)
  case invalidKeyMaterial
}

protocol ProjectSnapshotKeychainAccess: Sendable {
  func read(service: String, account: String) -> (data: Data?, status: OSStatus)
  func add(_ key: Data, service: String, account: String) -> OSStatus
  func delete(service: String, account: String) -> OSStatus
}

struct SecurityProjectSnapshotKeychainAccess: ProjectSnapshotKeychainAccess {
  func read(service: String, account: String) -> (data: Data?, status: OSStatus) {
    var query = baseQuery(service: service, account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else { return (nil, status) }
    guard let data = result as? Data else { return (nil, errSecDecode) }
    return (data, errSecSuccess)
  }

  func add(_ key: Data, service: String, account: String) -> OSStatus {
    var query = baseQuery(service: service, account: account)
    query[kSecValueData as String] = key
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(query as CFDictionary, nil)
  }

  func delete(service: String, account: String) -> OSStatus {
    SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
  }

  private func baseQuery(service: String, account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}

/// Owns one non-synchronizing, device-bound 256-bit recovery key. The key is
/// intentionally independent from the snapshot file so copying the file alone
/// does not disclose the user's transcript, OCR, notes, or source bookmark.
struct KeychainProjectSnapshotKeyProvider: ProjectSnapshotKeyProvider {
  static let keyByteCount = 32

  private let service: String
  private let account: String
  private let keychain: any ProjectSnapshotKeychainAccess

  init(
    service: String = "com.lukemclaughlin.videonotes.recovery",
    account: String = "ProjectSnapshotKey.v2",
    keychain: any ProjectSnapshotKeychainAccess = SecurityProjectSnapshotKeychainAccess()
  ) {
    self.service = service
    self.account = account
    self.keychain = keychain
  }

  func loadOrCreateKey() throws -> Data {
    if let existing = try loadKey() { return existing }

    let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    let status = keychain.add(key, service: service, account: account)
    if status == errSecSuccess { return key }

    // Another process/thread can win the add race. Re-read the winner rather
    // than replacing it and potentially stranding an encrypted snapshot.
    if status == errSecDuplicateItem {
      guard let winnerKey = try loadKey() else {
        throw ProjectSnapshotKeyProviderError.unavailable(errSecItemNotFound)
      }
      return winnerKey
    }
    throw ProjectSnapshotKeyProviderError.unavailable(status)
  }

  func loadKey() throws -> Data? {
    let existing = keychain.read(service: service, account: account)
    switch (existing.data, existing.status) {
    case (.some(let key), errSecSuccess):
      return try validated(key)
    case (_, errSecItemNotFound):
      return nil
    case (_, let status):
      throw ProjectSnapshotKeyProviderError.unavailable(status)
    }
  }

  func deleteKey() throws {
    let status = keychain.delete(service: service, account: account)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw ProjectSnapshotKeyProviderError.unavailable(status)
    }
  }

  private func validated(_ key: Data) throws -> Data {
    guard key.count == Self.keyByteCount else {
      throw ProjectSnapshotKeyProviderError.invalidKeyMaterial
    }
    return key
  }
}

struct ProjectSnapshotStore: Sendable {
  private struct VersionProbe: Decodable {
    var version: Int
  }

  /// The checksum envelope shipped before app-level encryption. It remains
  /// readable solely for one-way, atomic migration to EncryptedEnvelope.
  private struct LegacyEnvelope: Codable {
    var version: Int
    var payload: Data
    var checksum: Data
  }

  private struct EncryptedEnvelope: Codable {
    static let currentVersion = 2
    static let algorithm = "AES.GCM.256"

    var version: Int
    var algorithm: String
    var keyIdentifier: Data
    var sealedPayload: Data
  }

  static let maximumSnapshotBytes = 64 * 1_024 * 1_024

  let directoryURL: URL
  private let keyProvider: any ProjectSnapshotKeyProvider
  var snapshotURL: URL { directoryURL.appendingPathComponent("CurrentProject.vnsnapshot") }
  var quarantinedSnapshotURL: URL {
    directoryURL.appendingPathComponent("UnrecoverableProject.vnsnapshot")
  }

  init(
    directoryURL: URL,
    keyProvider: any ProjectSnapshotKeyProvider = KeychainProjectSnapshotKeyProvider()
  ) {
    self.directoryURL = directoryURL
    self.keyProvider = keyProvider
  }

  static func applicationSupport(fileManager: FileManager = .default) -> Self {
    #if DEBUG
      if let overridePath = ProcessInfo.processInfo.environment["VIDEONOTES_RECOVERY_DIR"],
        !overridePath.isEmpty
      {
        return Self(directoryURL: URL(fileURLWithPath: overridePath, isDirectory: true))
      }
    #endif
    let root: URL
    if let applicationSupport = fileManager.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first {
      root = applicationSupport
    } else {
      root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent("Library/Application Support", isDirectory: true)
    }
    return Self(directoryURL: root.appendingPathComponent("VideoNotes", isDirectory: true))
  }

  func save(_ snapshot: ProjectSnapshot, fileManager: FileManager = .default) throws {
    try snapshot.validate()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let payload = try encoder.encode(snapshot)
    guard payload.count <= Self.maximumSnapshotBytes else { throw ProjectSnapshotError.tooLarge }
    let keyMaterial = try encryptionKeyMaterial(createIfMissing: true)
    let keyIdentifier = Self.keyIdentifier(for: keyMaterial)
    let header = Self.authenticatedHeader(
      version: EncryptedEnvelope.currentVersion,
      algorithm: EncryptedEnvelope.algorithm,
      keyIdentifier: keyIdentifier)
    let sealedBox = try AES.GCM.seal(
      payload, using: SymmetricKey(data: keyMaterial), authenticating: header)
    guard let combined = sealedBox.combined else { throw ProjectSnapshotError.invalidContents }
    let envelope = EncryptedEnvelope(
      version: EncryptedEnvelope.currentVersion,
      algorithm: EncryptedEnvelope.algorithm,
      keyIdentifier: keyIdentifier,
      sealedPayload: combined)
    let data = try encoder.encode(envelope)
    guard data.count <= Self.maximumSnapshotBytes else { throw ProjectSnapshotError.tooLarge }

    try prepareDirectory(fileManager: fileManager)
    try data.write(to: snapshotURL, options: .atomic)
    applyLocalPrivacyAttributes(to: snapshotURL, isDirectory: false, fileManager: fileManager)
  }

  func load(fileManager: FileManager = .default) throws -> ProjectSnapshot? {
    guard fileManager.fileExists(atPath: snapshotURL.path) else { return nil }
    let attributes = try fileManager.attributesOfItem(atPath: snapshotURL.path)
    if let size = attributes[.size] as? NSNumber,
      size.intValue > Self.maximumSnapshotBytes
    {
      throw ProjectSnapshotError.tooLarge
    }
    let data = try Data(contentsOf: snapshotURL, options: [.mappedIfSafe])
    guard data.count <= Self.maximumSnapshotBytes else { throw ProjectSnapshotError.tooLarge }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let version: Int
    do {
      version = try decoder.decode(VersionProbe.self, from: data).version
    } catch {
      throw ProjectSnapshotError.invalidContents
    }

    switch version {
    case 1:
      return try loadAndMigrateLegacySnapshot(
        data, decoder: decoder, fileManager: fileManager)
    case EncryptedEnvelope.currentVersion:
      return try loadEncryptedSnapshot(data, decoder: decoder)
    default:
      throw ProjectSnapshotError.unsupportedVersion(version)
    }
  }

  func remove(fileManager: FileManager = .default) throws {
    // Remove every ciphertext first. If any removal fails, keep the key so no
    // undeletable snapshot is stranded. Only then cryptographically retire it.
    if fileManager.fileExists(atPath: snapshotURL.path) {
      try fileManager.removeItem(at: snapshotURL)
    }
    if fileManager.fileExists(atPath: quarantinedSnapshotURL.path) {
      try fileManager.removeItem(at: quarantinedSnapshotURL)
    }
    do {
      try keyProvider.deleteKey()
    } catch let error as ProjectSnapshotKeyProviderError {
      throw Self.snapshotError(for: error)
    } catch {
      throw ProjectSnapshotError.encryptionKeyUnavailable(errSecInternalError)
    }
  }

  /// Preserve the bad bytes for diagnostics or a future migration while
  /// ensuring every subsequent launch starts safely.
  func quarantineUnreadableSnapshot(fileManager: FileManager = .default) {
    guard fileManager.fileExists(atPath: snapshotURL.path) else { return }
    try? prepareDirectory(fileManager: fileManager)
    try? fileManager.removeItem(at: quarantinedSnapshotURL)
    do {
      try fileManager.moveItem(at: snapshotURL, to: quarantinedSnapshotURL)
      applyLocalPrivacyAttributes(
        to: quarantinedSnapshotURL, isDirectory: false, fileManager: fileManager)
    } catch {
      // A quarantine move can fail because of a transient file-system issue.
      // Keep the original bytes in place so recovery remains possible later.
    }
  }

  private func prepareDirectory(fileManager: FileManager) throws {
    try fileManager.createDirectory(
      at: directoryURL, withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    applyLocalPrivacyAttributes(to: directoryURL, isDirectory: true, fileManager: fileManager)
  }

  private func applyLocalPrivacyAttributes(
    to url: URL, isDirectory: Bool, fileManager: FileManager
  ) {
    try? fileManager.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(isDirectory ? 0o700 : 0o600))],
      ofItemAtPath: url.path)
    #if os(iOS)
      try? fileManager.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: url.path)
    #endif
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutableURL = url
    try? mutableURL.setResourceValues(values)
  }

  private func loadAndMigrateLegacySnapshot(
    _ data: Data, decoder: JSONDecoder, fileManager: FileManager
  ) throws -> ProjectSnapshot {
    let envelope: LegacyEnvelope
    do {
      envelope = try decoder.decode(LegacyEnvelope.self, from: data)
    } catch {
      throw ProjectSnapshotError.invalidContents
    }
    guard Data(SHA256.hash(data: envelope.payload)) == envelope.checksum else {
      throw ProjectSnapshotError.checksumMismatch
    }
    let snapshot: ProjectSnapshot
    do {
      snapshot = try decoder.decode(ProjectSnapshot.self, from: envelope.payload)
    } catch {
      throw ProjectSnapshotError.invalidContents
    }
    try snapshot.validate()

    // Migration is best-effort but never destructive: save performs an atomic
    // replacement, so any key/file-system failure leaves the valid v1 bytes in
    // place and the recovered project remains usable. The next autosave/load
    // retries encryption.
    try? save(snapshot, fileManager: fileManager)
    return snapshot
  }

  private func loadEncryptedSnapshot(
    _ data: Data, decoder: JSONDecoder
  ) throws -> ProjectSnapshot {
    let envelope: EncryptedEnvelope
    do {
      envelope = try decoder.decode(EncryptedEnvelope.self, from: data)
    } catch {
      throw ProjectSnapshotError.invalidContents
    }
    guard envelope.algorithm == EncryptedEnvelope.algorithm else {
      throw ProjectSnapshotError.unsupportedEncryptionAlgorithm(envelope.algorithm)
    }
    let keyMaterial = try encryptionKeyMaterial(createIfMissing: false)
    guard Self.keyIdentifier(for: keyMaterial) == envelope.keyIdentifier else {
      throw ProjectSnapshotError.encryptionKeyMismatch
    }
    let header = Self.authenticatedHeader(
      version: envelope.version, algorithm: envelope.algorithm,
      keyIdentifier: envelope.keyIdentifier)
    let payload: Data
    do {
      let sealedBox = try AES.GCM.SealedBox(combined: envelope.sealedPayload)
      payload = try AES.GCM.open(
        sealedBox, using: SymmetricKey(data: keyMaterial), authenticating: header)
    } catch {
      throw ProjectSnapshotError.authenticationFailed
    }
    guard payload.count <= Self.maximumSnapshotBytes else { throw ProjectSnapshotError.tooLarge }
    let snapshot: ProjectSnapshot
    do {
      snapshot = try decoder.decode(ProjectSnapshot.self, from: payload)
    } catch {
      throw ProjectSnapshotError.invalidContents
    }
    try snapshot.validate()
    return snapshot
  }

  private func encryptionKeyMaterial(createIfMissing: Bool) throws -> Data {
    do {
      let key: Data
      if createIfMissing {
        key = try keyProvider.loadOrCreateKey()
      } else {
        guard let existing = try keyProvider.loadKey() else {
          throw ProjectSnapshotError.encryptionKeyMissing
        }
        key = existing
      }
      guard key.count == KeychainProjectSnapshotKeyProvider.keyByteCount else {
        throw ProjectSnapshotError.invalidEncryptionKey
      }
      return key
    } catch let error as ProjectSnapshotError {
      throw error
    } catch let error as ProjectSnapshotKeyProviderError {
      throw Self.snapshotError(for: error)
    } catch {
      throw ProjectSnapshotError.encryptionKeyUnavailable(errSecInternalError)
    }
  }

  private static func snapshotError(
    for error: ProjectSnapshotKeyProviderError
  ) -> ProjectSnapshotError {
    switch error {
    case .unavailable(let status): return .encryptionKeyUnavailable(status)
    case .invalidKeyMaterial: return .invalidEncryptionKey
    }
  }

  private static func keyIdentifier(for key: Data) -> Data {
    Data(SHA256.hash(data: key).prefix(16))
  }

  private static func authenticatedHeader(
    version: Int, algorithm: String, keyIdentifier: Data
  ) -> Data {
    var header = Data("VideoNotes.ProjectSnapshot".utf8)
    header.append(0)
    header.append(Data(String(version).utf8))
    header.append(0)
    header.append(Data(algorithm.utf8))
    header.append(0)
    header.append(keyIdentifier)
    return header
  }
}

actor ProjectSnapshotPersistence {
  private let store: ProjectSnapshotStore
  private var newestRevision = 0

  init(store: ProjectSnapshotStore) { self.store = store }

  func save(_ snapshot: ProjectSnapshot, revision: Int) throws {
    guard revision >= newestRevision else { return }
    newestRevision = revision
    try store.save(snapshot)
  }

  func remove(revision: Int) throws {
    guard revision >= newestRevision else { return }
    newestRevision = revision
    try store.remove()
  }
}
