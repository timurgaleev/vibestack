#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["telethon>=1.36", "qrcode>=7"]
# ///
"""Read and send Telegram messages as your own account (MTProto, via Telethon).

The session file in ~/.config/tg/ is a full-account credential: never commit
it, and revoke it from Telegram -> Settings -> Devices when done.

  tg.py setup --api-id ID                      # api_hash is prompted, hidden
  tg.py login --qr                             # scan from the phone (preferred)
  tg.py login --phone +49... / --code 12345    # or the code route
  tg.py status                                 # logged in? as whom?
  tg.py chats "Alice"                          # resolve a name before sending
  tg.py read "Alice" -n 20
  tg.py voice "Alice" -n 1 [--language ru]      # download + whisper
  tg.py send "Alice" --text "..." --file a.pdf [--dry-run]

A chat is a dialog name (exact match required for `send`), an @username, or a
numeric id from `chats`.
"""
import argparse
import asyncio
import getpass
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

from telethon import TelegramClient
from telethon.errors import (
    FloodWaitError,
    PasswordHashInvalidError,
    PhoneCodeExpiredError,
    PhoneCodeInvalidError,
    RPCError,
    SessionPasswordNeededError,
)
from telethon.tl.functions.account import GetPasswordRequest
from telethon.tl.functions.auth import ResendCodeRequest

HOME = Path(os.environ.get("TG_HOME", Path.home() / ".config" / "tg"))
CONFIG = HOME / "config.json"
SESSION = HOME / "account"  # telethon appends .session
PENDING = HOME / "pending-login.json"
QR_ROUNDS = 10


def private_home() -> None:
    HOME.mkdir(parents=True, exist_ok=True)
    HOME.chmod(0o700)


def private_write(path: Path, data: dict) -> None:
    private_home()
    path.write_text(json.dumps(data))
    path.chmod(0o600)


def client() -> TelegramClient:
    if not CONFIG.exists():
        sys.exit("not set up: run `tg.py setup --api-id ...` first")
    cfg = json.loads(CONFIG.read_text())
    private_home()
    return TelegramClient(str(SESSION), int(cfg["api_id"]), cfg["api_hash"])


async def connected() -> TelegramClient:
    """Connect without ever falling into Telethon's interactive start() prompts."""
    c = client()
    await c.connect()
    if not await c.is_user_authorized():
        await c.disconnect()
        sys.exit("not logged in: the user runs `tg.py login --qr` in their own terminal")
    return c


def one_line(text: str) -> str:
    # A newline inside a message would let its author forge a line of the transcript.
    return (text or "").replace("\r", "").replace("\n", " ⏎ ")


def describe(entity) -> str:
    name = getattr(entity, "title", None) or " ".join(
        p for p in (getattr(entity, "first_name", None), getattr(entity, "last_name", None)) if p
    )
    kind = type(entity).__name__.lower()
    user = f" @{entity.username}" if getattr(entity, "username", None) else ""
    return f"{one_line(name) or '?'}{user} [{kind} {entity.id}]"


async def find_peer(c: TelegramClient, chat: str, exact_only: bool = False):
    chat = chat.strip()
    if not chat:
        sys.exit("empty chat name")
    if chat.startswith("@") or chat.lstrip("-").isdigit():
        try:
            return await c.get_entity(int(chat) if chat.lstrip("-").isdigit() else chat)
        except (ValueError, RPCError) as e:
            sys.exit(f"no chat {chat}: {e}")
    needle = chat.casefold()
    dialogs = [d for d in await c.get_dialogs() if d.name]
    exact = [d for d in dialogs if d.name.casefold() == needle]
    hits = exact or ([] if exact_only else [d for d in dialogs if needle in d.name.casefold()])
    if len(hits) != 1:
        found = "; ".join(describe(d.entity) for d in hits[:10]) or "nothing"
        rule = "exactly (send needs an exact name, @username or id)" if exact_only else "exactly one chat"
        sys.exit(f"'{chat}' must match {rule}; matched: {found}")
    return hits[0].entity


