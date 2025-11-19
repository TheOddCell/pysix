#!/usr/bin/env python3
import os
import sys
import shutil
import stat
import argparse

def copy_file(src, dst, follow_symlinks=True, preserve=False, force=False, interactive=False):
    # Interactive prompt (-i)
    if os.path.exists(dst):
        if interactive:
            resp = input(f"overwrite '{dst}'? [y/N]: ").strip().lower()
            if resp not in ("y", "yes"):
                return

        # Force remove target if needed (-f)
        if force:
            try:
                os.unlink(dst)
            except FileNotFoundError:
                pass

    # Copy actual file
    shutil.copy2(src, dst, follow_symlinks=follow_symlinks)

    # -p: preserve ownership + mode
    if preserve:
        st = os.stat(src, follow_symlinks=False)
        try:
            os.chown(dst, st.st_uid, st.st_gid, follow_symlinks=False)
        except PermissionError:
            pass  # can't chown as non-root — POSIX says this is allowed
        os.chmod(dst, stat.S_IMODE(st.st_mode))


def copy_tree(src, dst, follow_symlinks=True, preserve=False, force=False, interactive=False):
    # Exists?
    if os.path.isfile(dst):
        print(f"cp: cannot overwrite non-directory '{dst}' with directory '{src}'", file=sys.stderr)
        return

    # Create directory if needed
    if not os.path.exists(dst):
        os.makedirs(dst)

    for root, dirs, files in os.walk(src):
        rel = os.path.relpath(root, src)
        dest_dir = os.path.join(dst, rel) if rel != "." else dst

        if not os.path.exists(dest_dir):
            os.makedirs(dest_dir)

        # Copy files inside
        for f in files:
            s = os.path.join(root, f)
            d = os.path.join(dest_dir, f)
            copy_file(s, d, follow_symlinks=follow_symlinks, preserve=preserve,
                      force=force, interactive=interactive)

        # Create dirs inside (permission handling for -p)
        if preserve:
            st = os.stat(root)
            os.chmod(dest_dir, stat.S_IMODE(st.st_mode))


def main():
    p = argparse.ArgumentParser()
    p.add_argument("-R", action="store_true", help="copy directories recursively")
    p.add_argument("-f", action="store_true", help="force overwrite")
    p.add_argument("-i", action="store_true", help="interactive overwrite")
    p.add_argument("-p", action="store_true", help="preserve ownership/mode/times")
    p.add_argument("-P", action="store_true", help="never follow symlinks")
    p.add_argument("-L", action="store_true", help="follow all symlinks")
    p.add_argument("-H", action="store_true", help="follow symlinks at command line only")
    p.add_argument("paths", nargs="+")
    
    a = p.parse_args()

    if len(a.paths) < 2:
        print("cp: missing destination", file=sys.stderr)
        sys.exit(1)

    *sources, dest = a.paths

    # Symlink decision
    if a.P: follow = False
    elif a.L: follow = True
    else: follow = True  # default resembles -L

    # Single-file copy
    if len(sources) == 1 and not a.R:
        src = sources[0]
        if os.path.isdir(src) and not a.R:
            print(f"cp: '{src}' is a directory (use -R)", file=sys.stderr)
            sys.exit(1)
        copy_file(src, dest, follow_symlinks=follow, preserve=a.p,
                  force=a.f, interactive=a.i)
        return

    # Multi-source → dest must be a directory
    if not os.path.isdir(dest):
        print(f"cp: target '{dest}' is not a directory", file=sys.stderr)
        sys.exit(1)

    for src in sources:
        base = os.path.basename(src)
        new = os.path.join(dest, base)

        if os.path.isdir(src):
            if not a.R:
                print(f"cp: '{src}' is a directory (use -R)", file=sys.stderr)
                continue
            copy_tree(src, new, follow_symlinks=follow, preserve=a.p,
                      force=a.f, interactive=a.i)
        else:
            copy_file(src, new, follow_symlinks=follow, preserve=a.p,
                      force=a.f, interactive=a.i)


if __name__ == "__main__":
    main()
