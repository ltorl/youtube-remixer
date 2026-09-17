#!/usr/bin/env bash
#
# setup.sh -- bootstrap the yt-remixer "rmx" tool on a fresh machine.
#
# Installs dependencies (yt-dlp, ffmpeg, jq, curl, python3, git), sets up the
# youtube-upload CLI in its own venv, patches its dead OAuth flow, imports a
# YouTube OAuth client JSON downloaded from the Google Cloud console,
# generates rmx.sh, and adds the `rmx` shell shortcut to your shell rc file.
#
# Usage:  ./setup.sh
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YT_UPLOAD_HOME="${YT_UPLOAD_HOME:-$HOME/youtube-upload}"
YT_UPLOAD_REPO="https://github.com/tokland/youtube-upload.git"
# Where the `rmx` executable is installed. ~/.local/bin is the conventional
# per-user bin dir and needs no sudo; /usr/bin is SIP-protected on macOS and
# not writable at all. Override with RMX_BIN_DIR=/usr/local/bin if you would
# rather install system-wide (that one may need sudo).
BIN_DIR="${RMX_BIN_DIR:-$HOME/.local/bin}"
CONSOLE_URL="https://console.cloud.google.com/apis/dashboard"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Ask on the terminal rather than on stdin.
#
# If setup.sh is piped (curl ... | bash) or has its stdin redirected, a plain
# `read` hits EOF and returns immediately -- without even printing its prompt --
# so every question silently takes its default and the script races past them.
# Reading /dev/tty keeps the questions working in those cases.
# `[ -r /dev/tty ]` is not enough: the node can exist and still fail to open
# when the process has no controlling terminal, so actually try to open it.
if { : < /dev/tty; } 2>/dev/null; then
  TTY_OK=1
else
  TTY_OK=0
fi

ask() {
  local prompt="$1" var="$2"
  if [ "$TTY_OK" = "1" ]; then
    read -r -p "$prompt" "$var" < /dev/tty || true
  else
    read -r -p "$prompt" "$var" || true
  fi
}

ask_secret() {
  local prompt="$1" var="$2"
  if [ "$TTY_OK" = "1" ]; then
    read -r -s -p "$prompt" "$var" < /dev/tty || true
  else
    read -r -s -p "$prompt" "$var" || true
  fi
  echo
}

# ---------------------------------------------------------------- dependencies

install_deps_macos() {
  if ! command -v brew >/dev/null 2>&1; then
    say "Homebrew not found. Installing it..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Make brew usable in this shell for both Apple Silicon and Intel layouts.
    for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do
      [ -x "$p" ] && eval "$("$p" shellenv)"
    done
  fi
  command -v brew >/dev/null 2>&1 || die "Homebrew install failed; install it manually and re-run."

  local missing=()
  for pkg in yt-dlp ffmpeg jq python@3.12 git; do
    case "$pkg" in
      yt-dlp)     command -v yt-dlp  >/dev/null 2>&1 || missing+=("$pkg") ;;
      ffmpeg)     command -v ffmpeg  >/dev/null 2>&1 || missing+=("$pkg") ;;
      jq)         command -v jq      >/dev/null 2>&1 || missing+=("$pkg") ;;
      git)        command -v git     >/dev/null 2>&1 || missing+=("$pkg") ;;
      python@*)   command -v python3 >/dev/null 2>&1 || missing+=("$pkg") ;;
    esac
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    say "Installing: ${missing[*]}"
    brew install "${missing[@]}"
  else
    say "All Homebrew dependencies already present."
  fi
}

install_deps_linux() {
  local pkgs=(jq ffmpeg git curl python3 python3-venv python3-pip)
  if command -v apt-get >/dev/null 2>&1; then
    say "Installing dependencies with apt-get (sudo required)..."
    sudo apt-get update
    sudo apt-get install -y "${pkgs[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    say "Installing dependencies with dnf (sudo required)..."
    sudo dnf install -y jq ffmpeg git curl python3 python3-pip
  else
    warn "No apt-get or dnf found. Install jq, ffmpeg, git, curl and python3 yourself."
  fi
  if ! command -v yt-dlp >/dev/null 2>&1; then
    say "Installing yt-dlp via pip..."
    python3 -m pip install --user --upgrade yt-dlp
  fi
}

