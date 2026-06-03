#!/usr/bin/env bash
set -euo pipefail

# @mentions each author in the given timezone group about their open, non-draft
# PRs that have no reviewer assigned and all CI checks passing.
# Runs Monday 9am per timezone group alongside draft-pr-reminders.
#
# Required env vars:
#   GH_PAT               GitHub PAT with read:org + repo scopes
#   SLACK_WEBHOOK_URL    Slack incoming webhook URL
#   TIMEZONE_GROUP       IANA timezone string (e.g. Australia/Melbourne)

export GH_TOKEN="${GH_PAT}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAPPING=$(cat "${SCRIPT_DIR}/../draft-pr-slack-mapping.json")

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
  echo "No unreviewed PRs found — skipping."
  exit 0
fi

NOW=$(date -u +%s)
BLOCKS=$(echo "$PRS" | jq \
  --argjson mapping "$MAPPING" \
  --arg tz "$TIMEZONE_GROUP" \
  --argjson now "$NOW" '
  [.[] | . as $pr |
    ($mapping[$pr.author.login] // null) as $user |
    select($user != null and $user.timezone == $tz) |
    { pr: $pr, slack_id: $user.slack_id }
  ] |
  if length == 0 then empty else . end |
  group_by(.pr.author.login) |
  [
    {
      "type": "header",
      "text": { "type": "plain_text", "text": "👀 PRs waiting for a reviewer — pactflow org", "emoji": true }
    }
  ] +
  map(
    . as $group |
    ($group[0].slack_id) as $slack_id |
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": (
          "<@\($slack_id)> has \($group | length) PR\(if ($group | length) == 1 then "" else "s" end) waiting for a reviewer:\n" +
          (
            $group | map(
              (.pr.createdAt | sub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) as $created |
              (($now - $created) / 86400 | floor) as $days |
              "• <\(.pr.url)|\(.pr.title)>  —  `\(.pr.repository.name)`  —  \($days)d old"
            ) | join("\n")
          )
        )
      }
    }
  )
')

if [ -z "$BLOCKS" ] || [ "$BLOCKS" = "null" ]; then
  echo "No unreviewed PRs for timezone group $TIMEZONE_GROUP — skipping."
  exit 0
fi

PAYLOAD=$(jq -n --argjson blocks "$BLOCKS" '{"blocks": $blocks}')
curl -s -X POST "$SLACK_WEBHOOK_URL" \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD"
