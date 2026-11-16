;;; codex-draft.el --- Streaming Codex drafts in Org mode -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Stephen Ma
;;
;; Author: Stephen Ma <stphnma@gmail.com>
;; Maintainer: Stephen Ma <stphnma@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (org "9.4"))
;; Keywords: outlines, tools
;; URL: https://github.com/stphnma/codex-draft
;; SPDX-License-Identifier: MIT

;;; Commentary:
;; Codex Draft turns a topic or URL into a researched Org document.  It streams
;; text into a normal Org buffer, accepts comments on lines or selected regions,
;; answers individual comments, revises one commented passage, and revises the
;; complete draft from all feedback.
;;
;; Install and authenticate the Codex CLI, then run `M-x codex-draft'.  Comment
;; with `C-c C-c', answer pending comments with `C-c C-a', revise one passage
;; with `C-c u', submit all with `C-c C-s', or revisit versions with
;; `C-c C-p' and `C-c C-n'.

;;; Code:

(require 'json)
(require 'org)
(require 'org-element)
(require 'face-remap)
(require 'cl-lib)
(require 'subr-x)

(defvar codex-draft--source-file
  (let ((loaded-file (or load-file-name buffer-file-name)))
    (if (and loaded-file (string-suffix-p ".elc" loaded-file))
        (substring loaded-file 0 -1)
      loaded-file))
  "Source file used by `codex-draft-reload'.")

(defgroup codex-draft nil
  "Streaming Codex-assisted Org drafts."
  :group 'org)

(defcustom codex-draft-command
  '("codex" "--search" "app-server" "--listen" "stdio://")
  "Command that starts the Codex app-server."
  :type '(repeat string)
  :group 'codex-draft)

(defcustom codex-draft-model nil
  "Codex model used to research and revise drafts.

When nil, use the model configured by the Codex CLI."
  :type '(choice (const :tag "Codex default" nil) string)
  :group 'codex-draft)

(defcustom codex-draft-directory nil
  "Directory in which to start `codex-draft-command'.

When nil, use the current buffer's `default-directory'."
  :type '(choice (const :tag "Current directory" nil) directory)
  :group 'codex-draft)

(defcustom codex-draft-preview-math nil
  "Control which LaTeX fragments are rendered after a draft finishes.

Use `display' to render multiline equations while keeping inline notation
editable with Org pretty entities.  Use `all' to render every fragment, or nil
to keep all LaTeX source visible."
  :type '(choice (const :tag "Display equations only" display)
                 (const :tag "All math" all)
                 (const :tag "Pretty entities only" nil))
  :group 'codex-draft)

(defcustom codex-draft-math-scale 1.15
  "Scale used for LaTeX previews relative to the surrounding text."
  :type 'number
  :group 'codex-draft)

(defcustom codex-draft-math-process 'dvisvgm
  "Org LaTeX preview process used for crisp vector equations."
  :type 'symbol
  :group 'codex-draft)

(defcustom codex-draft-read-only-by-default t
  "Keep generated drafts read-only so user input is captured as comments."
  :type 'boolean
  :group 'codex-draft)

(defcustom codex-draft-text-width 108
  "Maximum text width for a draft buffer, in columns."
  :type 'integer
  :group 'codex-draft)

(defvar-local codex-draft--process nil)
(defvar-local codex-draft--comments nil)
(defvar-local codex-draft--streaming nil)
(defvar-local codex-draft--received-text nil)
(defvar-local codex-draft--status "Ready")
(defvar-local codex-draft--face-remaps nil)
(defvar-local codex-draft--thread-id nil)
(defvar-local codex-draft--pending-prompt nil)
(defvar-local codex-draft--next-request-id 0)
(defvar-local codex-draft--requests nil)
(defvar-local codex-draft--message-phases nil)
(defvar-local codex-draft--turn-kind 'document)
(defvar-local codex-draft--active-comment nil)
(defvar-local codex-draft--answer-queue nil)
(defvar-local codex-draft--passage-start nil)
(defvar-local codex-draft--passage-end nil)
(defvar-local codex-draft--passage-response "")
(defvar-local codex-draft--previous-state nil)
(defvar-local codex-draft--versions nil)
(defvar-local codex-draft--version-index nil)

(defvar codex-draft-mode-map (make-sparse-keymap))

(define-key codex-draft-mode-map (kbd "C-c C-c") #'codex-draft-comment)
(define-key codex-draft-mode-map (kbd "C-c C-a") #'codex-draft-answer-comments)
(define-key codex-draft-mode-map (kbd "C-c u") #'codex-draft-revise-passage)
(define-key codex-draft-mode-map (kbd "C-c C-s") #'codex-draft-submit-comments)
(define-key codex-draft-mode-map (kbd "C-c C-r") #'codex-draft-revise)
(define-key codex-draft-mode-map (kbd "C-c C-d") #'codex-draft-remove-comment)
(define-key codex-draft-mode-map (kbd "C-c C-k") #'codex-draft-clear-comments)
(define-key codex-draft-mode-map (kbd "C-c C-g") #'codex-draft-cancel)
(define-key codex-draft-mode-map (kbd "C-c C-e") #'codex-draft-toggle-editing)
(define-key codex-draft-mode-map (kbd "C-c C-m") #'codex-draft-refresh-math)
(define-key codex-draft-mode-map (kbd "C-c C-p") #'codex-draft-previous-version)
(define-key codex-draft-mode-map (kbd "C-c C-n") #'codex-draft-next-version)
(define-key codex-draft-mode-map (kbd "C-c r") #'codex-draft-reload)

(define-minor-mode codex-draft-mode
  "Annotate and revise an Org document with Codex."
  :lighter " Draft"
  :keymap codex-draft-mode-map
  (if codex-draft-mode
      (progn
        (add-hook 'kill-buffer-hook #'codex-draft--stop-process nil t)
        (add-hook 'write-contents-functions
                  #'codex-draft--write-contents nil t)
        (codex-draft--apply-presentation)
        (codex-draft--recover-comments)
        (when codex-draft-read-only-by-default
          (setq buffer-read-only t)))
    (remove-hook 'kill-buffer-hook #'codex-draft--stop-process t)
    (remove-hook 'write-contents-functions #'codex-draft--write-contents t)
    (setq buffer-read-only nil)
    (codex-draft--remove-presentation)
    (codex-draft-clear-comments)))

(defun codex-draft-reload ()
  "Reload Codex Draft from its source file and refresh this buffer."
  (interactive)
  (unless (and codex-draft--source-file
               (file-readable-p codex-draft--source-file))
    (user-error "Cannot find the Codex Draft source file"))
  (load-file codex-draft--source-file)
  (add-hook 'write-contents-functions #'codex-draft--write-contents nil t)
  (codex-draft--apply-presentation)
  (codex-draft--recover-comments)
  (if codex-draft-preview-math
      (codex-draft-refresh-math)
    (org-clear-latex-preview)
    (font-lock-flush))
  (message "Codex Draft reloaded from %s" codex-draft--source-file))

;;;###autoload
(defun codex-draft (topic)
  "Research TOPIC or URL and stream a new Org document."
  (interactive "sTopic or URL: ")
  (let ((buffer (generate-new-buffer
                 (format "*Draft: %s*" (truncate-string-to-width topic 55 nil nil "…")))))
    (switch-to-buffer buffer)
    (org-mode)
    (codex-draft-mode 1)
    (setq header-line-format
          '(:eval
            (concat
             (propertize "  DRAFT  "
                         'face '(:foreground "#20242a"
                                 :background "#61afef"
                                 :weight bold))
             (propertize (format "  %s  " codex-draft--status)
                         'face '(:foreground "#b8bec9"
                                 :background "#30343c")))))
    (codex-draft--start-turn (codex-draft--initial-prompt topic))))

(defun codex-draft-comment (start end text)
  "Attach comment TEXT to START through END."
  (interactive
   (if (use-region-p)
       (list (region-beginning) (region-end) (read-string "Comment: "))
     (list (line-beginning-position)
           (line-end-position)
           (read-string "Comment on this line: "))))
  (when (string-empty-p (string-trim text))
    (user-error "Comment cannot be empty"))
  (when codex-draft--streaming
    (user-error "Wait for the current request to finish"))
  (codex-draft--ensure-latest-version)
  (let* ((overlay (make-overlay start end nil t nil))
         (comment (list :overlay overlay :text text :answer "")))
    (overlay-put overlay 'face '(:background "#45402f"
                                 :foreground "#f0dfaf"
                                 :extend t))
    (overlay-put overlay 'help-echo text)
    (overlay-put overlay 'codex-draft-comment t)
    (overlay-put overlay 'evaporate (< start end))
    (push comment codex-draft--comments)
    (codex-draft--render-comment comment)
    (deactivate-mark)
    (message "Comment added; C-c C-a answers pending comments and C-c C-s revises")))

(defun codex-draft--render-comment (comment)
  "Render COMMENT beneath its selected passage."
  (let* ((overlay (plist-get comment :overlay))
         (text (plist-get comment :text))
         (answer (string-trim (or (plist-get comment :answer) "")))
         (indentation (codex-draft--comment-indentation comment))
         (comment-text
          (propertize
           (format "\n%s◀  %s"
                   indentation
                   (replace-regexp-in-string
                    "\n" (concat "\n" indentation "   ") text))
           'face '(:foreground "#20242a"
                   :background "#e5c07b"
                   :weight semi-bold))))
    (when (overlay-buffer overlay)
      (overlay-put overlay 'codex-draft-answer answer)
      (overlay-put overlay 'after-string comment-text))))

(defun codex-draft--comment-indentation (comment)
  "Return the indentation used for COMMENT and its answer."
  (let ((overlay (plist-get comment :overlay)))
    (when (overlay-buffer overlay)
      (save-excursion
        (goto-char (overlay-start overlay))
        (make-string (+ (current-indentation) 4) ?\s)))))

(defun codex-draft--source-block-context (comment)
  "Return the Org source block containing COMMENT, when there is one."
  (let ((overlay (plist-get comment :overlay)))
    (when (and (overlay-buffer overlay)
               (derived-mode-p 'org-mode))
      (save-excursion
        (goto-char (overlay-start overlay))
        (org-element-lineage (org-element-context) '(src-block) t)))))

(defun codex-draft--source-comment-marker (language)
  "Return the line-comment marker for source LANGUAGE."
  (pcase (downcase (or language ""))
    ((or "python" "python-ts" "bash" "sh" "shell" "zsh" "fish"
         "ruby" "perl" "r" "julia" "yaml" "toml" "conf") "#")
    ((or "emacs-lisp" "elisp" "lisp" "scheme" "clojure") ";;")
    ((or "sql" "lua" "haskell" "ada") "--")
    ((or "rust" "c" "c++" "cpp" "java" "javascript" "js"
         "typescript" "ts" "go" "swift" "kotlin" "scala" "csharp") "//")
    (_ nil)))

(defun codex-draft--answer-prefixes (comment)
  "Return first-line and continuation prefixes for COMMENT's answer."
  (let* ((indentation (codex-draft--comment-indentation comment))
         (source-block (codex-draft--source-block-context comment))
         (comment-marker
          (when source-block
            (codex-draft--source-comment-marker
             (org-element-property :language source-block)))))
    (if comment-marker
        (cons (concat indentation comment-marker " Codex: ")
              (concat indentation comment-marker " "))
      (cons (concat indentation "   Codex: ")
            (concat indentation "          ")))))

(defun codex-draft--delete-rendered-answer (comment)
  "Delete COMMENT's temporary answer without marking the document changed."
  (let* ((overlay (plist-get comment :overlay))
         (start (overlay-get overlay 'codex-draft-answer-start))
         (end (overlay-get overlay 'codex-draft-answer-end))
         (was-modified (buffer-modified-p)))
    (when (and (markerp start)
               (markerp end)
               (marker-buffer start)
               (marker-buffer end))
      (let ((inhibit-read-only t))
        (delete-region start end)))
    (when (markerp start)
      (set-marker start nil))
    (when (markerp end)
      (set-marker end nil))
    (overlay-put overlay 'codex-draft-answer-start nil)
    (overlay-put overlay 'codex-draft-answer-end nil)
    (set-buffer-modified-p was-modified)))

(defun codex-draft--start-rendered-answer (comment)
  "Insert the prefix for COMMENT's temporary, scrollable answer."
  (let* ((overlay (plist-get comment :overlay))
         (prefix (car (codex-draft--answer-prefixes comment)))
         (was-modified (buffer-modified-p))
         start
         end)
    (save-excursion
      (goto-char (overlay-end overlay))
      (setq start (copy-marker (point)))
      (let ((inhibit-read-only t))
        (insert
         (propertize (concat "\n" prefix)
                     'codex-draft-annotation t
                     'face '(:foreground "#d6d9df"
                             :background "#313640"
                             :extend t))))
      (setq end (copy-marker (point) t)))
    (overlay-put overlay 'codex-draft-answer-start start)
    (overlay-put overlay 'codex-draft-answer-end end)
    (set-buffer-modified-p was-modified)))

(defun codex-draft--append-rendered-answer (comment text)
  "Append streamed TEXT to COMMENT as temporary buffer text."
  (let ((overlay (plist-get comment :overlay)))
    (unless (markerp (overlay-get overlay 'codex-draft-answer-end))
      (codex-draft--start-rendered-answer comment)))
  (let* ((overlay (plist-get comment :overlay))
         (continuation-prefix (cdr (codex-draft--answer-prefixes comment)))
         (end (overlay-get overlay 'codex-draft-answer-end))
         (window (get-buffer-window (current-buffer)))
         (follow-output
          (and window
               (= (window-point window) (point-max))
               (>= (window-end window t) (point-max))))
         (was-modified (buffer-modified-p)))
    (save-excursion
      (goto-char end)
      (let ((inhibit-read-only t))
        (insert
         (propertize
          (replace-regexp-in-string
           "\n" (concat "\n" continuation-prefix) text)
          'codex-draft-annotation t
          'face '(:foreground "#d6d9df"
                  :background "#313640"
                  :extend t)))))
    (when follow-output
      (set-window-point window (point-max)))
    (set-buffer-modified-p was-modified)))

(defun codex-draft--set-rendered-answer (comment)
  "Render COMMENT's stored answer as temporary buffer text."
  (let ((answer (or (plist-get comment :answer) "")))
    (codex-draft--delete-rendered-answer comment)
    (unless (string-empty-p answer)
      (codex-draft--append-rendered-answer comment answer))))

(defun codex-draft-answer-comments ()
  "Ask Codex to answer every comment that has no answer yet."
  (interactive)
  (codex-draft--ensure-latest-version)
  (when codex-draft--streaming
    (user-error "Wait for the current request to finish"))
  (codex-draft--recover-comments)
  (unless codex-draft--comments
    (user-error "No comments are attached to this draft"))
  (setq codex-draft--answer-queue
        (sort
         (cl-remove-if-not
          (lambda (comment)
            (string-empty-p
             (string-trim (or (plist-get comment :answer) ""))))
          (copy-sequence codex-draft--comments))
         (lambda (left right)
           (< (overlay-start (plist-get left :overlay))
              (overlay-start (plist-get right :overlay))))))
  (unless codex-draft--answer-queue
    (user-error "Every comment already has an answer"))
  (codex-draft--start-next-comment-answer))

(defun codex-draft--recover-comments ()
  "Recover visible comments after the package has been reloaded."
  (unless codex-draft--comments
    (dolist (overlay (overlays-in (point-min) (point-max)))
      (let* ((after-string (overlay-get overlay 'after-string))
             (display-text
              (when after-string (substring-no-properties after-string)))
             (comment-text (overlay-get overlay 'help-echo))
             (stored-answer (overlay-get overlay 'codex-draft-answer))
             (answer-prefix "\n     Codex: ")
             (answer-start
              (when display-text (string-match (regexp-quote answer-prefix)
                                               display-text))))
        (when (and (stringp comment-text)
                   display-text
                   (or (overlay-get overlay 'codex-draft-comment)
                       (string-match-p "◀" display-text)))
          (overlay-put overlay 'codex-draft-comment t)
          (push (list :overlay overlay
                      :text comment-text
                      :answer
                      (cond
                       ((stringp stored-answer) stored-answer)
                       (answer-start
                          (replace-regexp-in-string
                           "\n            " "\n"
                           (substring display-text
                                      (+ answer-start (length answer-prefix)))))
                       (t "")))
                codex-draft--comments)))))
  (dolist (comment codex-draft--comments)
    (codex-draft--render-comment comment)
    (codex-draft--set-rendered-answer comment)))

(defun codex-draft--start-next-comment-answer ()
  "Start answering the next comment in the pending queue."
  (let ((comment (pop codex-draft--answer-queue)))
    (when comment
      (codex-draft--start-comment-answer comment))))

(defun codex-draft--comment-at-point ()
  "Return the comment whose selected passage contains point."
  (cl-find-if
   (lambda (comment)
     (let* ((overlay (plist-get comment :overlay))
            (answer-start
             (overlay-get overlay 'codex-draft-answer-start))
            (answer-end
             (overlay-get overlay 'codex-draft-answer-end)))
       (or (and (overlay-buffer overlay)
                (<= (overlay-start overlay) (point))
                (<= (point) (overlay-end overlay)))
           (and (markerp answer-start)
                (markerp answer-end)
                (marker-buffer answer-start)
                (<= answer-start (point))
                (<= (point) answer-end)))))
   codex-draft--comments))

(defun codex-draft--start-comment-answer (comment)
  "Ask Codex for a focused answer to COMMENT."
  (setf (plist-get comment :answer) "")
  (codex-draft--delete-rendered-answer comment)
  (codex-draft--render-comment comment)
  (let* ((overlay (plist-get comment :overlay))
         (selected-text
          (buffer-substring-no-properties
           (overlay-start overlay) (overlay-end overlay)))
         (source-block (codex-draft--source-block-context comment))
         (source-context
          (when source-block
            (format
             (concat
              "The selection is inside an Org source block written in %s. "
              "Consider the entire block when answering. Answer as explanatory "
              "comments appropriate for that language. Return the comment text "
              "without comment delimiters because the editor adds them.\n\n"
              "<source-block language=\"%s\">\n%s</source-block>\n\n")
             (org-element-property :language source-block)
             (org-element-property :language source-block)
             (org-element-property :value source-block))))
         (document (codex-draft--document-text))
         (prompt
          (format
           (concat
            "Answer the user's comment about the selected passage. Explain it "
            "directly and concretely. Do not revise the document. Return only "
            "the answer in concise Org text, without a heading.\n\n%s"
            "<selected>\n%s\n</selected>\n\n"
            "<comment>\n%s\n</comment>\n\n"
            "<document>\n%s\n</document>")
           (or source-context "")
           selected-text (plist-get comment :text) document)))
    (setq codex-draft--active-comment comment)
    (codex-draft--start-turn prompt 'comment-answer)))

(defun codex-draft-revise-passage ()
  "Replace the commented passage under point using its feedback."
  (interactive)
  (codex-draft--ensure-latest-version)
  (when codex-draft--streaming
    (user-error "Wait for the current request to finish"))
  (let ((comment (codex-draft--comment-at-point)))
    (unless comment
      (user-error "Move the cursor onto a commented passage first"))
    (let ((overlay (plist-get comment :overlay)))
      (setq codex-draft--active-comment comment
            codex-draft--passage-start
            (copy-marker (overlay-start overlay))
            codex-draft--passage-end
            (copy-marker (overlay-end overlay) t)
            codex-draft--passage-response "")
      (codex-draft--record-current-version t)
      (codex-draft--start-turn
       (codex-draft--passage-revision-prompt comment)
       'passage-revision))))

(defun codex-draft--passage-revision-prompt (comment)
  "Build a focused revision prompt for COMMENT."
  (let* ((overlay (plist-get comment :overlay))
         (selected-text
          (buffer-substring-no-properties
           (overlay-start overlay) (overlay-end overlay)))
         (answer (string-trim (or (plist-get comment :answer) ""))))
    (format
     (concat
      "Revise only the selected passage using the user's comment. Make the "
      "replacement fit naturally into the surrounding Org document. Preserve "
      "useful detail, links, and Org structure. Do not use LaTeX syntax. If the "
      "comment asks to remove, delete, cut, drop, or omit the passage without a "
      "replacement, return exactly <delete-passage/>. Otherwise return only the "
      "replacement passage, without a heading, preamble, quotation, or fenced "
      "wrapper. Do not preserve the original merely because a replacement is "
      "normally expected.\n\n"
      "<selected>\n%s\n</selected>\n\n"
      "<comment>\n%s\n</comment>\n\n"
      "%s"
      "<document>\n%s\n</document>")
     selected-text
     (plist-get comment :text)
     (if (string-empty-p answer)
         ""
       (format "<earlier-answer>\n%s\n</earlier-answer>\n\n" answer))
     (codex-draft--document-text))))

(defun codex-draft-remove-comment ()
  "Remove the temporary comment under the cursor."
  (interactive)
  (codex-draft--ensure-latest-version)
  (let ((comment (codex-draft--comment-at-point)))
    (unless comment
      (user-error "Move the cursor onto a commented region first"))
    (codex-draft--delete-rendered-answer comment)
    (delete-overlay (plist-get comment :overlay))
    (setq codex-draft--comments
          (delq comment codex-draft--comments))
    (message "Comment removed")))

(defun codex-draft-clear-comments ()
  "Remove all temporary comments from the current draft."
  (interactive)
  (when (called-interactively-p 'interactive)
    (codex-draft--ensure-latest-version))
  (dolist (comment codex-draft--comments)
    (codex-draft--delete-rendered-answer comment)
    (delete-overlay (plist-get comment :overlay)))
  (setq codex-draft--comments nil))

(defun codex-draft-toggle-editing ()
  "Toggle direct editing of the generated document.

Comment mode is the default.  Direct edits are treated as authoritative
document text, but are not individually identified to the agent."
  (interactive)
  (codex-draft--ensure-latest-version)
  (setq buffer-read-only (not buffer-read-only))
  (codex-draft--set-status
   (if buffer-read-only
       "Comment mode · select text and C-c C-c"
     "Direct editing · C-c C-e returns to comment mode"))
  (message "%s"
           (if buffer-read-only
               "Comment mode enabled"
             "Direct editing enabled")))

(defun codex-draft-cancel ()
  "Stop the current draft request and restore the previous document."
  (interactive)
  (codex-draft--stop-process)
  (when (and codex-draft--streaming
             codex-draft--received-text
             (memq codex-draft--turn-kind '(document passage-revision))
             codex-draft--previous-state)
    (codex-draft--restore-state codex-draft--previous-state))
  (when (markerp codex-draft--passage-start)
    (set-marker codex-draft--passage-start nil))
  (when (markerp codex-draft--passage-end)
    (set-marker codex-draft--passage-end nil))
  (setq codex-draft--streaming nil
        codex-draft--received-text nil
        codex-draft--previous-state nil
        codex-draft--active-comment nil
        codex-draft--passage-start nil
        codex-draft--passage-end nil
        codex-draft--passage-response ""
        codex-draft--answer-queue nil)
  (codex-draft--set-status "Cancelled")
  (message "Draft cancelled"))

(defun codex-draft-submit-comments ()
  "Revise the whole draft using every comment and inline answer."
  (interactive)
  (codex-draft--ensure-latest-version)
  (when codex-draft--streaming
    (user-error "Wait for the current request to finish"))
  (unless codex-draft--comments
    (user-error "Add at least one comment with C-c C-c"))
  (codex-draft--record-current-version t)
  (codex-draft--start-turn (codex-draft--revision-prompt nil) 'document))

(defun codex-draft-revise (instruction)
  "Revise the whole document according to INSTRUCTION."
  (interactive "sRevision instruction: ")
  (codex-draft--ensure-latest-version)
  (when (string-empty-p (string-trim instruction))
    (user-error "Instruction cannot be empty"))
  (codex-draft--send-revision instruction))

(defun codex-draft--send-revision (instruction)
  "Start a full-document revision using INSTRUCTION."
  (when codex-draft--streaming
    (user-error "A draft is already streaming"))
  (codex-draft--record-current-version t)
  (codex-draft--start-turn
   (codex-draft--revision-prompt instruction)))

(defun codex-draft--initial-prompt (topic)
  "Build the first-draft prompt for TOPIC."
  (format
   (concat
    "Research this topic or source using web search: %s\n\n"
    "If it is a URL, read the source and verify important claims. If it is a "
    "general question, research it broadly. Prefer primary sources and current "
    "documentation. Write a clear, self-contained Org mode learning note with "
    "concrete explanations and examples. Use Org headings, lists, source blocks, "
    "and [[URL][title]] links. Do not use LaTeX syntax. Express math with readable "
    "plain text and Unicode symbols such as ×, Δ, ≤, ≥, →, and Greek letters. Use "
    "indented Org example blocks when a calculation needs several aligned lines. "
    "Include a Sources "
    "section. Return only the complete Org document, with no preamble or fenced wrapper.")
   topic))

(defun codex-draft--revision-prompt (instruction)
  "Build a revision prompt from the document, comments, and INSTRUCTION."
  (let ((document (codex-draft--document-text))
        (feedback ""))
    (when instruction
      (setq feedback (format "General instruction: %s\n" instruction)))
    (dolist (comment (reverse codex-draft--comments))
      (let* ((overlay (plist-get comment :overlay))
             (start (overlay-start overlay))
             (end (overlay-end overlay))
             (start-line (line-number-at-pos start))
             (end-line (line-number-at-pos (max start (1- end))))
             (selected-text (buffer-substring-no-properties start end))
             (answer (string-trim (or (plist-get comment :answer) ""))))
        (setq feedback
              (concat feedback
                      (format "\nLines %d-%d:\n%s\nComment: %s\n"
                              start-line end-line selected-text
                              (plist-get comment :text))
                      (unless (string-empty-p answer)
                        (format "Earlier answer: %s\n" answer))))))
    (format
     (concat
      "Revise the Org document using every item of feedback. Preserve useful "
      "detail and source links. Rewrite any existing LaTeX as readable plain text "
      "or Unicode, using Org example blocks for multiline calculations. Do not "
      "return LaTeX commands or environments. Return "
      "only the complete revised "
      "Org document, with no preamble or fenced wrapper.\n\n"
      "<document>\n%s\n</document>\n\n<feedback>\n%s\n</feedback>")
     document feedback)))

(defun codex-draft--document-text (&optional start end)
  "Return document text without temporary comments or answers."
  (let ((position (or start (point-min)))
        (limit (or end (point-max)))
        pieces)
    (while (< position limit)
      (let ((next (next-single-property-change
                   position 'codex-draft-annotation nil limit)))
        (unless (get-text-property position 'codex-draft-annotation)
          (push (buffer-substring-no-properties position next) pieces))
        (setq position next)))
    (apply #'concat (nreverse pieces))))

(defun codex-draft--document-position (position)
  "Translate buffer POSITION to its position in the annotation-free document."
  (+ (point-min)
     (length (codex-draft--document-text (point-min) position))))

(defun codex-draft--write-contents ()
  "Save the Org document without temporary Draft annotations."
  (when buffer-file-name
    (let ((coding-system-for-write buffer-file-coding-system))
      (write-region (codex-draft--document-text) nil buffer-file-name
                    nil 'silent))
    (set-buffer-modified-p nil)
    t))

(defun codex-draft--snapshot-state ()
  "Return the current document, comments, answers, and view position."
  (let ((comments nil)
        (window (get-buffer-window (current-buffer))))
    (dolist (comment codex-draft--comments)
      (let ((overlay (plist-get comment :overlay)))
        (when (overlay-buffer overlay)
          (push (list :start (codex-draft--document-position
                              (overlay-start overlay))
                      :end (codex-draft--document-position
                            (overlay-end overlay))
                      :text (plist-get comment :text)
                      :answer (or (plist-get comment :answer) ""))
                comments))))
    (list :document (codex-draft--document-text)
          :comments (sort comments
                          (lambda (left right)
                            (< (plist-get left :start)
                               (plist-get right :start))))
          :point (codex-draft--document-position (point))
          :window-start
          (when window
            (codex-draft--document-position (window-start window)))
          :saved-at (current-time-string))))

(defun codex-draft--restore-state (state)
  "Restore a document STATE captured by `codex-draft--snapshot-state'."
  (codex-draft-clear-comments)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (plist-get state :document)))
  (dolist (saved-comment (plist-get state :comments))
    (let* ((start (min (point-max) (plist-get saved-comment :start)))
           (end (min (point-max) (plist-get saved-comment :end)))
           (overlay (make-overlay start end nil t nil))
           (comment (list :overlay overlay
                          :text (plist-get saved-comment :text)
                          :answer (or (plist-get saved-comment :answer) ""))))
      (overlay-put overlay 'face '(:background "#45402f"
                                   :foreground "#f0dfaf"
                                   :extend t))
      (overlay-put overlay 'help-echo (plist-get comment :text))
      (overlay-put overlay 'codex-draft-comment t)
      (overlay-put overlay 'evaporate (< start end))
      (push comment codex-draft--comments)
      (codex-draft--render-comment comment)
      (codex-draft--set-rendered-answer comment)))
  (goto-char (min (point-max) (or (plist-get state :point) (point-min))))
  (when-let ((window (get-buffer-window (current-buffer))))
    (set-window-start
     window
     (min (point-max) (or (plist-get state :window-start) (point-min)))))
  (setq codex-draft--active-comment nil)
  (font-lock-flush))

(defun codex-draft--record-current-version (&optional replace-latest)
  "Save the current state, replacing the latest entry when requested."
  (let ((state (codex-draft--snapshot-state)))
    (if (and replace-latest codex-draft--versions)
        (setf (nth (1- (length codex-draft--versions)) codex-draft--versions)
              state)
      (setq codex-draft--versions
            (append codex-draft--versions (list state))))
    (setq codex-draft--version-index
          (1- (length codex-draft--versions)))))

(defun codex-draft--ensure-latest-version ()
  "Reject edits while an older saved version is visible."
  (when (and codex-draft--versions
             (/= codex-draft--version-index
                 (1- (length codex-draft--versions))))
    (user-error "Return to the latest version with C-c C-n first")))

(defun codex-draft-previous-version ()
  "Show the previous saved version of this draft."
  (interactive)
  (when codex-draft--streaming
    (user-error "Wait for the current request to finish"))
  (unless codex-draft--versions
    (user-error "No earlier versions are available"))
  (when (= codex-draft--version-index
           (1- (length codex-draft--versions)))
    (codex-draft--record-current-version t))
  (when (zerop codex-draft--version-index)
    (user-error "Already at the oldest version"))
  (cl-decf codex-draft--version-index)
  (codex-draft--restore-state
   (nth codex-draft--version-index codex-draft--versions))
  (setq buffer-read-only t)
  (codex-draft--set-status
   (format "Viewing version %d of %d · C-c C-n returns forward"
           (1+ codex-draft--version-index)
           (length codex-draft--versions))))

(defun codex-draft-next-version ()
  "Show the next saved version of this draft."
  (interactive)
  (when codex-draft--streaming
    (user-error "Wait for the current request to finish"))
  (unless codex-draft--versions
    (user-error "No saved versions are available"))
  (when (= codex-draft--version-index
           (1- (length codex-draft--versions)))
    (user-error "Already at the latest version"))
  (cl-incf codex-draft--version-index)
  (codex-draft--restore-state
   (nth codex-draft--version-index codex-draft--versions))
  (setq buffer-read-only t)
  (codex-draft--set-status
   (if (= codex-draft--version-index
          (1- (length codex-draft--versions)))
       "Comment mode · latest version"
     (format "Viewing version %d of %d · C-c C-n returns forward"
             (1+ codex-draft--version-index)
             (length codex-draft--versions)))))

(defun codex-draft--start-turn (prompt &optional kind)
  "Start a Codex turn using PROMPT.

KIND is `document', `comment-answer', or `passage-revision'."
  (when codex-draft--streaming
    (user-error "A draft is already streaming"))
  (setq codex-draft--previous-state (codex-draft--snapshot-state)
        codex-draft--received-text nil
        codex-draft--streaming t
        codex-draft--pending-prompt prompt
        codex-draft--turn-kind (or kind 'document))
  (setq buffer-read-only t)
  (codex-draft--set-status "Starting Codex")
  (codex-draft--ensure-process)
  (when codex-draft--thread-id
    (codex-draft--send-turn)))

(defun codex-draft--ensure-process ()
  "Start and initialize the buffer's Codex app-server when needed."
  (unless (process-live-p codex-draft--process)
    (unless (and codex-draft-command
                 (executable-find (car codex-draft-command)))
      (user-error "Codex CLI is not installed or is not on Emacs's PATH"))
    (let* ((document-buffer (current-buffer))
           (name (format "codex-draft-%s" (buffer-name)))
           (stderr-buffer (get-buffer-create (format " *%s stderr*" name)))
           (default-directory (or codex-draft-directory default-directory)))
      (setq codex-draft--process
            (make-process
             :name name
             :buffer (get-buffer-create (format " *%s protocol*" name))
             :command codex-draft-command
             :connection-type 'pipe
             :coding 'utf-8-unix
             :filter #'codex-draft--process-filter
             :sentinel #'codex-draft--process-sentinel
             :stderr stderr-buffer
             :noquery t))
      (process-put codex-draft--process 'document-buffer document-buffer)
      (process-put codex-draft--process 'pending "")
      (setq codex-draft--thread-id nil
            codex-draft--next-request-id 0
            codex-draft--requests (make-hash-table :test #'eql)
            codex-draft--message-phases (make-hash-table :test #'equal))
      (codex-draft--request
       "initialize"
       '((clientInfo . ((name . "codex-draft")
                        (title . "Emacs Org drafts")
                        (version . "0.1.0")))
         (capabilities . ()))
       'initialize))))

(defun codex-draft--send (object)
  "Send JSON-RPC OBJECT to the current Codex app-server."
  (process-send-string codex-draft--process
                       (concat (json-encode object) "\n")))

(defun codex-draft--request (method params kind)
  "Send METHOD with PARAMS and associate its response with KIND."
  (let ((request-id (cl-incf codex-draft--next-request-id)))
    (puthash request-id kind codex-draft--requests)
    (codex-draft--send
     `((id . ,request-id) (method . ,method) (params . ,params)))))

(defun codex-draft--notify (method params)
  "Send a JSON-RPC notification with METHOD and PARAMS."
  (codex-draft--send
   (if params
       `((method . ,method) (params . ,params))
     `((method . ,method)))))

(defun codex-draft--start-thread ()
  "Create the Codex thread used by this draft buffer."
  (let ((params
         `((cwd . ,(expand-file-name
                    (or codex-draft-directory default-directory)))
           (approvalPolicy . "never")
           (sandbox . "read-only")
           (ephemeral . t)
           (baseInstructions
            . ,(concat
                "You are a research and writing agent embedded in an Emacs Org buffer. "
                "Use live web search when research is requested. Maintain the Org document "
                "and follow each turn's requested output format exactly.")))))
    (when codex-draft-model
      (push `(model . ,codex-draft-model) params))
    (codex-draft--request "thread/start" params 'thread-start)))

(defun codex-draft--send-turn ()
  "Send the pending prompt to the current Codex thread."
  (let ((prompt codex-draft--pending-prompt)
        (params nil))
    (setq codex-draft--pending-prompt nil)
    (codex-draft--set-status
     (cond
      ((eq codex-draft--turn-kind 'comment-answer) "Answering comment")
      ((eq codex-draft--turn-kind 'passage-revision) "Revising passage")
      (codex-draft--versions "Revising draft")
      (t "Researching and drafting")))
    (setq params
          `((threadId . ,codex-draft--thread-id)
            (input . [((type . "text") (text . ,prompt))])
            (effort . "medium")))
    (codex-draft--request
     "turn/start"
     params
     'turn-start)))

(defun codex-draft--process-filter (process chunk)
  "Parse complete JSON lines from CHUNK received from PROCESS."
  (let* ((pending (concat (process-get process 'pending) chunk))
         (start 0)
         (line-end (string-match "\n" pending start)))
    (while line-end
      (let ((line (substring pending start line-end)))
        (unless (string-empty-p line)
          (codex-draft--handle-event process line)))
      (setq start (1+ line-end)
            line-end (string-match "\n" pending start)))
    (process-put process 'pending (substring pending start))))

(defun codex-draft--handle-event (process line)
  "Handle one JSON event LINE received from PROCESS."
  (let ((document-buffer (process-get process 'document-buffer))
        (json-object-type 'alist)
        (json-array-type 'list)
        (json-key-type 'symbol))
    (when (buffer-live-p document-buffer)
      (with-current-buffer document-buffer
        (let ((event (json-read-from-string line)))
          (cond
           ((alist-get 'id event)
            (codex-draft--handle-response event))
           ((alist-get 'method event)
            (codex-draft--handle-notification event))))))))

(defun codex-draft--handle-response (response)
  "Handle a JSON-RPC RESPONSE from Codex."
  (let* ((request-id (alist-get 'id response))
         (kind (gethash request-id codex-draft--requests))
         (result (alist-get 'result response))
         (error (alist-get 'error response)))
    (remhash request-id codex-draft--requests)
    (if error
        (codex-draft--stream-error
         (or (alist-get 'message error) "Codex request failed"))
      (pcase kind
        ('initialize
         (codex-draft--notify "initialized" nil)
         (codex-draft--start-thread))
        ('thread-start
         (setq codex-draft--thread-id
               (alist-get 'id (alist-get 'thread result)))
         (if codex-draft--thread-id
             (codex-draft--send-turn)
           (codex-draft--stream-error "Codex did not return a thread ID")))
        ('turn-start nil)))))

(defun codex-draft--handle-notification (notification)
  "Handle a JSON-RPC NOTIFICATION from Codex."
  (let* ((method (alist-get 'method notification))
         (params (alist-get 'params notification)))
    (pcase method
      ("item/agentMessage/delta"
       (unless (equal (gethash (alist-get 'itemId params)
                               codex-draft--message-phases)
                      "commentary")
         (codex-draft--insert-delta (alist-get 'delta params))))
      ("item/started"
       (let* ((item (alist-get 'item params))
              (item-type (alist-get 'type item)))
         (pcase item-type
           ("agentMessage"
            (puthash (alist-get 'id item) (alist-get 'phase item)
                     codex-draft--message-phases))
           ("webSearch"
            (codex-draft--set-status "Researching the web")))))
      ("turn/completed"
       (let* ((turn (alist-get 'turn params))
              (status (alist-get 'status turn))
              (error (alist-get 'error turn)))
         (if (equal status "completed")
             (codex-draft--finish-stream)
           (codex-draft--stream-error
            (or (alist-get 'message error)
                (format "Codex turn %s" status))))))
      ("error"
       (unless (alist-get 'willRetry params)
         (codex-draft--stream-error
          (or (alist-get 'message (alist-get 'error params))
              "Codex turn failed")))))))

(defun codex-draft--insert-delta (text)
  "Add streamed response TEXT to the current turn."
  (cond
   ((eq codex-draft--turn-kind 'comment-answer)
    (setq codex-draft--received-text t)
    (setf (plist-get codex-draft--active-comment :answer)
          (concat (plist-get codex-draft--active-comment :answer) text))
    (overlay-put (plist-get codex-draft--active-comment :overlay)
                 'codex-draft-answer
                 (plist-get codex-draft--active-comment :answer))
    (codex-draft--append-rendered-answer
     codex-draft--active-comment text)
    (codex-draft--set-status "Answering comment"))
   ((eq codex-draft--turn-kind 'passage-revision)
    (let ((was-started codex-draft--received-text))
      (setq codex-draft--passage-response
            (concat codex-draft--passage-response text))
      (unless (codex-draft--possible-delete-response-p)
        (codex-draft--begin-passage-replacement)
        (let ((inhibit-read-only t))
          (save-excursion
            (goto-char codex-draft--passage-end)
            (insert (if was-started
                        text
                      codex-draft--passage-response))))))
    (codex-draft--set-status "Revising passage"))
   (t
    (let* ((window (get-buffer-window (current-buffer)))
           (follow-output
            (and (= (point) (point-max))
                 (or (not window)
                     (>= (window-end window t) (point-max))))))
      (unless codex-draft--received-text
        (codex-draft-clear-comments)
        (let ((inhibit-read-only t))
          (erase-buffer))
        (setq codex-draft--received-text t))
      (codex-draft--set-status "Streaming")
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (point-max))
          (insert text)))
      (when follow-output
        (goto-char (point-max))
        (when window
          (set-window-point window (point-max))))))))

(defun codex-draft--possible-delete-response-p ()
  "Return non-nil while the passage response may be the deletion marker."
  (let ((response (string-trim codex-draft--passage-response))
        (delete-marker "<delete-passage/>"))
    (and (<= (length response) (length delete-marker))
         (string-prefix-p response delete-marker))))

(defun codex-draft--begin-passage-replacement ()
  "Remove the selected passage and its comment before streaming a replacement."
  (unless codex-draft--received-text
    (codex-draft--delete-rendered-answer codex-draft--active-comment)
    (delete-overlay (plist-get codex-draft--active-comment :overlay))
    (setq codex-draft--comments
          (delq codex-draft--active-comment codex-draft--comments))
    (let ((inhibit-read-only t))
      (delete-region codex-draft--passage-start codex-draft--passage-end))
    (set-marker codex-draft--passage-end codex-draft--passage-start)
    (setq codex-draft--received-text t)))

(defun codex-draft--finish-stream ()
  "Finish the current document or comment-answer stream."
  (pcase codex-draft--turn-kind
    ('comment-answer (codex-draft--finish-comment-answer))
    ('passage-revision (codex-draft--finish-passage-revision))
    (_ (codex-draft--finish-document-stream))))

(defun codex-draft--finish-comment-answer ()
  "Finish an inline answer and restore comment mode."
  (setq codex-draft--streaming nil
        codex-draft--received-text nil
        codex-draft--previous-state nil
        codex-draft--active-comment nil)
  (if codex-draft--answer-queue
      (codex-draft--start-next-comment-answer)
    (setq buffer-read-only codex-draft-read-only-by-default)
    (codex-draft--set-status "Comment mode · pending comments answered")
    (message "Answered all pending comments; C-c C-s revises the draft")))

(defun codex-draft--finish-document-stream ()
  "Finish a complete-document stream and restore comment mode."
  (setq codex-draft--streaming nil
        codex-draft--previous-state nil)
  (setq buffer-read-only codex-draft-read-only-by-default)
  (codex-draft--record-current-version)
  (codex-draft--set-status "Comment mode · select text and C-c C-c")
  (font-lock-flush)
  (when codex-draft-preview-math
    (ignore-errors (codex-draft-refresh-math)))
  (message "Draft finished; C-c C-p shows the previous version"))

(defun codex-draft--finish-passage-revision ()
  "Finish a passage revision and restore comment mode."
  (when (string= (string-trim codex-draft--passage-response)
                 "<delete-passage/>")
    (codex-draft--begin-passage-replacement))
  (when (markerp codex-draft--passage-start)
    (set-marker codex-draft--passage-start nil))
  (when (markerp codex-draft--passage-end)
    (set-marker codex-draft--passage-end nil))
  (setq codex-draft--streaming nil
        codex-draft--received-text nil
        codex-draft--previous-state nil
        codex-draft--active-comment nil
        codex-draft--passage-start nil
        codex-draft--passage-end nil
        codex-draft--passage-response "")
  (setq buffer-read-only codex-draft-read-only-by-default)
  (codex-draft--record-current-version)
  (codex-draft--set-status "Comment mode · passage revised")
  (font-lock-flush)
  (message "Passage revised; C-c C-p shows the previous version"))

(defun codex-draft-refresh-math ()
  "Normalize and regenerate every LaTeX preview in the draft."
  (interactive)
  (codex-draft--simplify-inline-identifiers)
  (codex-draft--normalize-aligned-display-math)
  (codex-draft--protect-display-math)
  (org-clear-latex-preview)
  (pcase codex-draft-preview-math
    ('display (codex-draft--preview-display-math))
    ((or 'all 't) (org-latex-preview '(16)))))

(defun codex-draft--preview-display-math ()
  "Render multiline LaTeX environments and leave inline math editable."
  (org-element-map (org-element-parse-buffer) 'latex-environment
    (lambda (element)
      (org--latex-preview-region (org-element-begin element)
                                 (org-element-end element)))))

(defun codex-draft--normalize-aligned-display-math ()
  "Convert nested aligned display math into an Org-friendly environment."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-min))
      (while
          (re-search-forward
           "\\\\\\\[[ \t]*\n[ \t]*\\\\begin{aligned}[ \t]*\n\\(\\(?:.\\|\n\\)*?\\)\n[ \t]*\\\\end{aligned}[ \t]*\n[ \t]*\\\\\\\]"
           nil t)
        (replace-match
         "\\\\begin{align*}\n\\1\n\\\\end{align*}" nil nil)))))

(defun codex-draft--simplify-inline-identifiers ()
  "Display single-letter inline variables as ordinary buffer text."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "\\\\(\\([[:alpha:]]\\)\\\\)" nil t)
        (replace-match "\\1")))))

(defun codex-draft--protect-display-math ()
  "Keep leading operators inside display math from becoming Org list items."
  (let ((inhibit-read-only t)
        (inside-display-math nil))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (cond
         ((looking-at-p "^[[:space:]]*\\\\\\[$")
          (setq inside-display-math t))
         ((looking-at-p "^[[:space:]]*\\\\\\]$")
          (setq inside-display-math nil))
         ((and inside-display-math
               (looking-at "^\\([[:space:]]*\\)\\([+-]\\)\\([[:space:]]+\\)"))
          (replace-match "\\1{}\\2\\3")))
        (forward-line 1)))))

(defun codex-draft--stream-error (error-message)
  "Stop the current turn and display ERROR-MESSAGE."
  (when (and codex-draft--streaming
             codex-draft--received-text
             (memq codex-draft--turn-kind '(document passage-revision))
             codex-draft--previous-state)
    (codex-draft--restore-state codex-draft--previous-state))
  (when (markerp codex-draft--passage-start)
    (set-marker codex-draft--passage-start nil))
  (when (markerp codex-draft--passage-end)
    (set-marker codex-draft--passage-end nil))
  (setq codex-draft--streaming nil
        codex-draft--received-text nil
        codex-draft--previous-state nil
        codex-draft--active-comment nil
        codex-draft--answer-queue nil
        codex-draft--passage-start nil
        codex-draft--passage-end nil
        codex-draft--passage-response "")
  (codex-draft--set-status (format "Failed · %s" error-message))
  (message "Draft failed: %s" error-message))

(defun codex-draft--set-status (status)
  "Display STATUS in the draft header."
  (setq codex-draft--status status)
  (force-mode-line-update))

(defun codex-draft--apply-presentation ()
  "Give the current draft a focused document-editor presentation."
  (codex-draft--configure-macos-tex-path)
  (dolist (cookie codex-draft--face-remaps)
    (face-remap-remove-relative cookie))
  (setq codex-draft--face-remaps nil)
  (setq-local display-line-numbers nil
              cursor-type 'bar
              line-spacing 0.18
              word-wrap t
              truncate-lines nil
              org-adapt-indentation nil
              org-hide-emphasis-markers t
              org-pretty-entities t
              org-pretty-entities-include-sub-superscripts t
              org-fontify-quote-and-verse-blocks t
              org-fontify-whole-heading-line t
              org-startup-folded 'showeverything)
  (setq-local org-format-latex-options
              (plist-put (copy-sequence org-format-latex-options)
                         :scale codex-draft-math-scale))
  (setq-local org-preview-latex-default-process
              codex-draft-math-process)
  (visual-line-mode 1)
  (org-indent-mode 1)
  (setq codex-draft--face-remaps
        (list
         (face-remap-add-relative 'default
                                  :background "#282b31"
                                  :foreground "#d6d9df"
                                  :height 1.12)
         (face-remap-add-relative 'org-level-1
                                  :foreground "#61afef"
                                  :height 1.38 :weight 'bold)
         (face-remap-add-relative 'org-level-2
                                  :foreground "#56b6c2"
                                  :height 1.22 :weight 'bold)
         (face-remap-add-relative 'org-level-3
                                  :foreground "#c678dd"
                                  :height 1.10 :weight 'bold)
         (face-remap-add-relative 'org-level-4
                                  :foreground "#98c379" :weight 'bold)
         (face-remap-add-relative 'org-document-title
                                  :foreground "#e6e9ef"
                                  :height 1.55 :weight 'bold)
         (face-remap-add-relative 'org-link
                                  :foreground "#61afef" :underline t)
         (face-remap-add-relative 'org-block
                                  :background "#21242a"
                                  :foreground "#c8ccd4" :extend t)
         (face-remap-add-relative 'org-block-begin-line
                                  :background "#21242a"
                                  :foreground "#69717d" :extend t)
         (face-remap-add-relative 'org-block-end-line
                                  :background "#21242a"
                                  :foreground "#69717d" :extend t)
         (face-remap-add-relative 'org-quote
                                  :background "#313640"
                                  :foreground "#d2d6de"
                                  :slant 'italic :extend t)
         (face-remap-add-relative 'org-code :foreground "#e5c07b")
         (face-remap-add-relative 'org-verbatim :foreground "#d19a66")
         (face-remap-add-relative 'org-table :foreground "#c8ccd4")
         (face-remap-add-relative 'org-meta-line :foreground "#69717d")
         (face-remap-add-relative 'org-special-keyword :foreground "#69717d")))
  (codex-draft--update-window-margins)
  (font-lock-flush))

(defun codex-draft--configure-macos-tex-path ()
  "Make a GUI Emacs process find MacTeX inside the current buffer."
  (let ((tex-bin "/Library/TeX/texbin"))
    (when (and (eq system-type 'darwin)
               (file-directory-p tex-bin))
      (setq-local exec-path
                  (cons tex-bin (delete tex-bin (copy-sequence exec-path))))
      (setq-local process-environment (copy-sequence process-environment))
      (unless (member tex-bin (parse-colon-path (getenv "PATH")))
        (setenv "PATH" (concat tex-bin path-separator (getenv "PATH")))))))

(defun codex-draft--remove-presentation ()
  "Remove presentation settings from the current draft."
  (dolist (cookie codex-draft--face-remaps)
    (face-remap-remove-relative cookie))
  (setq codex-draft--face-remaps nil)
  (visual-line-mode -1)
  (org-indent-mode -1)
  (dolist (window (get-buffer-window-list (current-buffer) nil t))
    (set-window-margins window nil nil)))

(defun codex-draft--update-window-margins (&optional _frame)
  "Center visible drafts and keep their text comfortably narrow."
  (dolist (window (get-buffer-window-list (current-buffer) nil t))
    (let* ((available-width (window-total-width window))
           (margin (max 2 (/ (- available-width codex-draft-text-width) 2))))
      (set-window-margins window margin margin))))

(defun codex-draft--resize-visible-drafts (frame)
  "Recenter visible draft buffers after a size change to FRAME."
  (dolist (window (window-list frame 'no-minibuffer))
    (with-current-buffer (window-buffer window)
      (when codex-draft-mode
        (codex-draft--update-window-margins frame)))))

(add-hook 'window-size-change-functions #'codex-draft--resize-visible-drafts)

(defun codex-draft--process-sentinel (process event)
  "Handle termination of Codex PROCESS described by EVENT."
  (unless (process-live-p process)
    (let ((document-buffer (process-get process 'document-buffer)))
      (when (buffer-live-p document-buffer)
        (with-current-buffer document-buffer
          (setq codex-draft--process nil)
          (unless (process-get process 'intentional-stop)
            (if codex-draft--streaming
                (codex-draft--stream-error "Codex app-server stopped")
              (codex-draft--set-status "Codex stopped"))
            (unless (string-match-p "finished" event)
              (message "Codex stopped: %s" (string-trim event)))))))))

(defun codex-draft--stop-process ()
  "Stop the current buffer's Codex app-server."
  (when (process-live-p codex-draft--process)
    (process-put codex-draft--process 'intentional-stop t)
    (delete-process codex-draft--process))
  (setq codex-draft--process nil
        codex-draft--thread-id nil))

(provide 'codex-draft)

;;; codex-draft.el ends here
