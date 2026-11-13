;;; codex-draft-test.el --- Tests for Codex Draft -*- lexical-binding: t; -*-

(require 'ert)
(require 'codex-draft)

(ert-deftest codex-draft-builds-targets-in-document-order ()
  (with-temp-buffer
    (insert "alpha\nbeta\ngamma\n")
    (let* ((first (make-overlay 1 6))
           (second (make-overlay 12 17))
           (codex-draft--comments
            (list (list :overlay second :text "Explain gamma")
                  (list :overlay first :text "Clarify alpha")))
           (targets (codex-draft--comment-targets)))
      (should (= 2 (length targets)))
      (should (equal "alpha" (plist-get (nth 0 targets) :text)))
      (should (equal "gamma" (plist-get (nth 1 targets) :text)))
      (should (= 1 (plist-get (nth 0 targets) :id)))
      (should (= 2 (plist-get (nth 1 targets) :id))))))

(ert-deftest codex-draft-applies-only-targeted-text ()
  (with-temp-buffer
    (insert "alpha beta gamma")
    (setq-local codex-draft-preview-math nil
                codex-draft-read-only-by-default t
                codex-draft--streaming t
                codex-draft--revision-targets
                (list (list :id 1 :replacement nil :start 7 :end 11))
                codex-draft--response-text
                "{\"replacements\":[{\"id\":1,\"text\":\"BETA\"}]}")
    (codex-draft--apply-targeted-revision)
    (should (equal "alpha BETA gamma" (buffer-string)))
    (should buffer-read-only)
    (should-not codex-draft--streaming)))

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

(provide 'codex-draft-test)

;;; codex-draft-test.el ends here