say "Installing system dependencies"
case "$(uname -s)" in
  Darwin) install_deps_macos ;;
  Linux)  install_deps_linux ;;
  *)      die "Unsupported platform: $(uname -s)" ;;
esac

for cmd in yt-dlp ffmpeg jq curl python3 git; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd is still missing after install; fix that and re-run."
done

# ------------------------------------------------------------- youtube-upload

say "Setting up youtube-upload in $YT_UPLOAD_HOME"
if [ -d "$YT_UPLOAD_HOME/.git" ]; then
  say "Repo already cloned; pulling latest."
  git -C "$YT_UPLOAD_HOME" pull --ff-only || warn "Could not fast-forward; keeping existing checkout."
elif [ -e "$YT_UPLOAD_HOME" ]; then
  warn "$YT_UPLOAD_HOME exists but is not a git checkout; using it as-is."
else
  git clone "$YT_UPLOAD_REPO" "$YT_UPLOAD_HOME"
fi

if [ ! -x "$YT_UPLOAD_HOME/venv/bin/python" ]; then
  say "Creating virtualenv"
  python3 -m venv "$YT_UPLOAD_HOME/venv"
fi

say "Installing python packages into the venv"
"$YT_UPLOAD_HOME/venv/bin/python" -m pip install --upgrade pip >/dev/null
"$YT_UPLOAD_HOME/venv/bin/python" -m pip install \
  google-api-python-client oauth2client progressbar2 httplib2
# NOTE: do NOT use `pip install -e` here. This project's setup.py calls
# distutils.core.setup(), and modern pip builds an editable wheel from it
# that maps none of the packages: the console script lands in venv/bin but
# `import youtube_upload` raises ModuleNotFoundError. A regular install
# from the path works correctly.
"$YT_UPLOAD_HOME/venv/bin/python" -m pip uninstall -y youtube-upload >/dev/null 2>&1 || true
"$YT_UPLOAD_HOME/venv/bin/python" -m pip install "$YT_UPLOAD_HOME"

YT_UPLOAD_BIN="$YT_UPLOAD_HOME/venv/bin/youtube-upload"
[ -x "$YT_UPLOAD_BIN" ] || die "youtube-upload was not installed into the venv."
"$YT_UPLOAD_HOME/venv/bin/python" -c 'import youtube_upload.main' 2>/dev/null \
  || die "youtube-upload installed but is not importable. Try removing $YT_UPLOAD_HOME and re-running."
"$YT_UPLOAD_BIN" --help >/dev/null 2>&1 || die "youtube-upload is installed but will not run."
say "youtube-upload verified working."

# ------------------------------------------------------- patch the OAuth flow
#
# Upstream youtube-upload hardcodes the out-of-band OAuth flow
# (redirect_uri = urn:ietf:wg:oauth:2.0:oob). Google turned that flow off for
# good in 2023, so the consent page now fails with
# "Error 400: redirect_uri_mismatch" before you can even sign in.
#
# Replace the auth wrapper with one that uses the loopback flow: a throwaway
# web server on 127.0.0.1 catches the redirect, so no verification code needs
# to be pasted back into the terminal. This is what a "Desktop app" OAuth
# client is meant to do. Re-applied on every run, so a reinstall or an upstream
# pull can not quietly restore the broken flow.

say "Patching youtube-upload to use the loopback OAuth flow"
SITE_PKG=$("$YT_UPLOAD_HOME/venv/bin/python" -c \
  'import youtube_upload, os; print(os.path.dirname(youtube_upload.__file__))')
[ -d "$SITE_PKG/auth" ] || die "Could not locate the installed youtube_upload/auth package."

cat > "$SITE_PKG/auth/__init__.py" <<'AUTH_EOF'
"""Wrapper for Google OAuth2 API.

PATCHED by yt-remixer setup.sh -- see the patch notes in setup.sh. Upstream
forces the out-of-band flow (urn:ietf:wg:oauth:2.0:oob), which Google removed
in 2023; this uses the loopback flow instead.
"""

