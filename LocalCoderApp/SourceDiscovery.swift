import Foundation
import ZIPFoundation

enum SourceDiscovery {
    static func inspect(_ url: URL) -> String {
        do {
            let archive = try Archive(url:url, accessMode:.read)
            let entries = Array(archive)
            let code = entries.filter { e in
                let p = e.path.lowercased()
                return p.hasSuffix(".swift") || p.hasSuffix(".m") || p.hasSuffix(".mm") || p.hasSuffix(".h") || p.hasSuffix(".c") || p.hasSuffix(".cpp")
            }
            let metadata = entries.filter { e in
                let p = e.path.lowercased()
                return p.hasSuffix(".git/config") || p.hasSuffix("package.swift") || p.hasSuffix("project.pbxproj") || p.hasSuffix("readme.md")
            }
            var lines = ["Source candidates in archive: \(code.count)"]
            lines += code.prefix(30).map { "• " + $0.path }
            if !metadata.isEmpty { lines += ["Project metadata:"] + metadata.prefix(15).map { "• " + $0.path } }
            if code.isEmpty {
                lines.append("No original source found inside the IPA. Executable machine code cannot reliably reconstruct its original source.")
                lines.append("Next: look for a verified matching source repository using bundle identifier, version, and executable UUID. Never assume a similarly named public repository is the correct source.")
            } else {
                lines.append("Candidates only: confirm they match the installed executable before applying changes.")
            }
            return lines.joined(separator:"\n")
        } catch { return "Source scan failed: \(error.localizedDescription)" }
    }
    /// Discover public repository candidates by app metadata. Never call a name match verified source.
    static func searchPublicRepositories(_ archiveURL: URL) async -> String {
        do {
            let archive = try Archive(url:archiveURL, accessMode:.read)
            guard let manifest = archive.first(where: { $0.path.hasPrefix("Payload/") && $0.path.hasSuffix(".app/Info.plist") }) else {
                return "Cannot search: app Info.plist missing."
            }
            var bytes = Data()
            _ = try archive.extract(manifest, consumer:{ bytes.append($0) })
            guard let plist = try PropertyListSerialization.propertyList(from:bytes,format:nil) as? [String:Any] else { return "Cannot read app metadata." }
            let identifier = plist["CFBundleIdentifier"] as? String ?? ""
            let title = plist["CFBundleDisplayName"] as? String ?? plist["CFBundleName"] as? String ?? ""
            let candidateTerms = [identifier.split(separator: ".").last.map(String.init) ?? "", title]
                .map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }
                .filter { $0.count >= 4 }
            guard let queryTerm = candidateTerms.first else { return "No suitable public repository search term found." }
            var components = URLComponents(string:"https://api.github.com/search/repositories")!
            components.queryItems = [URLQueryItem(name:"q",value:queryTerm+" in:name,description"),URLQueryItem(name:"per_page",value:"5")]
            var request = URLRequest(url:components.url!)
            request.setValue("application/vnd.github+json",forHTTPHeaderField:"Accept")
            request.setValue("LocalCoder/1.0",forHTTPHeaderField:"User-Agent")
            let (data,response) = try await URLSession.shared.data(for:request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return "Repository lookup unavailable. Check connectivity or GitHub API limits."
            }
            guard let json = try JSONSerialization.jsonObject(with:data) as? [String:Any],
                  let results = json["items"] as? [[String:Any]] else { return "Unexpected repository search response." }
            guard !results.isEmpty else { return "No matching public GitHub repository found. Private or local source projects cannot be discovered without access." }
            let entries = results.compactMap { item -> String? in
                guard let full = item["full_name"] as? String,
                      let url = item["html_url"] as? String else { return nil }
                return full+" — "+url
            }
            return "Unverified public source candidates for \(queryTerm):\n"+entries.joined(separator:"\n")+"\nThese are name matches only, NOT authenticated source for this IPA. Confirm bundle ID, revision, and binary identifiers before patching."
        } catch {
            return "Repository lookup failed: "+error.localizedDescription
        }
    }

}
