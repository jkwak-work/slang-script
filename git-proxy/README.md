# Native WSL Git proxy

This is a native Linux executable for WSL that delegates to Git for Windows. It
converts absolute WSL path arguments to Windows paths while leaving ordinary
arguments, drive-letter paths, and UNC paths unchanged.

## Build

Install the standard build tools if WSL does not already have them, then run:

```sh
sudo apt install build-essential
make
```

The result is `git-proxy`. Test it before replacing the existing script:

```sh
GIT_PROXY_TRACE=1 ./git-proxy status
./git-proxy --version
```

To use it as `git`, copy it to a directory that precedes other Git executables
on `PATH`, or replace the existing wrapper after keeping a backup.

## Behavior

- Uses `/mnt/c/Program Files/Git/cmd/git.exe` when executable, otherwise finds
  `git.exe` on `PATH`.
- Converts `/absolute/path` and dash-prefixed options such as
  `--option=/absolute/path` or `-option=/absolute/path` with `wslpath -w`.
- Passes Windows drive paths and UNC paths through unchanged.
- Keeps the original argument if `wslpath` is unavailable or conversion fails.
- Replaces itself with `git.exe`, preserving Git's exit code and signal behavior.
- Prints the final command to standard error when `GIT_PROXY_TRACE` is nonempty.

No shell is involved when launching `wslpath` or Git, so all argument text is
passed literally.
