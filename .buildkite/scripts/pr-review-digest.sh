#!/usr/bin/env bash
set -euo pipefail

# Posts a channel digest of open, non-draft, human-authored pactflow org PRs that:
#   - have no reviewer assigned
#   - have all CI checks passing
#   - do not carry the "DO NOT MERGE" label
#
# Required env vars:
#   GH_PAT               GitHub PAT with read:org + repo scopes
#   SLACK_WEBHOOK_URL    Slack incoming webhook URL

export GH_TOKEN="${GH_PAT}"

PRS=$(gh api graphql -f query='
{
  search(query: "org:pactflow is:pr is:open draft:false review:none status:success", type: ISSUE, first: 100) {
    nodes {
      ... on PullRequest {
        title
        url
        createdAt
        author { login __typename }
        labels(first: 10) { nodes { name } }
        reviewRequests(first: 1) { totalCount }
        repository { name }
      }
    }
  }
}' --jq '
  [.data.search.nodes[] |
    select(
      (.author.__typename == "User") and
      (.labels.nodes | map(.name) | any(. == "DO NOT MERGE") | not) and
      (.reviewRequests.totalCount == 0)
    )
  ] | sort_by(.createdAt)
')

COUNT=$(echo "$PRS" | jq 'length')
if [ "$COUNT" -eq 0 ]; then
  echo "No PRs awaiting a reviewer — skipping Slack notification."
  exit 0
fi

NOW=$(date -u +%s)
BLOCKS=$(echo "$PRS" | jq --argjson now "$NOW" '
  [
    {
      "type": "header",
      "text": { "type": "plain_text", "text": "PRs awaiting a reviewer — pactflow org", "emoji": true }
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": (
          map(
            (.createdAt | sub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) as $created |
            (($now - $created) / 86400 | floor) as $days |
            "• <\(.url)|\(.title)>  —  `\(.repository.name)`  —  @\(.author.login)  —  :white_check_mark: \($days)d ago"
          ) | join("\n")
        )
      }
    }
  ]
')

PAYLOAD=$(jq -n --argjson blocks "$BLOCKS" '{"blocks": $blocks}')
curl -s -X POST "$SLACK_WEBHOOK_URL" \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD"