import argparse
import json
from urllib.parse import urlparse

import googleapiclient.discovery
import httplib2
import oauth2client

from oauth2client import client
from oauth2client import file
from oauth2client import tools

# main.py reaches into these as auth.console.get_code / auth.browser.get_code,
# so importing the package must keep exposing them even though the loopback
# flow below no longer calls either one.
from youtube_upload.auth import browser
from youtube_upload.auth import console

YOUTUBE_UPLOAD_SCOPE = ["https://www.googleapis.com/auth/youtube.upload",
                        "https://www.googleapis.com/auth/youtube"]

DEFAULT_LOOPBACK_PORTS = [8080, 8090, 8100, 9090]


def _loopback_ports(client_secrets_file):
    """Ports to offer the local redirect listener, in preference order.

    A "Desktop app" client accepts any loopback port, so the defaults are
    fine. A "Web application" client only accepts redirect URIs registered in
    the Cloud console, so prefer the loopback ports it actually lists --
    otherwise the consent screen fails with redirect_uri_mismatch.
    """
    try:
        with open(client_secrets_file) as fd:
            block = json.load(fd)
    except (OSError, ValueError):
        return DEFAULT_LOOPBACK_PORTS
    block = block.get("installed") or block.get("web") or {}

    ports = []
    for uri in block.get("redirect_uris") or []:
        parsed = urlparse(uri)
        if parsed.hostname not in ("localhost", "127.0.0.1"):
            continue
        # run_flow always redirects to the root path, so a registered URI
        # carrying a path such as /callback can never match it.
        if parsed.path not in ("", "/"):
            continue
        if parsed.port and parsed.port not in ports:
            ports.append(parsed.port)
    return ports or DEFAULT_LOOPBACK_PORTS


def _get_credentials_interactively(flow, storage, ports):
    """Run the loopback OAuth flow and return the stored credentials."""
    flags = argparse.Namespace(
        noauth_local_webserver=False,
        auth_host_name="localhost",
        auth_host_port=list(ports),
        logging_level="ERROR",
    )
    return tools.run_flow(flow, storage, flags=flags)


def _get_credentials(flow, storage, ports):
    """Return the user credentials. If not found, run the interactive flow."""
    existing_credentials = storage.get()
    if existing_credentials and not existing_credentials.invalid:
        return existing_credentials
    else:
        return _get_credentials_interactively(flow, storage, ports)


def get_resource(client_secrets_file, credentials_file, get_code_callback=None):
    """Authenticate and return a googleapiclient.discovery.Resource object."""
    get_flow = oauth2client.client.flow_from_clientsecrets
    flow = get_flow(client_secrets_file, scope=YOUTUBE_UPLOAD_SCOPE)
    storage = oauth2client.file.Storage(credentials_file)
    ports = _loopback_ports(client_secrets_file)
    credentials = _get_credentials(flow, storage, ports)
    if credentials:
        httplib = httplib2.Http()
        httplib.redirect_codes = httplib.redirect_codes - {308}
        http = credentials.authorize(httplib)
        return googleapiclient.discovery.build("youtube", "v3", http=http)
AUTH_EOF

"$YT_UPLOAD_HOME/venv/bin/python" -c \
  'from youtube_upload import auth; auth.console; auth.DEFAULT_LOOPBACK_PORTS' \
  || die "The patched auth module does not import."
say "OAuth flow patched."

# ------------------------------------------------------------ client secrets

CLIENT_SECRETS="$YT_UPLOAD_HOME/client_secrets.json"

# Google Cloud Console hands you a JSON file whose top-level key is "web" or
# "installed", named after the client id. youtube-upload wants an "installed"
# block with specific fields, so normalise whatever was downloaded into that
# shape rather than making you retype the id and secret.

