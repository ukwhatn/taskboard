import Foundation
import Hummingbird
import TaskboardKit

/// PR の一覧と中身
extension APIServer {
    static func registerPullRequestRoutes(v1: RouterGroup<TaskboardRequestContext>, dependencies: Dependencies, encoder: JSONEncoder) {
        v1.get("prs") { _, _ in
            try json(await dependencies.requirePRs().snapshot(), encoder)
        }
        v1.post("prs/refresh") { _, _ in
            try json(await dependencies.requirePRs().refresh(force: true), encoder)
        }
        v1.get("prs/detail") { request, _ in
            guard let raw = request.uri.queryParameters.get("url"), case let url = String(raw), !url.isEmpty else {
                throw APIError.invalid("url が要る")
            }
            do {
                return try json(try await dependencies.requirePRs().detail(url: url), encoder)
            } catch let error as PullRequestQueries.ParseError where error == .notAPullRequest {
                throw APIError.notFound(.pullRequest, error.description)
            } catch let error as GitHubCLI.Failure {
                throw APIError(.badGateway, .githubFailed, error.description)
            } catch let error as PullRequestQueries.ParseError {
                throw APIError(.badGateway, .githubFailed, error.description)
            }
        }
    }
}
