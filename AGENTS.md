# AGENTS.md

## Conventions

- Manifest vocabulary is strictly native package-vc (`:url`, `:branch`,
  `:lisp-dir`, `:main-file`, `:doc`, `:make`, `:shell-command`,
  `:vc-backend`, bare-string specs). Never add `:rev`/`:newest`/`:latest`
  to manifests or docs — package-vc silently ignores unknown keys.
- Emacs 29.1+ compatibility: no `package-get-descriptor` with `dir`/`kind`
  args; use `package-vc-sync--installed-vc-desc`.
- Tests never touch the network. The VC path uses real local git repos; the
  archive path is tested by stubbing `package-refresh-contents`,
  `package-install` and `package-upgrade-all` — there is no archive fixture,
  no tar, and no `archive-contents` on disk.

## Verify before claiming done

    emacs -Q --batch -L . -l test/package-vc-sync-test.el -f ert-run-tests-batch-and-exit
    emacs -Q --batch -L . -f batch-byte-compile package-vc-sync.el && rm -f package-vc-sync.elc
    emacs -Q --batch -L . --eval "(progn (package-initialize) (require 'package-lint))" -f package-lint-batch-and-exit package-vc-sync.el