convert_client_secrets() {
  local src="$1" dst="$2" kind tmp
  [ -f "$src" ] || die "No such file: $src"
  jq -e 'has("installed") or has("web")' "$src" >/dev/null 2>&1 \
    || die "$src is not a Google OAuth client file (no \"installed\" or \"web\" key)."

  kind=$(jq -r 'if has("installed") then "installed" else "web" end' "$src")
  if [ "$kind" = "web" ]; then
    warn "That is a \"Web application\" OAuth client."
    warn "Converting it works, but Google still only accepts redirect URIs you"
    warn "registered in the console, so sign-in succeeds only on a loopback"
    warn "port listed there (http://localhost:PORT, no path). A \"Desktop app\""
    warn "client accepts any loopback port and needs no such bookkeeping."
  fi

  tmp=$(mktemp)
  jq '(.installed // .web) as $c | {installed: {
        client_id:    $c.client_id,
        client_secret: $c.client_secret,
        auth_uri:     ($c.auth_uri     // "https://accounts.google.com/o/oauth2/auth"),
        token_uri:    ($c.token_uri    // "https://oauth2.googleapis.com/token"),
        auth_provider_x509_cert_url:
          ($c.auth_provider_x509_cert_url // "https://www.googleapis.com/oauth2/v1/certs"),
        redirect_uris: ($c.redirect_uris // ["http://localhost"])
      }}' "$src" > "$tmp" || { rm -f "$tmp"; die "Could not parse $src"; }

  jq -e '.installed.client_id and .installed.client_secret' "$tmp" >/dev/null 2>&1 \
    || { rm -f "$tmp"; die "$src has no client_id / client_secret."; }

  umask 077
  mv "$tmp" "$dst"
  chmod 600 "$dst"
  say "Wrote $dst"
  say "  client id : $(jq -r '.installed.client_id' "$dst")"
  say "  type      : $kind"
}

# Open a URL in the default browser. Returns non-zero if there is no way to
# (a headless box, or an SSH session with no display), so the caller can fall
# back to just printing the link.
open_url() {
  local url="$1"
  if command -v open >/dev/null 2>&1; then
    open "$url" >/dev/null 2>&1 && return 0
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" >/dev/null 2>&1 && return 0
  fi
  return 1
}

# macOS file picker. Returns empty if cancelled or unavailable.
pick_client_secrets_file() {
  [ "$(uname -s)" = "Darwin" ] || return 0
  command -v osascript >/dev/null 2>&1 || return 0
  osascript -e 'POSIX path of (choose file with prompt "Select the OAuth client JSON downloaded from Google Cloud Console:")' 2>/dev/null || true
}

write_client_secrets_manually() {
  local id secret
  ask        "YouTube OAuth client ID: " id
  ask_secret "YouTube OAuth client secret: " secret
  [ -n "$id" ] && [ -n "$secret" ] || die "Both the client ID and secret are required."

  umask 077
  cat > "$CLIENT_SECRETS" <<JSON
{
  "installed": {
    "client_id": "$id",
    "client_secret": "$secret",
    "auth_uri": "https://accounts.google.com/o/oauth2/auth",
    "token_uri": "https://oauth2.googleapis.com/token",
    "auth_provider_x509_cert_url": "https://www.googleapis.com/oauth2/v1/certs",
    "redirect_uris": ["http://localhost"]
  }
}
JSON
  chmod 600 "$CLIENT_SECRETS"
  say "Wrote $CLIENT_SECRETS"
}

write_client_secrets() {
  local src=""
  echo
  if open_url "$CONSOLE_URL"; then
    say "Opened $CONSOLE_URL in your browser."
  else
    say "Open this in your browser: $CONSOLE_URL"
  fi
  echo

  # A file dialog is the easy path, but it only exists on a macOS desktop.
  # Anywhere else -- Linux, or over SSH with no window server -- fall through
  # to entering the client id and secret by hand.
  if [ "$(uname -s)" = "Darwin" ] && command -v osascript >/dev/null 2>&1; then
    ask "Press Enter once you have downloaded the client JSON to pick it... " _
    src=$(pick_client_secrets_file)
    [ -n "$src" ] || warn "No file chosen; enter the credentials by hand instead."
  else
    ask "Press Enter once you have created the OAuth client... " _
  fi

  if [ -n "$src" ]; then
    convert_client_secrets "$src" "$CLIENT_SECRETS"
  else
    write_client_secrets_manually
  fi
}

if [ -f "$CLIENT_SECRETS" ]; then
  ask "client_secrets.json already exists. Replace it? [y/N] " reply
  case "$reply" in
    [yY]*) write_client_secrets ;;
    *)     say "Keeping existing client_secrets.json." ;;
  esac
