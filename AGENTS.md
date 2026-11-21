# Agent instructions

## Git workflow

- Always work on `main`. Do not create feature, fix or other branches, even for large changes.
- Commit directly to `main` once the work is tested.
- Only push when the user asks for it.
- If a branch was created by mistake, fast-forward `main` to it and delete it before finishing.

## Testing before commit

- Unit tests (no container needed): `python3 -m unittest discover -s tests`
- Integration tests: build the image, start it on a loopback port, and run `bash tests/smoke.sh http://127.0.0.1:<port>` with `PUSH_PASSWORD` and `PULL_PASSWORD` set. Remove the container and any temporary data afterwards.
