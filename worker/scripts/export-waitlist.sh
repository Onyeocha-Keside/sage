#!/bin/bash
#
# Exports every waitlist signup as a CSV you can open in Excel or Numbers.
#
#   cd worker
#   ./scripts/export-waitlist.sh > waitlist.csv     # save to a file
#   ./scripts/export-waitlist.sh                    # or just print it
#
# Signups live in the WAITLIST storage (Cloudflare KV) behind the Sage Worker.

set -euo pipefail
cd "$(dirname "$0")/.."

signup_keys=$(npx wrangler kv key list --binding WAITLIST --remote 2>/dev/null \
  | python3 -c 'import json, sys; [print(entry["name"]) for entry in json.load(sys.stdin)]')

echo "email,platform,signed_up_at,signed_up_from"
for signup_key in $signup_keys; do
  npx wrangler kv key get "$signup_key" --binding WAITLIST --remote 2>/dev/null \
    | python3 -c 'import json, sys
signup = json.load(sys.stdin)
print(",".join([signup.get("email", ""), signup.get("platform", ""), signup.get("signedUpAt", ""), signup.get("origin") or ""]))'
done
