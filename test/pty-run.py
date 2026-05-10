#!/usr/bin/env python3
"""
PTY harness for testing TTY-gated install paths.

Used by test-install-integration.sh to exercise install branches that only
run when stdin is a real terminal (the v1.5.0 install plan + prompt UX).

Usage:
  pty-run.py [--input STRING] [--timeout N] [--input-delay N] -- CMD [ARGS...]

`--input` accepts \\n, \\t escape sequences. The harness:
  1. Allocates a pseudo-terminal pair.
  2. Spawns CMD with the slave fd as stdin/stdout/stderr.
  3. After --input-delay seconds (default 0.3), writes --input to master fd.
  4. Reads output from master fd until child exits or --timeout fires.
  5. Prints captured output verbatim and exits with the child's exit code.

The child sees a real terminal: `[ -t 0 ]` true, `/dev/tty` readable, etc.
"""
import argparse
import os
import pty
import select
import subprocess
import sys
import time


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--input', default='',
                   help='Input to feed (supports \\n, \\t escapes)')
    p.add_argument('--timeout', type=float, default=30.0,
                   help='Hard timeout in seconds (default 30)')
    p.add_argument('--input-delay', type=float, default=0.3,
                   help='Seconds to wait before sending input (default 0.3)')
    p.add_argument('rest', nargs=argparse.REMAINDER)
    args = p.parse_args()

    if args.rest and args.rest[0] == '--':
        args.rest = args.rest[1:]
    if not args.rest:
        sys.stderr.write("ERROR: no command provided after `--`\n")
        sys.exit(2)

    feed = args.input.encode('utf-8').decode('unicode_escape').encode('utf-8')

    master_fd, slave_fd = pty.openpty()
    try:
        proc = subprocess.Popen(
            args.rest,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            close_fds=True,
            preexec_fn=os.setsid,
        )
    finally:
        os.close(slave_fd)

    sent = (len(feed) == 0)
    deadline = time.time() + args.timeout
    send_at = time.time() + args.input_delay
    output_chunks = []

    try:
        while True:
            now = time.time()
            if now >= deadline:
                try:
                    proc.kill()
                except ProcessLookupError:
                    pass
                sys.stderr.write(
                    f"\nERROR: pty-run timeout after {args.timeout}s\n"
                )
                break

            if not sent and now >= send_at:
                try:
                    os.write(master_fd, feed)
                except OSError:
                    pass
                sent = True

            r, _, _ = select.select([master_fd], [], [], 0.1)
            if master_fd in r:
                try:
                    data = os.read(master_fd, 4096)
                except OSError:
                    data = b''
                if not data:
                    break
                output_chunks.append(data)
            elif proc.poll() is not None:
                # Child exited — drain any remaining output before exit.
                drain_deadline = time.time() + 0.2
                while time.time() < drain_deadline:
                    r2, _, _ = select.select([master_fd], [], [], 0.05)
                    if master_fd not in r2:
                        break
                    try:
                        data = os.read(master_fd, 4096)
                    except OSError:
                        data = b''
                    if not data:
                        break
                    output_chunks.append(data)
                break
    finally:
        try:
            os.close(master_fd)
        except OSError:
            pass

    output = b''.join(output_chunks)
    sys.stdout.buffer.write(output)
    sys.stdout.buffer.flush()
    sys.exit(proc.wait() & 0xFF)


if __name__ == '__main__':
    main()
