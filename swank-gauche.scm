;;;; swank-gauche.scm --- SLIME server for Gauche
;;;
;;; Copyright (C) 2009-2011  Takayuki Suzuki
;;;
;;;   Redistribution and use in source and binary forms, with or without
;;;   modification, are permitted provided that the following conditions
;;;   are met:
;;;   
;;;   1. Redistributions of source code must retain the above copyright
;;;      notice, this list of conditions and the following disclaimer.
;;;  
;;;   2. Redistributions in binary form must reproduce the above copyright
;;;      notice, this list of conditions and the following disclaimer in the
;;;      documentation and/or other materials provided with the distribution.
;;;  
;;;   3. Neither the name of the authors nor the names of its contributors
;;;      may be used to endorse or promote products derived from this
;;;      software without specific prior written permission.
;;;  
;;;   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
;;;   "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
;;;   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
;;;   A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
;;;   OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
;;;   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
;;;   TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
;;;   PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
;;;   LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
;;;   NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
;;;   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
(define-module swank-gauche
  (export 
   ;; entry point
   swank start-swank)
  (use srfi-1)
  (use srfi-11)
  (use srfi-13)
  (use gauche.net)
  (use gauche.charconv)
  (use gauche.array)
  (use gauche.uvector)
  (use gauche.parameter)
  (use gauche.time)
  (use gauche.vport)
  (use gauche.collection)
  (use gauche.interactive)
  (use gauche.sequence)
  (use util.match)
  (use util.queue)
  (use util.stream)
  (use file.util)
  (use text.parse)
  )

(select-module swank-gauche)

