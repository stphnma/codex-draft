# Codex Draft

Codex Draft is an Emacs package for researching and revising living Org documents
with Codex. Give it a topic, question, paper, or URL and it streams a researched
draft into a normal Org buffer. Add comments to lines or regions, then ask Codex
to update only those passages.

## Requirements

- Emacs 27.1 or newer
- Org 9.4 or newer
- [Codex CLI](https://github.com/openai/codex), installed and authenticated
- LaTeX and `dvisvgm` for optional equation previews

Codex Draft uses your existing Codex CLI login. It starts a local Codex
app-server for each draft buffer and communicates with it over standard input and
output. The model still runs through OpenAI; the app-server is not a local model.

## Installation

With Emacs 29 or newer:

```elisp
(package-vc-install
 '(codex-draft :url "https://github.com/stphnma/codex-draft"))
```

With `use-package` in Emacs 30 or newer:

```elisp
(use-package codex-draft
  :vc (:url "https://github.com/stphnma/codex-draft"
       :rev :newest)
  :commands codex-draft)
```

For a local checkout:

```elisp
(add-to-list 'load-path "/path/to/codex-draft")
(require 'codex-draft)
```

## Usage

Run `M-x codex-draft` and enter a URL, topic, or question such as `How does Ray
work?`. Codex researches the request with web search and streams an Org document
into a new buffer.

Codex Draft begins in comment mode, which keeps the generated text read-only.

| Key | Action |
| --- | --- |
| `C-c C-c` | Comment on the selected region or current line |
| `C-c C-s` | Submit all comments and update only their regions |
| `C-c C-d` | Remove the comment under the cursor |
| `C-c C-k` | Remove every pending comment |
| `C-c C-r` | Request a full-document revision |
| `C-c C-e` | Toggle direct editing |
| `C-c C-m` | Refresh LaTeX previews |
| `C-c C-g` | Cancel the active request |

Save a draft with the normal Emacs commands. Reopen the Org file, enable
`codex-draft-mode`, and comments and revisions will work in the existing document.

## Configuration

By default, Codex Draft uses the model and working directory already configured
for Codex.

```elisp
;; Override the configured Codex model.
(setq codex-draft-model "MODEL_NAME")

;; Always start Codex in a particular directory.
(setq codex-draft-directory "~/notes/")

;; Disable automatic LaTeX previews.
(setq codex-draft-preview-math nil)
```

The `codex-draft-command` option contains the exact command used to launch the
app-server. Its default is:

```elisp
("codex" "--search" "app-server" "--listen" "stdio://")
```

## Data and permissions

Topics, document text, and submitted comments are sent through Codex to OpenAI.
Codex Draft enables web search and runs the Codex thread in a read-only sandbox.
Codex may use read-only commands while researching, but it cannot modify files.

## License

MIT
