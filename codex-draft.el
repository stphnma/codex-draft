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
;; and asks Codex to revise only the commented passages.
;;
;; Install and authenticate the Codex CLI, then run `M-x codex-draft'.  Comment
;; with `C-c C-c', submit comments with `C-c C-s', or request a full revision
;; with `C-c C-r'.

;;; Code:

(require 'json)
(require 'org)
(require 'face-remap)
(require 'cl-lib)
(require 'subr-x)

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

(defcustom codex-draft-preview-math t
  "Preview all LaTeX fragments after a draft finishes."
  :type 'boolean
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
(defvar-local codex-draft--previous-document nil)
(defvar-local codex-draft--status "Ready")
(defvar-local codex-draft--face-remaps nil)
(defvar-local codex-draft--thread-id nil)
(defvar-local codex-draft--pending-prompt nil)
(defvar-local codex-draft--next-request-id 0)
(defvar-local codex-draft--requests nil)
(defvar-local codex-draft--message-phases nil)
(defvar-local codex-draft--turn-kind 'document)
(defvar-local codex-draft--output-schema nil)
(defvar-local codex-draft--response-text "")
(defvar-local codex-draft--revision-targets nil)

(defvar codex-draft-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'codex-draft-comment)
    (define-key map (kbd "C-c C-s") #'codex-draft-submit-comments)
    (define-key map (kbd "C-c C-r") #'codex-draft-revise)
    (define-key map (kbd "C-c C-d") #'codex-draft-remove-comment)
    (define-key map (kbd "C-c C-k") #'codex-draft-clear-comments)
    (define-key map (kbd "C-c C-g") #'codex-draft-cancel)
    (define-key map (kbd "C-c C-e") #'codex-draft-toggle-editing)
    (define-key map (kbd "C-c C-m") #'codex-draft-refresh-math)
    map))

(define-minor-mode codex-draft-mode
  "Annotate and revise an Org document with Codex."
  :lighter " Draft"
  :keymap codex-draft-mode-map
  (if codex-draft-mode
      (progn
        (add-hook 'kill-buffer-hook #'codex-draft--stop-process nil t)
        (codex-draft--apply-presentation)
        (when codex-draft-read-only-by-default
          (setq buffer-read-only t)))
    (remove-hook 'kill-buffer-hook #'codex-draft--stop-process t)
    (setq buffer-read-only nil)
    (codex-draft--remove-presentation)
    (codex-draft-clear-comments)))

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
  "Attach temporary comment TEXT to the region from START to END."
  (interactive
   (if (use-region-p)
       (list (region-beginning) (region-end) (read-string "Comment: "))
     (list (line-beginning-position)
           (line-end-position)
           (read-string "Comment on this line: "))))
  (when (string-empty-p (string-trim text))
    (user-error "Comment cannot be empty"))
  (let ((overlay (make-overlay start end nil t nil)))
    (overlay-put overlay 'face '(:background "#45402f"
                                 :foreground "#f0dfaf"
                                 :extend t))
    (overlay-put overlay 'help-echo text)
    (overlay-put overlay 'after-string
                 (propertize (format "  ◀  %s" text)
                             'face '(:foreground "#20242a"
                                     :background "#e5c07b"
                                     :weight semi-bold)))
    (overlay-put overlay 'evaporate (< start end))
    (push (list :overlay overlay :text text) codex-draft--comments))
  (deactivate-mark)
  (message "Comment added; C-c C-d removes it and C-c C-s submits all comments"))

(defun codex-draft-remove-comment ()
  "Remove the temporary comment under the cursor."
  (interactive)
  (let ((comment
         (cl-find-if
          (lambda (comment)
            (let ((overlay (plist-get comment :overlay)))
              (and (overlay-buffer overlay)
                   (<= (overlay-start overlay) (point))
                   (<= (point) (overlay-end overlay)))))
          codex-draft--comments)))
    (unless comment
      (user-error "Move the cursor onto a commented region first"))
    (delete-overlay (plist-get comment :overlay))
    (setq codex-draft--comments
          (delq comment codex-draft--comments))
    (message "Comment removed")))

(defun codex-draft-clear-comments ()
  "Remove all temporary comments from the current draft."
  (interactive)
  (dolist (comment codex-draft--comments)
    (delete-overlay (plist-get comment :overlay)))
  (setq codex-draft--comments nil))

(defun codex-draft-toggle-editing ()
  "Toggle direct editing of the generated document.

Comment mode is the default.  Direct edits are treated as authoritative
document text, but are not individually identified to the agent."
  (interactive)
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
             (eq codex-draft--turn-kind 'document))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert codex-draft--previous-document)))
  (setq codex-draft--streaming nil
        codex-draft--received-text nil
        codex-draft--previous-document nil
        codex-draft--response-text ""
        codex-draft--revision-targets nil
        codex-draft--output-schema nil)
  (codex-draft--set-status "Cancelled")
  (message "Draft cancelled"))

(defun codex-draft-submit-comments ()
  "Apply comments only to their selected regions."
  (interactive)
  (unless codex-draft--comments
    (user-error "Add at least one comment with C-c C-c"))
  (codex-draft--send-targeted-revision))

(defun codex-draft-revise (instruction)
  "Revise the whole document according to INSTRUCTION."
  (interactive "sRevision instruction: ")
  (when (string-empty-p (string-trim instruction))
    (user-error "Instruction cannot be empty"))
  (codex-draft--send-revision instruction))

(defun codex-draft--send-revision (instruction)
  "Start a full-document revision using INSTRUCTION."
  (when codex-draft--streaming
    (user-error "A draft is already streaming"))
  (codex-draft--start-turn
   (codex-draft--revision-prompt instruction)))

(defun codex-draft--send-targeted-revision ()
  "Ask Codex for replacements limited to the commented regions."
  (when codex-draft--streaming
    (user-error "A draft is already streaming"))
  (setq codex-draft--revision-targets
        (codex-draft--comment-targets))
  (codex-draft--start-turn
   (codex-draft--targeted-revision-prompt
    codex-draft--revision-targets)
   'targeted
   (codex-draft--targeted-output-schema
    codex-draft--revision-targets)))

(defun codex-draft--initial-prompt (topic)
  "Build the first-draft prompt for TOPIC."
  (format
   (concat
    "Research this topic or source using web search: %s\n\n"
    "If it is a URL, read the source and verify important claims. If it is a "
    "general question, research it broadly. Prefer primary sources and current "
    "documentation. Write a clear, self-contained Org mode learning note with "
    "concrete explanations and examples. Use Org headings, lists, source blocks, "
    "[[URL][title]] links, and LaTeX fragments where useful. For multiline display "
    "math, use an aligned environment and never begin a source line with +, -, or * "
    "because Org parses those as list markers. Put & before continuation operators. "
    "Include a Sources "
    "section. Return only the complete Org document, with no preamble or fenced wrapper.")
   topic))

(defun codex-draft--revision-prompt (instruction)
  "Build a revision prompt from the document, comments, and INSTRUCTION."
  (let ((document (buffer-substring-no-properties (point-min) (point-max)))
        (feedback ""))
    (when instruction
      (setq feedback (format "General instruction: %s\n" instruction)))
    (dolist (comment (reverse codex-draft--comments))
      (let* ((overlay (plist-get comment :overlay))
             (start (overlay-start overlay))
             (end (overlay-end overlay))
             (start-line (line-number-at-pos start))
             (end-line (line-number-at-pos (max start (1- end))))
             (selected-text (buffer-substring-no-properties start end)))
        (setq feedback
              (concat feedback
                      (format "\nLines %d-%d:\n%s\nComment: %s\n"
                              start-line end-line selected-text
                              (plist-get comment :text))))))
    (format
     (concat
      "Revise the Org document using every item of feedback. Preserve useful "
      "detail, source links, and LaTeX math. Return only the complete revised "
      "Org document, with no preamble or fenced wrapper.\n\n"
      "<document>\n%s\n</document>\n\n<feedback>\n%s\n</feedback>")
     document feedback)))

(defun codex-draft--comment-targets ()
  "Return non-overlapping replacement targets for the current comments."
  (let ((targets nil))
    (dolist (comment (reverse codex-draft--comments))
      (let* ((overlay (plist-get comment :overlay))
             (start (overlay-start overlay))
             (end (overlay-end overlay))
             (existing
              (cl-find-if
               (lambda (target)
                 (and (= start (plist-get target :start))
                      (= end (plist-get target :end))))
               targets)))
        (if existing
            (setf (plist-get existing :feedback)
                  (concat (plist-get existing :feedback)
                          "\n" (plist-get comment :text)))
          (push (list :id nil
                      :replacement nil
                      :start start
                      :end end
                      :text (buffer-substring-no-properties start end)
                      :feedback (plist-get comment :text))
                targets))))
    (setq targets
          (sort targets
                (lambda (left right)
                  (< (plist-get left :start) (plist-get right :start)))))
    (let ((previous-end nil)
          (id 0))
      (dolist (target targets)
        (when (and previous-end (< (plist-get target :start) previous-end))
          (user-error "Commented regions overlap; combine those comments first"))
        (setq previous-end (plist-get target :end))
        (setf (plist-get target :id) (cl-incf id))))
    targets))

(defun codex-draft--targeted-revision-prompt (targets)
  "Build a minimal-edit prompt for TARGETS."
  (let ((document (buffer-substring-no-properties (point-min) (point-max)))
        (target-text ""))
    (dolist (target targets)
      (setq target-text
            (concat target-text
                    (format
                     (concat "\n<target id=\"%d\">\n"
                             "<selected>\n%s\n</selected>\n"
                             "<feedback>\n%s\n</feedback>\n"
                             "</target>\n")
                     (plist-get target :id)
                     (plist-get target :text)
                     (plist-get target :feedback)))))
    (format
     (concat
      "Update only the selected regions below. Use the full Org document only as "
      "context. For each target, return replacement Org text for exactly that "
      "selected range. Do not rewrite, summarize, or return any unselected text. "
      "Preserve the surrounding style, factual precision, links, and math. Return "
      "one replacement for every target ID and follow the response schema exactly.\n\n"
      "<document>\n%s\n</document>\n\n<targets>%s</targets>")
     document target-text)))

(defun codex-draft--targeted-output-schema (targets)
  "Return the JSON schema for replacements of TARGETS."
  (let ((ids (vconcat (mapcar (lambda (target) (plist-get target :id)) targets)))
        (count (length targets)))
    `((type . "object")
      (properties
       . ((replacements
           . ((type . "array")
              (minItems . ,count)
              (maxItems . ,count)
              (items
               . ((type . "object")
                  (properties
                   . ((id . ((type . "integer") (enum . ,ids)))
                      (text . ((type . "string")))))
                  (required . ["id" "text"])
                  (additionalProperties . :json-false)))))))
      (required . ["replacements"])
      (additionalProperties . :json-false))))