(define (swank port)
  (make-swank-server (or port 4005) #f))
(define (start-swank port-file)
  (make-swank-server #f port-file))

;; inject repl symbols into gauche module
(with-module gauche
  (define *1 #f)
  (define *2 #f)
  (define *3 #f)
  (define %0 #f)
  (define %1 #f)
  (define %2 #f)
  (define %3 #f)
  (define /1 #f)
  (define /2 #f)
  (define /3 #f))

;;;; Auxilary functions
(define nil '())
(define t 't)
(define (elisp-false? o) (member o '(nil ())))
(define (elisp-true? o) (not (elisp-false? o)))
(define (to-elisp-bool o) (if o 't 'nil))
(define (id x) x)

(define (1+ n) (+ n 1))
(define (1- n) (- n 1))

(define (write-to-string/ss s) (write-to-string s write/ss))
(define (describe-to-string s)  (with-output-to-string (lambda () (describe s))))
(define pretty-printer write-to-string/ss)

(define (group2 rest)
    (if (null? rest)
	'()
	(cons (list (car rest) (cadr rest))
	      (group2 (cddr rest)))))

(define-macro (set!* . rest)
  `(begin
     ,@(map (lambda (var-val)
	      `(set! ,(car var-val) ,(cadr var-val)))
	    (group2 rest))))


;;;; logging
(define log-port #f)
;;(define log-port (current-output-port))
(define-macro (log-event fstring . args)
  `(when log-port
     (format log-port ,fstring ,@args)
     (flush log-port)))

;;;; Multi threading
(define (current-thread-id)
  1)

;;;; Networking
(define (make-swank-server port port-file)
  (let ((server   (make-server-socket (make <sockaddr-in>
                                        :host :loopback
                                        :port (or port 0))
				      :reuse-addr? #t)))

    (define (accept-handler sock)
      (let* ((client (socket-accept sock))
             (output (socket-output-port client))
             (input  (socket-input-port client :buffering #f)))
	(format #t #`"Client:,(sockaddr-name (socket-address client)) Start~%")
	(swank-receive client input output)
	(format #t #`"Client:,(sockaddr-name (socket-address client)) Closed~%")))
    (define (swank-receive client input output)
      (parameterize
          ((*emacs-input-port* input)
           (*emacs-output-port* output))
        (do ((packet (read-packet) (read-packet)))
	    ((eof-object? packet) (socket-close client))
	  (when (not (condition-type? packet))
	    (event-enqueue! packet)
	    (do ((event (event-dequeue!) (event-dequeue!)))
		((not event))
	      (dispatch-event event))))))

    (define (write-port-file portnumber filename)
      (call-with-output-file filename (lambda (p) (write portnumber p))))

    (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let* ((addr (socket-address server)))
            (format #t #`"Listening on port: ,(sockaddr-name addr) ~%")
            (when port-file
              (write-port-file (sockaddr-port addr) port-file)))
	  (accept-handler server))
        (lambda ()
          (format #t #`"Close Listening on port: ,(sockaddr-name (socket-address server))~%")
          (socket-close server)))))


;;;; Reading/Writing of SLIME packets
(define *emacs-input-port* (make-parameter #f))
(define *emacs-output-port* (make-parameter #f))
(define *emacs-packet-id* (make-parameter #f))

;;;; packet-queue
(define *event-queue* (make-queue))
(define *events-enqueued* 0)
(define (event-enqueue! packet)
  (enqueue! *event-queue* packet)
  (inc! *events-enqueued*))
(define (event-dequeue!)
  (if (not (queue-empty? *event-queue*))
      (dequeue! *event-queue*)
      #f))

(define (wait-for-event pattern . rest)
  (let ((timeout (get-optional rest #f)))
    (log-event "wait-for-event: ~s ~s~%" pattern timeout)
    (wait-for-event/event-loop pattern timeout)))

(define (wait-for-event/event-loop pattern timeout)
  ;; (assert (or (not timeout) (eq timeout t)))
  (let loop ()
    ;(check-slime-interrupts)
    (cond ((poll-for-event pattern) => id)
          ((read-packet) =>
           (lambda (packet)
             (cond ((eof-object? packet) (values nil t))
		   ((condition-type? packet) (values nil t))
                   ((event-match-p packet pattern) packet)
                   (else (dispatch-event packet)
                         ;; rescan event queue, interrupts may enqueue new events 
                         (loop))))))))

(define (poll-for-event pattern)
  (let ((event (find-in-queue (lambda (e) (event-match-p e pattern))
                              *event-queue*)))
    (if event
        (begin
          (remove-from-queue! (lambda (e) (eq? e event)) *event-queue*)
          event)
        #f)))

(define (event-match-p event pattern)
  (cond ((or (keyword? pattern) (number? pattern) (string? pattern)
	     (member pattern '(nil t)))
	 (equal? event pattern))
	((and (null? event) (null? pattern)) #t)
        ((symbol? pattern) #t)
	((pair? pattern)
         (case (car pattern)
           ((or) (any (lambda (p) (event-match-p event p)) (cdr pattern)))
           (else (and (pair? event)
                      (and (event-match-p (car event) (car pattern))
                           (event-match-p (cdr event) (cdr pattern)))))))
        (else (error "Invalid pattern: " pattern))))

;;;; send and receive processing
(define (read-packet)
  (define (read-len len in)
    (if (eof-object? len) len
	(let1 len* (read-block len in)
	  (if (eof-object? len*) len*
	      (string->number len* #x10)))))
  (define (read-packet len in)
    (if (eof-object? len) len
	(let1 packet* (read-string len in)
	  (if (eof-object? packet*) packet*
	      (read-from-string packet*)))))

  (guard (exc (else (report-error exc)
		    exc))
    (let* ((in (*emacs-input-port*))
           (len (read-len 6 in))
           (packet (read-packet len in)))
      (cond ((eof-object? len) len)
	    ((eof-object? packet) packet)
	    (else
	     (log-event "READ: [~a] ~s~%" len packet)
	     packet)))))

(define (write-packet message)
  (let* ((out (*emacs-output-port*))
	 (string (write-to-string/ss message)))
    (log-event "WRITE: [~a] ~s~%" (string-length string) string)
    (format out "~6,'0x" (string-length string))
    (display string out)
    (flush out)))

(define (send-to-emacs event)
  (dispatch-event event))

(define (write-return message)
  (send-to-emacs `(:return ,message ,(*emacs-packet-id*))))

(define (write-string message)
  (send-to-emacs `(:write-string ,message)))

(define (write-abort message . rest)
  (write-return (list :abort (apply format #f  message rest))))
(define (new-package module)
  (when (not (equal? (*buffer-package*) module))
    (*buffer-package* module)
    (let ((module-name (x->string module)))
      (send-to-emacs `(:new-package ,module-name ,module-name)))))

(define (send-event thread event)
  (log-event "send-event: ~s ~s~%" thread event)
  (event-enqueue! event))

(define (interrupt-worker-thread thread-id)
  (log-event "interrupt-worker-thread: ~a~%" thread-id)
  (error "interrupt-worker-thread: " thread-id)
  t)

;;
;; gauche module procedures
;;
(define *buffer-package* (make-parameter 'user))

(define (module-symbol package)
  (if (or (elisp-false? package) (not package))
      (*buffer-package*)
      (if (symbol? package)
          package
          (string->symbol package))))

(define (user-env name)
  (or (find-module (module-symbol name))
      (error "Could not find user environment." name)))

(define (all-modules->string-list)
  (map (lambda (m) (symbol->string (module-name m))) (all-modules)))


;;;; Event dispatching
(define (package:symbol->symbol symbol)
  (string->symbol
   (last (string-split (symbol->string symbol) #\:))))

(define (swank-gauche: symbol)
  (global-variable-ref 'swank-gauche
                       (package:symbol->symbol symbol)))

(define (swank-gauche:bound? symbol)
  (global-variable-bound? 'swank-gauche
                          (package:symbol->symbol symbol)))

(define (dispatch-event event)
  (log-event "dispatch-event: ~s~%" event)
  (match event
    ((:emacs-rex params ...) (apply emacs-rex params))
    ((:emacs-interrupt thread-id)
     (interrupt-worker-thread thread-id))
    (((or :write-string 
	   :debug :debug-condition :debug-activate :debug-return :channel-send
	   :presentation-start :presentation-end
	   :new-package :new-features :ed :%apply :indentation-update
	   :eval :eval-no-wait :background-message :inspect :ping
	   :y-or-n-p :read-string :read-aborted :return) params ...)
     (write-packet event))
    (_
     (log-event "Unknown event: ~s~%" event))))


(define (make-emacs-input-stream)
  (make <buffered-input-port>
    :fill (lambda (u8v)
            (let ((tag (make-tag)))
              (send-to-emacs `(:read-string ,(current-thread-id) ,tag))
              (let ((ok #f)
                    (str #f))
                (dynamic-wind
                    (lambda () #f)
                    (lambda ()
                      (set! str (cadddr (wait-for-event
                                         `(:emacs-return-string ,(current-thread-id) ,tag value))))
                      (string->u8vector! u8v 0 str)
                      (set! ok #t))
                    (lambda ()
                      (unless ok
                        (send-to-emacs `(:read-aborted ,(current-thread-id) ,tag)))))
                (string-size str))))))

(define (make-emacs-output-stream)
  (make <buffered-output-port>
    :flush (lambda (u8v flag)
             (write-string (u8vector->string u8v))
             (u8vector-length u8v))))

(define (with-input-from-repl fun)
  (let ((p (make-emacs-input-stream)))
    (dynamic-wind
        (lambda () #f)
        (lambda () (with-input-from-port p fun))
        (lambda ()
          (close-input-port p)))))

(define (with-output-to-repl fun)
  (let ((p (make-emacs-output-stream)))
    (dynamic-wind
        (lambda () #f)
        (lambda () (with-output-to-port p fun))
        (lambda ()
          (flush p)
          (close-output-port p)))))

(define (with-io-repl fun)
  (let ((out (make-emacs-output-stream))
        (in  (make-emacs-input-stream)))
    (dynamic-wind
        (lambda () #f)
        (lambda () (with-ports in out out fun))
        (lambda ()
          (flush out)
          (close-output-port out)
          (close-input-port in)))))
                
(define (emacs-rex sexp package thread id)
  (parameterize
      ((*emacs-packet-id* id)
       (*buffer-package* (module-symbol package)))
    (if (and (list? sexp)
	     (not (swank-gauche:bound? (car sexp))))
        (begin
	  (log-event "Not Impremented: ~s~%" (car sexp))
	  (write-abort "Not Impremented: ~s" (car sexp)))
        (with-error-handler
          (lambda (e)
            (with-io-repl (lambda () (report-error e))))
	  (lambda ()
	    (let ((ok #f))
	      (dynamic-wind
		  (lambda () #f)
		  (lambda () 
		    (write-return `(:ok ,(apply (swank-gauche: (car sexp))
						(cdr sexp))))
		    (set! ok #t))
		  (lambda ()
		    (unless ok
		      (write-abort "eval ~a" sexp))))))))))

(define (eval-region string)
  (let ((sexp (read-from-string string)))
    (if (eof-object? sexp)
        (values)
        (with-io-repl
            (lambda ()
              (eval sexp (user-env (*buffer-package*))))))))

(define (eval-repl string)
  (let ((sexp (read-from-string string)))
    (if (eof-object? sexp)
        (values)
        (with-io-repl
            (lambda ()
	      (set!* %3 %2
		     %2 %1
		     %1 %0
		     %0 sexp)
	      (match sexp
		(('select-module module) ;; select-module is special
		 (eval sexp (user-env (*buffer-package*)))
		 ((global-variable-ref 'swank-gauche 'new-package) module))
		(else
		 (eval sexp (user-env (*buffer-package*))))))))))

(define *tag-counter* (make-parameter 0))
(define (make-tag)
  (*tag-counter* (modulo (1+ (*tag-counter*)) (expt 2 22))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; Swank functions
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(define-macro (defslimefun name params :rest bodys)
  `(with-module swank-gauche
     (define (,name ,@params) ,@bodys)))

(defslimefun connection-info ()
  `(:pid ,(sys-getpid)
	 :package (:name "user" :prompt "user")
	 :features '()
	 :modules ,(all-modules->string-list)
	 :lisp-implementation (:type "Gauche" :version ,(gauche-version))
	 :version "2010-01-03"))

(defslimefun quit-lisp ()
  (exit))

(defslimefun swank-require (modules :optional filename)
  (all-modules->string-list))

(defslimefun create-repl (target)
  (list "user" "user"))

;;;; Evaluation
(defslimefun listener-eval (string)
  (call-with-values (lambda () (eval-repl string))
    (lambda ret
      (set!* /3 /2 *3 *2
	     /2 /1 *2 *1
	     /1 (if (null? ret) (values) ret)
	     *1 (if (null? ret) (values) (car ret)))
      `(:values . ,(map write-to-string/ss ret)))))

(defslimefun interactive-eval (string)
  (call-with-values (lambda () (eval-region string))
    format-values))

(define (format-values . values)
  (if (null? values) 
      "; No value"
      (call-with-output-string
        (lambda (out)
          (display "=> " out)
          (do ((vs values (cdr vs))) ((null? vs))
            (write (car vs) out)
            (if (not (null? (cdr vs)))
                (display ", " out)))))))

(defslimefun compile-string-for-emacs (string buffer position filename policy)
  ;; easy implemantation
  (let ((timer (make <real-time-counter>)))
    (with-time-counter timer
      (eval-region string))
    `(:compilation-result nil t ,(time-counter-value timer))))

;;;; Compilation
(define (module-symbols module)
  (hash-table-keys (module-table module)))

(define (module-exports% module)
  (if (eq? (module-exports module) #t)
      (module-symbols module)
      (module-exports module)))

(define (visible-symbols module)
  (map x->string
       (append (append-map module-symbols  (module-precedence-list module))
	       (append-map module-exports% (module-imports module)))))

(define (all-completions pattern env match?)
  (filter (lambda (s) (match? pattern s)) 
	  (visible-symbols env)))

(define (longest-common-prefix strings)
  (define (common-prefix s1 s2)
    (substring s1 0 (string-prefix-length s1 s2)))
  (reduce common-prefix "" strings))

(defslimefun simple-completions (string package)
  (let ((strings (all-completions string
                                  (user-env (cadr package))
                                  string-prefix?)))
    (list (sort strings string<?)
	  (longest-common-prefix strings))))

(define (c-p-c-match? pattern symbol)
  (define (iter patterns symbols)
    (cond ((null? patterns) #t)
          ((null? symbols) #f)
          (else
           (let ((p (car patterns))
                 (s (car symbols)))
             (if (not (string-prefix? p s)) #f
                 (iter (cdr patterns) (cdr symbols)))))))
  (let ((split-char #\-))
    (iter (string-split pattern split-char)
          (string-split symbol split-char))))

(defslimefun completions (string package)
  (let ((strings (all-completions string
                                  (user-env (cadr package))
                                  c-p-c-match?)))
    (list (sort strings string<?)
	  (longest-common-prefix strings))))

(defslimefun set-package (module)
  (*buffer-package* (module-symbol module))
  (list (x->string module) (x->string module)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; operator arg list
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(define (grep regex-str file proc)
  (let ((regex (string->regexp regex-str)))
    (with-input-from-file file
      (lambda ()
	(let loop ((acc '()))
	  (let ((l (read-line)))
	    (cond ((eof-object? l) (reverse acc))
		  (else (if (regex l)
			    (loop (cons (proc l) acc))
			    (loop acc))))))))))

(define *operator-args* '())
(define (load-operator-args gauche-refe-path)
  (set! *operator-args*
	(append (if gauche-refe-path
		    (grep "^@defun|^@defmac|^@defspec|^@deffn"
			  gauche-refe-path
			  (lambda (line)
			    (read-from-string
			     (regexp-replace-all* #`"(,line)"
						  #/@dots{}/ "..."
						  #/@code{(\S*)}/ "\\1"
						  #/@def\w+ / ""
						  #/:optional/ "&optional"
						  #/\[(.*)\]/ "&optional \\1"))))
		    '())
		*operator-args*)))

(define (load-gauche-operator-args gauche-source-path)
  (when (not (elisp-false? gauche-source-path))
    (load-operator-args #`",|gauche-source-path|/doc/gauche-refe.texi")))

(define (get-func-args op-sym a)
  (cond
   ((number? a) 
    (cons op-sym
	  (map (lambda (i)
		 (string->symbol #`"arg,i")) (iota a))))
   ((arity-at-least? a)
    (cons op-sym
	  (let loop ((i 0))
	    (if (>= i (arity-at-least-value a))
		(list '&rest 'rest)
		(cons (string->symbol #`"arg,i") (loop (1+ i)))))))))

(define (lookup-operator-args sym env)
  (let1 args (filter (lambda (form) (eq? sym (car form)))
		     *operator-args*)
    (if (not (null? args)) args
	(and-let* ((val (global-variable-ref env sym #f))
		   (not (procedure? val))
		   (a (arity val)))
	  (list (get-func-args sym 
			       (if (pair? a) (car a) a)))))))

(defslimefun operator-arglist (op-name module)
  (or (and-let* ((forms (lookup-operator-args (string->symbol op-name)
					      (user-env module))))
	(format #f "~a" (car forms)))
      (format #f "(~a ...)" op-name)))

(define +cursor-marker+ 'swank::%cursor-marker%)
(define-constant +special-symbols+ (list +cursor-marker+ 'nil 'quasiquote 'quote))
(define (parse-raw-form raw-form)
  (define  (read-conversatively element)
    (let ((sym (string->symbol element)))
      (if (symbol-bound? sym)
	  sym
	  element)))

  (map (lambda (element)
	 (cond ((string? element) (read-conversatively element))
	       ((list? element)  (parse-raw-form element))
	       ((symbol? element) (if (memq element +special-symbols+)
				      element
				      (error "unknown symbol" element)))
	       (else
		(error "unknown type" element))))
       raw-form))

(define (emphasis lis num)
  (cond ((null? lis) '())
	((eq? (car lis) '&rest) '(&rest ===> rest <===))
	((eq? (car lis) '...)   '(===> ... <===))
	((eq? (car lis) '&optional)
	 ;; skip optional-parameter indicator 
	 (cons '&optional (emphasis (cdr lis) num)))
	((<= num 0) `(===> ,(car lis) <=== ,@(cdr lis)))
	(else
	 (cons (car lis) (emphasis (cdr lis) (- num 1))))))

(define (contain-marker? sexp)
  (find-with-index (lambda (elem)
		     (if (list? elem)
			 (contain-marker? elem)
			 (or (equal? "" elem)
			     (eq? +cursor-marker+ elem)))) sexp))

(define (operator-and-makerindex sexp)
  (receive (index elem) (contain-marker? sexp)
	   (if index
	       (list (car sexp) index)
	       #f)))

(define (arglist-candidates form)
  (cond ((list? form)
	 (if-let1 candidate (operator-and-makerindex form)
		  (cons candidate
			(arglist-candidates
			 (ref form (cadr candidate))))
		  '()))
	(else '())))

(define (find-arglist form)
  (call/cc (lambda (return)
	     (for-each (lambda (candidate)
			 (cond ((symbol? (car candidate))
				(if-let1 found-args (lookup-operator-args (car candidate) (user-env #f))
					 (return (list (car found-args) (cadr candidate)))))
			       (else #f)))
		       (reverse (arglist-candidates form)))
	     #f)))

(defslimefun autodoc (raw-form :key 
			       (print-right-margin #f)
			       (print-lines #f))
  ;; create arglist
  (list
   (cond ((elisp-false? (cadr raw-form)) "")
	 ((find-arglist (parse-raw-form (cdr raw-form))) 
	  => (lambda (arglist)
	       (format #f "~a" (emphasis (car arglist)
					 (cadr arglist)))))
	 (else ""))
   t))

;; for backword compatibility
(define arglist-for-echo-area autodoc)

(defslimefun list-all-package-names (flag)
  (all-modules->string-list))

(define (string->macroexpand string expander)
  (let ((sexp (read-from-string string)))
    (if (eof-object? sexp)
        ""
        (pretty-printer
	 (eval `(,expander ',sexp) (user-env #f))))))

(defslimefun swank-macroexpand-1 (string)
  (string->macroexpand string 'macroexpand-1))

(defslimefun swank-macroexpand-all (string)
  (string->macroexpand string 'macroexpand))

(defslimefun default-directory ()
  (current-directory))

(defslimefun set-default-directory (path)
  (current-directory path)
  path)

(defslimefun compile-file-if-needed (filename loadp)
  (let ((ret #f))
    (with-io-repl
     (lambda ()
       (set! ret (load filename))))
    (to-elisp-bool ret)))

(defslimefun load-file (filename)
  (compile-file-if-needed filename #t))

(defslimefun compile-file-for-emacs (filename load-p :rest options)
  (let ((ret #f)
        (timer (make <real-time-counter>)))
    (with-time-counter timer
      (set! ret (compile-file-if-needed filename #f)))
    `(:compilation-result nil ret ,(time-counter-value timer))))

(defslimefun disassemble-form (quoted-form)
  (let ((form (string-copy quoted-form 1)))
    (with-output-to-string
      (lambda ()
	(disasm (eval (read-from-string form) (user-env #f)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; inspector
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(define (label-value-line label value :key (newline #t) (string #f))
  (list* (x->string label) ": " `(:value ,value ,string)
	 (if newline '((:newline)) '())))

(define-macro (label-value-line* . label-values)
  `(append ,@(map (match-lambda 
		   ((label value ... )
		    `(label-value-line ,label ,@value)))
		  label-values)))

(define (iline label value)
  `(:line ,label ,value))


(define *inspector-verbose* (make-parameter #f))
(define *istate* (make-parameter #f))
(define *inspector-history* (make-parameter '()))
(define *inspector-verbose* (make-parameter #f))

(define-class <inspector-state> ()
  ((object :init-keyword :object :accessor istate.object)
   (verbose :accessor istate.verbose
	    :init-form (*inspector-verbose*))
   (parts   :accessor istate.parts
	    :init-form (make-queue))
   (actions :accessor istate.actions
	    :init-form (make-queue))
   (content :init-keyword :content :accessor istate.content)
   (next    :init-form #f :accessor istate.next)
   (previous :init-keyword :previous :accessor istate.previous)))


(define-generic emacs-inspect)
(define-method emacs-inspect ((o <top>))
  (let* ((class (class-of o))
	 (slots (class-slots class)))
    `("Don't know how to inspect the object, use describe." (:newline)
      (:value ,o) " is an instance of class " (:value ,class) (:newline)
      (:newline)
      ,@(if (null? slots)
	    '("no slots")
	    (append-map
	     (lambda (s)
	       `(,(format #f " ~10s: " s)
		  ,(if (slot-bound? o s)
		       `(:value ,(slot-ref o s))
		       "#<unbound>") (:newline)))
	     (map slot-definition-name slots))))))

(define (cl-list? o)
  (or (pair? o) (null? o)))

(define-method emacs-inspect ((o <pair>))
  (if (cl-list? (cdr o))
      (inspect-list o)
      (inspect-cons o)))

(define (inspect-cons cons-cell)
  `("Cons cell" (:newline)
    ,@(label-value-line*
       (:car (car cons-cell))
       (:cdr (cdr cons-cell)))))

(define (inspect-list lis)
  (let-values (((length tail) (safe-length lis)))
    (define (frob title lis)
      (list* title '(:newline) (inspect-list-aux lis)))
    (cond ((not length)
	   `("A circular list: show first pair" (:newline)
	     ,@(inspect-cons lis)))
	  ((null? tail)
	   (frob "A proper list:" lis))
	  (else
	   (frob "An improper list:" lis)))))

(define (inspect-list-aux lis)
  (define (iter i rest)
    (if (not (pair? rest))
	'()
	(append
	 (if (cl-list? (cdr rest))
	     (label-value-line i (car rest))
	     (label-value-line* (i (car rest))
				(:tail (cdr rest))))
	 (iter (+ i 1) (cdr rest)))))
  (iter 0 lis))


;;; Hashtables
(define (make-compare-func func key)
  (lambda (x y)
    (let ((xx (key x))
	  (yy (key y)))
      (func xx yy))))

(define (or-pred val . preds)
  (define (iter pred)
    (cond ((null? pred) #t)
	  (((car pred) val) #t)
	  (else (iter (cdr pred)))))
  (iter preds))

(define-method emacs-inspect ((ht <hash-table>))
  (append
   (label-value-line*
    ("Count" (hash-table-num-entries ht))
    ("Type"  (hash-table-type ht)))
   (if (not (zero? (hash-table-num-entries ht)))
       `((:action "[clear hashtable]"
		  ,(lambda () (hash-table-clear! ht)))
	 (:newline)
	 "Contents: " (:newline))
       '((:newline)))
   (let ((content (hash-table-map ht cons)))
     (cond ((every (lambda (x) (or-pred (first x) string? symbol?)) content)
	    (set! content (sort content (make-compare-func 
					  string<?
					  (lambda (x) (x->string (first x)))))))
	   ((every (lambda (x) (number? (first x))) content)
	    (set! content (sort content (make-compare-func < first)))))
     (append-map (lambda (key-val)
		   (let ((key (car key-val))
			 (val (cdr key-val)))
		     `((:value ,key) " = " (:value ,val)
		       " " (:action "[remove entry]"
				    ,(let ((key key))
				       (lambda () (hash-table-delete! ht key))))
		       (:newline))))
		 content))))

;;;; Arrays
(define (row-major-array-index array index)
  (define (get-index ind-obj ind-val r)
    (if (< r 0)
	ind-obj
	(begin
	  (vector-set! ind-obj r (+ (modulo ind-val (array-length array r))
				    (array-start array r)))
	  (get-index ind-obj (floor->exact (/ ind-val (array-length array r))) (1- r)))))
  (get-index (make-vector (array-rank array)) index (1- (array-rank array))))

(define (row-major-array-ref array index)
  (array-ref array (row-major-array-index array index)))

(define-method emacs-inspect ((array <array>))
  (stream-cons*
   (iline "Rank" (array-rank array))
   (iline "Shape" (array-shape array))
   (iline "Size" (array-size array))
   "Contents:" '(:newline)
   (let k ((i 0) (max (array-size array)))
     (cond ((= i max) stream-null)
	   (else
	    (stream-cons (iline (row-major-array-index array i)
				(row-major-array-ref array i))
			 (k (1+ i) max)))))))

;;;; Chars	       
(define-method emacs-inspect ((c <char>))
  (append
   (label-value-line*
    ("Integer code" (char->integer c))
    ("UCS point code" (char->ucs c))
    ("UCS point code(Hex)" (char->ucs c)
     :string #`"#x,(number->string (char->ucs c) 16)")
    ("Lower cased" (char-downcase c))
    ("Upper cased" (char-upcase c)))))
    
;;;; Number
(define-method emacs-inspect ((n <number>))
  (append
   (list
    (cond ((integer? n) 
	   (string-append
	    "An "
	    (if (exact? n) "Exact " "Inexact ")
	    (if (bignum? n) "Bignum " "Fixnum ")
	    "Integer Number"))
	  ((rational? n)
	   (string-append
	    "An "
	    (if (exact? n) "Exact " "Inexact ")
	    "Rational Number"))
	  ((real? n)    "A Real Number")
	  ((complex? n) "A Complex Number")
	  (else         "A Number")))
   '((:newline)(:newline))
   (label-value-line*
    ("Zero?"  (zero? n))
    ("Abs"    (abs n)))
   '((:newline))
   (if (and (integer? n) (exact? n) (>= n 0))
       (label-value-line*
	("Hex" n :string #`"#x,(number->string n 16)")
	("Oct" n :string #`"#o,(number->string n 8)")
	("Bin" n :string #`"#b,(number->string n 2)"))
       '())))

;;;; Strings
(define-method emacs-inspect ((str <string>))
  (append
   (list
    (if (string-immutable? str)
	"An Immutable "
	"A Mutable ")
    (if (string-incomplete? str)
	"Incomplete "
	"")
    "String")
   '((:newline)(:newline))
   (label-value-line*
    ("Length" (string-length str))
    ("Size"   (string-size   str)))
   (let ((num -1))
     (append-map (lambda (char)
		   (inc! num)
		   `("["(:value ,num)"] = " (:value ,char)
		     (:newline)))
		 (string->list str)))))

;;;; Booleans
(define-method emacs-inspect ((bool <boolean>))
  (list
   "Boolean value : "
   (if bool "True" "False")))


(define (safe-length lis)
;; Similar to `list-length', but avoid errors on improper lists.
;; Return two values: the length of the list and the last cdr.
;; Return #f if LIST is circular.
  (define (iter n		;Counter.
		fast		;Fast pointer: leaps by 2.
		slow)		;Slow pointer: leaps by 1.
    (cond ((null? fast) (values n '()))
	  ((not (pair? fast)) (values n fast))
	  ((null? (cdr fast)) (values (1+ n) (cdr fast)))
	  ((and (eq? fast slow) (> n 0)) (values #f #f))
	  ((not (pair? (cdr fast))) (values (1+ n) (cdr fast)))
	  (else
	   (iter (+ n 2) (cddr fast) (cdr slow)))))
  (iter 0 lis lis))

(define (reset-inspector)
  (*istate* #f)
  (*inspector-history* (make-queue)))

(defslimefun init-inspector (str)
  (reset-inspector)
  (inspect-object (eval-region str)))

(define (inspect-object o)
  (let ((previous (*istate*))
	(content (emacs-inspect o)))
    (unless (find (cut eq? o <>) (*inspector-history*))
      (enqueue! (*inspector-history*) o))
    (*istate* (make <inspector-state>
		:object o
		:previous previous
		:content content))
    (if previous (set! (istate.next previous) (*istate*)))
    (istate>elisp (*istate*))))

(define (assign-index object queue)
  (let ((index (queue-length queue)))
    (enqueue! queue object)
    index))

(define (stream-range stream start end)
  (stream-take-safe (stream-drop-safe stream start) (- end start)))

(define (content-range lis start end)
  (cond
   ((stream? lis)
    (stream->list (stream-range lis start end)))
   ((pair? lis)
    (let ((len (length lis)))
      (subseq lis start (min len end))))))

(define (prepare-part part istate)
  (let ((newline (string #\newline)))
    (cond
     ((string? part) (list part))
     ((pair? part)
      (match part
	((:newline) (list newline))
	((:value obj rest ...)
	 (let-optionals* rest ((str #f))
	   (list (value-part obj str (istate.parts istate)))))
	((:action label lambda rest ...)
	 (let-keywords rest ((refreshp #t))
	   (list (action-part label lambda refreshp
			      (istate.actions istate)))))
	((:line label value)
	 (list (write-to-string/ss label) ": "
	       (value-part value #f (istate.parts istate))
	       newline))))
     (else (error "prepare-part: Malformed part" part)))))

(define (value-part object string parts)
  (list :value
	(or string (write-to-string/ss object))
	(assign-index object parts)))

(define (action-part label lambda refreshp actions)
  (list :action label (assign-index (list lambda refreshp)
				    actions)))

(define (prepare-range istate start end)
  (let* ((range (content-range (istate.content istate) start end))
         (ps (append-map (lambda (part)
				  (prepare-part part istate))
				range)))
    (list ps 
          (if (< (length ps) (- end start))
              (+ start (length ps))
              (+ end 1000))
          start end)))

(define (istate>elisp istate)
  (list :title (if (istate.verbose istate)
		   (write-to-string/ss (istate.object istate))
		   (let1 s (write-to-string/ss (istate.object istate))
		     (if (<= (string-length s) 128)
			 s
			 #`",(string-take s 128) ...")))
	:id (assign-index (istate.object istate)
			  (istate.parts istate))
	:content (prepare-range istate 0 500)))

(define (queue-nth queue index)
  (let ((n 0))
    (find-in-queue (lambda (elm)
		     (if (= n index) #t
			 (begin (inc! n)
				#f)))
		   queue)))

(defslimefun inspector-nth-part (index)
  (queue-nth (istate.parts (*istate*)) index))

(defslimefun inspect-nth-part (index)
  (inspect-object (inspector-nth-part index)))

(defslimefun inspector-reinspect ()
  (set! (istate.content (*istate*))
        (emacs-inspect (istate.object (*istate*))))
  (istate>elisp (*istate*)))

(defslimefun inspector-toggle-verbose ()
  (set! (istate.verbose (*istate*))
	(not (istate.verbose (*istate*))))
  (istate>elisp (*istate*)))

(defslimefun inspector-call-nth-action (index :rest args)
  (match (queue-nth (istate.actions (*istate*)) index)
    ((fun refreshp)
     (apply fun args)
     (if refreshp
	 (inspector-reinspect)
	 nil))))

(defslimefun inspector-range (from to)
  (prepare-range (*istate*) from to))

(defslimefun inspector-pop ()
  "Inspect the previous object.
Return nil if there's no previous object."
  (cond ((istate.previous (*istate*))
	 (*istate* (istate.previous (*istate*)))
	 (istate>elisp (*istate*)))
	(else nil)))

(defslimefun inspector-next ()
  "Inspect the next element in the history of inspected objects.."
  (cond ((istate.next (*istate*))
	 (*istate* (istate.next (*istate*)))
	 (istate>elisp (*istate*)))
	(else nil)))
	 
(defslimefun quit-inspector ()
  (reset-inspector)
  nil)

(defslimefun describe-inspectee ()
  "Describe the currently inspected object."
  (describe-to-string (istate.object *istate*)))

(defslimefun describe-symbol (symbol-name)
  (describe-to-string (string->symbol symbol-name)))

(defslimefun describe-function (name)
  ;; in scheme, function and variable in same namespace.
  (describe-symbol name))
