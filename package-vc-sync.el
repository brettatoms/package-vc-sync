;;; package-vc-sync.el --- Sync packages from a declarative manifest -*- lexical-binding: t; -*-

;; Copyright (C) 2026 brettatoms
;; Author: brettatoms <brettadams@fastmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; Keywords: tools, convenience
;; URL: https://github.com/brettatoms/package-vc-sync
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Declare packages in a manifest file (default: packages.el in your
;; `user-emacs-directory') and sync them out-of-band, never during
;; startup:
;;
;;   M-x package-vc-sync
;;   emacs -Q -nw -l package-vc-sync.el -f package-vc-sync-cli [-- FILE]
;;
;; See README.md for the manifest format.

;;; Code:

(require 'cl-lib)
(require 'package)
(require 'package-vc)
(require 'seq)
(require 'vc)

(defgroup package-vc-sync nil
  "Sync packages from a declarative manifest."
  :group 'package
  :prefix "package-vc-sync-")

(defcustom package-vc-sync-manifest-file nil
  "Manifest file to sync from.
If nil, use \"packages.el\" in `user-emacs-directory'."
  :type '(choice (const :tag "packages.el in user-emacs-directory" nil)
                 (file :tag "Custom path")))

(defcustom package-vc-sync-state-file nil
  "File recording the package specs last applied.
If nil, use \"package-vc-sync-state.eld\" next to the manifest."
  :type '(choice (const :tag "Next to the manifest" nil)
                 (file :tag "Custom path")))

(defcustom package-vc-sync-archives '(("melpa" . "https://melpa.org/packages/")
                                      ("gnu"   . "https://elpa.gnu.org/packages/")
                                      ("nongnu" . "https://elpa.nongnu.org/nongnu/"))
  "Package archives to use during a sync.
Set this in the manifest file to override the default."
  :type '(alist :key-type string :value-type string))

(defvar package-vc-sync-packages nil
  "List of archive packages to install, e.g. `(which-key magit)'.
Set this in the manifest file.")

(defun package-vc-sync--manifest-file ()
  "Return the manifest file to use."
  (expand-file-name
   (or package-vc-sync-manifest-file "packages.el")
   user-emacs-directory))

(defun package-vc-sync--state-file ()
  "Return the state file to use."
  (if package-vc-sync-state-file
      (expand-file-name package-vc-sync-state-file)
    (expand-file-name "package-vc-sync-state.eld"
                      (file-name-directory (package-vc-sync--manifest-file)))))

(defun package-vc-sync--load-manifest ()
  "Load the manifest file, signaling an error if it cannot be loaded."
  (let ((file (package-vc-sync--manifest-file)))
    (unless (file-exists-p file)
      (error "package-vc-sync: no manifest at %s (set `package-vc-sync-manifest-file' to change this)"
             file))
    (condition-case err
        (load file nil 'nomessage)
      (error (error "package-vc-sync: failed to load manifest %s: %S" file err)))))

(defun package-vc-sync--read-state ()
  "Return the state alist from the state file, or nil."
  (let ((file (package-vc-sync--state-file)))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (condition-case err
            (read (current-buffer))
          (error (error "package-vc-sync: corrupt state file %s: %S" file err)))))))

(defun package-vc-sync--write-state (state)
  "Write STATE to the state file."
  (let ((file (package-vc-sync--state-file)))
    (make-directory (file-name-directory file) t)
    (with-temp-buffer
      (prin1 state (current-buffer))
      (insert "\n")
      (write-region (point-min) (point-max) file))))

(defun package-vc-sync--canonical-spec (spec)
  "Return SPEC in a canonical form for comparison.
Plist specs are normalized so that key order does not matter."
  (if (and (listp spec) (not (stringp spec)))
      (let ((alist nil))
        (while spec
          (push (cons (car spec) (cadr spec)) alist)
          (setq spec (cddr spec)))
        (sort alist (lambda (a b)
                      (string< (symbol-name (car a))
                               (symbol-name (car b))))))
    spec))

