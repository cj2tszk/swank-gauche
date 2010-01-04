;; -*- mode: emacs-lisp -*-
;; swank-gaucheを使うためのSLIME設定
;;
(push "<path-to-slime-dir>" load-path)
(require 'slime)
(slime-setup
 '(slime-fancy
   slime-scheme))

;; swank-gauche.scmが格納されているディレクトリへのパスを設定して下さい。
(setq swank-gauche-path "<path-to-swank-gauche-dir>")

;; Gaucheのソースを持っていて、かつ、コンパイル済の場合、ソースのトップ
;; ディレクトリへのパスを設定して下さい。Gaucheのマニュアルに記載されている
;; オペレータの引数名がルックアップ出来るようになります。
(setq swank-gauche-gauche-source-path nil)

(push swank-gauche-path load-path)
(require 'swank-gauche)

(setq slime-lisp-implementations
      '((gauche ("gosh") :init gauche-init :coding-system utf-8-unix)))

;; バッファのモジュールを決定するための設定
(setq slime-find-buffer-package-function 'find-gauche-package)
;; c-p-c補完に設定
(setq slime-complete-symbol-function 'slime-complete-symbol*)
;; web上のGaucheリファレンスマニュアルを引く設定
(define-key slime-mode-map (kbd "C-c C-d H") 'gauche-ref-lookup)
