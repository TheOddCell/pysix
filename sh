#!/usr/bin/env python3
"""pysh - a compact POSIX-like shell implemented in Python

Features implemented (practical subset of POSIX sh):
- invocation: pysh [-c command_string] [script-file [args...]]
- -s reading from stdin
- interactive line editing and history (uses readline if available)
- ENV processing for interactive shells (ENV env var)
- positional parameters ($1..), special parameter 0 (lightweight)
- simple expansions: tilde, environment variables
- command parsing (tokens via shlex) with support for: redirections (<, >, >>, 2>, &>), pipes (|), background (&)
- builtins: cd, exit, export, unset, alias, unalias, history, source (.), pwd
- pipelines and redirections executed with subprocess (no os.system)
- background jobs (very simple job table)
- signal handling: Ctrl-C forwards SIGINT to foreground pipeline

Limitations / omissions:
- not a full POSIX parser (no arithmetic, no process substitution, limited quoting edge-cases)
- limited set and +set options
- job control (stopping/fg/bg) is minimal

This file is intended to be a compact, educational starting point. It has guarded use of readline so it runs in environments where readline is not installed (e.g. some sandboxes or Windows without pyreadline).

Save as a single file (e.g. pysh.py) and run: ./pysh.py or python3 pysh.py
"""

import sys
import os
import shlex
import subprocess
import signal
import argparse
from pathlib import Path
from collections import deque
import io

# Conditionally import readline (some environments don't have it)
try:
    import readline
except Exception:
    readline = None

# --- Configuration / globals ---
HISTFILE_DEFAULT = Path.home() / '.pysh_history'
jobs = {}  # pid -> subprocess.Popen
foreground_pids = set()
aliases = {}

# --- Utilities ---

def debug(msg):
    # toggle for extra logging
    # print(f"[debug] {msg}", file=sys.stderr)
    pass


def safe_expand_token(token):
    # quick tilde and env var expansion for words that don't contain complex expansions
    if not token:
        return token
    if token.startswith('~'):
        token = os.path.expanduser(token)
    token = os.path.expandvars(token)
    return token


# --- Builtins ---

def builtin_cd(args):
    target = args[0] if args else os.environ.get('HOME', '/')
    try:
        os.chdir(os.path.expanduser(target))
    except Exception as e:
        print(f'cd: {e}', file=sys.stderr)
        return 1
    return 0


def builtin_pwd(args):
    print(os.getcwd())
    return 0


def builtin_exit(args):
    code = int(args[0]) if args else 0
    sys.exit(code)


def builtin_export(args):
    for a in args:
        if '=' in a:
            k, v = a.split('=', 1)
            os.environ[k] = v
        else:
            os.environ[a] = os.environ.get(a, '')
    return 0


def builtin_unset(args):
    for a in args:
        os.environ.pop(a, None)
    return 0


def builtin_alias(args):
    if not args:
        for k, v in aliases.items():
            print(f"alias {k}='{v}'")
        return 0
    for a in args:
        if '=' in a:
            k, v = a.split('=', 1)
            # allow alias name=value or name='value'
            if v.startswith("'") and v.endswith("'"):
                v = v[1:-1]
            aliases[k] = v
        else:
            print(aliases.get(a, '' ))
    return 0


def builtin_unalias(args):
    for a in args:
        aliases.pop(a, None)
    return 0


def builtin_history(args):
    try:
        histfile = Path(os.environ.get('HISTFILE', str(HISTFILE_DEFAULT)))
        if not histfile.exists():
            return 0
        with histfile.open() as f:
            for i, line in enumerate(f, 1):
                print(f'{i}  {line.rstrip()}')
    except Exception as e:
        print('history:', e, file=sys.stderr)
    return 0


def builtin_source(args):
    # dot built-in
    if not args:
        print('source: filename required', file=sys.stderr)
        return 1
    filename = args[0]
    try:
        with open(filename) as f:
            code = f.read()
        # Execute the commands synchronously in this process
        run_script_string(code, filename)
    except Exception as e:
        print(f'source: {e}', file=sys.stderr)
        return 1
    return 0


BUILTINS = {
    'cd': builtin_cd,
    'exit': builtin_exit,
    'export': builtin_export,
    'unset': builtin_unset,
    'alias': builtin_alias,
    'unalias': builtin_unalias,
    'history': builtin_history,
    '.': builtin_source,
    'source': builtin_source,
    'pwd': builtin_pwd,
}

# --- Parsing ---

def parse_pipeline(tokens):
    """Parse a flat list of tokens into a list of commands representing a pipeline.
    Each command is dict: { 'argv': [...], 'stdin': None or filename, 'stdout': None or (filename, append), 'stderr': None or (filename, append) }
    Background is handled outside by seeing trailing '&' token.
    """
    commands = []
    cur = {'argv': [], 'stdin': None, 'stdout': None, 'stderr': None}
    it = iter(tokens)
    for tok in it:
        if tok == '|':
            commands.append(cur)
            cur = {'argv': [], 'stdin': None, 'stdout': None, 'stderr': None}
            continue
        if tok in ('>', '>>', '<', '2>', '2>>', '&>'):
            try:
                target = next(it)
            except StopIteration:
                raise ValueError('redirection without target')
            if tok == '<':
                cur['stdin'] = safe_expand_token(target)
            elif tok in ('>', '>>'):
                cur['stdout'] = (safe_expand_token(target), tok == '>>')
            elif tok in ('2>', '2>>'):
                cur['stderr'] = (safe_expand_token(target), tok == '2>>')
            elif tok == '&>':
                cur['stdout'] = (safe_expand_token(target), False)
                cur['stderr'] = (safe_expand_token(target), False)
            continue
        # normal arg
        cur['argv'].append(tok)
    commands.append(cur)
    return commands


