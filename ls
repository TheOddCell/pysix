#!/usr/bin/env python3
import os, sys, pwd, grp, stat, time

args = sys.argv[1:]
show_all = False
dir_only = False
classify = False
inode = False
long = False
append_slash = False
quote_nonprint = False
reverse_sort = False
recursive = False
block_size = False     # POSIX -s
sort_time = False
use_atime = False
one_per_line = False

paths = []

for a in args:
    if a.startswith("-"):
        for c in a[1:]:
            if c == "a": show_all = True
            elif c == "d": dir_only = True
            elif c == "F": classify = True
            elif c == "i": inode = True
            elif c == "l": long = True
            elif c == "p": append_slash = True
            elif c == "q": quote_nonprint = True
            elif c == "r": reverse_sort = True
            elif c == "R": recursive = True
            elif c == "s": block_size = True
            elif c == "t": sort_time = True
            elif c == "u": use_atime = True
            elif c == "1": one_per_line = True
            else:
                print(f"ls: invalid option -- '{c}'", file=sys.stderr)
                sys.exit(1)
    else:
        paths.append(a)

if not paths:
    paths = ["."]
    
def fmt_nonprint(name):
    if not quote_nonprint:
        return name
    return ''.join(c if 32 <= ord(c) < 127 else "?" for c in name)

def fmt_mode(m):
    perms = ["-"] * 10
    if stat.S_ISDIR(m): perms[0] = "d"
    elif stat.S_ISLNK(m): perms[0] = "l"
    elif stat.S_ISCHR(m): perms[0] = "c"
    elif stat.S_ISBLK(m): perms[0] = "b"
    elif stat.S_ISFIFO(m): perms[0] = "p"
    elif stat.S_ISSOCK(m): perms[0] = "s"
    else: perms[0] = "-"
    
    bits = [(stat.S_IRUSR, "r"), (stat.S_IWUSR, "w"), (stat.S_IXUSR, "x"),
            (stat.S_IRGRP, "r"), (stat.S_IWGRP, "w"), (stat.S_IXGRP, "x"),
            (stat.S_IROTH, "r"), (stat.S_IWOTH, "w"), (stat.S_IXOTH, "x")]
    
    for i, (bit, char) in enumerate(bits):
        if m & bit: perms[i+1] = char

    return "".join(perms)

def list_dir(path, header=True):
    try:
        st = os.lstat(path)
    except Exception as e:
        print(f"ls: cannot access '{path}': {e}", file=sys.stderr)
        return

    if dir_only or not stat.S_ISDIR(st.st_mode):
        print_entry(path, os.path.basename(path))
        return

    try:
        entries = os.listdir(path)
    except Exception as e:
        print(f"ls: cannot open directory '{path}': {e}", file=sys.stderr)
        return

    if not show_all:
        entries = [e for e in entries if not e.startswith(".")]

    # Sorting
    if sort_time:
        def key(e):
            try:
                st = os.lstat(os.path.join(path, e))
                t = st.st_atime if use_atime else st.st_mtime
                return t
            except:
                return 0
        entries.sort(key=key, reverse=not reverse_sort)
    else:
        entries.sort(reverse=reverse_sort)

    if header:
        print(f"{path}:")

    for e in entries:
        print_entry(os.path.join(path, e), e)

    if recursive:
        for e in entries:
            full = os.path.join(path, e)
            try:
                if stat.S_ISDIR(os.lstat(full).st_mode) and e not in (".", ".."):
                    print()
                    list_dir(full)
            except:
                pass

def print_entry(full, name):
    try:
        st = os.lstat(full)
    except:
        print(f"ls: cannot access '{name}'", file=sys.stderr)
        return

    shown = fmt_nonprint(name)

    # append classifications
    if classify:
        if stat.S_ISDIR(st.st_mode): shown += "/"
        elif stat.S_ISLNK(st.st_mode): shown += "@"
        elif stat.S_ISFIFO(st.st_mode): shown += "|"
        elif stat.S_ISSOCK(st.st_mode): shown += "="
        elif st.st_mode & stat.S_IXUSR: shown += "*"
    elif append_slash:
        if stat.S_ISDIR(st.st_mode):
            shown += "/"

    parts = []

    if inode:
        parts.append(str(st.st_ino))

    if block_size:
        # st_blocks is already 512-byte units → POSIX block size
        parts.append(str(st.st_blocks))

    if long:
        m = fmt_mode(st.st_mode)
        nlink = st.st_nlink
        user = pwd.getpwuid(st.st_uid).pw_name
        group = grp.getgrgid(st.st_gid).gr_name
        size = st.st_size
        t = st.st_atime if use_atime else st.st_mtime
        ts = time.strftime("%b %d %H:%M", time.localtime(t))
        parts += [m, str(nlink), user, group, str(size), ts, shown]
    else:
        parts.append(shown)

    print(" ".join(parts))

# MAIN
multiple = len(paths) > 1
for p in paths:
    list_dir(p, header=multiple)
    if multiple:
        print()