(defun package-vc-sync--spec-pin-class (spec)
  "Classify SPEC: `frozen', `branch', `head' or `any'.
`frozen': a bare-string spec (specific revision).
`branch': a plist spec with a `:branch' key.
`head':   a plist spec without a `:branch' key (follow HEAD).
`any':    a nil spec (any version)."
  (cond ((null spec) 'any)
        ((stringp spec) 'frozen)
        ((plist-get spec :branch) 'branch)
        (t 'head)))

(cl-defstruct (package-vc-sync--report (:constructor package-vc-sync--make-report))
  "Sync result.  Lists of package names; FAILED holds (name . error-string)."
  (installed nil) (upgraded nil) (reinstalled nil) (pinned nil) (failed nil))

;;;###autoload
(defun package-vc-sync ()
  "Sync packages according to the manifest file.
Return the `package-vc-sync--report' for this run."
  (interactive)
  (package-vc-sync--load-manifest)
  (setq package-archives package-vc-sync-archives)
  (package-initialize)
  (condition-case err
      (package-refresh-contents)
    (error
     (if package-archive-contents
         (warn "package-vc-sync: could not refresh archives, using cached metadata: %S" err)
       (error "package-vc-sync: could not refresh archives and no cached metadata exists: %S" err))))
  (let* ((report (package-vc-sync--make-report))
         (state (package-vc-sync--read-state))
         (processes-before (process-list))
         ;; `package-vc-install' mutates `package-vc-selected-packages' itself
         ;; as a side effect on Emacs 29/30 (visible as "Setting
         ;; `package-vc-selected-packages' temporarily..."), overwriting an
         ;; entry with just the :url plist it cloned from and dropping a
         ;; separately-passed revision string.  Snapshot the manifest's
         ;; declared value now, before `--sync-vc' can trigger that, so the
         ;; state file records what the manifest actually said.
         (manifest-vc-packages package-vc-selected-packages))
    (package-vc-sync--sync-archives report)
    (package-vc-sync--sync-vc report state)
    (package-vc-sync--warn-removed state)
    (package-vc-sync--await-new-processes processes-before)
    (if (package-vc-sync--report-failed report)
        report
      (package-vc-sync--write-state
       (mapcar (lambda (entry)
                 (cons (package-vc-sync--manifest-name entry) (cdr entry)))
               manifest-vc-packages))
      report)))

(defun package-vc-sync--sync-archives (report)
  "Install missing archive packages and upgrade all installed ones."
  (dolist (name package-vc-sync-packages)
    (unless (package-installed-p name)
      (condition-case err
          (progn
            (package-install name)
            (push name (package-vc-sync--report-installed report)))
        (error (push (cons name (error-message-string err))
                     (package-vc-sync--report-failed report))))))
  (condition-case err
      (package-upgrade-all)
    (error (push (cons 'package-upgrade-all (error-message-string err))
                 (package-vc-sync--report-failed report)))))

(defun package-vc-sync--installed-vc-desc (name)
  "Return the installed VC descriptor for NAME, or nil."
  (seq-find #'package-vc-p (cdr (assq name package-alist))))

(defun package-vc-sync--installed-vc-url (name)
  "Return the remote URL of NAME's installed VC checkout, or nil.
Needed to reinstall a bare-string revision pin: the installed descriptor
records only `:commit', and `package-vc-install' resolves a bare package
name against archive metadata, which a private repository does not have."
  (when-let* ((desc (package-vc-sync--installed-vc-desc name))
              (dir (package-desc-dir desc)))
    (with-demoted-errors "package-vc-sync: could not read remote URL: %S"
      (let* ((backend (vc-responsible-backend dir t))
             (url (and backend (vc-call-backend backend 'repository-url dir))))
        (and (stringp url) (not (string-empty-p url)) url)))))

(defun package-vc-sync--force-install (name spec)
  "Install VC package NAME from SPEC, auto-answering yes to prompts."
  (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_prompt) t))
            ((symbol-function 'y-or-n-p) (lambda (_prompt) t)))
    (cond ((null spec) (package-vc-install name))
          ;; A string SPEC is a revision, not a source: recover the URL from
          ;; the existing checkout so the pin can be re-fetched without
          ;; archive metadata.  No checkout yet -> fall back to the archive
          ;; path, which is correct for a package that really is on an archive.
          ((stringp spec)
           (if-let* ((url (package-vc-sync--installed-vc-url name)))
               (package-vc-install (list name :url url) spec)
             (package-vc-install name spec)))
          (t (package-vc-install (cons name spec))))))

(defun package-vc-sync--manifest-name (entry)
  "Return the package name of manifest ENTRY, interned if a string."
  (if (stringp (car entry)) (intern (car entry)) (car entry)))

(defconst package-vc-sync--vc-lock-retries 20
  "Max retries for `package-vc-sync--upgrade-retrying' before giving up.")

(defun package-vc-sync--upgrade-retrying (desc)
  "Call `package-vc-upgrade' on DESC, retrying if another VC action is busy.
A background VC action (e.g. an async status refresh right after install)
can still hold the checkout's VC output buffer when this runs; that shows
up as `vc-do-async-command' signaling \"Another VC action ... is running\".
That is a transient race, not a real failure, so wait briefly for it to
clear instead of failing the sync over it."
  (let ((attempts 0) (done nil))
    (while (not done)
      (condition-case err
          (progn (package-vc-upgrade desc) (setq done t))
        (error
         (if (and (< attempts package-vc-sync--vc-lock-retries)
                  (string-match-p "\`Another VC action on .* is running\'"
                                   (error-message-string err)))
             (progn (cl-incf attempts) (accept-process-output nil 0.25))
           (signal (car err) (cdr err))))))))

(defun package-vc-sync--sync-vc (report state)
  "Install/upgrade/reinstall VC packages per the manifest."
  (dolist (entry package-vc-selected-packages)
    (let* ((name (package-vc-sync--manifest-name entry))
           (spec (cdr entry)))
      (condition-case err
          (if-let* ((desc (package-vc-sync--installed-vc-desc name)))
              (if (equal (package-vc-sync--canonical-spec spec)
                         (package-vc-sync--canonical-spec (alist-get name state)))
                  ;; Spec unchanged: upgrade per pin class.
                  (pcase (package-vc-sync--spec-pin-class spec)
                    ('frozen
                     (push name (package-vc-sync--report-pinned report)))
                    (_
                     (package-vc-sync--upgrade-retrying desc)
                     (push name (package-vc-sync--report-upgraded report))))
                ;; Spec changed: reinstall.
                (package-vc-sync--force-install name spec)
                (push name (package-vc-sync--report-reinstalled report)))
            ;; Not installed: install.
            (package-vc-sync--force-install name spec)
            (push name (package-vc-sync--report-installed report)))
        (error (push (cons name (error-message-string err))
                     (package-vc-sync--report-failed report)))))))

(defun package-vc-sync--warn-removed (state)
  "Warn about installed VC packages no longer in the manifest."
  (let ((names (mapcar #'package-vc-sync--manifest-name package-vc-selected-packages)))
    (dolist (entry (or state nil))
      (let ((name (car entry)))
        (unless (memq name names)
          (warn "package-vc-sync: %s is installed but no longer in the manifest; sync will not manage it"
                name))))))

(defun package-vc-sync--await-new-processes (before)
  "Wait until every process not present in BEFORE has finished."
  (let ((remaining (cl-set-difference (process-list) before)))
    (while remaining
      (accept-process-output nil 0.5)
      (setq remaining (cl-set-difference (process-list) before)))))

(defvar package-vc-sync--cli nil
  "Non-nil when running as a CLI (`package-vc-sync-cli').")

(defun package-vc-sync--print-summary (report)
  "Print a human-readable summary of REPORT.
In CLI mode, writes to stderr.  Otherwise populates the
*package-vc-sync* buffer."
  (let ((lines
         (list "package-vc-sync finished."
               (format "  Installed:   %S" (nreverse (package-vc-sync--report-installed report)))
               (format "  Upgraded:    %S" (nreverse (package-vc-sync--report-upgraded report)))
               (format "  Reinstalled: %S" (nreverse (package-vc-sync--report-reinstalled report)))
               (format "  Pinned:      %S" (nreverse (package-vc-sync--report-pinned report)))
               (format "  Failed:      %S" (nreverse (package-vc-sync--report-failed report))))))
    (if package-vc-sync--cli
        (dolist (line lines)
          (princ line #'external-debugging-output)
          (princ "\n" #'external-debugging-output))
      (with-current-buffer (get-buffer-create "*package-vc-sync*")
        (erase-buffer)
        (dolist (line lines) (insert line "\n"))
        (unless noninteractive (display-buffer (current-buffer)))))))

;;;###autoload
(defun package-vc-sync-cli ()
  "Run `package-vc-sync' as a command-line program and exit.
Usage: emacs -Q -nw -l package-vc-sync.el -f package-vc-sync-cli [-- MANIFEST]"
  (let ((package-vc-sync--cli t)
        ;; Emacs leaves the "--" separator itself in `command-line-args-left',
        ;; so the documented `-- /path/to/packages.el' form would otherwise be
        ;; read as the manifest path (verified on 31.1:
        ;; command-line-args-left => ("--" "/path/to/packages.el")).
        (args (seq-remove (lambda (arg) (equal arg "--"))
                          command-line-args-left)))
    (when args
      (setq package-vc-sync-manifest-file (car args)))
    (condition-case err
        (let ((report (package-vc-sync)))
          (package-vc-sync--print-summary report)
          (kill-emacs (if (package-vc-sync--report-failed report) 1 0)))
      (error
       (princ (format "package-vc-sync: %S\n" err) #'external-debugging-output)
       (kill-emacs 1)))))

(provide 'package-vc-sync)
;;; package-vc-sync.el ends here