async def sign_in_2fa(c: TelegramClient) -> None:
    if os.environ.get("TG_PASSWORD"):
        await c.sign_in(password=os.environ["TG_PASSWORD"])
        return
    if not sys.stdin.isatty():
        sys.exit("2FA password needed: run this login in your own terminal")
    hint = (await c(GetPasswordRequest())).hint
    for attempt in range(3):
        try:
            await c.sign_in(password=getpass.getpass(f"2FA cloud password (hint: {hint or '-'}): "))
            return
        except PasswordHashInvalidError:
            print("wrong password" + ("; try again" if attempt < 2 else ""))
    sys.exit("giving up after 3 attempts")


async def login_qr(c: TelegramClient) -> None:
    import qrcode

    qr = await c.qr_login()
    for _ in range(QR_ROUNDS):
        q = qrcode.QRCode(border=1)
        q.add_data(qr.url)
        q.print_ascii(invert=True)
        print("scan within 30 s: Telegram app -> Settings -> Devices -> Link Desktop Device")
        try:
            await qr.wait(30)
            return
        except asyncio.TimeoutError:
            await qr.recreate()
        except SessionPasswordNeededError:
            await sign_in_2fa(c)
            return
    sys.exit(f"no scan after {QR_ROUNDS} codes; run it again when the phone is at hand")


async def cmd_login(a) -> None:
    c = client()
    await c.connect()
    try:
        if await c.is_user_authorized():
            print("already logged in as", describe(await c.get_me()))
            return
        if a.qr:
            await login_qr(c)
        elif a.phone:
            sent = await c.send_code_request(a.phone)
            private_write(PENDING, {"phone": a.phone, "hash": sent.phone_code_hash})
            # Usually lands as an in-app message from "Telegram", not as SMS.
            print(f"code sent via {type(sent.type).__name__}; now run: tg.py login --code <code>")
            return
        else:
            if not PENDING.exists():
                sys.exit("no pending login: use `tg.py login --qr` (or --phone first)")
            p = json.loads(PENDING.read_text())
            if a.resend:
                # Falls back to the next delivery channel (SMS / call) Telegram offers.
                sent = await c(ResendCodeRequest(p["phone"], p["hash"]))
                private_write(PENDING, {"phone": p["phone"], "hash": sent.phone_code_hash})
                print(f"code re-sent via {type(sent.type).__name__}; now run: tg.py login --code <code>")
                return
            try:
                await c.sign_in(p["phone"], a.code, phone_code_hash=p["hash"])
            except SessionPasswordNeededError:
                await sign_in_2fa(c)
            except (PhoneCodeInvalidError, PhoneCodeExpiredError) as e:
                sys.exit(f"{type(e).__name__}: request a new one with --phone, or use --qr")
        PENDING.unlink(missing_ok=True)
        print("logged in as", describe(await c.get_me()))
    finally:
        await c.disconnect()


async def cmd_status(a) -> None:
    c = await connected()
    try:
        print("logged in as", describe(await c.get_me()))
    finally:
        await c.disconnect()


async def cmd_chats(a) -> None:
    c = await connected()
    try:
        needle = a.query.casefold()
        for d in await c.get_dialogs(limit=a.n):
            if d.name and needle in d.name.casefold():
                print(describe(d.entity))
    finally:
        await c.disconnect()


async def cmd_read(a) -> None:
    c = await connected()
    try:
        peer = await find_peer(c, a.chat)
        msgs = [m async for m in c.iter_messages(peer, limit=a.n)]
        for m in reversed(msgs):
            who = "me" if m.out else describe(m.sender) if m.sender else "?"
            kind = "[voice] " if m.voice else f"[file: {one_line(m.file.name or '')}] " if m.file else ""
            print(f"{m.date:%Y-%m-%d %H:%M}Z {who}: {kind}{one_line(m.message)}")
    finally:
        await c.disconnect()


