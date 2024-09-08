(setq inhibit-startup-message t)

(menu-bar-mode -1)
(tool-bar-mode -1)
(scroll-bar-mode -1)
(set-fringe-mode 10)
;(setq visible-bell t)

;; Display line numbers in every buffer
(global-display-line-numbers-mode 1)
(setq user-emacs-directory "~/.config/emacsud")

;(set-face-attribute 'default nil :font "Fira Code" :height 150)
(setq default-frame-alist '((font . "spleen-20")))

;; Disable line numbers for some modes
(dolist (mode '(org-mode-hook
                term-mode-hook
                shell-mode-hook
                treemacs-mode-hook
                eshell-mode-hook))
  (add-hook mode (lambda () (display-line-numbers-mode 0))))

;; Make ESC quit prompts
(global-set-key (kbd "<escape>") 'keyboard-escape-quit)

;; Initialise straight.el
(defvar bootstrap-version)
(let ((bootstrap-file
       (expand-file-name "straight/repos/straight.el/bootstrap.el" user-emacs-directory))
      (bootstrap-version 6))
  (unless (file-exists-p bootstrap-file)
    (with-current-buffer
        (url-retrieve-synchronously
         "https://raw.githubusercontent.com/radian-software/straight.el/develop/install.el"
         'silent 'inhibit-cookies)
      (goto-char (point-max))
      (eval-print-last-sexp)))
  (load bootstrap-file nil 'nomessage))
(setq package-enable-at-startup nil)

(setq package-archives '(("melpa" . "https://melpa.org/packages/")
                         ("org" . "https://orgmode.org/elpa/")
                         ("elpa" . "https://elpa.gnu.org/packages/")))

;(setq backup-directory-alist '((".*" . "~/.config/emacs/backup")))
(setq backup-diretory-alist
          `(("." . ,(concat user-emacs-directory "backups"))))

(straight-use-package 'use-package)

; Always apply flyspell on buffer when flyspell-mode is enabled.
(add-hook 'flyspell-mode-hook 'flyspell-buffer)

(use-package straight
             :custom (straight-use-package-by-default t))

;(use-package fira-code-mode
;  :config (global-fira-code-mode))

(use-package all-the-icons
  :if (display-graphic-p))

(use-package command-log-mode)

(use-package ivy
  :diminish
  :bind (("C-s" . swiper)
         :map ivy-minibuffer-map
         ("TAB" . ivy-alt-done)
         ("C-l" . ivy-alt-done)
         ("C-j" . ivy-next-line)
         ("C-k" . ivy-previous-line)
         :map ivy-switch-buffer-map
         ("C-k" . ivy-previous-line)
         ("C-l" . ivy-done)
         ("C-d" . ivy-switch-buffer-kill)
         :map ivy-reverse-i-search-map
         ("C-k" . ivy-previous-line)
         ("C-d" . ivy-reverse-i-search-kill))
  :config
  (ivy-mode 1))

(use-package doom-modeline
  :init (doom-modeline-mode 1)
  :custom (
		   (doom-modeline-height 15)
		   (doom-modeline-lsp t)))


(use-package lsp-mode
  :hook (
		 (python-mode . lsp)
		 (go-mode . lsp)
		 (python-mode . lsp)
		 )
  :commands lsp
)
(use-package lsp-ui :commands lsp-ui-mode)
(use-package lsp-ivy :commands lsp-ivy-workspace-symbol)

;; languages
(use-package nix-mode
  :mode "\\.nix\\'")
(use-package go-mode)
(use-package rust-mode)
(use-package python-mode)
(use-package json-mode)
(use-package kotlin-mode)
(use-package sml-mode)
(use-package yaml-mode)
(use-package lua-mode)
(use-package markdown-mode)
(use-package lsp-java)
(add-hook 'java-mode-hook #'lsp)

;; Evil and related packages
(use-package undo-tree)
(global-undo-tree-mode)
(setq undo-tree-history-directory-alist '(("." . "~/.config/emacs/undo")))


(use-package evil
  :init
  (setq evil-want-integration t)
  (setq evil-want-keybinding nil)
  (setq evil-want-C-u-scroll t)
  (setq evil-want-C-i-jump nil)
  (setq evil-undo-system 'undo-tree)
  :config
  (evil-mode 1)
  (define-key evil-insert-state-map (kbd "C-g") 'evil-normal-state)
  (define-key evil-insert-state-map (kbd "C-h") 'evil-delete-backward-char-and-join)

  ;; Use visual line motions even outside of visual-line-mode buffers
  (evil-global-set-key 'motion "j" 'evil-next-visual-line)
  (evil-global-set-key 'motion "k" 'evil-previous-visual-line)

  (evil-set-initial-state 'messages-buffer-mode 'normal)
  (evil-set-initial-state 'dashboard-mode 'normal))

(use-package evil-collection
  :after evil
  :config
  (evil-collection-init))

(use-package evil-surround
  :after evil
  :config
  (global-evil-surround-mode 1))

(use-package evil-numbers
  :after evil)
(global-set-key (kbd "C-a") 'evil-numbers/inc-at-pt)
(global-set-key (kbd "C-c +") 'evil-numbers/inc-at-pt)
(global-set-key (kbd "C-c -") 'evil-numbers/dec-at-pt)

(use-package evil-org
  :after evil)

(use-package rainbow-delimiters
  :hook (prog-mode . rainbow-delimiters-mode))

(use-package rainbow-mode
  :config
  (rainbow-mode))

(use-package which-key
  :defer 0
  :diminish which-key-mode
  :config
  (which-key-mode)
  (setq which-key-idle-delay 1))


(use-package magit)

;(use-package auctex)

(use-package editorconfig
  :ensure t
  :config
  (editorconfig-mode 1))

;(use-package org-plus-contrib)
(use-package org
  :ensure org-plus-contrib)

(use-package org-ql)

(use-package org-roam
  :custom
  (org-roam-directory (file-truename "~/wiki"))
  :bind (("C-c n l" . org-roam-buffer-toggle)
         ("C-c n f" . org-roam-node-find)
         ("C-c n g" . org-roam-graph)
         ("C-c n i" . org-roam-node-insert)
         ("C-c n c" . org-roam-capture)
         ;; Dailies
         ("C-c n j" . org-roam-dailies-capture-today))
  :config
  ;; If you're using a vertical completion framework, you might want a more informative completion interface
  ;(setq org-roam-node-display-template (concat "${title:*} " (propertize "${tags:10}" 'face 'org-tag)))
  (org-roam-db-autosync-mode)
  ;; If using org-roam-protocol
  (require 'org-roam-protocol))


(add-hook 'org-mode-hook (lambda ()
   "Beautify Org Checkbox Symbol"
   (push '("[ ]" .  "☐") prettify-symbols-alist)
   (push '("[X]" . "☑" ) prettify-symbols-alist)
   (push '("[-]" . "❍" ) prettify-symbols-alist)
   (prettify-symbols-mode)))

(use-package toc-org)
(add-hook 'org-mode-hook 'toc-org-mode)

(use-package org-bullets)
(add-hook 'org-mode-hook (lambda () (org-bullets-mode 1)))

(setq org-agenda-files (list "~/wiki/agenda.org"))

(setq org-todo-keywords
      '((sequence
         "TODO(t)"  ; A task that needs doing & is ready to do
         "PROJ(p)"  ; A project, which usually contains other tasks
         "LOOP(r)"  ; A recurring task
         "STRT(s)"  ; A task that is in progress
         "WAIT(w)"  ; Something external is holding up this task
         "HOLD(h)"  ; This task is paused/on hold because of me
         "IDEA(i)"  ; An unconfirmed and unapproved task or notion
         "|"
         "DONE(d)"  ; Task successfully completed
         "KILL(k)") ; Task was cancelled, aborted or is no longer applicable
        (sequence
         "[ ](T)"   ; A task that needs doing
         "[-](S)"   ; Task is in progress
         "[?](W)"   ; Task is being held up or paused
         "|"
         "[X](D)")  ; Task was completed
        (sequence
         "|"
         "OKAY(o)"
         "YES(y)"
         "NO(n)"))
      org-todo-keyword-faces
      '(("[-]"  . +org-todo-active)
        ("STRT" . +org-todo-active)
        ("[?]"  . +org-todo-onhold)
        ("WAIT" . +org-todo-onhold)
        ("HOLD" . +org-todo-onhold)
        ("PROJ" . +org-todo-project)
        ("NO"   . +org-todo-cancel)
        ("KILL" . +org-todo-cancel)))

;(straight-use-package
; '(org-sort-tasks :type git :host github :repo "felipelalli/org-sort-tasks"))

; bell
;(setq org-clock-sound "~/inbox/web/ding.mp3") ;; this sounds corrupted

;; Setup autowrap
(setq fill-column 80)
(add-hook 'text-mode-hook #'auto-fill-mode)
(add-hook 'prog-mode-hook #'auto-fill-mode)
(setq auto-fill-mode 1)
(setq column-number-mode t)
(load-theme 'humaid t)
