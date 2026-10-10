#!/bin/bash
# Daily P1 post, run by Hermes cron on kraken (`--script p1_post.sh --no-agent`).
# Railway variables only reach shells through env.sh, so load it before the script.
set -euo pipefail
[ -f "$HOME/.config/kraken/env.sh" ] && . "$HOME/.config/kraken/env.sh"
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/p1_slack.py" --send