(defun codex-draft--start-turn (prompt &optional kind output-schema)
  "Start a Codex turn using PROMPT.

KIND is `document' or `targeted'.  OUTPUT-SCHEMA constrains a targeted
response when non-nil."
  (when codex-draft--streaming
    (user-error "A draft is already streaming"))
  (setq codex-draft--previous-document
        (buffer-substring-no-properties (point-min) (point-max))
        codex-draft--received-text nil
        codex-draft--streaming t
        codex-draft--pending-prompt prompt
        codex-draft--turn-kind (or kind 'document)
        codex-draft--output-schema output-schema
        codex-draft--response-text "")
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
     (if (eq codex-draft--turn-kind 'targeted)
         "Thinking about selected edits"
       "Researching and drafting"))
    (setq params
          `((threadId . ,codex-draft--thread-id)
            (input . [((type . "text") (text . ,prompt))])
            (effort . "medium")))
    (when codex-draft--output-schema
      (setq params
            (append params
                    `((outputSchema . ,codex-draft--output-schema)))))
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
  (if (eq codex-draft--turn-kind 'targeted)
      (progn
        (setq codex-draft--received-text t
              codex-draft--response-text
              (concat codex-draft--response-text text))
        (codex-draft--set-status "Preparing selected edits"))
    (let ((follow-output (= (point) (point-max))))
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
        (goto-char (point-max))))))

