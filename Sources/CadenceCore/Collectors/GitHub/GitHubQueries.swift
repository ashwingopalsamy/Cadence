/// The two GraphQL documents the built-in GitHub collector sends to `gh api graphql` (docs/SPEC.md section 10.3).
enum GitHubQueries {
    static let contributions = """
        query($from: DateTime!, $to: DateTime!, $prs: String, $reviews: String) {
          viewer {
            login
            contributionsCollection(from: $from, to: $to) {
              pullRequestContributions(first: 100, after: $prs) {
                pageInfo { hasNextPage endCursor }
                nodes { pullRequest { id number title url isDraft createdAt additions deletions bodyText
                                      repository { nameWithOwner } } }
              }
              pullRequestReviewContributions(first: 100, after: $reviews) {
                pageInfo { hasNextPage endCursor }
                nodes { pullRequestReview { id state submittedAt comments { totalCount } }
                        pullRequest { id number title url author { login } repository { nameWithOwner } } }
              }
            }
          }
        }
        """

    static let mergedSearch = """
        query($q: String!, $cursor: String) {
          search(type: ISSUE, first: 100, after: $cursor, query: $q) {
            pageInfo { hasNextPage endCursor }
            nodes { ... on PullRequest { id number title url mergedAt additions deletions bodyText
                                         repository { nameWithOwner } } }
          }
        }
        """
}
