;;; codex-draft-test.el --- Tests for Codex Draft -*- lexical-binding: t; -*-

(require 'ert)
(require 'codex-draft)

(ert-deftest codex-draft-adds-comments-without-calling-codex ()
  (with-temp-buffer
    (insert "alpha beta gamma")
    (let ((turn-started nil))
      (cl-letf (((symbol-function 'codex-draft--start-turn)
                 (lambda (&rest _arguments)
                   (setq turn-started t))))
        (codex-draft-comment 1 6 "How does this work?"))
      (should-not turn-started)
      (should (= 1 (length codex-draft--comments)))
      (should (equal "How does this work?"
                     (plist-get (car codex-draft--comments) :text)))
      (should (equal "" (plist-get (car codex-draft--comments) :answer))))))

(ert-deftest codex-draft-renders-comments-indented-beneath-the-passage ()
  (with-temp-buffer
    (insert "  selected passage")
    (codex-draft-comment 3 (point-max) "How does this work?")
    (let* ((comment (car codex-draft--comments))
           (overlay (plist-get comment :overlay))
           (rendered (substring-no-properties
                      (overlay-get overlay 'after-string))))
      (should (string-prefix-p "\n      ◀  How does this work?" rendered)))))

(ert-deftest codex-draft-builds-a-focused-comment-answer-prompt ()
  (with-temp-buffer
    (insert "alpha beta gamma")
    (let* ((overlay (make-overlay 7 11))
           (comment (list :overlay overlay
                          :text "Explain this"
                          :answer "old answer"))
           prompt
           kind)
      (cl-letf (((symbol-function 'codex-draft--start-turn)
                 (lambda (sent-prompt &optional sent-kind)
                   (setq prompt sent-prompt
                         kind sent-kind))))
        (codex-draft--start-comment-answer comment))
      (should (eq 'comment-answer kind))
      (should (string-search "<selected>\nbeta\n</selected>" prompt))
      (should (string-search "<comment>\nExplain this\n</comment>" prompt))
      (should (equal "" (plist-get comment :answer))))))

(ert-deftest codex-draft-gives-comment-answers-source-block-context ()
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src python\nx = fetch_value()\nprint(x)\n#+end_src\n")
    (goto-char (point-min))
    (forward-line 1)
    (let* ((start (line-beginning-position))
           (end (line-end-position))
           (overlay (make-overlay start end))
           (comment (list :overlay overlay
                          :text "Where does this value come from?"
                          :answer ""))
           prompt)
      (cl-letf (((symbol-function 'codex-draft--start-turn)
                 (lambda (sent-prompt &optional _kind)
                   (setq prompt sent-prompt))))
        (codex-draft--start-comment-answer comment))
      (should (string-search
               "<source-block language=\"python\">" prompt))
      (should (string-search "x = fetch_value()\nprint(x)" prompt))
      (should (string-search
               "comments appropriate for that language" prompt)))))

(ert-deftest codex-draft-renders-python-answers-as-comments ()
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src python\nx = fetch_value()\n#+end_src\n")
    (goto-char (point-min))
    (forward-line 1)
    (let ((original-document (buffer-string)))
      (codex-draft-comment
       (line-beginning-position) (line-end-position)
       "Where does this value come from?")
      (let ((comment (car codex-draft--comments)))
        (setq-local codex-draft--turn-kind 'comment-answer
                    codex-draft--active-comment comment)
        (codex-draft--insert-delta "It comes from the API.\nCheck for errors.")
        (should (string-search "# Codex: It comes from the API."
                               (buffer-string)))
        (should (string-search "# Check for errors." (buffer-string)))
        (should (equal original-document (codex-draft--document-text)))))))

(ert-deftest codex-draft-builds-a-focused-passage-revision-prompt ()
  (with-temp-buffer
    (insert "before alpha after")
    (let* ((overlay (make-overlay 8 13))
           (comment (list :overlay overlay
                          :text "Make this clearer"
                          :answer "Alpha needs a concrete example."))
           prompt
           kind)
      (setq-local codex-draft--comments (list comment))
      (goto-char 9)
      (cl-letf (((symbol-function 'codex-draft--record-current-version)
                 #'ignore)
                ((symbol-function 'codex-draft--start-turn)
                 (lambda (sent-prompt &optional sent-kind)
                   (setq prompt sent-prompt
                         kind sent-kind))))
        (codex-draft-revise-passage))
      (should (eq 'passage-revision kind))
      (should (string-search "<selected>\nalpha\n</selected>" prompt))
      (should (string-search
               "<comment>\nMake this clearer\n</comment>" prompt))
      (should (string-search "Alpha needs a concrete example" prompt))
      (should (string-search "<delete-passage/>" prompt)))))

(ert-deftest codex-draft-streams-a-revised-passage-in-place ()
  (with-temp-buffer
    (insert "before alpha after")
    (let* ((other-overlay (make-overlay 1 7))
           (other-comment (list :overlay other-overlay
                                :text "Keep this comment"
                                :answer ""))
           (target-overlay (make-overlay 8 13))
           (target-comment (list :overlay target-overlay
                                 :text "Rewrite this"
                                 :answer "")))
      (setq-local codex-draft--comments (list target-comment other-comment)
                  codex-draft--active-comment target-comment
                  codex-draft--passage-start (copy-marker 8)
                  codex-draft--passage-end (copy-marker 13 t)
                  codex-draft--turn-kind 'passage-revision
                  codex-draft--received-text nil)
      (codex-draft--insert-delta "revised")
      (codex-draft--insert-delta " passage")
      (should (equal "before revised passage after" (buffer-string)))
      (should-not (overlay-buffer target-overlay))
      (should (overlay-buffer other-overlay))
      (should (equal (list other-comment) codex-draft--comments)))))

(ert-deftest codex-draft-deletes-a-passage-when-requested ()
  (with-temp-buffer
    (insert "before alpha after")
    (let* ((overlay (make-overlay 8 13))
           (comment (list :overlay overlay
                          :text "You can remove this"
                          :answer "")))
      (setq-local codex-draft--comments (list comment)
                  codex-draft--active-comment comment
                  codex-draft--passage-start (copy-marker 8)
                  codex-draft--passage-end (copy-marker 13 t)
                  codex-draft--passage-response ""
                  codex-draft--turn-kind 'passage-revision
                  codex-draft--streaming t)
      (codex-draft--insert-delta "<delete-")
      (codex-draft--insert-delta "passage/>")
      (should (equal "before alpha after" (buffer-string)))
      (codex-draft--finish-passage-revision)
      (should (equal "before  after" (buffer-string)))
      (should-not codex-draft--comments))))

(ert-deftest codex-draft-restores-a-passage-when-revision-fails ()
  (with-temp-buffer
    (insert "before alpha after")
    (let* ((overlay (make-overlay 8 13))
           (comment (list :overlay overlay
                          :text "Rewrite this"
                          :answer "")))
      (overlay-put overlay 'help-echo "Rewrite this")
      (overlay-put overlay 'codex-draft-comment t)
      (setq-local codex-draft--comments (list comment)
                  codex-draft--active-comment comment
                  codex-draft--passage-start (copy-marker 8)
                  codex-draft--passage-end (copy-marker 13 t)
                  codex-draft--previous-state (codex-draft--snapshot-state)
                  codex-draft--streaming t
                  codex-draft--turn-kind 'passage-revision)
      (codex-draft--insert-delta "replacement")
      (codex-draft--stream-error "test failure")
      (should (equal "before alpha after" (codex-draft--document-text)))
      (should (= 1 (length codex-draft--comments)))
      (should (equal "Rewrite this"
                     (plist-get (car codex-draft--comments) :text)))
      (should-not codex-draft--passage-start)
      (should-not codex-draft--passage-end))))

(ert-deftest codex-draft-answers-all-unanswered-comments-in-document-order ()
  (with-temp-buffer
    (insert "alpha beta gamma")
    (let* ((first (list :overlay (make-overlay 1 6)
                        :text "Explain alpha"
                        :answer ""))
           (second (list :overlay (make-overlay 7 11)
                         :text "Explain beta"
                         :answer ""))
           (answered (list :overlay (make-overlay 12 17)
                           :text "Explain gamma"
                           :answer "Already answered"))
           (codex-draft--comments (list answered second first))
           (started nil))
      (cl-letf (((symbol-function 'codex-draft--start-comment-answer)
                 (lambda (comment)
                   (setq started (append started (list comment))))))
        (codex-draft-answer-comments)
        (should (eq first (car started)))
        (should (equal (list second) codex-draft--answer-queue))
        (codex-draft--finish-comment-answer)
        (should (equal (list first second) started))
        (should-not codex-draft--answer-queue)))))

(ert-deftest codex-draft-recovers-comments-left-visible-after-reload ()
  (with-temp-buffer
    (insert "alpha beta")
    (let ((overlay (make-overlay 1 6)))
      (overlay-put overlay 'help-echo "How does this work?")
      (overlay-put overlay 'after-string
                   "  ◀  How does this work?\n     Codex: An earlier answer.")
      (codex-draft--recover-comments)
      (should (= 1 (length codex-draft--comments)))
      (should (equal "How does this work?"
                     (plist-get (car codex-draft--comments) :text)))
      (should (equal "An earlier answer."
                     (plist-get (car codex-draft--comments) :answer)))
      (should (overlay-get overlay 'codex-draft-comment)))))

(ert-deftest codex-draft-revision-includes-comments-and-answers ()
  (with-temp-buffer
    (insert "alpha beta gamma")
    (let ((overlay (make-overlay 7 11)))
      (setq-local codex-draft--comments
                  (list (list :overlay overlay
                              :text "Explain this"
                              :answer "Beta is the second letter.")))
      (let ((prompt (codex-draft--revision-prompt nil)))
        (should (string-match-p "Comment: Explain this" prompt))
        (should (string-match-p
                 "Earlier answer: Beta is the second letter" prompt))))))

(ert-deftest codex-draft-submit-comments-starts-a-whole-document-turn ()
  (with-temp-buffer
    (insert "alpha beta gamma")
    (let ((overlay (make-overlay 7 11))
          prompt
          kind)
      (setq-local codex-draft--comments
                  (list (list :overlay overlay
                              :text "Explain this"
                              :answer "")))
      (cl-letf (((symbol-function 'codex-draft--record-current-version)
                 #'ignore)
                ((symbol-function 'codex-draft--start-turn)
                 (lambda (sent-prompt &optional sent-kind)
                   (setq prompt sent-prompt
                         kind sent-kind))))
        (codex-draft-submit-comments))
      (should (eq 'document kind))
      (should (string-match-p "Revise the Org document" prompt))
      (should (string-match-p "Comment: Explain this" prompt)))))

(ert-deftest codex-draft-versions-restore-comments-and-answers ()
  (with-temp-buffer
    (insert "version one")
    (let* ((overlay (make-overlay 1 8))
           (comment (list :overlay overlay
                          :text "Clarify this"
                          :answer "This is the first version.")))
      (setq-local codex-draft--comments (list comment))
      (codex-draft--record-current-version)
      (codex-draft-clear-comments)
      (erase-buffer)
      (insert "version two")
      (codex-draft--record-current-version)
      (codex-draft-previous-version)
      (should (equal "version one" (codex-draft--document-text)))
      (should (= 1 (length codex-draft--comments)))
      (should (equal "Clarify this"
                     (plist-get (car codex-draft--comments) :text)))
      (should (equal "This is the first version."
                     (plist-get (car codex-draft--comments) :answer))))))

(ert-deftest codex-draft-uses-codex-default-model-when-unset ()
  (with-temp-buffer
    (let ((default-directory temporary-file-directory)
          (codex-draft-directory nil)
          (codex-draft-model nil)
          request-params)
      (cl-letf (((symbol-function 'codex-draft--request)
                 (lambda (_method params _kind)
                   (setq request-params params))))
        (codex-draft--start-thread))
      (should-not (assq 'model request-params))
      (should (equal (expand-file-name temporary-file-directory)
                     (alist-get 'cwd request-params))))))

(ert-deftest codex-draft-sends-an-explicit-model ()
  (with-temp-buffer
    (let ((default-directory temporary-file-directory)
          (codex-draft-model "test-model")
          request-params)
      (cl-letf (((symbol-function 'codex-draft--request)
                 (lambda (_method params _kind)
                   (setq request-params params))))
        (codex-draft--start-thread))
      (should (equal "test-model" (alist-get 'model request-params))))))

(ert-deftest codex-draft-reload-key-does-not-shadow-an-org-binding ()
  (should-not (lookup-key org-mode-map (kbd "C-c r")))
  (should (eq #'codex-draft-reload
              (lookup-key codex-draft-mode-map (kbd "C-c r")))))

(ert-deftest codex-draft-passage-key-does-not-shadow-an-org-binding ()
  (should-not (lookup-key org-mode-map (kbd "C-c u")))
  (should (eq #'codex-draft-revise-passage
              (lookup-key codex-draft-mode-map (kbd "C-c u")))))

(ert-deftest codex-draft-normalizes-aligned-display-math ()
  (with-temp-buffer
    (insert "\\[\n\\begin{aligned}\n"
            "\\text{Revenue} &= \\$100\\text{B}, \\\\\n"
            "\\text{Net income} &= \\$20\\text{B}.\n"
            "\\end{aligned}\n\\]\n")
    (codex-draft--normalize-aligned-display-math)
    (should (equal
             (buffer-string)
             (concat "\\begin{align*}\n"
                     "\\text{Revenue} &= \\$100\\text{B}, \\\\\n"
                     "\\text{Net income} &= \\$20\\text{B}.\n"
                     "\\end{align*}\n")))))

(ert-deftest codex-draft-previews-display-math-without-inline-math ()
  (with-temp-buffer
    (org-mode)
    (insert "Inline: \\(x+y\\).\n\n"
            "\\begin{align*}\n"
            "x &= y + z\n"
            "\\end{align*}\n")
    (let ((codex-draft-preview-math 'display)
          previews)
      (cl-letf (((symbol-function 'org-clear-latex-preview) #'ignore)
                ((symbol-function 'org--latex-preview-region)
                 (lambda (start end)
                   (push (buffer-substring-no-properties start end) previews))))
        (codex-draft-refresh-math))
      (should (= 1 (length previews)))
      (should (string-match-p "begin{align\\*}" (car previews)))
      (should-not (string-match-p "x+y" (car previews))))))

(ert-deftest codex-draft-streams-answers-as-scrollable-temporary-text ()
  (with-temp-buffer
    (insert "alpha beta")
    (codex-draft-comment 1 6 "Explain alpha")
    (let ((comment (car codex-draft--comments)))
      (setq-local codex-draft--turn-kind 'comment-answer
                  codex-draft--active-comment comment)
      (codex-draft--insert-delta "First line.\nSecond line.")
      (should (string-match-p "Codex: First line" (buffer-string)))
      (should (string-match-p "Second line" (buffer-string)))
      (should (get-text-property
               (marker-position
                (overlay-get (plist-get comment :overlay)
                             'codex-draft-answer-start))
               'codex-draft-annotation))
      (should (equal "alpha beta" (codex-draft--document-text)))
      (should (equal "First line.\nSecond line."
                     (plist-get comment :answer))))))

(ert-deftest codex-draft-saves-without-temporary-answers ()
  (let ((file (make-temp-file "codex-draft-" nil ".org")))
    (unwind-protect
        (with-temp-buffer
          (insert "alpha beta")
          (setq buffer-file-name file)
          (codex-draft-comment 1 6 "Explain alpha")
          (let ((comment (car codex-draft--comments)))
            (setf (plist-get comment :answer) "A temporary answer.")
            (codex-draft--set-rendered-answer comment))
          (codex-draft--write-contents)
          (should (equal "alpha beta"
                         (with-temp-buffer
                           (insert-file-contents file)
                           (buffer-string)))))
      (delete-file file))))

(provide 'codex-draft-test)

;;; codex-draft-test.el ends here
