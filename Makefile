EMACS ?= emacs

.PHONY: check compile test clean

check: compile test

compile:
	$(EMACS) -Q --batch -L . -f batch-byte-compile codex-draft.el

test:
	$(EMACS) -Q --batch -L . -l test/codex-draft-test.el \
		-f ert-run-tests-batch-and-exit

clean:
	rm -f *.elc test/*.elc
