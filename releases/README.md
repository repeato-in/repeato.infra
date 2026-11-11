# Release records

`release/release.ps1` writes one record here per run: `vYYYY.MM.DD-N.md` for a production release or rollback, `staging-YYYY-MM-DD-HHMMSS.md` for a staging deploy. Each lists, per app, the ref, the full commit, the tag, the result and how long it took, the commit messages, what ran, and for production the previous release and the rollback command.

Commit the record after the run (the script prints the command). The full logs stay in `releases/logs/` on the machine that ran the release and are not committed.

The tags `deployed/staging` and `deployed/prod` in each app repository always point at what runs there now; a production release takes `deployed/staging` unless `-Refs` names other commits.
