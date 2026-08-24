#!/usr/bin/env python3
"""Route Telegram forum-topic replies back into the matching Claude TUI.

This is deliberately independent of Claude Code Channels. One process owns the
Bot API getUpdates stream and routes messages by message_thread_id. The process
is cheap while idle: Telegram holds the long-poll HTTP request open and returns
as soon as an update arrives.
"""

from __future__ import annotations

import fcntl
import glob
import json
import os
import re
import shlex
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Optional


HOME = Path.home()
CLAUDE_DIR = HOME / ".claude"
CONF = Path(os.environ.get("CLAUDE_NOTIFY_CONF", str(CLAUDE_DIR / "notify.conf")))
OFFSET_FILE = CLAUDE_DIR / ".tg_reply_offset"
LOCK_FILE = CLAUDE_DIR / ".tg_reply_gateway.lock"
LOG_FILE = CLAUDE_DIR / "telegram-reply.log"
LOG_LOCK_FILE = CLAUDE_DIR / ".tg_reply_log.lock"
DEFAULT_LOG_MAX_MB = 100
DEFAULT_LOG_BACKUPS = 3


def int_setting(value: str, default: int, minimum: int) -> int:
    try:
        parsed = int(value)
        return parsed if parsed >= minimum else default
    except (TypeError, ValueError):
        return default


def rotate_log_if_needed(incoming_bytes: int, max_bytes: int, backups: int) -> None:
    try:
        current_size = LOG_FILE.stat().st_size
    except OSError:
        current_size = 0
    if current_size + incoming_bytes <= max_bytes:
        return

    if backups <= 0:
        try:
            LOG_FILE.unlink()
        except FileNotFoundError:
            pass
        return

    oldest = Path(f"{LOG_FILE}.{backups}")
    try:
        oldest.unlink()
    except FileNotFoundError:
        pass
    for index in range(backups - 1, 0, -1):
        source = Path(f"{LOG_FILE}.{index}")
        if source.exists():
            os.replace(source, Path(f"{LOG_FILE}.{index + 1}"))
    if LOG_FILE.exists():
        os.replace(LOG_FILE, Path(f"{LOG_FILE}.1"))


def log(message: str) -> None:
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {message}\n"
    try:
        config = read_conf()
        max_mb = int_setting(config.get("NOTIFY_TG_REPLY_LOG_MAX_MB", ""),
                             DEFAULT_LOG_MAX_MB, 1)
        backups = int_setting(config.get("NOTIFY_TG_REPLY_LOG_BACKUPS", ""),
                              DEFAULT_LOG_BACKUPS, 0)
        with LOG_LOCK_FILE.open("a+", encoding="utf-8") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            rotate_log_if_needed(len(line.encode("utf-8")),
                                 max_mb * 1024 * 1024, backups)
            with LOG_FILE.open("a", encoding="utf-8") as stream:
                stream.write(line)
    except OSError:
        pass


def read_conf() -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        lines = CONF.read_text(encoding="utf-8").splitlines()
    except OSError:
        return values
    for line in lines:
        match = re.match(r"^([A-Z][A-Z0-9_]*)=(.*)$", line.strip())
        if not match:
            continue
        try:
            parsed = shlex.split(match.group(2), comments=True)
            values[match.group(1)] = parsed[0] if parsed else ""
        except ValueError:
            continue
    return values


def api(token: str, method: str, params: dict[str, Any]) -> dict[str, Any]:
    url = f"https://api.telegram.org/bot{token}/{method}"
    body = urllib.parse.urlencode({k: str(v) for k, v in params.items()}).encode()
    request = urllib.request.Request(url, data=body, method="POST")
    with urllib.request.urlopen(request, timeout=65) as response:
        result = json.load(response)
    if not result.get("ok"):
        raise RuntimeError(f"{method}: {result.get('description', 'Telegram API error')}")
    return result


def send_text(token: str, chat_id: str, thread: str, text: str) -> None:
    api(token, "sendMessage", {
        "chat_id": chat_id,
        "message_thread_id": thread,
        "text": text,
        "disable_notification": "true",
    })