else
  write_client_secrets
fi

# -------------------------------------------------------------- install rmx

RMX="$BIN_DIR/rmx"
mkdir -p "$BIN_DIR"
if [ -f "$RMX" ]; then
  cp "$RMX" "$RMX.bak.$(date +%Y%m%d%H%M%S)"
  say "Backed up the existing $RMX"
fi

say "Writing $RMX"
cat > "$RMX" <<'RMX_EOF'
#!/usr/bin/env bash
#
# rmx -- re-upload a YouTube short (or a whole playlist) to your own channel.
#
#   rmx <url>              re-upload one video
#   rmx --playlist <url>   re-upload every video in a playlist
#
# Installed by setup.sh. Paths can be overridden with YT_UPLOAD_HOME
# and RMX_CLIENT_SECRETS.

PLAYLIST=0
URL=""

for arg in "$@"; do
  case "$arg" in
    -playlist|--playlist) PLAYLIST=1 ;;
    *) URL="$arg" ;;
  esac
done

if [ -z "$URL" ]; then
  if [ "$PLAYLIST" -eq 1 ]; then
    read -r -p "Enter playlist URL: " URL
  else
    read -r -p "Enter yt-shorts URL: " URL
  fi
fi

YT_UPLOAD_HOME="${YT_UPLOAD_HOME:-@YT_UPLOAD_HOME@}"
CLIENT_SECRETS="${RMX_CLIENT_SECRETS:-$YT_UPLOAD_HOME/client_secrets.json}"

# youtube-upload is installed in a venv, so prefer that over PATH.
YT_UPLOAD="$YT_UPLOAD_HOME/venv/bin/youtube-upload"
if [ ! -x "$YT_UPLOAD" ]; then
  YT_UPLOAD=$(command -v youtube-upload)
fi
if [ -z "$YT_UPLOAD" ]; then
  echo "youtube-upload not found (checked venv and PATH). Run setup.sh." >&2
  exit 1
fi
if [ ! -f "$CLIENT_SECRETS" ]; then
  echo "client_secrets.json not found at $CLIENT_SECRETS. Run setup.sh." >&2
  exit 1
fi
for cmd in yt-dlp ffmpeg jq curl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "$cmd not found. Run setup.sh." >&2; exit 1; }
done

repost() {
  local url="$1"

  local json
  json=$(yt-dlp --no-playlist --skip-download -j "$url") || return 1

  local title description tags thumbnail_url
  title=$(echo "$json" | jq -r '.title')
  description=$(echo "$json" | jq -r '.description')
  tags=$(echo "$json" | jq -r '.tags | join(",")')
  thumbnail_url=$(echo "$json" | jq -r '.thumbnail')

  local tmpdir
  tmpdir=$(mktemp -d)

  # Download into its own subdir so the thumbnail can never be picked as the
  # video, and force a merge so we get one file rather than separate
  # video-only and audio-only streams.
  mkdir -p "$tmpdir/dl"
  yt-dlp --no-playlist --merge-output-format mp4 \
    -o "$tmpdir/dl/video.%(ext)s" "$url" || { rm -rf "$tmpdir"; return 1; }

  # dl/ is flat, so `ls -S` (size descending, portable across BSD and GNU)
  # puts the merged video first.
  local video name
  name=$(ls -S "$tmpdir/dl" 2>/dev/null | head -n 1)
  video="$tmpdir/dl/$name"
  if [ -z "$name" ] || [ ! -f "$video" ]; then
    echo "No video file downloaded." >&2
    rm -rf "$tmpdir"
    return 1
  fi

  curl -L "$thumbnail_url" -o "$tmpdir/thumbnail.jpg"

  "$YT_UPLOAD" \
    --client-secrets="$CLIENT_SECRETS" \
    --title="$title" \
    --description="$description" \
    --tags="$tags" \
    --category="Film & Animation" \
    --thumbnail="$tmpdir/thumbnail.jpg" \
    "$video"

  local status=$?
  rm -rf "$tmpdir"
  return $status
}

