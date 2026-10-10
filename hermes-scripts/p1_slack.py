#!/usr/bin/env python3
"""Today's P1 summary for Slack, run by Hermes cron on kraken (via p1_post.sh).

Without arguments it prints the message (preview). With --send it posts it once
per day to P1_SLACK_CHANNEL_ID as the bot behind SLACK_BOT_TOKEN.
Any Linear failure exits non-zero before anything is posted, so a partial summary
never goes out. A send whose outcome is unknown is not retried: inspect Slack first.

Needs LINEAR_API_KEY, and for --send SLACK_BOT_TOKEN and P1_SLACK_CHANNEL_ID
(environment, or ~/.hermes/.env). Stdlib only.
"""
import json
import os
import sys
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

TEAM_KEY = os.environ.get("P1_LINEAR_TEAM_KEY", "ATL")
BANGKOK = timezone(timedelta(hours=7))  # no DST; avoids needing tzdata in the image
STATUS_NAMES = {"Todo": "To do", "In Progress": "In progress"}

ISSUES_QUERY = """
query P1Issues($team: String!, $after: String) {
  issues(first: 100, after: $after, filter: {
    team: { key: { eq: $team } }
    priority: { eq: 1 }
    state: { type: { nin: ["completed", "canceled"] } }
  }) {
    nodes { title url state { name } assignee { id } }
    pageInfo { hasNextPage endCursor }
  }
}
"""

MEMBERS_QUERY = """
query TeamMembers($team: String!, $after: String) {
  teams(filter: { key: { eq: $team } }) {
    nodes {
      members(first: 100, after: $after) {
        nodes { id name active }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}
"""


def setting(name):
    value = os.environ.get(name)
    if value:
        return value
    env_file = Path(os.environ.get("HERMES_HOME", Path.home() / ".hermes")) / ".env"
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            if line.startswith(name + "="):
                return line.split("=", 1)[1].strip().strip("\"'")
    sys.exit(f"{name} is not set")


def graphql(key, query, variables):
    request = urllib.request.Request(
        "https://api.linear.app/graphql",
        data=json.dumps({"query": query, "variables": variables}).encode(),
        headers={"Authorization": key, "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        body = json.load(response)
    if body.get("errors") or not body.get("data"):
        # Message only: never echo the request or key.
        sys.exit("Linear query failed: " + "; ".join(e.get("message", "?") for e in body.get("errors", [])))
    return body["data"]


def fetch(key):
    issues, after = [], None
    while True:
        page = graphql(key, ISSUES_QUERY, {"team": TEAM_KEY, "after": after})["issues"]
        issues += page["nodes"]
        if not page["pageInfo"]["hasNextPage"]:
            break
        after = page["pageInfo"]["endCursor"]

    members, after = [], None
    while True:
        teams = graphql(key, MEMBERS_QUERY, {"team": TEAM_KEY, "after": after})["teams"]["nodes"]
        if len(teams) != 1:
            sys.exit(f"Expected one Linear team with key {TEAM_KEY}, found {len(teams)}")
        page = teams[0]["members"]
        members += [m for m in page["nodes"] if m["active"]]
        if not page["pageInfo"]["hasNextPage"]:
            break
        after = page["pageInfo"]["endCursor"]
    return issues, members


def status(issue):
    name = issue["state"]["name"]
    return STATUS_NAMES.get(name, name)


def link(issue):
    # Slack mrkdwn: <url|text>, with &, < and > escaped in the text.
    title = issue["title"].replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    return f"<{issue['url']}|{title}>"


def group(name, issues):
    if len(issues) == 1:
        return f"*{name}* · {status(issues[0])}\n{link(issues[0])}"
    return "\n".join([f"*{name}*"] + [f"{link(i)} · {status(i)}" for i in issues])


def compose(issues, members, today):
    first_names = {m["id"]: m["name"].split()[0] for m in members}
    by_assignee, unassigned = {}, []
    for issue in issues:
        assignee = issue["assignee"]
        if assignee and assignee["id"] in first_names:
            by_assignee.setdefault(assignee["id"], []).append(issue)
        else:
            # Unassigned, or assigned to someone outside the team's active members.
            unassigned.append(issue)

    blocks = [f"*Today’s P1 · {today.strftime('%b')} {today.day}*"]
    if not issues:
        return blocks[0] + "\n\nNo open P1s across the team."
    for member in sorted(members, key=lambda m: first_names[m["id"]]):
        if member["id"] in by_assignee:
            blocks.append(group(first_names[member["id"]], by_assignee[member["id"]]))
    if unassigned:
        blocks.append(group("Unassigned", unassigned))
    idle = sorted(first_names[m["id"]] for m in members if m["id"] not in by_assignee)
    if idle:
        blocks.append(", ".join(idle) + " — no open P1s")
    return "\n\n".join(blocks)


def send(text, today):
    token, channel = setting("SLACK_BOT_TOKEN"), setting("P1_SLACK_CHANNEL_ID")
    receipts = Path.home() / ".local/state/p1-slack"
    receipts.mkdir(parents=True, exist_ok=True)
    receipt = receipts / f"{today:%Y-%m-%d}-{channel}.json"
    try:
        # Claimed before the network call; an existing receipt of any status blocks a resend.
        handle = receipt.open("x")
    except FileExistsError:
        sys.exit(f"Already attempted today; inspect Slack and {receipt} before resending")
    record = {"status": "uncertain"}
    try:
        request = urllib.request.Request(
            "https://slack.com/api/chat.postMessage",
            data=json.dumps({"channel": channel, "text": text, "unfurl_links": False, "unfurl_media": False}).encode(),
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json; charset=utf-8"},
        )
        with urllib.request.urlopen(request, timeout=15) as response:
            result = json.load(response)
        if result.get("ok") is True:
            record = {"status": "sent", "ts": result.get("ts")}
        elif result.get("ok") is False:
            record = {"status": "failed", "error": result.get("error")}
    except Exception as error:  # timeout or transport error: may or may not have posted
        record["error"] = type(error).__name__
    finally:
        json.dump(record, handle)
        handle.close()
    if record["status"] == "failed":
        receipt.unlink()  # Slack rejected it, so nothing was posted and a rerun is safe
    if record["status"] != "sent":
        sys.exit(f"Slack send {record['status']}: {record.get('error', '')}")
    print(f"sent {record['ts']} to {channel}")


if __name__ == "__main__":
    now = datetime.now(BANGKOK)
    message = compose(*fetch(setting("LINEAR_API_KEY")), now)
    if "--send" in sys.argv[1:]:
        send(message, now)
    else:
        print(message)