async def cmd_voice(a) -> None:
    if not (shutil.which("whisper") and shutil.which("ffmpeg")):
        sys.exit("voice needs whisper and ffmpeg on PATH (brew install openai-whisper ffmpeg)")
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    c = await connected()
    try:
        peer = await find_peer(c, a.chat)
        voices = [m async for m in c.iter_messages(peer, limit=a.scan) if m.voice][: a.n]
        if not voices:
            sys.exit(f"no voice notes in the last {a.scan} messages (raise --scan)")
        for m in reversed(voices):
            path = await m.download_media(file=out / f"voice-{m.date:%Y%m%d-%H%M%S}-{m.id}.ogg")
            print(f"# {m.date:%Y-%m-%d %H:%M}Z ({'me' if m.out else 'them'}, {m.file.duration or '?'}s)")
            cmd = ["whisper", path, "--model", a.model, "--output_format", "txt",
                   "--output_dir", str(out), "--verbose", "False"]
            if a.language:
                cmd += ["--language", a.language]
            r = subprocess.run(cmd, capture_output=True, text=True)
            if r.returncode:
                sys.exit(f"whisper failed on {path}:\n{r.stderr.strip()[-2000:]}")
            print(Path(path).with_suffix(".txt").read_text().strip(), "\n")
    finally:
        await c.disconnect()


async def cmd_send(a) -> None:
    files = [Path(f).expanduser() for f in a.file]
    missing = [str(f) for f in files if not f.is_file()]
    if missing:
        sys.exit("no such file: " + ", ".join(missing))
    if not files and not a.text:
        sys.exit("nothing to send: pass --text and/or --file")
    c = await connected()
    try:
        peer = await find_peer(c, a.chat, exact_only=True)
        what = ", ".join(["text"] * bool(a.text) + [f.name for f in files])
        if a.dry_run:
            print(f"would send to {describe(peer)}: {what}")
            return
        if len(files) == 1:
            await c.send_file(peer, str(files[0]), caption=a.text or "", force_document=True)
        elif files:
            # One album: the text rides as the caption of the last file, so a
            # failed upload cannot leave the text delivered on its own.
            captions = [""] * (len(files) - 1) + [a.text or ""]
            await c.send_file(peer, [str(f) for f in files], caption=captions, force_document=True)
        else:
            await c.send_message(peer, a.text)
        print(f"sent to {describe(peer)}: {what}")
    finally:
        await c.disconnect()


def main() -> None:
    os.umask(0o077)  # session, journal, config, downloads: owner-only from creation
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("setup")
    s.add_argument("--api-id", required=True, type=int)
    s.add_argument("--api-hash", help="prompted hidden when omitted")
    s = sub.add_parser("login")
    g = s.add_mutually_exclusive_group(required=True)
    g.add_argument("--qr", action="store_true")
    g.add_argument("--phone")
    g.add_argument("--code")
    g.add_argument("--resend", action="store_true")
    sub.add_parser("status")
    s = sub.add_parser("chats")
    s.add_argument("query", nargs="?", default="")
    s.add_argument("-n", type=int, default=200, help="dialogs to scan")
    s = sub.add_parser("read")
    s.add_argument("chat")
    s.add_argument("-n", type=int, default=20)
    s = sub.add_parser("voice")
    s.add_argument("chat")
    s.add_argument("-n", type=int, default=1)
    s.add_argument("--scan", type=int, default=1000, help="messages to search for voice notes")
    s.add_argument("--language")
    s.add_argument("--model", default="large-v3-turbo")
    s.add_argument("--out", default=str(HOME / "voice"))
    s = sub.add_parser("send")
    s.add_argument("chat")
    s.add_argument("--text")
    s.add_argument("--file", action="append", default=[])
    s.add_argument("--dry-run", action="store_true", help="resolve the recipient, send nothing")
    a = ap.parse_args()

    if getattr(a, "n", 1) < 1 or getattr(a, "scan", 1) < 1:
        ap.error("counts must be at least 1")

    if a.cmd == "setup":
        api_hash = a.api_hash or getpass.getpass("api_hash: ")
        if not api_hash.strip():
            sys.exit("empty api_hash")
        private_write(CONFIG, {"api_id": a.api_id, "api_hash": api_hash.strip()})
        print(f"saved to {CONFIG}")
        return
    cmds = {"login": cmd_login, "status": cmd_status, "chats": cmd_chats,
            "read": cmd_read, "voice": cmd_voice, "send": cmd_send}
    try:
        asyncio.run(cmds[a.cmd](a))
    except FloodWaitError as e:
        sys.exit(f"Telegram rate limit: wait {e.seconds} s")
    except RPCError as e:
        sys.exit(f"Telegram refused: {type(e).__name__}: {e}")
    except (ConnectionError, OSError) as e:
        sys.exit(f"{type(e).__name__}: {e}")


if __name__ == "__main__":
    main()
