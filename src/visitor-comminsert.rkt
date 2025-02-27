#lang racket

(require "header.rkt"
         "ast.rkt" "ast-util.rkt"
         "visitor-interface.rkt"
         "layout-sa.rkt" "routing.rkt"
         )

(provide commcode-inserter%)

;; 1) Insert communication route to send-path field.
;; 2) Convert partition ID to actual core ID.
;; Note: this visitor mutates AST.
(define commcode-inserter%
  (class* object% (visitor<%>)
    (super-new)
    (init-field routing-table part2core w h obstacles conflict-list
                actors actors*-no-cf-map actor-index cores)
    ;; TODO: check if obstacles have everything.

    (define debug #f)
    (define n (* w h))
    (define visited (make-hash))
    (define obs? (> (set-count obstacles) 0))
    (define conflicts (car conflict-list))
    (define conflict-index (cdr conflict-list))

    (define (get-route i j)
      (define ret (vector-2d-ref routing-table i j))
      (cond
       [ret ret]
       [else
        (define path (gen-route-i-j i j w h obstacles cores
                                    conflicts conflict-index
                                    actors*-no-cf-map actor-index))
        (unless
         path
         (raise (format "routing: no available route between cores ~a and ~a"
                        i j)))
        (vector-2d-set! routing-table n i j path)
        (vector-2d-set! routing-table n j i (reverse path))
        path]))

    (define (construct-placelist x-placelist y-placelist index)
      (if (and (empty? x-placelist) (empty? y-placelist))
          (list)
          (let* ([x-first (car x-placelist)]
                 [y-first (car y-placelist)]
                 [x-to (get-field to x-first)]
                 [y-to (get-field to y-first)]
                 [x-place (get-field place x-first)]
                 [y-place (get-field place y-first)])
            (cond 
             
             [(equal? x-to y-to)
              (cons (new RangePlace% [from index] [to x-to] 
                         [place x-place]
                         [send-path (get-route x-place y-place)])
                    (construct-placelist (cdr x-placelist) (cdr y-placelist) x-to))]
             
             [(< x-to y-to)
              (cons (new RangePlace% [from index] [to x-to]
                         [place x-place]
                         [send-path (get-route x-place y-place)])
                    (construct-placelist (cdr x-placelist) y-placelist x-to))]
             
             [(> x-to y-to)
              (cons (new RangePlace% [from index] [to y-to]
                         [place x-place]
                         [send-path (get-route x-place y-place)])
                    (construct-placelist x-placelist (cdr y-placelist) y-to))]
             
             [else (raise "contruct-placelist: unimplemented")]))))
    
    (define (gen-path x-ast y-ast)
      (define x (get-field place-type x-ast))
      (define y (get-field place-type y-ast))
      (when debug
        (pretty-display `(gen-path ,(send x-ast to-string) ,x  ,(send y-ast to-string) ,y)))

      (set-field! send-path x-ast
        (cond
         [(same-place? x y) #f]
         [(and (is-a? x TypeExpansion%) (is-a? y TypeExpansion%)) #f]
         
         [(and (number? x) (number? y))
          (get-route x y)]
         
         [(and (number? x) (place-type-dist? y))
          (cons
           (for/list ([p (car y)])
                     (new RangePlace% [from (get-field from p)] [to (get-field to p)]
                          [place x] [send-path (get-route x (get-field place p))]))
           (cdr y))]
         
         [(and (number? y) (place-type-dist? x))
          (cons 
           (for/list ([p (car x)])
                     (let ([place (get-field place p)])
                       (new RangePlace% [from (get-field from p)] [to (get-field to p)]
                            [place place] [send-path (get-route place y)])))
           (cdr x))]
         
         [(and (place-type-dist? x) 
               (place-type-dist? y) 
               (equal? (send (cdr x) to-string) (send (cdr y) to-string)))
          (let ([x-from (get-field from (caar x))]
                [y-from (get-field from (caar y))])
            (unless (equal? x-from y-from) 
                    (raise "visitor-comminsert: distributions do not start at the same index"))
            (cons (construct-placelist (car x) (car y) x-from) (cdr x)))]
         
         [else (raise (format "gen-path: unimplemented for ~a and ~a" x y))])))

    ;; TODO turn list into tree!
    (define (get-path-one-to-many from placelist)
      (when debug
        (pretty-display `(get-path-one-to-many ,from ,placelist)))
      (let* ([filtered-list (filter (lambda (x) (not (equal? x from))) (set->list placelist))]
             [ret (for/list ([p filtered-list])
                            (get-route from p))])
             (if (empty? ret)
                 #f
                 ret)))

    ;; TODO optimize for if(a[i]) { ... b[i] ... }
    (define (gen-path-condition cond-ast)
      (let ([x (get-field place-type (get-field condition cond-ast))]
            [placeset (get-field body-placeset cond-ast)])
        (set-field! send-path cond-ast
          (cond
           [(number? x)
            (get-path-one-to-many x placeset)]
         
           [(place-type-dist? x)
            (for/list ([p (car x)])
                      (let ([place (get-field place p)])
                        (new RangePlace% [from (get-field from p)] [to (get-field to p)]
                             [place place] [send-path (get-path-one-to-many place placeset)])))]
           [(at-any? x) #f]
           
           [else (raise (format "gen-path-condition: unimplemented ~a" x))]))
        ;`(gen-path-condition ,(get-field condition cond-ast) x ,x placeset ,placeset ,(get-field send-path cond-ast))
        ))

    (define/public (visit ast)
      (define (update-placeset addition)
        (pretty-display `(update-addition ,addition))
        (pretty-display `(update-old
                          ,(for/set ([p (get-field body-placeset ast)])
                                    (vector-ref part2core p))
                          ,(get-field body-placeset ast)))
        (define ret (set-union
                     (for/set ([p (get-field body-placeset ast)])
                              (vector-ref part2core p))
                     addition))
        (set-field! body-placeset ast ret)
        ret)
      
      (define (convert-base p)
        (cond
         [(number? p)
          (vector-ref part2core p)]
         [(list? p)
          (for ([i p])
               (send i accept this))
          p]
         [(pair? p)
          (for ([i (car p)])
               (send i accept this))
          p]
         [(at-io? p)
          (raise "visitor-comminsert: io should be converted at visitor-evaluator!")
          n]
	 ;; [(is-a? p Place%)
	 ;;  p]
         [(and (is-a? p Place%) (equal? (get-field at p) "any"))
          p]
         [(is-a? p TypeExpansion%)
          (unless (get-field convert p)
                  (set-field! convert p #t)
                  (set-field! place-list p
                              (map (lambda (x) (convert-base x)) (get-field place-list p))))
          p]
         [(not p) p]
	 [else p]))
         ;; [else
         ;;  (raise (format "convert-place-type: unimplemented for ~a" p))]))

      (define (convert-place)
        (set-field! place ast (convert-base (get-field place ast))))

      (define (convert-place-type)
        (set-field! place-type ast (convert-base (get-field place-type ast))))

      (define (convert)
        (unless (get-field convert ast)
                (set-field! convert ast #t)
                (when (field-bound? place ast)
                      (convert-place))
                (when (field-bound? place-type ast)
                      (convert-place-type))))

      (define (all-place-from place)
        (cond
         
         [(number? place)
          (set place)]

         [(place-type-dist? place)
          (list->set (map (lambda (x) (get-field place x)) (car place)))]

         [(and (list? place) (field-bound? place (car place)))
          (list->set (map (lambda (x) (get-field place x)) place))]

         [(and (list? place) (field-bound? place-type (car place)))
          (list->set (map (lambda (x) (get-field place-type x)) place))]

	 [(at-any? place)
	  (set)]

         [(is-a? place TypeExpansion%)
          (set)]

         [(not place)
          (set)]

         [else
	  (set)]))
          ;(raise (format "visitor-comminsert: all-place-from: unimplemented for ~a" place))]))
      
      (define (all-place)
        ;(pretty-display `(all-place ,(get-field place ast)))
        (all-place-from (get-field place ast)))

      (define (all-place-list)
        ;(pretty-display `(all-place-type ,(get-field place-list ast)))
        (all-place-from (get-field place-list ast)))

      (define (all-place-type)
        ;(pretty-display `(all-place-type ,(get-field place-type ast)))
        (all-place-from (get-field place-type ast)))

      (define (all-path-from path)
        ;(pretty-display `(all-path-from ,path))
        (cond 
          [(equal? path #f)
           (set)]
          
          [(list? path)
           (list->set (flatten path))]
          
          [else
           ;; place-type-dist
           (foldl (lambda (x all) (set-union all (all-path-from (get-field send-path x))))
                  (set) (car path))]))

      (define (all-path my-ast)
        (let ([path (get-field send-path my-ast)])
          (if path
              (all-path-from path)
              (set))))
                    

      (cond
       [(is-a? ast Param%)
        (when debug 
              (pretty-display (format "\nCOMMINSERT: ~a" (send ast to-string))))
        (convert)
        (all-place)
        ]
        
       [(is-a? ast VarDecl%)
        (when debug 
              (pretty-display (format "\nCOMMINSERT: VarDecl ~a, type:~a" 
				      (get-field var-list ast) (get-field type ast))))
        (if (equal? (get-field type ast) "void")
            (set)
            (begin
              (convert)
              (all-place)))]
        
       [(is-a? ast Livable%)
        (when debug 
              (pretty-display (format "\nCOMMINSERT: Livable")))
        (convert)
        (all-place)
        ]

       [(is-a? ast LivableGroup%)
        (when debug (pretty-display (format "COMMINSERT: ArrayDecl")))

        (let ([place (get-field place-list ast)])
          (if (list? place)
              (for ([p place])
                   (send p accept this))
              (when (number? place)
                    (set-field! place-list ast (vector-ref part2core place)))))

        (when (and (is-a? ast ArrayDecl%) (get-field ghost ast))
              (let ([ghost (get-field ghost ast)])
                (if (list? ghost)
                    (for ([p ghost])
                         (send p accept this))
                    (when (number? ghost)
                          (set-field! ghost ast (vector-ref part2core ghost))))))

        (all-place-list)
        ]

       [(is-a? ast For%)
        (let ([place (get-field place-list ast)])
          (if (list? place)
              (for ([p (get-field place-list ast)])
                   (send p accept this))
              (when (number? place)
                    (set-field! place-list ast (vector-ref part2core place)))))

        (let ([body-ret
               (update-placeset (send (get-field body ast) accept this))])
          body-ret)]

       [(is-a? ast Num%)
        (when debug 
              (pretty-display (format "\nCOMMINSERT: Num ~a" (send ast to-string))))
        (convert)
        (all-place-type)]

       [(is-a? ast Array%)
        (define index (get-field index ast))
        (define index-ret (send index accept this))
        (convert)
        (when debug 
              (pretty-display (format "\nCOMMINSERT: Array ~a" (send ast to-string))))
        (gen-path index ast)
        ;; (define index-sp (get-field send-path index))
        ;; (pretty-display `(Index send-path ,index-sp))
        ;; (when (place-type-dist? index-sp)
        ;;       (for ([p (car index-sp)])
        ;;            (pretty-display `(send-path ,(get-field send-path p)))))
        (set-union (all-place-type) (all-path index) index-ret)
        ]

       [(is-a? ast Var%)
        (when debug 
              (pretty-display (format "COMMINSERT: Var ~a" (send ast to-string))))
        (convert)
        (all-place-type)]

       [(is-a? ast BinExp%)
        (define e1 (get-field e1 ast))
        (define e2 (get-field e2 ast))
        (define op (get-field op ast))
        (define e1-ret (send e1 accept this))
        (define e2-ret (send e2 accept this))
        (send op accept this)

        (convert)
        (when debug
              (pretty-display (format "COMMINSERT: BinExp ~a" (send ast to-string))))
        (gen-path e1 ast)
        (gen-path e2 ast)
        
        (when debug
              (pretty-display (format "COMMINSERT: BinExp ~a (done)" (send ast to-string)))
              (pretty-display `(e1 ,e1-ret ,(all-path e1)))
              (pretty-display `(e2 ,e2-ret ,(all-path e2)))
              (pretty-display `(all-place-type ,(all-place-type))))
        
        (set-union e1-ret e2-ret (all-place-type) (all-path e1) (all-path e2))
        ]

       [(is-a? ast UnaExp%)
        (define e1 (get-field e1 ast))
        (define op (get-field op ast))
        (define e1-ret (send e1 accept this))
        (send op accept this)

	(convert)
        (when debug
              (pretty-display (format "COMMINSERT: UnaExp ~a" (send ast to-string))))
        (gen-path e1 ast)
        (set-union e1-ret (all-place-type) (all-path e1))
        ]

       [(is-a? ast ProxyReturn%)
        (convert)
        (all-place-type)]

       [(is-a? ast FuncCall%)
	(when debug 
	      (pretty-display (format "COMMINSERT: FuncCall ~a" (get-field name ast))))
	;; recurse on signature
        ;(define args-ret (send (get-field signature ast) accept this))
	(define func-sig (get-field signature ast))
	(define name (get-field name ast))
	(define args-ret 
	  (if (or (equal? name "in")
		  (equal? name "out")
                  (io-func? name))
	      (send func-sig accept this)
	      (get-field body-placeset func-sig)))

	;; recurse on arguments
	(for ([arg (get-field args ast)])
	     (set! args-ret (set-union args-ret (send arg accept this))))
        (when debug 
              (pretty-display (format "COMMINSERT: FuncCall ~a" (send ast to-string))))
	(convert)
        
        (define path-ret (set))
	;; Body-placeset of IO function is empty. Add funccall's place-type to it.
	;; (cond 
	;;  [(equal? (get-field name func-sig) "in")
	;;   (set-field! body-placeset func-sig (set (get-field place-type ast)))]
	;;  [(equal? (get-field name func-sig) "out")
	;;   (let ([arg (car (get-field stmts (get-field args func-sig)))])
	;;     (set-field! body-placeset func-sig (set (get-field place-type arg))))]
	;;  )
	
	;; Generate path for argument to parameter.
	(for ([param (get-field stmts (get-field args func-sig))]
	      [arg (flatten-arg (get-field args ast))])
	     (gen-path arg param)
	     (set! path-ret (set-union path-ret (all-path arg))))

        (define ret
          (set-union path-ret args-ret 
                     (get-field body-placeset (get-field signature ast))
                     (all-place-type)))
        
        (when debug (pretty-display `(funccall-before ,ret)))
        (when
         (hash-has-key? actors*-no-cf-map name)
         (for ([pair (hash-ref actors name)])
              (let ([actor (car pair)]
                    [caller (cdr pair)])
                (set! ret
                      (set-union
                       ret
                       (list->set (vector-2d-ref routing-table caller actor))))))
         (pretty-display `(actors*-no-cf-map ,(hash-ref actors*-no-cf-map name name)))
         (set! ret (set-subtract ret
                                 (hash-ref actors*-no-cf-map name name))))
        ;; (cond
        ;;  [(hash-has-key? actors*-no-cf-map name)
        ;;   (pretty-display `(actors*-no-cf-map ,(hash-ref actors*-no-cf-map name name)))
        ;;   (set! ret (set-subtract ret (hash-ref actors*-no-cf-map name name)))]
         
        ;;  [(hash-has-key? actors name)
        ;;   (define l (hash-ref actors name))
        ;;   (for ([pair l])
        ;;        (let* ([caller (cdr pair)]
        ;;               [actor (car pair)]
        ;;               [path (vector-2d-ref routing-table caller actor)])
        ;;          (set! ret (set-subtract ret (list->set (drop path 1))))))])

        (when debug (pretty-display `(funccall-after ,ret)))
        
	(when debug 
	      (pretty-display (format "COMMINSERT: FuncCall ~a, return ~a" (get-field name ast) ret)))
        ret
        ]

       [(is-a? ast AssignTemp%)
        (when debug 
              (pretty-display (format "COMMINSERT: AssignTemp ~a = ~a"
                                      (send (get-field lhs ast) to-string) 
                                      (send (get-field rhs ast) to-string))))
        (send (get-field lhs ast) accept this)
        (send (get-field rhs ast) accept this)]

       [(is-a? ast Assign%) 
        (let ([rhs (get-field rhs ast)]
              [lhs (get-field lhs ast)])
          (when debug 
                (pretty-display (format "COMMINSERT: Assign ~a = ~a"
					(send lhs to-string) (send rhs to-string))))
          (define lhs-ret (send lhs accept this))
          (define rhs-ret (send rhs accept this))
          (gen-path rhs lhs)
          (set-union rhs-ret lhs-ret (all-path rhs))
          )
        ]

       [(is-a? ast Return%)
        (define val (get-field val ast))
        (if (list? val)
            (for ([x val])
                 (send x accept this))
            (send val accept this))
	(set)]

       [(is-a? ast If%)
        (define cond-ret (send (get-field condition ast) accept this))
        (define true-ret (send (get-field true-block ast) accept this))
        (define false-ret
          (if (get-field false-block ast)
              (send (get-field false-block ast) accept this)
              (set)))
        ;(convert-placeset)
        (when debug 
              (pretty-display (format "\nCOMMINSERT: If")))
        
        (define body-ret (update-placeset (set-union true-ret false-ret)))
        
        (gen-path-condition ast)
        (set-union body-ret cond-ret (all-path ast))
        ]

       [(is-a? ast While%)
	(define pre-ret (send (get-field pre ast) accept this))
	(define cond-ret (send (get-field condition ast) accept this))
        (define body-ret (send (get-field body ast) accept this))
        ;(convert-placeset)
        ;; TODO
        (when debug 
              (pretty-display (format "\nCOMMINSERT: While")))

        (define ret (update-placeset (set-union body-ret)))

        (gen-path-condition ast)
        (set-union pre-ret cond-ret ret (all-path ast))
        ]

       [(is-a? ast Block%) 
        (when debug 
              (pretty-display (format "\nCOMMINSERT: Block")))
        (define ret (set))
        (for ([stmt (get-field stmts ast)])
             (set! ret (set-union ret (send stmt accept this))))
        ret]

       [(is-a? ast FuncDecl%)
        (define name (get-field name ast))
        (when debug 
          (pretty-display "\n--------------------------------------------")
          (pretty-display (format "\nCOMMINSERT: FuncDecl ~a" name)))
        (cond [(hash-has-key? visited (get-field name ast))
               (hash-ref visited (get-field name ast))]
              [else

               (define return-ret
                 (if (get-field return ast)
                     (send (get-field return ast) accept this)
                     (set)))
               (define args-ret (send (get-field args ast) accept this))
               (define body-ret (send (get-field body ast) accept this))

               (define new-placeset
                 (if (io-func? (get-field name ast))
                     (list->set (map (lambda (x) (vector-ref part2core x))
                                     (set->list (get-field body-placeset ast))))
                     (set)))


               (let ([ret
                      (if (member name (list "in" "out"))
                          (set-union return-ret args-ret body-ret new-placeset)
                          (update-placeset
                           (set-union return-ret args-ret body-ret new-placeset)))])
                 (set-field! body-placeset ast ret)
                 (hash-set! visited name ret)
                 (pretty-display (format "\nCOMMINSERT: FuncDecl ~a, return = ~a" name ret))
                 ret)
               ])]
       [else (raise (format "Error: in comm-inserter, ~a unimplemented!" ast))]
       ))
    ))
            
