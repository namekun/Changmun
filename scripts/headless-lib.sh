# Sourced by headless.sh and check-dmg.sh (and tested by test-scripts.sh): whether a process is Changmun Headless.app.
# A control.json that outlives a crash names a process ID that anything may have taken since.

# Succeeds when the command line (the program's path first) is that of the test copy.
is_headless_command() { [[ "$1" == *"Changmun Headless.app/Contents/MacOS/"* ]]; }

# Succeeds when process $1 is alive and is the test copy.
is_headless_pid() {
    local command
    command="$(ps -p "$1" -o command= 2>/dev/null)" || return 1
    is_headless_command "$command"
}