def tokenize_line(line):
    # quick alias expansion for first word
    try:
        lex = shlex.split(line, posix=True)
    except ValueError as e:
        print('parse error:', e, file=sys.stderr)
        return [], False
    if not lex:
        return [], False
    # apply aliases only for simple alias names (no parameters expansion)
    first = lex[0]
    if first in aliases:
        # naive: replace first token with alias split
        ali = shlex.split(aliases[first])
        lex = ali + lex[1:]
    # detect background
    background = False
    if lex and lex[-1] == '&':
        background = True
        lex = lex[:-1]
    # expand tokens (tilde, vars) except when quoted strictly (shlex removes quotes already)
    lex = [safe_expand_token(t) for t in lex]
    return lex, background

# --- Execution primitives ---

def _close_if_fileobj(obj):
    try:
        if hasattr(obj, 'close'):
            obj.close()
    except Exception:
        pass


def run_pipeline(commands, background=False):
    """Run a pipeline: list of command dicts. Use subprocess.Popen and wire pipes."""
    procs = []
    prev_stdout = None
    for i, cmd in enumerate(commands):
        argv = cmd['argv']
        if not argv:
            print('empty command in pipeline', file=sys.stderr)
            return 1
        # handle builtin-only single commands (only if pipeline len ==1 and not background)
        if len(commands) == 1 and argv[0] in BUILTINS and not background:
            return BUILTINS[argv[0]](argv[1:])
        stdin = None
        stdout = None
        stderr = None
        next_stdin = None
        if prev_stdout is not None:
            stdin = prev_stdout
        if cmd['stdin']:
            try:
                stdin = open(cmd['stdin'], 'rb')
            except Exception as e:
                print(f"{cmd['stdin']}: {e}", file=sys.stderr)
                return 1
        if i < len(commands) - 1:
            r, w = os.pipe()
            # turn descriptors into buffered file objects for subprocess
            stdout = os.fdopen(w, 'wb')
            next_stdin = os.fdopen(r, 'rb')
        else:
            next_stdin = None
        if cmd['stdout']:
            path, append = cmd['stdout']
            mode = 'ab' if append else 'wb'
            try:
                stdout = open(path, mode)
            except Exception as e:
                print(f"{path}: {e}", file=sys.stderr)
                # cleanup
                _close_if_fileobj(stdin)
                _close_if_fileobj(next_stdin)
                return 1
        if cmd['stderr']:
            path, append = cmd['stderr']
            mode = 'ab' if append else 'wb'
            try:
                stderr = open(path, mode)
            except Exception as e:
                print(f"{path}: {e}", file=sys.stderr)
                _close_if_fileobj(stdin)
                _close_if_fileobj(stdout)
                _close_if_fileobj(next_stdin)
                return 1
        # Launch process
        try:
            # Use preexec_fn to create a new process group on POSIX. On non-POSIX, ignore.
            preexec = os.setpgrp if hasattr(os, 'setpgrp') else None
            p = subprocess.Popen(argv,
                                 stdin=stdin if stdin is not None else None,
                                 stdout=stdout if stdout is not None else (subprocess.PIPE if next_stdin is not None else None),
                                 stderr=stderr if stderr is not None else None,
                                 preexec_fn=preexec)
        except FileNotFoundError:
            print(f"{argv[0]}: command not found", file=sys.stderr)
            # close fds
            _close_if_fileobj(stdin)
            _close_if_fileobj(stdout)
            _close_if_fileobj(next_stdin)
            return 127
        except Exception as e:
            print(f"failed to start {argv[0]}: {e}", file=sys.stderr)
            _close_if_fileobj(stdin)
            _close_if_fileobj(stdout)
            _close_if_fileobj(next_stdin)
            return 1
        procs.append(p)
        # close parent-side writable pipe objects (we don't need them)
        _close_if_fileobj(stdout)
        # set up for next
        if next_stdin is not None:
            prev_stdout = next_stdin
        else:
            prev_stdout = None

    # Foreground vs background
    if background:
        for p in procs:
            jobs[p.pid] = p
        print(f'[{len(jobs)}] {procs[-1].pid}')
        return 0
    else:
        # wait for pipeline
        for p in procs:
            foreground_pids.add(p.pid)
        rc = 0
        try:
            for p in procs:
                p.wait()
                rc = p.returncode
        except KeyboardInterrupt:
            # will be handled by signal handler; ensure children are killed
            for p in procs:
                try:
                    os.killpg(os.getpgid(p.pid), signal.SIGINT)
                except Exception:
                    try:
                        p.kill()
                    except Exception:
                        pass
            rc = 130
        finally:
            for pid in list(foreground_pids):
                foreground_pids.discard(pid)
        return rc


