;;; package-vc-sync-test.el --- Tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'package)
(require 'package-vc)
(require 'project)
(require 'package-vc-sync)

(ert-deftest package-vc-sync-manifest-file-default ()
  (let ((user-emacs-directory "/tmp/example-config/")
        (package-vc-sync-manifest-file nil))
    (should (equal (package-vc-sync--manifest-file)
                   "/tmp/example-config/packages.el"))))

(ert-deftest package-vc-sync-manifest-file-custom ()
  (let ((package-vc-sync-manifest-file "/somewhere/else/packages.el"))
    (should (equal (package-vc-sync--manifest-file)
                   "/somewhere/else/packages.el"))))

(ert-deftest package-vc-sync-state-file-default ()
  (let ((user-emacs-directory "/tmp/example-config/")
        (package-vc-sync-manifest-file nil)
        (package-vc-sync-state-file nil))
    (should (equal (package-vc-sync--state-file)
                   "/tmp/example-config/package-vc-sync-state.eld"))))

(ert-deftest package-vc-sync-state-file-custom ()
  (let ((package-vc-sync-state-file "/tmp/state.eld"))
    (should (equal (package-vc-sync--state-file) "/tmp/state.eld"))))

(ert-deftest package-vc-sync-load-manifest-missing ()
  (let ((package-vc-sync-manifest-file "/tmp/does-not-exist-pvc-sync.el"))
    ;; Match the message, not just the type: `void-function' is itself a
    ;; subtype of `error', so a bare (should-error ... :type 'error) would
    ;; pass against no implementation at all.
    (should (string-match-p
             "no manifest at"
             (error-message-string
              (should-error (package-vc-sync--load-manifest) :type 'error))))))

(ert-deftest package-vc-sync-load-manifest-syntax-error ()
  (let* ((dir (make-temp-file "pvc-sync-test-" t))
         (file (expand-file-name "packages.el" dir))
         (package-vc-sync-manifest-file file))
    (unwind-protect
        (progn
          (with-temp-file file (insert "(setq broken"))
          (should (string-match-p
                   "failed to load manifest"
                   (error-message-string
                    (should-error (package-vc-sync--load-manifest) :type 'error)))))
      (delete-directory dir t))))

(ert-deftest package-vc-sync-load-manifest-valid ()
  (let* ((dir (make-temp-file "pvc-sync-test-" t))
         (file (expand-file-name "packages.el" dir))
         (package-vc-sync-manifest-file file)
         (package-vc-sync-packages nil))
    (unwind-protect
        (progn
          (with-temp-file file (insert "(setq package-vc-sync-packages '(foo bar))"))
          (package-vc-sync--load-manifest)
          (should (equal package-vc-sync-packages '(foo bar))))
      (delete-directory dir t))))

(ert-deftest package-vc-sync-canonical-spec-plist-order-insensitive ()
  (should (equal (package-vc-sync--canonical-spec '(:url "u" :branch "b"))
                 (package-vc-sync--canonical-spec '(:branch "b" :url "u")))))

(ert-deftest package-vc-sync-canonical-spec-non-plists ()
  (should (equal (package-vc-sync--canonical-spec nil) nil))
  (should (equal (package-vc-sync--canonical-spec "abc123") "abc123")))

(ert-deftest package-vc-sync-spec-pin-class ()
  (should (eq (package-vc-sync--spec-pin-class nil) 'any))
  (should (eq (package-vc-sync--spec-pin-class "abc123") 'frozen))
  (should (eq (package-vc-sync--spec-pin-class '(:url "u" :branch "dev")) 'branch))
  (should (eq (package-vc-sync--spec-pin-class '(:url "u")) 'head)))

(ert-deftest package-vc-sync-state-round-trip ()
  (let* ((dir (make-temp-file "pvc-sync-test-" t))
         (package-vc-sync-state-file (expand-file-name "state.eld" dir))
         (state '((foo . "abc") (bar :url "u" :branch "dev"))))
    (unwind-protect
        (progn
          (package-vc-sync--write-state state)
          (should (equal (package-vc-sync--read-state) state)))
      (delete-directory dir t))))

(ert-deftest package-vc-sync-state-missing-file ()
  (let ((package-vc-sync-state-file "/tmp/does-not-exist-pvc-sync-state.eld"))
    (should (eq (package-vc-sync--read-state) nil))))

(ert-deftest package-vc-sync-state-corrupt-file ()
  (let* ((dir (make-temp-file "pvc-sync-test-" t))
         (package-vc-sync-state-file (expand-file-name "state.eld" dir)))
    (unwind-protect
        (progn
          (with-temp-file package-vc-sync-state-file (insert "(broken"))
          ;; Match the message: `void-function' is a subtype of `error', so a
          ;; bare :type 'error would pass against no implementation at all.
          (should (string-match-p
                   "corrupt state file"
                   (error-message-string
                    (should-error (package-vc-sync--read-state) :type 'error)))))
      (delete-directory dir t))))

;;; Helpers

(defvar package-vc-sync-test--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory holding this test file.
Captured at load time on purpose: `load-file-name\' is only bound while the
file is being loaded, and is nil by the time a test body runs.")

(defmacro package-vc-sync-test--with-temp-dirs (&rest body)
  "Run BODY with isolated user-emacs-directory and package-user-dir."
  (declare (indent 0))
  `(let* ((root (make-temp-file "pvc-sync-test-" t))
          (user-emacs-directory (expand-file-name "config/" root))
          (package-user-dir (expand-file-name "elpa/" root))
          (package-archives nil)
          ;; Without this the engine reads the defcustom default and every
          ;; test hits MELPA/GNU/NonGNU over the network.  nil archives make
          ;; `package-refresh-contents' and `package-upgrade-all' no-ops.
          (package-vc-sync-archives nil)
          (package--initialized nil)
          (package-alist nil)
          (package-archive-contents nil)
          (package--archives-cache nil)
          (package-vc-selected-packages nil)
          (package-vc-sync-packages nil)
          (package-vc-sync-manifest-file nil)
          (package-vc-sync-state-file nil)
          ;; `package-vc-install' clones through `vc-clone', which makes
          ;; project.el record the new checkout.  `project-list-file' is
          ;; computed from `user-emacs-directory' when project.el loads, so
          ;; without this it stays pinned to the first test's temp dir and
          ;; every later VC install fails writing projects.eld.  The
          ;; `(require 'project)' above is load-bearing: the variable must be
          ;; a known defvar for this to be a dynamic binding.
          (project-list-file (expand-file-name "projects.eld" user-emacs-directory)))
     (make-directory user-emacs-directory t)
     (make-directory package-user-dir t)
     (unwind-protect
         (progn ,@body)
       (delete-directory root t))))

(defun package-vc-sync-test--git (dir &rest args)
  "Run git in DIR with ARGS.  Return the exit status."
  (let ((default-directory (file-name-as-directory dir)))
    (apply #'call-process "git" nil nil nil args)))

(defun package-vc-sync-test--git-commit (dir msg)
  "Commit all changes in DIR with message MSG."
  (package-vc-sync-test--git dir "add" ".")
  (package-vc-sync-test--git dir "-c" "user.email=test@example.com"
                             "-c" "user.name=Test" "commit" "-m" msg))

(defun package-vc-sync-test--git-rev (dir)
  "Return the HEAD revision of DIR."
  (let ((default-directory (file-name-as-directory dir)))
    (string-trim (shell-command-to-string "git rev-parse HEAD"))))

(defun package-vc-sync-test--make-git-package (name version &optional root)
  "Create a git repo at ROOT/NAME containing a minimal package.
The repo has one commit on branch main."
  (let* ((dir (expand-file-name name (or root (make-temp-file "pvc-sync-git-" t)))))
    (make-directory dir t)
    (with-temp-file (expand-file-name (format "%s.el" name) dir)
      (insert (format ";;; %s.el --- Test package -*- lexical-binding: t; -*-\n\
;; Version: %s\n\
;;;###autoload\n\
(defun %s-hello ()\n  \"Say hello.\"\n  \"hello\")\n\
(provide '%s)\n\
;;; %s.el ends here\n" name version name name name)))
    (package-vc-sync-test--git dir "init" "-b" "main")
    (package-vc-sync-test--git-commit dir "Initial commit")
    dir))

(defun package-vc-sync-test--write-manifest (content)
  "Write CONTENT to the default manifest file in the temp config dir.
A `lexical-binding\' cookie is prepended unless CONTENT has one, so loading
the manifest does not warn."
  (let ((file (package-vc-sync--manifest-file)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (unless (string-match-p "lexical-binding" content)
        (insert ";;; -*- lexical-binding: t; -*-\n"))
      (insert content))
    file))

(ert-deftest package-vc-sync-test-git-fixture ()
  (let ((repo (package-vc-sync-test--make-git-package "fixturepkg" "0.1")))
    (unwind-protect
        (progn
          (should (file-exists-p (expand-file-name "fixturepkg.el" repo)))
          (should (eq (package-vc-sync-test--git repo "rev-parse" "--abbrev-ref" "HEAD") 0))
          (should (string-match-p "\\`[0-9a-f]\\{40\\}\\'" (package-vc-sync-test--git-rev repo))))
      (delete-directory (file-name-parent-directory repo) t))))

(ert-deftest package-vc-sync-archive-install-and-upgrade ()
  "Engine archive path: install missing, skip installed, always upgrade-all.
Also asserts `package-archives' is set from the manifest before any archive
access (sync algorithm step 2)."
  (package-vc-sync-test--with-temp-dirs
    (let* ((archives '(("test" . "/tmp/pvc-sync-nonexistent-archive/")))
           (installed nil)
           (calls nil))
      (cl-letf (((symbol-function 'package-initialize) #'ignore)
                ((symbol-function 'package-installed-p)
                 (lambda (name &rest _) (and (memq name installed) t)))
                ((symbol-function 'package-refresh-contents)
                 (lambda (&rest _) (push (cons 'refresh package-archives) calls)))
                ((symbol-function 'package-install)
                 (lambda (name &rest _)
                   (push (cons (list 'install name) package-archives) calls)
                   (push name installed)))
                ((symbol-function 'package-upgrade-all)
                 (lambda (&rest _) (push (cons 'upgrade-all package-archives) calls))))
        (package-vc-sync-test--write-manifest
         (format "(setq package-vc-sync-archives '%S)\n\
(setq package-vc-sync-packages '(alpha beta))\n"
                 archives))
        ;; First sync: neither package installed -> both installed.
        (let ((report (package-vc-sync)))
          (should report)
          (should-not (package-vc-sync--report-failed report))
          (should (equal (sort (copy-sequence
                                (package-vc-sync--report-installed report))
                               #'string<)
                         '(alpha beta))))
        (setq calls (nreverse calls))
        ;; Refresh and both installs precede upgrade-all, and every archive
        ;; access saw the manifest's archives -- not the defcustom default.
        (should (equal (mapcar #'car calls)
                       '(refresh (install alpha) (install beta) upgrade-all)))
        (dolist (call calls)
          (should (equal (cdr call) archives)))
        ;; Second sync: both installed -> no install, upgrade-all still runs.
        (setq calls nil)
        (let ((report (package-vc-sync)))
          (should report)
          (should-not (package-vc-sync--report-failed report))
          (should-not (package-vc-sync--report-installed report)))
        (should (equal (mapcar #'car (nreverse calls))
                       '(refresh upgrade-all)))))))

(ert-deftest package-vc-sync-vc-install-missing ()
  (package-vc-sync-test--with-temp-dirs
    (let* ((repo (package-vc-sync-test--make-git-package "vcpkg" "0.1")))
      (unwind-protect
          (progn
            (package-vc-sync-test--write-manifest
             (format "(setq package-vc-selected-packages '((vcpkg :url %S :vc-backend Git)))\n" repo))
            (let ((report (package-vc-sync)))
              (should report)
              (should-not (package-vc-sync--report-failed report))
              (should (package-vc-sync--installed-vc-desc 'vcpkg)))
            ;; State file records the applied spec.
            (should (equal (alist-get 'vcpkg (package-vc-sync--read-state))
                           (list :url repo :vc-backend 'Git))))
        (delete-directory (file-name-parent-directory repo) t)))))

(ert-deftest package-vc-sync-vc-reinstall-on-spec-change ()
  (package-vc-sync-test--with-temp-dirs
    (let* ((repo (package-vc-sync-test--make-git-package "vcpkg" "0.1"))
           ;; Second commit on a new branch dev; repo stays on main.
           (dev-tip (progn
                      (package-vc-sync-test--git repo "checkout" "-b" "dev")
                      (with-temp-file (expand-file-name "vcpkg.el" repo)
                        (insert ";;; vcpkg.el --- Test -*- lexical-binding: t; -*-\n\
;; Version: 0.2\n\
;;;###autoload\n\
(defun vcpkg-hello () \"hi\")\n\
(provide 'vcpkg)\n\
;;; vcpkg.el ends here\n"))
                      (package-vc-sync-test--git-commit repo "Dev commit")
                      ;; Read dev's tip *before* going back to main --
                      ;; `--git-rev' reports HEAD, so reading it after the
                      ;; checkout would capture main's tip instead.
                      (prog1 (package-vc-sync-test--git-rev repo)
                        (package-vc-sync-test--git repo "checkout" "main")))))
      (unwind-protect
          (progn
            ;; Install pinned to main.
            (package-vc-sync-test--write-manifest
             (format "(setq package-vc-selected-packages '((vcpkg :url %S :branch \"main\" :vc-backend Git)))\n" repo))
            (package-vc-sync)
            (let ((desc (package-vc-sync--installed-vc-desc 'vcpkg)))
              (should desc)
              (should (equal (package-vc-sync-test--git-rev (package-desc-dir desc))
                             (package-vc-sync-test--git-rev repo))))
            ;; Change the pin to dev: reinstall.
            (package-vc-sync-test--write-manifest
             (format "(setq package-vc-selected-packages '((vcpkg :url %S :branch \"dev\" :vc-backend Git)))\n" repo))
            (let* ((report (package-vc-sync))
                   (desc (package-vc-sync--installed-vc-desc 'vcpkg)))
              (should (member 'vcpkg (package-vc-sync--report-reinstalled report)))
              (should (equal (package-vc-sync-test--git-rev (package-desc-dir desc))
                             dev-tip)))
            ;; State updated to the new spec.
            (should (equal (alist-get 'vcpkg (package-vc-sync--read-state))
                           (list :url repo :branch "dev" :vc-backend 'Git))))
        (delete-directory (file-name-parent-directory repo) t)))))

(ert-deftest package-vc-sync-warn-on-removed ()
  (package-vc-sync-test--with-temp-dirs
    (let* ((repo (package-vc-sync-test--make-git-package "vcpkg" "0.1"))
           (warnings nil))
      (unwind-protect
          (progn
            (package-vc-sync-test--write-manifest
             (format "(setq package-vc-selected-packages '((vcpkg :url %S :vc-backend Git)))\n" repo))
            (package-vc-sync)
            ;; Drop the package from the manifest.
            (package-vc-sync-test--write-manifest
             "(setq package-vc-selected-packages nil)\n")
            (cl-letf (((symbol-function 'warn)
                       (lambda (fmt &rest args)
                         (push (apply #'format fmt args) warnings))))
              (package-vc-sync))
            (should (seq-find (lambda (w) (string-match-p "no longer in the manifest" w))
                              warnings)))
        (delete-directory (file-name-parent-directory repo) t)))))

(ert-deftest package-vc-sync-await-new-processes ()
  (let ((before (process-list))
        (proc (start-process "pvc-sync-test-sleep" nil "sleep" "1")))
    (unwind-protect
        (progn
          (package-vc-sync--await-new-processes before)
          (should-not (process-live-p proc)))
      (when (process-live-p proc) (kill-process proc)))))

(ert-deftest package-vc-sync-vc-upgrade-head ()
  (package-vc-sync-test--with-temp-dirs
    (let* ((repo (package-vc-sync-test--make-git-package "vcpkg" "0.1")))
      (unwind-protect
          (progn
            (package-vc-sync-test--write-manifest
             (format "(setq package-vc-selected-packages '((vcpkg :url %S :vc-backend Git)))\n" repo))
            (package-vc-sync)
            ;; New commit on main.
            (with-temp-file (expand-file-name "vcpkg.el" repo)
              (insert ";;; vcpkg.el --- Test -*- lexical-binding: t; -*-\n\
;; Version: 0.2\n\
;;;###autoload\n\
(defun vcpkg-hello () \"hi\")\n\
(provide 'vcpkg)\n\
;;; vcpkg.el ends here\n"))
            (package-vc-sync-test--git-commit repo "Second commit")
            (let* ((report (package-vc-sync))
                   (desc (package-vc-sync--installed-vc-desc 'vcpkg)))
              (should (member 'vcpkg (package-vc-sync--report-upgraded report)))
              (should (equal (package-vc-sync-test--git-rev (package-desc-dir desc))
                             (package-vc-sync-test--git-rev repo)))))
        (delete-directory (file-name-parent-directory repo) t)))))

(ert-deftest package-vc-sync-vc-frozen-string-pin ()
  (package-vc-sync-test--with-temp-dirs
    (let* ((repo (package-vc-sync-test--make-git-package "vcpkg" "0.1"))
           (main-tip (package-vc-sync-test--git-rev repo)))
      (unwind-protect
          (progn
            ;; Tag the initial commit.
            (package-vc-sync-test--git repo "tag" "v1")
            ;; Install via a plist spec (follow HEAD).
            (package-vc-sync-test--write-manifest
             (format "(setq package-vc-selected-packages '((vcpkg :url %S :vc-backend Git)))\n" repo))
            (package-vc-sync)
            ;; Switch to a bare-string tag pin: spec changed -> reinstall at v1.
            (package-vc-sync-test--write-manifest
             "(setq package-vc-selected-packages '((vcpkg . \"v1\")))\n")
            (let* ((report (package-vc-sync))
                   (desc (package-vc-sync--installed-vc-desc 'vcpkg)))
              (should (member 'vcpkg (package-vc-sync--report-reinstalled report)))
              (should (equal (package-vc-sync-test--git-rev (package-desc-dir desc))
                             main-tip)))
            ;; Same spec again: frozen -> skipped, no failure.
            (let ((report (package-vc-sync)))
              (should (member 'vcpkg (package-vc-sync--report-pinned report)))
              (should-not (package-vc-sync--report-failed report))))
        (delete-directory (file-name-parent-directory repo) t)))))

(ert-deftest package-vc-sync-cli-subprocess ()
  (package-vc-sync-test--with-temp-dirs
    (let* ((repo-root (expand-file-name ".." package-vc-sync-test--dir))
           (repo (package-vc-sync-test--make-git-package "vcpkg" "0.1"))
           ;; The subprocess does not inherit the parent's let-bindings, so
           ;; the manifest itself has to switch the archives off; otherwise
           ;; the CLI reads the defcustom default and hits the network.
           (manifest (package-vc-sync-test--write-manifest
                      (format "(setq package-vc-sync-archives nil)\n\
(setq package-vc-selected-packages '((vcpkg :url %S :vc-backend Git)))\n" repo)))
           (stdout (generate-new-buffer "*pvc-sync-cli-out*"))
           ;; `call-process' takes a FILE NAME for error output, never a
           ;; buffer -- passing a buffer signals (wrong-type-argument stringp).
           (errfile (make-temp-file "pvc-sync-cli-err-")))
      (unwind-protect
          (let ((status (call-process "emacs" nil (list stdout errfile) nil
                                      "-Q" "--batch" "-L" repo-root
                                      "-l" "package-vc-sync.el"
                                      ;; Redirect the subprocess away from the
                                      ;; developer's real ~/.emacs.d/elpa.
                                      "--eval" (format "(setq package-user-dir %S)"
                                                       package-user-dir)
                                      "-f" "package-vc-sync-cli" "--" manifest)))
            (should (eq status 0))
            (should (string-match-p
                     "Installed"
                     (with-temp-buffer (insert-file-contents errfile)
                                       (buffer-string))))
            (with-current-buffer stdout
              (should (equal (buffer-string) ""))))
        (kill-buffer stdout)
        (delete-file errfile)
        (delete-directory (file-name-parent-directory repo) t)))))

(ert-deftest package-vc-sync-cli-missing-manifest-exits-1 ()
  (let* ((repo-root (expand-file-name ".." package-vc-sync-test--dir))
         (stdout (generate-new-buffer "*pvc-sync-cli-out*"))
         (errfile (make-temp-file "pvc-sync-cli-err-")))
    (unwind-protect
        (let ((status (call-process "emacs" nil (list stdout errfile) nil
                                    "-Q" "--batch" "-L" repo-root
                                    "-l" "package-vc-sync.el"
                                    "-f" "package-vc-sync-cli" "--" "/tmp/definitely-missing-manifest.el")))
          (should (eq status 1))
          (should (string-match-p
                   "no manifest"
                   (with-temp-buffer (insert-file-contents errfile)
                                     (buffer-string)))))
      (kill-buffer stdout)
      (delete-file errfile))))

(ert-deftest package-vc-sync-summary-buffer ()
  (package-vc-sync-test--with-temp-dirs
    (package-vc-sync-test--write-manifest "(setq package-vc-sync-packages nil)\n")
    (let ((report (package-vc-sync)))
      (should report)
      (package-vc-sync--print-summary report)
      (with-current-buffer "*package-vc-sync*"
        (should (string-match-p "package-vc-sync finished" (buffer-string)))))))
