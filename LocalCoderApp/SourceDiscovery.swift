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
            var evaluations: [(score:Int,description:String)] = []
            for item in results.prefix(5) {
                guard let full = item["full_name"] as? String,
                      let html = item["html_url"] as? String,
                      let owner = item["owner"] as? [String:Any],
                      let ownerName = owner["login"] as? String,
                      let repoName = item["name"] as? String else { continue }
                let language = item["language"] as? String ?? "unknown"
                let license = (item["license"] as? [String:Any])?["spdx_id"] as? String ?? "unspecified"
                let description = item["description"] as? String ?? ""
                var score = 0
                if repoName.lowercased() == queryTerm.lowercased() { score += 2 }
                if ["Swift","Objective-C","C","C++"].contains(language) { score += 2 }
                if description.localizedCaseInsensitiveContains("ios") || description.localizedCaseInsensitiveContains("iphone") { score += 1 }
                var evidence = "Repository contents unavailable"
                if let url = URL(string:"https://api.github.com/repos/\(ownerName)/\(repoName)/contents") {
                    var detail = URLRequest(url:url)
                    detail.setValue("application/vnd.github+json",forHTTPHeaderField:"Accept")
                    detail.setValue("PocketForge/1.0",forHTTPHeaderField:"User-Agent")
                    if let (contents,response) = try? await URLSession.shared.data(for:detail),
                       let http = response as? HTTPURLResponse, http.statusCode == 200,
                       let files = try? JSONSerialization.jsonObject(with:contents) as? [[String:Any]] {
                        let names = files.compactMap { $0["name"] as? String }
                        let project = names.filter { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") || $0 == "Package.swift" || $0 == "project.yml" }
                        if !project.isEmpty { score += 3 }
                        evidence = project.isEmpty ? "No native project manifest at repository root" : "Native project: "+project.joined(separator:", ")
                    }
                }
                evaluations.append((score,"\(full) — \(html)\nLanguage: \(language); license: \(license); relevance: \(score)/8\n\(evidence)"))
            }
            evaluations.sort { $0.score > $1.score }
            return "Potential source candidates for \(queryTerm):\n\n"+
                (evaluations.map { $0.description }).joined(separator:"\n\n")+
                "\n\nThese are unverified candidates. Similarity is not proof of matching source. Check app identity, exact revision, permissions and asset licenses before reuse. Never automatically overwrite a native app with unrelated code."

        } catch {
            return "Repository lookup failed: "+error.localizedDescription
        }
    }

}