if [ "$PLAYLIST" -eq 1 ]; then
  ids=()
  while IFS= read -r id; do
    [ -n "$id" ] && ids+=("$id")
  done < <(yt-dlp --flat-playlist --print "%(id)s" "$URL")

  if [ "${#ids[@]}" -eq 0 ]; then
    echo "No videos found in playlist." >&2
    exit 1
  fi

  echo "Found ${#ids[@]} videos in playlist."

  i=0
  failed=0
  for id in "${ids[@]}"; do
    i=$((i + 1))
    echo "=== [$i/${#ids[@]}] https://www.youtube.com/watch?v=$id ==="
    if ! repost "https://www.youtube.com/watch?v=$id"; then
      echo "!!! Failed: $id" >&2
      failed=$((failed + 1))
    fi
  done

  echo "Done. ${#ids[@]} videos processed, $failed failed."
  [ "$failed" -eq 0 ] || exit 1
else
  repost "$URL"
fi
RMX_EOF

# Bake in the youtube-upload location this setup actually used, so the
# installed executable does not depend on it sitting under $HOME.
sed -i.tmp "s|@YT_UPLOAD_HOME@|$YT_UPLOAD_HOME|" "$RMX" && rm -f "$RMX.tmp"
chmod +x "$RMX"
# `grep -q ... && die` would return non-zero on the success path and, under
# `set -e`, kill the script exactly when substitution worked.
if grep -q '@YT_UPLOAD_HOME@' "$RMX"; then
  die "Failed to substitute the youtube-upload path into $RMX."
fi
# --------------------------------------------------------------- PATH entry
#
# rmx is a real executable now, so the rc file only has to make sure its
# directory is on PATH. Earlier versions of this script installed an rmx()
# shell function inside the same markers; rewriting the block removes it.

add_path_entry() {
  local rc="$1"
  local marker="# >>> rmx shortcut >>>"
  [ -f "$rc" ] || touch "$rc"
  if grep -qF "$marker" "$rc"; then
    # Replace the existing block so re-running setup keeps paths current.
    local tmp
    tmp=$(mktemp)
    awk '/# >>> rmx shortcut >>>/{skip=1} !skip{print} /# <<< rmx shortcut <<</{skip=0}' "$rc" > "$tmp"
    mv "$tmp" "$rc"
  elif grep -qE '^[[:space:]]*rmx\(\)' "$rc"; then
    warn "$rc defines an rmx function outside the managed block; it will shadow"
    warn "$RMX. Remove it by hand."
  fi
  cat >> "$rc" <<RC

# >>> rmx shortcut >>>
case ":\$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) export PATH="$BIN_DIR:\$PATH" ;;
esac
# <<< rmx shortcut <<<
RC
  say "Put $BIN_DIR on PATH in $rc"
}

case "$(basename "${SHELL:-/bin/bash}")" in
  zsh)  add_path_entry "$HOME/.zshrc" ;;
  bash) add_path_entry "$HOME/.bashrc" ;;
  *)    warn "Unrecognized shell '$SHELL'; updating both ~/.zshrc and ~/.bashrc."
        add_path_entry "$HOME/.zshrc"
        add_path_entry "$HOME/.bashrc" ;;
esac

# ---------------------------------------------------------------------- done

cat <<DONE

$(say "Setup complete.")

  rmx           : $RMX
  youtube-upload: $YT_UPLOAD_BIN
  credentials   : $CLIENT_SECRETS

Open a new terminal (or run: source ~/.zshrc) so PATH picks it up, then:

  rmx https://www.youtube.com/shorts/XXXXXXXXXXX
  rmx --playlist https://www.youtube.com/playlist?list=XXXXXXXX

The first upload opens a browser to authorize the OAuth client; the token is
cached in ~/.youtube-upload-credentials.json after that.
DONE
