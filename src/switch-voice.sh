#!/usr/bin/env bash
# Switch the active voice profile for Claude Code TTS
# Usage: bash switch-voice.sh [default|kitt|trek-computer|jarvis]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILES="$SCRIPT_DIR/voice-profiles.json"

show_profiles() {
  echo "Available voice profiles:"
  PROFILES_FILE="$PROFILES" python -c "
import json, os
with open(os.environ['PROFILES_FILE']) as f:
    data = json.load(f)
active = data.get('active', 'default')
for name, p in data['profiles'].items():
    marker = ' (active)' if name == active else ''
    print(f'  {name:20s} {p[\"engine\"]:8s} - {p[\"description\"]}{marker}')
"
}

if [ $# -eq 0 ]; then
  show_profiles
  echo ""
  echo "Usage: $0 <profile-name>"
  echo "  Or set CLAUDE_VOICE=<profile-name> before starting Claude Code"
  exit 0
fi

PROFILE="$1"

# Update the profiles JSON
PROFILES_FILE="$PROFILES" VOICE_PROFILE="$PROFILE" python -c "
import json, sys, os
profiles_path = os.environ['PROFILES_FILE']
profile = os.environ['VOICE_PROFILE']
with open(profiles_path) as f:
    data = json.load(f)
if profile not in data['profiles']:
    print(f'Unknown profile: {profile}', file=sys.stderr)
    print(f'Available: {list(data[\"profiles\"].keys())}', file=sys.stderr)
    sys.exit(1)
data['active'] = profile
with open(profiles_path, 'w') as f:
    json.dump(data, f, indent=2)
p = data['profiles'][profile]
print(f'Switched to: {profile} ({p[\"description\"]})')
print(f'Engine: {p[\"engine\"]}')
"

echo ""
echo "Voice will take effect on next TTS output."
echo "You can also use: CLAUDE_VOICE=$PROFILE claude"
