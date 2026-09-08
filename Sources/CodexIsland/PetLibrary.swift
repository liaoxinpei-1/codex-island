import AppKit
import ImageIO
import IslandCore

struct PetDescriptor: Identifiable {
    let id: String
    let name: String
    let location: Location
    enum Location { case archive(URL, String), file(URL) }
}

final class PetLibrary {
    let home: URL
    private(set) var pets: [PetDescriptor] = []
    init(home: URL) { self.home = home; reload() }

    static func codexApplication() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
        ?? ["/Applications/Codex.app", "/Applications/ChatGPT.app"].map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Resources/codex").path) }
    }
    func reload() {
        var found: [PetDescriptor] = []
        // Load built-in art from the user's installed client; no OpenAI artwork is redistributed.
        if let app = Self.codexApplication(),
           let archive = try? AsarReader(url: app.appendingPathComponent("Contents/Resources/app.asar")) {
            let refs = ["codex", "dewey", "fireball", "hoots", "rocky", "seedy", "stacky", "bsod", "null-signal"]
            let names = archive.names(in: "webview/assets")
            for ref in refs {
                if let filename = names.first(where: { $0.hasPrefix(ref + "-spritesheet-") && $0.hasSuffix(".webp") }) {
                    found.append(PetDescriptor(id: "builtin:" + ref, name: ref == "codex" ? "Codex" : ref.capitalized,
                                               location: .archive(archive.url, "webview/assets/" + filename)))
                }
            }
        }
        let folders = (try? FileManager.default.contentsOfDirectory(at: home.appendingPathComponent("pets"), includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            if let pet = Self.customPet(manifest: folder.appendingPathComponent("pet.json")) { found.append(pet) }
        }
        if let imported = UserDefaults.standard.string(forKey: "importedPetManifest"),
           let pet = Self.customPet(manifest: URL(fileURLWithPath: imported)), !found.contains(where: { $0.id == pet.id }) {
            found.append(pet)
        }
        pets = found
    }

    static func customPet(manifest: URL) -> PetDescriptor? {
        guard let data = try? Data(contentsOf: manifest), data.count < 64 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let version = object["spriteVersionNumber"] as? Int ?? 1
        guard [1, 2].contains(version) else { return nil }
        let name = object["displayName"] as? String ?? manifest.deletingLastPathComponent().lastPathComponent
        let relative = object["spritesheetPath"] as? String ?? "spritesheet.webp"
        let folder = manifest.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let sprite = folder.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard sprite.path.hasPrefix(folder.path + "/"), ["webp", "png"].contains(sprite.pathExtension.lowercased()),
              FileManager.default.fileExists(atPath: sprite.path) else { return nil }
        return PetDescriptor(id: "custom:" + manifest.path, name: name, location: .file(sprite))
    }

    func image(for id: String) -> CGImage? {
        guard let pet = pets.first(where: { $0.id == id }) else { return nil }
        let data: Data?
        switch pet.location {
        case .archive(let url, let path): data = try? AsarReader(url: url).data(at: path)
        case .file(let url):
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 24 * 1024 * 1024 else { return nil }
            data = try? Data(contentsOf: url)
        }
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == 1536, [1872, 2288].contains(image.height) else { return nil }
        return image
    }
}

private final class AsarReader {
    let url: URL
    private let header: [String: Any]
    private let base: UInt64
    init(url: URL) throws {
        self.url = url
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard let bytes = try file.read(upToCount: 16), bytes.count == 16 else { throw ReadError.invalid }
        func uint(_ offset: Int) -> UInt64 { (0..<4).reduce(0) { $0 | UInt64(bytes[offset + $1]) << ($1 * 8) } }
        let headerBytes = uint(12)
        guard headerBytes < 32 * 1024 * 1024, let data = try file.read(upToCount: Int(headerBytes)),
              let header = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ReadError.invalid }
        self.header = header; self.base = 8 + uint(4)
    }
    private func entry(_ path: String) -> [String: Any]? {
        var value = header
        for part in path.split(separator: "/") {
            guard let files = value["files"] as? [String: Any], let next = files[String(part)] as? [String: Any] else { return nil }
            value = next
        }
        return value
    }
    func names(in path: String) -> [String] { Array((entry(path)?["files"] as? [String: Any] ?? [:]).keys).sorted() }
    func data(at path: String) throws -> Data {
        guard let entry = entry(path), let offsetString = entry["offset"] as? String, let offset = UInt64(offsetString),
              let count = entry["size"] as? Int, count > 0, count < 24 * 1024 * 1024, entry["unpacked"] as? Bool != true else { throw ReadError.invalid }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        try file.seek(toOffset: base + offset)
        guard let data = try file.read(upToCount: count), data.count == count else { throw ReadError.invalid }
        return data
    }
    enum ReadError: Error { case invalid }
}
