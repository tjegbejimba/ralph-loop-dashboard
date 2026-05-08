# Don't fall back to bare `bash` on PATH for native Windows mode

`resolveBashExe` (`extension/lib/platform-shim.mjs`) probes for a Git Bash
executable in three places: the `RALPH_BASH_EXE` env override, then the two
default Git-for-Windows install paths under `C:\Program Files\Git\`. If all
three miss, it returns `null` and callers (`startLoopWindows`,
`launchRun`) surface an error telling the user to install Git for Windows
or set `RALPH_BASH_EXE`.

We deliberately do **not** fall back to bare `bash` on `PATH` as a last
resort. On a Windows machine with WSL2 installed, `bash` on `PATH` is
typically `C:\Windows\System32\bash.exe` — the WSL launcher. WSL bash will
happily `exec ./.ralph/launch.sh`, but it runs inside WSL2's filesystem
view with a different `gh`, `git`, and Copilot CLI toolchain (different
binaries, different auth state). The user sees logs scrolling past
("looks fine!") while the loop fails in subtle ways: `gh: command not
found`, `git push` rejecting with the wrong credentials, or worse — the
loop partially succeeds and corrupts branch state. None of those failure
modes point at "wrong bash."

We considered three approaches: keep the PATH fallback, drop it, or keep
it with a denylist for `C:\Windows\System32\bash.exe`. We picked drop.
Slots 1–3 cover the vast majority of real installs; anyone with a custom
Git layout (chocolatey, scoop, portable Git) is sophisticated enough to
set `RALPH_BASH_EXE` once. A positive list ("known-good Git Bash paths")
fails closed; a denylist ("not WSL bash") is fragile and silently breaks
when Microsoft moves the launcher or a user installs WSL at a non-default
path.

This decision is gated to Windows only; POSIX paths never call
`resolveBashExe`.
