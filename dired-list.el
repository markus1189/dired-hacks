;;; dired-list.el --- Create dired listings from sources

;; Copyright (C) 2014 Matúš Goljer <matus.goljer@gmail.com>

;; Author: Matúš Goljer <matus.goljer@gmail.com>
;; Maintainer: Matúš Goljer <matus.goljer@gmail.com>
;; Version: 0.0.1
;; Created: 14th February 2014
;; Package-requires: ((dash "2.9.0"))
;; Keywords: files

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License
;; as published by the Free Software Foundation; either version 3
;; of the License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program. If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Produce a file listing with a shell incantation and make a dired
;; out of it!

;;; Code:
(require 'dash)
(require 'dired-hacks-utils)

(defun dired-list-align-size-column ()
  (beginning-of-line)
  (save-match-data
    (when (and (looking-at "^  ")
               (re-search-forward dired-move-to-filename-regexp nil t))
      (goto-char (match-beginning 7))
      (backward-char 1)
      (let* ((size-end (point))
             (size-beg (search-backward " " nil t))
             (width (and size-end (- size-end size-beg))))
        (when (and size-end (< 1 width) (< width 12))
          (goto-char size-beg)
          (insert (make-string (- 12 width) ? )))))))

(defun dired-list-default-filter (proc string)
  "Filter the output of the process to make it suitable for `dired-mode'.

This filter assumes that the input is in the format of `ls -l'."
  (let ((buf (process-buffer proc))
        (inhibit-read-only t))
    (if (buffer-name buf)
        (with-current-buffer buf
          (save-excursion
            (save-restriction
              (widen)
              (let ((beg (point-max)))
                (goto-char beg)
                (insert string)
                (goto-char beg)
                (or (looking-at "^")
                    (progn
                      (dired-list-align-size-column)
                      (forward-line 1)))
                (while (looking-at "^")
                  (insert "  ")
                  (dired-list-align-size-column)
                  (forward-line 1))
                (goto-char (- beg 3))
                (while (search-forward " ./" nil t)
                  (delete-region (point) (- (point) 2)))
                (goto-char beg)
                (beginning-of-line)
                ;; Remove occurrences of default-directory.
                (while (search-forward (concat " " default-directory) nil t)
                  (replace-match " " nil t))
                (goto-char (point-max))
                (when (search-backward "\n" (process-mark proc) t)
                  (dired-insert-set-properties (process-mark proc) (1+ (point)))
                  (move-marker (process-mark proc) (1+ (point))))))))
      (delete-process proc))))

(defun dired-list-default-sentinel (proc state)
  "Update the status/modeline after the process finishes."
  (let ((buf (process-buffer proc))
        (inhibit-read-only t))
    (if (buffer-name buf)
        (with-current-buffer buf
          (let ((buffer-read-only nil))
            (save-excursion
              (goto-char (point-max))
              (insert "\n  " state)
              (forward-char -1)     ;Back up before \n at end of STATE.
              (insert " at " (substring (current-time-string) 0 19))
              (forward-char 1)
              (setq mode-line-process (concat ":" (symbol-name (process-status proc))))
              (delete-process proc)
              (force-mode-line-update)))
          (run-hooks 'dired-after-readin-hook)
          (message "%s finished." (current-buffer))))))

(defun dired-list-kill-process ()
  "Kill the process running in the current buffer."
  (interactive)
  (let ((proc (get-buffer-process (current-buffer))))
    (and proc
         (eq (process-status proc) 'run)
         (condition-case nil
             (delete-process proc)
           (error nil)))))

(defun dired-list (dir buffer-name cmd &optional revert-function filter sentinel)
  (let* ((dired-buffers nil) ;; do not mess with regular dired buffers
         (dir (file-name-as-directory (expand-file-name dir)))
         (filter (or filter 'dired-list-default-filter))
         (sentinel (or sentinel 'dired-list-default-sentinel)))
    (run-hooks 'dired-list-before-buffer-creation-hook)
    ;; TODO: abstract buffer creation
    (with-current-buffer (get-buffer-create buffer-name)
      (switch-to-buffer (current-buffer))
      (widen)
      ;; here we might want to remember some state from before, so add
      ;; a hook to do that
      (kill-all-local-variables)
      (read-only-mode -1) ;only support 24+
      (let ((inhibit-read-only t)) (erase-buffer))
      (setq default-directory dir)
      (run-hooks 'dired-before-readin-hook)
      (shell-command cmd (current-buffer))
      (insert "  " dir ":\n")
      (insert "  " cmd "\n")
      (dired-mode dir)
      (let ((map (make-sparse-keymap)))
        (set-keymap-parent map (current-local-map))
        (define-key map "\C-c\C-k" 'dired-list-kill-process)
        (use-local-map map))
      (set (make-local-variable 'dired-sort-inhibit) t)
      (set (make-local-variable 'revert-buffer-function) revert-function)
      (set (make-local-variable 'dired-subdir-alist)
           (list (cons default-directory (point-min-marker))))
      (let ((proc (get-buffer-process (current-buffer))))
        (set-process-filter proc filter)
        (set-process-sentinel proc sentinel)
        (move-marker (process-mark proc) 1 (current-buffer)))
      (setq mode-line-process '(":%s")))))

(defcustom dired-list-mpc-music-directory "~/Music"
  "MPD Music directory."
  :type 'directory
  :group 'dired-list)

(defun dired-list-mpc (query)
  (interactive "sMPC search query: ")
  (let ((dired-list-before-buffer-creation-hook
         '((lambda () (cd dired-list-mpc-music-directory)))))
    (dired-list dired-list-mpc-music-directory
                (concat "mpc " query)
                (concat "mpc search "
                        query
                        " | tr '\\n' '\\000' | xargs -I '{}' -0 ls -l '{}' &")
                `(lambda (ignore-auto noconfirm)
                   (dired-list-mpc ,query)))))

(defun dired-list-git-ls-files (dir)
  (interactive "DDirectory: ")
  (dired-list dir
              (concat "git ls-files " dir)
              (concat "git ls-files -z | xargs -I '{}' -0 ls -l '{}' &")
              `(lambda (ignore-auto noconfirm) (dired-list-git-ls-files ,dir))))

(defun dired-list-hg-locate (dir)
  (interactive "DDirectory: ")
  (dired-list dir
              (concat "hg locate " dir)
              (concat "hg locate -0 | xargs -I '{}' -0 ls -l '{}' &")
              `(lambda (ignore-auto noconfirm) (dired-list-hg-locate ,dir))))

(defun dired-list-locate (needle)
  (interactive "sLocate: ")
  (dired-list "/"
              (concat "locate " needle)
              (concat "locate " (shell-quote-argument needle) " -0 | xargs -I '{}' -0 ls -ld '{}' &")
              `(lambda (ignore-auto noconfirm) (dired-list-locate ,needle))))

(provide 'dired-list)
;;; dired-list.el ends here
