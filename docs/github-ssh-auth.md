# Authenticating to GitHub over SSH

SSH key authentication replaces personal access tokens for `git` operations.
A PAT expires and has to be regenerated; an SSH key is configured once and
reused. After setup, `git push` / `git pull` / `git clone` authenticate
automatically with no token prompts.

These steps are macOS-flavored (Keychain integration); the key generation and
GitHub steps are the same on any OS.

## 1. Check for an existing key

```sh
ls -la ~/.ssh
```

Look for a keypair such as `id_ed25519` + `id_ed25519.pub` (the `.pub` is the
public half; the file without an extension is the private key — never share it).

Test whether a key is already trusted by GitHub:

```sh
ssh -T git@github.com
```

If it prints `Hi <username>! You've successfully authenticated`, the key is
already registered — skip to step 6.

## 2. Generate a key (only if you don't have one)

```sh
ssh-keygen -t ed25519 -C "your_email@example.com"
```

- Accept the default path (`~/.ssh/id_ed25519`).
- Setting a passphrase is recommended — the macOS Keychain can remember it so
  you enter it only once.

## 3. Load the key into the ssh-agent (macOS)

Add this to `~/.ssh/config` so the agent and Keychain pick the key up
automatically on every session:

```
Host *
  AddKeysToAgent yes
  UseKeychain yes
  IdentityFile ~/.ssh/id_ed25519
```

Then add the key to the agent and store its passphrase in the Keychain:

```sh
ssh-add --apple-use-keychain ~/.ssh/id_ed25519
```

Confirm it's loaded:

```sh
ssh-add -l
```

## 4. Register the public key with GitHub

Copy the **public** key — the `.pub` file, never the private one:

```sh
pbcopy < ~/.ssh/id_ed25519.pub
```

Then add it using either method:

**Web UI:** GitHub → Settings → SSH and GPG keys → *New SSH key* → paste →
*Add SSH key*.

**`gh` CLI:**

```sh
gh auth login                                        # if not already logged in
gh ssh-key add ~/.ssh/id_ed25519.pub --title "my-laptop"
```

## 5. Test the connection

```sh
ssh -T git@github.com
```

Expected:

```
Hi <username>! You've successfully authenticated, but GitHub does not
provide shell access.
```

The "does not provide shell access" line is normal — GitHub never grants a
shell; the `Hi <username>` part is what confirms success.

## 6. Point a repository at the SSH remote

**New clone:**

```sh
git clone git@github.com:<owner>/<repo>.git
```

**Existing repo currently using HTTPS:**

```sh
git remote -v                                              # check current URL
git remote set-url origin git@github.com:<owner>/<repo>.git
git remote -v                                              # confirm it shows git@github.com
```

Verify push/pull authentication without changing anything:

```sh
git ls-remote --heads origin
```

A list of remote refs means SSH auth to the repo works.

## Troubleshooting

- **`Permission denied (publickey)`** — the key isn't loaded in the agent or
  isn't registered on GitHub. Check `ssh-add -l`, then redo steps 3 and 4.
- **See which key is offered** — `ssh -vT git@github.com` and look for the
  `Offering public key` and `Server accepts key` lines.
- **Authenticated as the wrong account** — `ssh -T git@github.com` prints the
  username it logged in as; if it's not yours, another key is matching first.
  Pin the key for GitHub with a dedicated `Host github.com` block using
  `IdentityFile` and `IdentitiesOnly yes`.
- **Never commit the private key.** Only the `.pub` file is ever shared. This
  repo's `.gitignore` already excludes `id_ed25519*`, `*.pem`, `*.key`, `*.pub`.

---

The `azure_hubspoke` remote is already configured for SSH — the steps above
apply when setting up a new machine or converting another repository.
