# One commit identity for the Repeato repositories

Vercel's Hobby plan refuses a Git-triggered deploy whose commit author is not the account that owns the project (`repeato.in@gmail.com`, GitHub user `repeatoin-3651`). Commits and merges made as `ritesh405` / `ritesh@email.com` were blocked. Two things changed:

1. The deploy scripts upload a clean export without `.git` and `vercel.json` turns Git-triggered deploys off, so deploys no longer depend on who wrote the commit.
2. For a clean history and for anything else that reads the author, use one identity for every Repeato repository, set once by folder.

Today: `repeato.console` and `repeato.vendor.app` use `repeato.in@gmail.com` (set in each repository); `repeato.backend`, `repeato.mobile.client` and `repeato.infra` use the global `ritesh@email.com`.

## Set it once by folder (Windows)

Create `C:\Users\<you>\.gitconfig-repeato`:

```ini
[user]
    name = Repeato
    email = repeato.in@gmail.com
```

Add to your global `C:\Users\<you>\.gitconfig` (the trailing slash matters; `gitdir/i` ignores case on Windows):

```ini
[includeIf "gitdir/i:C:/Ritesh/workspace/repeato_workspace/"]
    path = ~/.gitconfig-repeato
```

Every repository and worktree under `repeato_workspace` then commits as that identity; everything else keeps your own. Remove the per-repository `user.email` of console and vendor app so there is one source: `git -C repeato.console config --unset user.email` (same for `repeato.vendor.app`, and `user.name` if set).

Check: `git -C repeato.backend config user.email` shows `repeato.in@gmail.com`, and `git -C C:\some\other\repo config user.email` shows your own.

## Merges on GitHub

A merge button press records the GitHub account that pressed it. Merge pull requests while signed in as `repeatoin-3651`, or use "Squash and merge" / "Rebase and merge" with the commit email set to `repeato.in@gmail.com` (GitHub → Settings → Emails → that address verified on the account that merges). Since deploys no longer come from Vercel's Git integration, this matters only for the history.

## Signing (optional)

If you later turn on "Require signed commits" for `main`, add an SSH signing key to the `repeatoin-3651` account and `gpg.format = ssh`, `user.signingkey = ~/.ssh/<key>.pub`, `commit.gpgsign = true` in `.gitconfig-repeato`.
