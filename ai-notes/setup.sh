#!/bin/bash
# Roofr Assist AI notes: one-time setup on a Mac (the Windows twin is setup.ps1). No admin rights needed;
# everything goes into this user's own Library folder. Paste the one line from Options -> Coach & Sales -> AI notes
# into Terminal (Cmd+Space, type Terminal, Enter):
#
#   curl -fsSL https://arizona-roofers.github.io/roofr-assist-releases/ai-notes/setup.sh | bash -s -- --backend agy --ext-id <id>
#
#   1. installs the notes helper into ~/Library/Application Support/RoofrAssist/notes-helper
#   2. registers it with Chrome (native messaging host com.arizonaroofers.notes, this user only)
#   3. sets up the AI tool, signed in with the person's OWN account (agy = Google; claude = Claude subscription)
#   4. runs a live test
set -e
BACKEND=agy
EXT_IDS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --backend) BACKEND="$2"; shift 2 ;;
    --ext-id) EXT_IDS+=("$2"); shift 2 ;;
    *) shift ;;
  esac
done
BASE="https://arizona-roofers.github.io/roofr-assist-releases/ai-notes"
ROOFR_ASSIST_ID="fkldnfkfppeicfcgmlnpknfkmnfkaabo"
HOST="com.arizonaroofers.notes"
DIR="$HOME/Library/Application Support/RoofrAssist/notes-helper"
CHROME_HOSTS="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
say() { printf '%b\n' "$1"; }
ok() { printf '\033[32m%s\033[0m\n' "$1"; }
bad() { printf '\033[31m%s\033[0m\n' "$1"; }

[ "$(uname)" = "Darwin" ] || { bad "This is the Mac setup. On Windows, use the PowerShell line from Options."; exit 1; }
case "$BACKEND" in agy|claude) ;; *) bad "Unknown AI '$BACKEND' (use agy or claude)."; exit 1 ;; esac
say "\n\033[36mRoofr Assist AI notes setup ($BACKEND)\033[0m"
/usr/bin/perl -MJSON::PP -e1 2>/dev/null || { bad "This Mac is missing Perl (it normally ships with macOS). Ask Travis."; exit 1; }

# 3 first (quietly): find or install the AI tool so its full path goes into the config Chrome's helper reads.
if [ "$BACKEND" = "agy" ]; then
  AGY="$(command -v agy || true)"; [ -x "$AGY" ] || AGY="$HOME/.local/bin/agy"
  if [ ! -x "$AGY" ]; then
    say "  installing Google Antigravity CLI (agy)..."
    curl -fsSL https://antigravity.google/cli/install.sh | bash </dev/null >/dev/null
    AGY="$HOME/.local/bin/agy"
  fi
  [ -x "$AGY" ] || { bad "  couldn't install agy. Ask Travis."; exit 1; }
  CLI="$AGY"
else
  CLAUDE="$(command -v claude || true)"; [ -x "$CLAUDE" ] || CLAUDE="$HOME/.local/bin/claude"
  [ -x "$CLAUDE" ] || { bad "Claude Code CLI isn't installed. Install it, run 'claude' once to sign in with your subscription, then run this again."; exit 1; }
  CLI="$CLAUDE"
fi

# 1. helper
mkdir -p "$DIR"
curl -fsSL "$BASE/notes-helper.pl" -o "$DIR/notes-helper.pl"
chmod +x "$DIR/notes-helper.pl"
/usr/bin/perl -MJSON::PP -e 'print JSON::PP->new->pretty->canonical->encode({ backend => $ARGV[0], $ARGV[0] => $ARGV[1] })' "$BACKEND" "$CLI" > "$DIR/config.json"
ok "  [1/4] helper installed in $DIR"

# 2. register with Chrome (this user only)
mkdir -p "$CHROME_HOSTS"
/usr/bin/perl -MJSON::PP -e '
  my ($path, @ids) = @ARGV; my %seen;
  print JSON::PP->new->pretty->canonical->encode({ name => "com.arizonaroofers.notes", description => "Roofr Assist AI notes helper",
    path => $path, type => "stdio", allowed_origins => [ map { "chrome-extension://$_/" } grep { /^[a-p]{32}$/ && !$seen{$_}++ } @ids ] })
' "$DIR/notes-helper.pl" "$ROOFR_ASSIST_ID" "${EXT_IDS[@]}" > "$CHROME_HOSTS/$HOST.json"
ok "  [2/4] registered with Chrome for: $ROOFR_ASSIST_ID ${EXT_IDS[*]}"

# 3. sign in with the person's own account
if [ "$BACKEND" = "agy" ]; then
  say "\033[33m  signing in: a browser window opens. Pick your @arizonaroofers.com Google account and click Allow.\033[0m"
  "$AGY" -p "Reply with exactly: OK" --print-timeout 120s </dev/null >/dev/null 2>&1 || true
fi
ok "  [3/4] $BACKEND ready ($CLI)"

# 4. live test through the helper, the same way Chrome will call it
RESULT="$(/usr/bin/perl -MJSON::PP -e 'my $m = encode_json({ type => "generate", backend => $ARGV[0], system => "You are a test. Reply with exactly: NOTES-OK", prompt => "test" }); print pack("V", length $m), $m' "$BACKEND" \
  | "$DIR/notes-helper.pl" \
  | /usr/bin/perl -MJSON::PP -e 'binmode STDIN; read(STDIN, my $l, 4) == 4 or do { print "FAIL no reply from the helper\n"; exit }; read(STDIN, my $b, unpack("V", $l)); my $r = JSON::PP->new->utf8->decode($b); print $r->{ok} ? "PASS $r->{text}\n" : "FAIL $r->{error}\n"')"
case "$RESULT" in
  PASS*) ok "  [4/4] live test passed: ${RESULT#PASS }" ;;
  *) bad "  [4/4] live test FAILED: ${RESULT#FAIL }" ;;
esac
say "\n\033[36mDone. In Chrome: Roofr Assist Options -> Coach & Sales -> AI notes -> Test.\033[0m"