def routes() -> dict[str, dict[str, str]]:
    found: dict[str, dict[str, str]] = {}
    for filename in glob.glob(str(CLAUDE_DIR / ".tg_topic_*")):
        try:
            data = json.loads(Path(filename).read_text(encoding="utf-8"))
            thread = str(data.get("thread", ""))
            if thread:
                found[thread] = {str(k): str(v) for k, v in data.items()}
        except (OSError, ValueError, TypeError):
            continue
    return found


def tmux_target(route: dict[str, str]) -> str:
    direct = route.get("tmux_pane", "")
    if direct:
        try:
            subprocess.run(["tmux", "display-message", "-p", "-t", direct, "#S"],
                           check=True, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
            return direct
        except (OSError, subprocess.SubprocessError):
            pass
    tty = route.get("tty", "")
    if not tty:
        return ""
    try:
        listing = subprocess.check_output(
            ["tmux", "list-panes", "-a", "-F", "#{pane_tty}\t#{pane_id}"],
            text=True, stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    for line in listing.splitlines():
        pane_tty, _, pane_id = line.partition("\t")
        if pane_tty == tty:
            return pane_id
    return ""


def inject_tmux(route: dict[str, str], text: str) -> bool:
    target = tmux_target(route)
    if not target:
        return False
    try:
        # -l makes the entire Telegram payload literal: text such as "Enter" or
        # "C-c" must not be interpreted as a tmux key name.
        subprocess.run(["tmux", "send-keys", "-l", "-t", target, text],
                       check=True, timeout=5, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
        subprocess.run(["tmux", "send-keys", "-t", target, "Enter"],
                       check=True, timeout=5, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
        return True
    except (OSError, subprocess.SubprocessError):
        return False


def inject_iterm(route: dict[str, str], text: str) -> bool:
    tty = route.get("tty", "")
    if not tty or sys.platform != "darwin" or not shutil_which("osascript"):
        return False
    script = r'''on run argv
    set wantedTTY to item 1 of argv
    set promptText to item 2 of argv
    tell application "iTerm2"
        repeat with w in windows
            repeat with t in tabs of w
                repeat with s in sessions of t
                    if (tty of s) is wantedTTY then
                        tell s to write text promptText
                        return "ok"
                    end if
                end repeat
            end repeat
        end repeat
    end tell
    return "missing"
end run'''
    try:
        result = subprocess.run(
            ["osascript", "-", tty, text], input=script, text=True,
            capture_output=True, timeout=10, check=False,
        )
        return result.returncode == 0 and result.stdout.strip().endswith("ok")
    except (OSError, subprocess.SubprocessError):
        return False


def shutil_which(command: str) -> Optional[str]:
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        candidate = Path(directory) / command
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def inject(route: dict[str, str], text: str) -> str:
    if inject_tmux(route, text):
        return "tmux"
    if inject_iterm(route, text):
        return "iterm2"
    return ""


def load_offset() -> int:
    try:
        return int(OFFSET_FILE.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return 0


def save_offset(offset: int) -> None:
    temporary = OFFSET_FILE.with_suffix(".tmp")
    try:
        temporary.write_text(str(offset), encoding="utf-8")
        os.replace(temporary, OFFSET_FILE)
    except OSError:
        try:
            temporary.unlink()
        except OSError:
            pass


def allowed_sender(sender_id: str, configured: str) -> bool:
    allow = {item.strip() for item in re.split(r"[, ]+", configured) if item.strip()}
    return bool(allow) and sender_id in allow


def gateway_running() -> bool:
    """Return True when another process owns the singleton gateway lock."""
    CLAUDE_DIR.mkdir(parents=True, exist_ok=True)
    try:
        with LOCK_FILE.open("a+", encoding="utf-8") as lock:
            try:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except (OSError, BlockingIOError):
                return True
            return False
    except OSError:
        return False


def check() -> int:
    """Check configuration and connectivity without consuming Telegram updates."""
    config = read_conf()
    token = config.get("NOTIFY_TG_BOT_TOKEN", "")
    chat_id = config.get("NOTIFY_TG_CHAT_ID", "")
    allowed = config.get("NOTIFY_TG_REPLY_ALLOW_FROM", "")
    problems: list[str] = []

    enabled = config.get("NOTIFY_TG_REPLY", "0") == "1"
    print(f"config.reply: {'enabled' if enabled else 'disabled'}")
    if not enabled:
        problems.append("set NOTIFY_TG_REPLY=1")
    print(f"config.bot_token: {'set' if token else 'missing'}")
    if not token:
        problems.append("set NOTIFY_TG_BOT_TOKEN")
    print(f"config.chat_id: {'set' if chat_id else 'missing'}")
    if not chat_id:
        problems.append("set NOTIFY_TG_CHAT_ID")
    allow_items = [item for item in re.split(r"[, ]+", allowed) if item]
    valid_allow = bool(allow_items) and all(item.isdigit() for item in allow_items)
    print(f"config.allow_from: {'valid' if valid_allow else 'missing/invalid'}")
    if not valid_allow:
        problems.append("set numeric NOTIFY_TG_REPLY_ALLOW_FROM")
    forum = config.get("NOTIFY_TG_FORUM", "0") == "1"
    print(f"config.forum: {'enabled' if forum else 'disabled'}")
    if not forum:
        problems.append("set NOTIFY_TG_FORUM=1 for topic routing")

    running = gateway_running()
    print(f"gateway: {'running' if running else 'stopped'}")
    if enabled and not running:
        problems.append("start a new Claude session or run this script normally")
        try:
            last_log = LOG_FILE.read_text(encoding="utf-8").splitlines()[-1]
            print(f"gateway.last_log: {last_log}")
        except (OSError, IndexError):
            pass

    route_map = routes()
    routable = sum(1 for route in route_map.values()
                   if route.get("tmux_pane") or route.get("tty"))
    print(f"routes: {len(route_map)} total, {routable} with terminal target")
    if route_map and routable == 0:
        problems.append("no routable topic yet; wait for a notification from a new tmux/iTerm2 Claude session")

    if token:
        try:
            identity = api(token, "getMe", {}).get("result", {})
            print(f"telegram.bot: ok (@{identity.get('username', 'unknown')})")
        except Exception as error:
            print(f"telegram.bot: failed ({error})")
            problems.append("fix Bot Token or Telegram connectivity")
        try:
            webhook = api(token, "getWebhookInfo", {}).get("result", {})
            webhook_url = str(webhook.get("url", ""))
            print(f"telegram.webhook: {'configured (conflict)' if webhook_url else 'none'}")
            if webhook_url:
                problems.append("remove the webhook before using getUpdates")
        except Exception as error:
            print(f"telegram.webhook: check failed ({error})")
            problems.append("could not verify webhook state")

    if problems:
        print("result: FAIL")
        for problem in problems:
            print(f"- {problem}")
        return 1
    print("result: OK")
    return 0


def main() -> int:
    CLAUDE_DIR.mkdir(parents=True, exist_ok=True)
    try:
        lock = LOCK_FILE.open("a+", encoding="utf-8")
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (OSError, BlockingIOError):
        return 0

    config = read_conf()
    if config.get("NOTIFY_TG_REPLY", "0") != "1":
        log("gateway disabled: NOTIFY_TG_REPLY is not enabled")
        return 0
    token = config.get("NOTIFY_TG_BOT_TOKEN", "")
    chat_id = config.get("NOTIFY_TG_CHAT_ID", "")
    allowed = config.get("NOTIFY_TG_REPLY_ALLOW_FROM", "")
    if not token or not chat_id:
        log("gateway disabled: Telegram token/chat id not configured")
        return 0
    if not allowed:
        log("gateway disabled: set NOTIFY_TG_REPLY_ALLOW_FROM first")
        return 0

    offset = load_offset()
    if not OFFSET_FILE.exists():
        # First start must not replay commands that may have been sitting in the
        # bot queue for days. Telegram's negative offset returns only the newest
        # update and forgets the older backlog; that newest item is discarded too.
        try:
            pending = api(token, "getUpdates", {"offset": -1, "timeout": 0})
            offset = max((int(item.get("update_id", 0))
                          for item in pending.get("result", [])), default=0)
            save_offset(offset)
        except Exception as error:
            # Keep the singleton alive and let the normal retry loop recover.
            # The first successful request still uses offset=-1 below, so stale
            # commands are never replayed after a transient startup failure.
            log(f"initial offset error: {error}")
            retry_delay = 2
            while not OFFSET_FILE.exists():
                time.sleep(retry_delay)
                retry_delay = min(retry_delay * 2, 30)
                try:
                    pending = api(token, "getUpdates", {"offset": -1, "timeout": 0})
                    offset = max((int(item.get("update_id", 0))
                                  for item in pending.get("result", [])), default=0)
                    save_offset(offset)
                except Exception as retry_error:
                    log(f"initial offset retry: {retry_error}")
    log("gateway started")
    retry_delay = 2
    while True:
        try:
            result = api(token, "getUpdates", {
                "offset": offset + 1,
                "timeout": 50,
                "allowed_updates": json.dumps(["message"]),
            })
            latest = read_conf()
            if latest.get("NOTIFY_TG_REPLY", "0") != "1":
                log("gateway stopped: NOTIFY_TG_REPLY disabled")
                return 0
            if (latest.get("NOTIFY_TG_BOT_TOKEN", "") != token
                    or latest.get("NOTIFY_TG_CHAT_ID", "") != chat_id):
                log("gateway stopped: Telegram token/chat changed; start a new session to restart")
                return 0
            allowed = latest.get("NOTIFY_TG_REPLY_ALLOW_FROM", "")
            if not allowed:
                log("gateway stopped: allowlist removed")
                return 0
            updates = result.get("result", [])
            retry_delay = 2
            route_map = routes() if updates else {}
            for update in updates:
                update_id = int(update.get("update_id", 0))
                offset = max(offset, update_id)
                # Persist before any terminal side effect. If an acknowledgement
                # request fails after injection, a restart must not submit the
                # same user prompt twice. At-most-once delivery is safer here.
                save_offset(offset)
                message = update.get("message") or {}
                chat = message.get("chat") or {}
                thread = str(message.get("message_thread_id", ""))
                text = str(message.get("text", "")).strip()
                sender = str((message.get("from") or {}).get("id", ""))
                if str(chat.get("id", "")) != chat_id or not thread or not text:
                    continue
                route = route_map.get(thread)
                if not route:
                    # A forum may host several bots. An unknown topic belongs to
                    # another integration (or an expired local session), so it is
                    # not an error and must not produce cross-bot noise.
                    log(f"ignored unknown thread={thread} sender={sender}")
                    continue
                if not allowed_sender(sender, allowed):
                    log(f"ignored unauthorized sender={sender} thread={thread}")
                    send_text(token, chat_id, thread, "⛔ 此 Telegram 用户未被授权控制 Claude。")
                    continue
                backend = inject(route, text)
                if backend:
                    log(f"injected update={update_id} session={route.get('session', '')} "
                        f"thread={thread} backend={backend}")
                    send_text(token, chat_id, thread, f"✅ 已发送到 Claude（{backend}）")
                else:
                    log(f"inject failed update={update_id} session={route.get('session', '')} "
                        f"thread={thread}")
                    send_text(token, chat_id, thread,
                              "⚠️ 找不到原 Claude 终端。请确认会话仍在运行，且使用 tmux 或 iTerm2。")
        except Exception as error:  # keep the gateway alive across network failures
            log(f"poll error: {error}")
            time.sleep(retry_delay)
            retry_delay = min(retry_delay * 2, 30)


if __name__ == "__main__":
    raise SystemExit(check() if "--check" in sys.argv[1:] else main())
