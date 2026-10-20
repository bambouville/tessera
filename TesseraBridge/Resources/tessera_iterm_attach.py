#!/usr/bin/env python3
import asyncio
import os
import re
import shlex
import sys

import iterm2


ALLOWED_TMUX_PATHS = {
    os.path.realpath(path)
    for path in ("/opt/homebrew/bin/tmux", "/usr/local/bin/tmux")
}


def validated_arguments():
    if len(sys.argv) != 4:
        raise ValueError("expected tmux path, session ID, and receipt nonce")
    tmux_path = os.path.realpath(sys.argv[1])
    session_id = sys.argv[2]
    receipt_nonce = sys.argv[3]
    if tmux_path not in ALLOWED_TMUX_PATHS:
        raise ValueError("tmux path is not allowlisted")
    if not re.fullmatch(r"\$[0-9]+", session_id):
        raise ValueError("tmux session ID is invalid")
    if not re.fullmatch(
        r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
        receipt_nonce,
    ):
        raise ValueError("receipt nonce is invalid")
    return tmux_path, session_id, receipt_nonce


TMUX_PATH, SESSION_ID, RECEIPT_NONCE = validated_arguments()


async def main(connection):
    prior_connection_ids = {
        value.connection_id
        for value in await iterm2.async_get_tmux_connections(connection)
    }
    command = shlex.join(
        [TMUX_PATH, "-CC", "attach-session", "-t", SESSION_ID]
    )
    app = await iterm2.async_get_app(connection)
    window = await iterm2.Window.async_create(connection, command=command)
    if window is None:
        raise RuntimeError("iTerm2 did not create a tmux window")
    await app.async_activate()
    await window.async_activate()
    for _ in range(100):
        connections = await iterm2.async_get_tmux_connections(connection)
        for value in connections:
            if value.connection_id in prior_connection_ids:
                continue
            try:
                observed_id = await value.async_send_command(
                    "display-message -p '#{session_id}'"
                )
                if observed_id.strip() != SESSION_ID:
                    continue
                await value.async_send_command(
                    "set-option -t "
                    + SESSION_ID
                    + " @tessera_attach_receipt "
                    + RECEIPT_NONCE
                )
                return
            except Exception:
                continue
        await asyncio.sleep(0.1)
    raise RuntimeError("iTerm2 did not establish the requested tmux connection")


iterm2.run_until_complete(main)
