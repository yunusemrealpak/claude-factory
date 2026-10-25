# Factory: what differs on Windows, in one place. Sourced, never run.
#
# Under Git Bash, MSYS2 or Cygwin the jq on PATH is usually the native
# jq.exe, which writes CRLF line ends. Every `jq -r ... | while read` and every
# `grep -qxF` on its output then compares "name\r" with "name" and quietly
# finds nothing. `-b` (--binary) makes it write LF. The function is exported so
# the scripts these scripts start get it too. Nothing changes on macOS or Linux.
case "${OSTYPE:-}" in
  msys*|cygwin*|win32*)
    if command jq -b -n 1 >/dev/null 2>&1; then
      jq() { command jq -b "$@"; }
      export -f jq
    fi
    ;;
esac

# A path in the spelling git and the task files use: forward slashes.
factory_posix_path() {
  printf '%s' "$1" | tr '\\' '/'
}

# A path as a native program reads it: C:/x for /c/x or /tmp/x under Git Bash,
# where Python and git.exe know nothing of the MSYS mounts. Unchanged elsewhere.
factory_native_path() {
  case "${OSTYPE:-}" in
    msys*|cygwin*) command -v cygpath >/dev/null 2>&1 && { cygpath -m "$1" 2>/dev/null && return 0; } ;;
  esac
  printf '%s\n' "$1"
}
