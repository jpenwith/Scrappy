import ArgumentParser
import Foundation
import SwiftSoup


@main
struct ScrappyCommand: ParsableCommand {
    @Argument(help: "URL to scrape")
    public var url: String

    @Option(help: "Maximum number of urls to crawl")
    public var maximumURLCount = 10

    public func run() throws {
        let semaphore = DispatchSemaphore(value: 0)

        let url = URL(string: url)!

        Task {
            var scrappy = Scrappy(url: url, maximumURLCount: maximumURLCount)

            let emailAddresses = try await scrappy.execute()

            try FileHandle.standardOutput.write(contentsOf: try JSONSerialization.data(withJSONObject: Array(emailAddresses), options: [.prettyPrinted]))

            semaphore.signal()
        }

        semaphore.wait()
    }
}


struct Scrappy {
    private var initialURL: URL
    private let maximumURLCount: Int

    private var urlsToProcess: Set<URL> = []
    private var processedURLs: Set<URL> = []
    private var emailAddresses: Set<String> = []

    init(url: URL, maximumURLCount: Int) {
        self.initialURL = url
        self.maximumURLCount = maximumURLCount

        appendURLsToProcess([initialURL])
    }

    mutating func execute() async throws -> Set<String> {
        try await processURLs()

        return emailAddresses
    }
    
    mutating private func processURLs() async throws {

        while processedURLs.count < maximumURLCount && urlsToProcess.count > 0 {
            let urlToProcess = urlsToProcess.removeFirst()
            
            try await processURL(urlToProcess)
        }
    }

    mutating private func processURL(_ url: URL) async throws {
        logMessage("Processing \(url)...")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:122.0) Gecko/20100101 Firefox/122.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        processedURLs.insert(url)
        
        guard let response = response as? HTTPURLResponse else {
            return
        }

        guard response.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/html") ?? false else {
            return
        }

        let responseBody = String(data: data, encoding: .utf8)!

        let document = try SwiftSoup.parse(responseBody)

        let emailAddresses = try extractEmailAddressesFromDocument(document)
        if !emailAddresses.isEmpty {
            logMessage("Found \(emailAddresses.count) emails: \(emailAddresses.joined(separator: ", "))...")
        }
        self.appendEmailAddresses(emailAddresses)


        let anchorHREFs = try extractAnchorHREFsFromDocument(document)
        if !anchorHREFs.isEmpty {
            logMessage("Found \(anchorHREFs.count) anchor hrefs...")
        }
        self.appendURLsToProcess(Set(anchorHREFs.compactMap({$0.url(baseURL: url)})))
    }
    
    mutating private func appendEmailAddresses(_ emailAddresses: Set<String>) {
        self.emailAddresses = emailAddresses.union(emailAddresses)
    }

    mutating private func appendURLsToProcess(_ urls: Set<URL>) {
        self.urlsToProcess = self.urlsToProcess.union(
            urls
                .compactMap { url in
                    if url.host() != nil {
                        return url
                    }
                    
                    guard var urlComponents = URLComponents(url: initialURL, resolvingAgainstBaseURL: false) else {
                        return nil
                    }

                    urlComponents.path = url.path.hasPrefix("/") ? url.path : "/\(url.path)"
                    urlComponents.query = url.query
                    urlComponents.fragment = url.fragment

                    return urlComponents.url
                }
                .filter { url in
                    url.host() == initialURL.host()
                }
                .filter { url in
                    !processedURLs.contains(url)
                }
        )
    }

    private func extractEmailAddressesFromDocument(_ document: Document) throws -> Set<String> {
        guard let documentHTML = try document.body()?.html() else {
            return []
        }

        let regex = try Regex("([a-zA-Z][a-zA-Z0-9._-]*@[a-zA-Z0-9._-]+\\.[a-zA-Z]+)")
        let matches = documentHTML.matches(of: regex)

        return Set(matches.map { match in
            String(documentHTML[match.range]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
    }
    
    private func extractAnchorHREFsFromDocument(_ document: Document) throws -> Set<HREF> {
        try Set(document.select("a").compactMap { link in
            guard let hrefString = try? link.attr("href") else {
                return nil
            }

            let href = HREF(string: hrefString)
            
            guard !href.isFragmentOnly else {
                return nil
            }

            return href
        })
    }
        
    private func logMessage(_ message: String) {
        guard let messageData = (message + "\n").data(using: .utf8) else {
            return
        }

        try? FileHandle.standardError.write(contentsOf: messageData)
    }
}


extension Scrappy {
    struct HREF: Hashable {
        let string: String
        
        init(string: String) {
            self.string = string.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var isFragmentOnly: Bool {
            string.hasPrefix("#")
        }

        var isPathOnly: Bool {
            guard let url = URL(string: string) else {
                return true
            }

            return url.host == nil && url.scheme == nil && !url.path.isEmpty
        }
        
        func url(baseURL: URL) -> URL? {
            guard !isFragmentOnly else {
                return nil
            }
            
            if isPathOnly {
                return URL(string: string, relativeTo: baseURL)
            }

            return URL(string: string)
        }
    }
}
