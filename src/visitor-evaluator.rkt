#lang s-exp rosette

(require "header.rkt" "ast.rkt" "visitor-interface.rkt")

(provide (all-defined-out))

(define symbolic-evaluator%
  (class* object% (visitor<%>)
    (super-new)
    (init-field num-cores)
    (define actors #f)
    (define actors* #f)
    (define backup-placeset #f)
    
    (define/public (visit ast)

      (define (evaluate-placeset)
        (let ([symplace-list (set->list (get-field body-placeset ast))])
          (set-field! body-placeset ast
                      (list->set 
                       (map (lambda (x) (evaluate-with-sol x)) 
                            symplace-list)))))
        
      (cond
       [(is-a? ast Livable%)
        (send ast to-concrete)
        (when (at-io? (get-field place ast))
              (set-field! place ast (sub1 num-cores))
              (when (is-a? ast Param%)
                    (set-field! place-type ast (sub1 num-cores))))
        ]

       [(is-a? ast LivableGroup%)
	(send ast to-concrete)
        ]

       [(is-a? ast For%)
        (let ([place (get-field place-list ast)])
          (if (list? place)
              (for ([p place])
                   (send p accept this))
              (send ast to-concrete)))

        (send (get-field body ast) accept this)
        (evaluate-placeset)]

       [(is-a? ast Num%)
        (send ast to-concrete)
        ;; convert io
        (when (at-io? (get-field place-type ast))
          (set-field! place-type ast (sub1 num-cores)))
        ]

       [(is-a? ast Array%)
        (send ast to-concrete)
        (send (get-field index ast) accept this)
        (send (get-field index ast) infer-place (get-field place-type ast))
        ]

       [(or (is-a? ast Var%) 
            (is-a? ast ProxyReturn%))
	;(pretty-display (format "EVALUATE: Var ~a" (send ast to-string)))
        (send ast to-concrete)
        ]

       [(is-a? ast UnaExp%)
        (send (get-field op ast) accept this)
        (send (get-field e1 ast) accept this)
        (send ast to-concrete)
        (send ast infer-place (get-field place-type ast))
        ]

       [(is-a? ast BinExp%)
        (define e1 (get-field e1 ast))
        (define e2 (get-field e1 ast))
        (send (get-field op ast) accept this)
        (send (get-field e1 ast) accept this)
        (send (get-field e2 ast) accept this)
        (send ast to-concrete)
        (send ast infer-place (get-field place-type ast))
        ]

       [(is-a? ast FuncCall%)
	(define func-ast (get-field signature ast))
        (define params (get-field stmts (get-field args func-ast)))
	(define name (get-field name ast))

        (for ([arg (flatten-arg (get-field args ast))])
	     (send arg accept this))
        (send ast to-concrete)

        ;; convert io                      
        (when (at-io? (get-field place-type ast))
              (set-field! place-type ast (sub1 num-cores)))
        
        (when (or (equal? name "in")
		  (equal? name "out")
                  (io-func? name))
              (send func-ast accept this))

	;; infer
	(for ([param params] ; signature
              [arg (flatten-arg (get-field args ast))]) ; actual
             (when
              (at-any? (get-field place-type arg))
              (cond
               [(hash-has-key? actors name)
                (define caller-place (cdar (hash-ref actors name)))
                (send arg infer-place caller-place)]
               
               [(hash-has-key? actors* name)
                (define caller-place (cdar (hash-ref actors* name)))
                (pretty-display `(infer ,name ,caller-place))
                (send arg infer-place caller-place)]

               [else
                (send arg infer-place (get-field place-type param))]
               )))
        ;; return can't be at any, so we don't need to infer return
        ]

       [(is-a? ast Assign%)
        (define lhs (get-field lhs ast))
        (define rhs (get-field rhs ast))
        (send lhs accept this)
        (send rhs accept this)
        (send lhs infer-place (get-field place-type rhs))
        (send rhs infer-place (get-field place-type lhs))
        ]

       [(is-a? ast Return%)
	;(pretty-display (format "EVALUATE: Return"))
	(define val (get-field val ast))
        (if (list? val)
	    (for ([x val])
		 (send x accept this))
	    (send val accept this))]

       [(is-a? ast If%)
        (send (get-field condition ast) accept this)
        (send (get-field true-block ast) accept this)
        (let ([false-block (get-field false-block ast)])
          (when false-block
              (send false-block accept this)))
        (evaluate-placeset)
        ]

       [(is-a? ast While%)
        (send (get-field pre ast) accept this)
        (send (get-field condition ast) accept this)
        (send (get-field body ast) accept this)
        (evaluate-placeset)
        ]

       [(is-a? ast Program%)
        (set! actors (get-field actors ast))
        (set! actors* (get-field actors* ast))

        (for ([stmt (get-field stmts ast)])
             (when (and (is-a? stmt FuncDecl%)
                        (equal? (get-field name stmt) "main"))
                   (set! backup-placeset
                         (for/set ([x (get-field body-placeset stmt)])
                                  (evaluate-with-sol x)))))
         
        (for ([stmt (get-field stmts ast)])
             (send stmt accept this))

        (set-field!
         conflict-list ast
         (for/list
          ([conflict (get-field conflict-list ast)])
          (for/list
           ([group conflict])
           (list->set
            (filter
             (lambda (x) (not (symbolic? x)))
             (for/list ([part group]) (evaluate-with-sol part)))))))
        
        (set-field!
         module-inits ast
         (for/list ([pair (get-field module-inits ast)])
                   (cons (list->set
                          (filter
                           (lambda (x) (not (symbolic? x)))
                           (for/list ([x (car pair)]) (evaluate-with-sol x))))
                         (cdr pair))
                   ))
                
        ]

       [(is-a? ast Block%)
        (for ([stmt (get-field stmts ast)])
             (send stmt accept this))
        ]

       [(is-a? ast FuncDecl%)
	;(pretty-display (format "EVALUATE: FuncDecl ~a" (get-field name ast)))
        (when (get-field return ast)
              (send (get-field return ast) accept this))
        (send (get-field args ast) accept this)
        (send (get-field body ast) accept this)
        (evaluate-placeset)

        ;; Assign caller-actor for actor* if not specified by the user.
        (define name (get-field name ast))
        (when (and (hash-has-key? actors* name)
                   (not (caar (hash-ref actors* name))))
              (define args (get-field stmts (get-field args ast)))
              (define return (get-field return ast))
              (define placeset (get-field body-placeset ast))
              (define caller
                (if return
                    (get-field place return)
                    (set-first (set-subtract backup-placeset placeset))))
              (define actor
                (if (empty? args)
                    (set-first (set-remove placeset caller))
                    (get-field place (car args))))
              (hash-set! actors* name (list (cons actor caller)))
              )
        ]

       [else (raise (format "Error: symbolic-evaluator unimplemented for ~a!" ast))]

       ))))
