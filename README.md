# package-vc-sync

Sync your Emacs packages from a declarative manifest. Built on Emacs's `package.el` and `package-vc`.

- Install missing packages (from MELPA/ELPA archives or git repos)
- Upgrade installed ones
- Detect when a git package's manifest spec changed (branch, pinned
  revision, URL) and reinstall it. package-vc does not do this on its own.

## Install

From MELPA:

    M-x package-install RET package-vc-sync RET

Or straight from git, before it reaches MELPA:

```elisp
(use-package package-vc-sync
  :vc (:url "https://github.com/brettatoms/package-vc-sync"))
```

Requires Emacs 29.1+.

## The no-blocking-at-startup pattern

package-vc-sync splits "what is installed" from "how it is configured":

1. Declare packages in a manifest. By default `packages.el` in your
   `user-emacs-directory` (`~/.emacs.d/packages.el`, or
   `~/.config/emacs/packages.el` under XDG):

   ```elisp
   (setq package-vc-sync-archives '(("melpa" . "https://melpa.org/packages/")
                                    ("gnu"   . "https://elpa.gnu.org/packages/")
                                    ("nongnu" . "https://elpa.nongnu.org/nongnu/")))
   (setq package-vc-sync-packages '(which-key magit))
   (setq package-vc-selected-packages
         '((my-fork :url "https://github.com/me/my-fork")   ; no pin = follow HEAD
           (other   :url "https://github.com/me/other"
                    :branch "develop")                      ; track a branch
           (stable  . "v1.2.3")))                           ; pin a tag/commit
   ```

   A local archive goes in as a plain directory path
   (`("local" . "/path/to/archive/")`), not a `file://` URL. package.el does
   not accept `file://` here.

2. Configure packages in your init with `use-package`, without `:ensure`,
   so nothing ever installs at startup:

   ```elisp
   (use-package which-key
     :config (which-key-mode 1))
   ```

3. Sync on demand, then restart Emacs:

       M-x package-vc-sync
       emacs -Q -nw -l package-vc-sync.el -f package-vc-sync-cli [-- /path/to/packages.el]

## Pin semantics

| Manifest spec | Meaning | Sync behavior |
|---|---|---|
| `(pkg :url "...")` | follow HEAD | upgrade (pull) |
| `(pkg :url "..." :branch "dev")` | track branch `dev` | upgrade (pull `dev`) |
| `(pkg . "rev")` | frozen at revision | skipped ("pinned") |
| `(pkg)` or `(pkg . nil)` | any version (archive metadata) | upgrade |

Manifest vocabulary is native package-vc: `:url`, `:branch`, `:lisp-dir`,
`:main-file`, `:doc`, `:make`, `:shell-command`, `:vc-backend`. There is no
`:rev` key. package-vc silently ignores unknown keys. (`:rev :newest` is
use-package `:vc` dialect; here "follow newest" is simply the default.)

## State file

`package-vc-sync-state.eld` (next to the manifest by default) records the
specs last applied. Commit it to your config repo to get identical pins on
every machine.

## FAQ

Does M-x package-vc-sync reload upgraded packages? No. Changed code loads
after a restart, the same caveat elpaca's manual states.

What if a git checkout is conflicted? The sync reports the failure. Resolve
the conflict by hand, or delete the checkout and re-sync.

Does it upgrade archive packages installed outside the manifest? Yes. Sync
runs `package-upgrade-all` for every installed archive package.

What about offline use? A failed archive refresh falls back to cached
metadata. With no metadata at all, the sync aborts with an error.

## License

GPL-3.0-or-later.