(defun codex-draft--finish-stream ()
  "Finish the current document or targeted response stream."
  (if (eq codex-draft--turn-kind 'targeted)
      (codex-draft--apply-targeted-revision)
    (codex-draft--finish-document-stream)))

(defun codex-draft--finish-document-stream ()
  "Finish a complete-document stream and restore comment mode."
  (setq codex-draft--streaming nil
        codex-draft--previous-document nil)
  (setq buffer-read-only codex-draft-read-only-by-default)
  (codex-draft--set-status "Comment mode · select text and C-c C-c")
  (font-lock-flush)
  (when codex-draft-preview-math
    (ignore-errors (codex-draft-refresh-math)))
  (message "Draft finished"))

(defun codex-draft--apply-targeted-revision ()
  "Apply the structured targeted response without touching other text."
  (condition-case error-data
      (let* ((json-object-type 'alist)
             (json-array-type 'list)
             (json-key-type 'symbol)
             (response (json-read-from-string codex-draft--response-text))
             (replacements (alist-get 'replacements response)))
        (unless (= (length replacements)
                   (length codex-draft--revision-targets))
          (error "Codex returned the wrong number of replacements"))
        (dolist (target codex-draft--revision-targets)
          (let ((matches
                 (cl-remove-if-not
                  (lambda (replacement)
                    (= (alist-get 'id replacement) (plist-get target :id)))
                  replacements)))
            (unless (= (length matches) 1)
              (error "Codex did not return exactly one replacement for target %d"
                     (plist-get target :id)))
            (setf (plist-get target :replacement)
                  (alist-get 'text (car matches)))))
        (codex-draft-clear-comments)
        (let ((inhibit-read-only t))
          (dolist (target
                   (sort (copy-sequence codex-draft--revision-targets)
                         (lambda (left right)
                           (> (plist-get left :start)
                              (plist-get right :start)))))
            (delete-region (plist-get target :start) (plist-get target :end))
            (goto-char (plist-get target :start))
            (insert (plist-get target :replacement))))
        (setq codex-draft--streaming nil
              codex-draft--previous-document nil
              codex-draft--revision-targets nil
              codex-draft--response-text "")
        (setq buffer-read-only codex-draft-read-only-by-default)
        (codex-draft--set-status
         "Comment mode · selected regions updated")
        (font-lock-flush)
        (when codex-draft-preview-math
          (ignore-errors (codex-draft-refresh-math)))
        (message "Updated only the commented regions"))
    (error
     (codex-draft--stream-error
      (format "Could not apply selected edits: %s"
              (error-message-string error-data))))))

(defun codex-draft-refresh-math ()
  "Normalize and regenerate every LaTeX preview in the draft."
  (interactive)
  (codex-draft--simplify-inline-identifiers)
  (codex-draft--protect-display-math)
  (org-clear-latex-preview)
  (org-latex-preview '(16)))

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
             (eq codex-draft--turn-kind 'document))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert codex-draft--previous-document)))
  (setq codex-draft--streaming nil
        codex-draft--previous-document nil
        codex-draft--response-text ""
        codex-draft--revision-targets nil
        codex-draft--output-schema nil)
  (codex-draft--set-status (format "Failed · %s" error-message))
  (message "Draft failed: %s" error-message))

(defun codex-draft--set-status (status)
  "Display STATUS in the draft header."
  (setq codex-draft--status status)
  (force-mode-line-update))

(defun codex-draft--apply-presentation ()
  "Give the current draft a focused document-editor presentation."
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
