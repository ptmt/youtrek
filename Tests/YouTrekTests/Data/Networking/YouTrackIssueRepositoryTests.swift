import XCTest
@testable import YouTrek

final class YouTrackIssueRepositoryTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.requestHandler = nil
        MockURLProtocol.lastRequest = nil
    }

    func testFetchIssuesDecodesYouTrackResponse() async throws {
        let sampleResponse = """
        [
          {
            "id": "0-100",
            "idReadable": "YT-100",
            "summary": "Fix sync race",
            "project": {
              "name": "YouTrek",
              "shortName": "YT"
            },
            "updated": 1697040000000,
            "customFields": [
              {
                "$type": "SingleEnumIssueCustomField",
                "name": "Priority",
                "value": { "name": "High" }
              },
              {
                "$type": "StateIssueCustomField",
                "name": "State",
                "value": { "name": "In Progress" }
              },
              {
                "$type": "SingleUserIssueCustomField",
                "name": "Assignee",
                "value": {
                  "login": "morgan",
                  "name": "Morgan Chan",
                  "avatarUrl": "https://example.com/avatar.png"
                }
              }
            ],
            "tags": [
              { "name": "sync" },
              { "name": "network" }
            ]
          }
        ]
        """.data(using: .utf8)!

        MockURLProtocol.requestHandler = { request in
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer TOKEN" else {
                throw NSError(domain: "Auth", code: 0)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, sampleResponse)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let repo = YouTrackIssueRepository(
            configuration: YouTrackAPIConfiguration(
                baseURL: URL(string: "https://example.com/api")!,
                tokenProvider: .constant("TOKEN")
            ),
            session: session
        )

        let query = IssueQuery(
            search: "project: YT",
            filters: ["#Unresolved"],
            sort: .updated(descending: true),
            page: .init(size: 50, offset: 0)
        )

        let issues = try await repo.fetchIssues(query: query)
        let issue = try XCTUnwrap(issues.first)

        XCTAssertEqual(issue.readableID, "YT-100")
        XCTAssertEqual(issue.title, "Fix sync race")
        XCTAssertEqual(issue.projectName, "YT")
        XCTAssertEqual(issue.priority, .high)
        XCTAssertEqual(issue.status, .inProgress)
        XCTAssertEqual(issue.tags, ["sync", "network"])
        XCTAssertNotNil(issue.assignee)
        XCTAssertEqual(issue.assignee?.displayName, "Morgan Chan")
        XCTAssertEqual(issue.updatedAt.timeIntervalSince1970, 1_697_040_000.0, accuracy: 0.1)

        let lastRequest = try XCTUnwrap(MockURLProtocol.lastRequest)
        let components = try XCTUnwrap(URLComponents(url: lastRequest.url!, resolvingAgainstBaseURL: false))
        let queryItems = components.queryItems ?? []
        XCTAssertTrue(queryItems.contains(URLQueryItem(name: "\u{24}top", value: "50")))
        XCTAssertTrue(queryItems.contains(URLQueryItem(name: "\u{24}skip", value: "0")))
        XCTAssertTrue(queryItems.contains(where: { $0.name == "fields" && $0.value?.contains("idReadable") == true }))
        XCTAssertTrue(queryItems.contains(where: { $0.name == "query" && $0.value?.contains("sort by: updated desc") == true }))
    }

    func testCreateIssueBuildsPayloadAndDecodesResponse() async throws {
        let sampleResponse = """
        {
          "id": "0-123",
          "idReadable": "YT-123",
          "summary": "Ship settings panel",
          "project": {
            "name": "YouTrek",
            "shortName": "YT"
          },
          "updated": 1697040000000,
          "customFields": [
            {
              "$type": "SingleEnumIssueCustomField",
              "name": "Priority",
              "value": { "name": "High" }
            },
            {
              "$type": "StateIssueCustomField",
              "name": "State",
              "value": { "name": "Open" }
            },
            {
              "$type": "SingleUserIssueCustomField",
              "name": "Assignee",
              "value": {
                "login": "morgan",
                "name": "Morgan Chan"
              }
            }
          ],
          "tags": []
        }
        """.data(using: .utf8)!

        MockURLProtocol.requestHandler = { request in
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer TOKEN" else {
                throw NSError(domain: "Auth", code: 0)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, sampleResponse)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let repo = YouTrackIssueRepository(
            configuration: YouTrackAPIConfiguration(
                baseURL: URL(string: "https://example.com/api")!,
                tokenProvider: .constant("TOKEN")
            ),
            session: session
        )

        let draft = IssueDraft(
            title: "Ship settings panel",
            description: "The preferences pane should ship this week.",
            projectID: "0-1",
            module: "Settings",
            priority: .high,
            assigneeID: "morgan"
        )

        let created = try await repo.createIssue(draft: draft)
        XCTAssertEqual(created.readableID, "YT-123")
        XCTAssertEqual(created.title, "Ship settings panel")
        XCTAssertEqual(created.projectName, "YT")
        XCTAssertEqual(created.priority, .high)

        let lastRequest = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(lastRequest.httpMethod, "POST")
        let components = try XCTUnwrap(URLComponents(url: lastRequest.url!, resolvingAgainstBaseURL: false))
        let queryItems = components.queryItems ?? []
        XCTAssertTrue(queryItems.contains(where: { $0.name == "fields" && $0.value?.contains("idReadable") == true }))

        let body = try XCTUnwrap(lastRequest.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["summary"] as? String, "Ship settings panel")

        let project = json["project"] as? [String: Any]
        XCTAssertEqual(project?["id"] as? String, "0-1")

        let customFields = json["customFields"] as? [[String: Any]]
        let priorityField = customFields?.first(where: { $0["name"] as? String == "Priority" })
        let priorityValue = priorityField?["value"] as? [String: Any]
        XCTAssertEqual(priorityValue?["name"] as? String, "High")
        XCTAssertEqual(priorityField?["$type"] as? String, "SingleEnumIssueCustomField")

        let assigneeField = customFields?.first(where: { $0["name"] as? String == "Assignee" })
        let assigneeValue = assigneeField?["value"] as? [String: Any]
        XCTAssertEqual(assigneeValue?["login"] as? String, "morgan")

        let moduleField = customFields?.first(where: { $0["name"] as? String == "Subsystem" })
        let moduleValue = moduleField?["value"] as? [String: Any]
        XCTAssertEqual(moduleValue?["name"] as? String, "Settings")
    }
}

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "NoHandler", code: 0))
            return
        }

        do {
            let (response, data) = try handler(request)
            Self.lastRequest = request
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        // no-op
    }
}
