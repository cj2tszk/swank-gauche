;; -*- mode: emacs-lisp -*-
;; swank-gaucheを使うためのSLIME設定
;;

(defun gauche-init (file encoding)
  (format "%S\n\n"
          `(begin
	    (add-load-path ,swank-gauche-path)
	    (require "swank-gauche")
	    (with-module swank-gauche
	       (load-gauche-operator-args ,swank-gauche-gauche-source-path)
	       (start-swank ,file)))))

(defun gauche ()
  "Gaucheを開始します"
  (interactive)
  (slime 'gauche))

;; `find-gauche-package' はバッファが属するモジュールを
;; "(select-module foo)" フォームを探して推定します。
;; モジュール化されたGaucheのプログラムソースファイルは
;; 大体select-moduleフォームを含んでいます。
(defun find-gauche-package ()
  (interactive)
  (let ((case-fold-search t)
	(regexp (concat "^(select-module\\>[ \t']*"
			"\\([^)]+\\)[ \t]*)")))
    (save-excursion
      (if (or (re-search-backward regexp nil t)
	      (re-search-forward regexp nil t))
	  (match-string-no-properties 1)
	(slime-search-buffer-package)))))

(defun gauche-ref-lookup ()
  (interactive)
  (browse-url
   (format "http://practical-scheme.net/gauche/man/?l=jp&p=%s" (thing-at-point 'symbol))))

(provide 'swank-gauche)