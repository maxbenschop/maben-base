## What and why

<!-- What does this change, and why? Link the issue if there is one. -->

## How I tested it

<!-- e.g. swift test, ./build.sh demo, the server tests against Postgres 17 and MySQL 8.4. -->

## Checklist

- [ ] `swift test` passes
- [ ] If it touches a driver or the SQL that edits rows: the server tests ran against the engines it touches
- [ ] If people will notice the change: a line under the next version in `CHANGELOG.md`
- [ ] No version bump in `Info.plist` (the maintainer does that when releasing)