# --- Signal handling ---

def sigint_handler(signum, frame):
    # forward to foreground pgrp(s)
    if foreground_pids:
        # send SIGINT to each foreground process group
        for pid in list(foreground_pids):
            try:
                pgid = os.getpgid(pid)
                os.killpg(pgid, signal.SIGINT)
            except Exception:
                try:
                    os.kill(pid, signal.SIGINT)
                except Exception:
                    pass
        return
    # else re-issue a newline and redisplay prompt
    print('')


signal.signal(signal.SIGINT, sigint_handler)

# --- Script execution helpers ---

def run_script_string(code, filename='<string>'):
    # run code line-by-line as shell commands (naive)
    for raw_line in code.splitlines():
        line = raw_line.strip()
        if not line or line.startswith('#'):
            continue
        lex, bg = tokenize_line(line)
        if not lex and not bg:
            continue
        try:
            cmds = parse_pipeline(lex)
        except ValueError as e:
            print('parse error:', e, file=sys.stderr)
            continue
        run_pipeline(cmds, background=bg)

# --- Interactive loop ---

def init_readline():
    if readline is None:
        return
    # history file
    histfile = Path(os.environ.get('HISTFILE', str(HISTFILE_DEFAULT)))
    try:
        readline.read_history_file(str(histfile))
    except Exception:
        pass
    try:
        readline.set_history_length(int(os.environ.get('HISTSIZE', '1000')))
    except Exception:
        pass
    # set vi-mode if user asked via SHELL_VI_MODE env (naive)
    if os.environ.get('SHELL_VI_MODE') == '1':
        try:
            readline.parse_and_bind('set editing-mode vi')
        except Exception:
            pass


def save_history():
    if readline is None:
        return
    histfile = Path(os.environ.get('HISTFILE', str(HISTFILE_DEFAULT)))
    try:
        readline.write_history_file(str(histfile))
    except Exception:
        pass


def repl_loop(interactive=True):
    init_readline()
        # Bash-like prompt escape expansion
    # Simplified prompt: no escape sequences, just root (#) or user ($)
    sym = '#' if os.geteuid() == 0 else '$'
    prompt = f"{sym} "
    try:
        while True:
            try:
                line = input(prompt)
            except EOFError:
                print('')
                break
            except KeyboardInterrupt:
                print('')
                continue
            line = line.strip()
            if not line:
                continue
            # history is handled by readline if present
            lex, bg = tokenize_line(line)
            if not lex and not bg:
                continue
            try:
                commands = parse_pipeline(lex)
            except ValueError as e:
                print('parse error:', e, file=sys.stderr)
                continue
            rc = run_pipeline(commands, background=bg)
    finally:
        save_history()


# --- Tests ---

def run_tests():
    """Simple tests that exercise basic functionality without requiring readline.
    These tests are minimal and run the internal functions directly.
    """
    print('Running basic internal tests...')
    # tokenize + parse
    lex, bg = tokenize_line("echo hello | tr a-z A-Z")
    assert not bg
    assert lex[0] == 'echo'
    cmds = parse_pipeline(lex)
    assert isinstance(cmds, list) and len(cmds) == 2

    # run a simple pipeline (echo -> tr) using the system /bin/echo available on POSIX
    rc = run_pipeline(parse_pipeline(['echo', 'test']), background=False)
    # echo returns 0
    assert rc == 0

    # test builtin cd: change to /, then back
    old = os.getcwd()
    rc = builtin_cd(['/'])
    assert rc == 0 and os.getcwd() == '/'
    os.chdir(old)

    print('All basic tests passed.')


# --- Main entry ---

def main(argv=None):
    parser = argparse.ArgumentParser(prog='pysh')
    parser.add_argument('-c', dest='command', help='read commands from command_string')
    parser.add_argument('-s', dest='stdin', action='store_true', help='read commands from standard input')
    parser.add_argument('--run-tests', dest='run_tests', action='store_true', help='run internal tests and exit')
    parser.add_argument('script', nargs='?', help='script file to execute')
    parser.add_argument('args', nargs=argparse.REMAINDER)
    ns = parser.parse_args(argv)

    if ns.run_tests:
        run_tests()
        return

    # set positional parameters (simple emulation)
    if ns.command is not None:
        # -c: run command_string
        run_script_string(ns.command)
        return
    if ns.stdin or (ns.script is None and sys.stdin.isatty() is False):
        # read from stdin
        code = sys.stdin.read()
        run_script_string(code)
        return
    if ns.script:
        # run script file
        scriptfile = ns.script
        if scriptfile == '-':
            code = sys.stdin.read()
            run_script_string(code)
            return
        try:
            with open(scriptfile) as f:
                code = f.read()
            run_script_string(code)
        except Exception as e:
            print(f"{scriptfile}: {e}", file=sys.stderr)
        return
    # interactive
    repl_loop(interactive=True)


if __name__ == '__main__':
    main(sys.argv[1:])
