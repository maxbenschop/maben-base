# Security

Maben Base holds passwords for your databases and writes to them, so a bug that leaks a password, skips a certificate check the user asked for, or writes something the user didn't save is treated as a security problem. Please don't open a public issue for one. Report it privately on GitHub instead: [Report a vulnerability](https://github.com/maxbenschop/maben-base/security/advisories/new) (Security tab → Report a vulnerability). Only the maintainer sees it, and you'll get a reply within a few days.

Passwords are kept in the macOS Keychain, never in the app's files. The app makes no network connections except to the databases and SSH servers you configure, and to GitHub to look for a new version (which can be switched off in Settings).

Releases are signed with the Developer ID of team NJTYRVLSA8 and notarized by Apple. The app only installs an update that passes the same checks, so a release on GitHub alone can't put other code on anyone's Mac.
