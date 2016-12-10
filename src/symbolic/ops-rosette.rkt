#lang s-exp rosette

(provide (all-defined-out))

(define-syntax-rule (assert-return c message val)
  (begin
    (assert c message)
    val))

(define (<< x y bit)
  (unless (term? x) (set! x (bv x bit)))
  (unless (term? y) (set! y (bv y bit)))
  (bvshl x y))
(define (>> x y bit)
  (unless (term? x) (set! x (bv x bit)))
  (unless (term? y) (set! y (bv y bit)))
  (bvashr x y))
(define (>>> x y bit)
  (unless (term? x) (set! x (bv x bit)))
  (unless (term? y) (set! y (bv y bit)))
  (bvlshr x y))

(define bit 16)
(define (bv+ a b)
  (unless (bv? a) (set! a (bv a bit)))
  (unless (bv? b) (set! b (bv b bit)))
  (bvadd a b))

(define (bv* a b)
  (unless (bv? a) (set! a (bv a bit)))
  (unless (bv? b) (set! b (bv b bit)))
  (bvmul a b))

(define (bvu< a b)
  (unless (bv? a) (set! a (bv a bit)))
  (unless (bv? b) (set! b (bv b bit)))
  (bvult a b))

(define (bvu<= a b)
  (unless (bv? a) (set! a (bv a bit)))
  (unless (bv? b) (set! b (bv b bit)))
  (bvule a b))

(define (bvu> a b)
  (unless (bv? a) (set! a (bv a bit)))
  (unless (bv? b) (set! b (bv b bit)))
  (bvugt a b))

(define (bvu>= a b)
  (unless (bv? a) (set! a (bv a bit)))
  (unless (bv? b) (set! b (bv b bit)))
  (bvuge a b))

(define (bv= a b)
  (unless (bv? a) (set! a (bv a bit)))
  (unless (bv? b) (set! b (bv b bit)))
  (bveq a b))

(define (bv!= a b)
  (unless (bv? a) (set! a (bv a bit)))
  (unless (bv? b) (set! b (bv b bit)))
  (not (bveq a b)))

;; This function is very memory expensive in Rosette
(define (vector-copy! dest dest-start src 
                      [src-start 0] [src-end (vector-length src)])
  ;;(pretty-display `(vector-copy! ,src-start ,src-end ,(- src-end src-start)))
  (for ([i (in-range (- src-end src-start))])
       ;;(pretty-display `(copy-* ,(quotient (current-memory-use) 1000)))
       (vector-set! dest (+ dest-start i)
                    (vector-ref src (+ src-start i))))
  )



;; This function is very memory expensive in Rosette
(define (vector-copy-len! dest dest-start 
                          src src-start len)
  (for ([i (in-range len)])
       ;;(pretty-display `(copy-* ,i))
       (vector-set! dest (+ dest-start i)
                    (vector-ref src (+ src-start i))))
  )

;; TODO: do we need this?
(define (vector-copy-len vec start len)
  ;(pretty-display `(vector-copy ,start ,len))
  (for/vector ([i len]) (vector-ref vec (+ start i))))
  

(define (vector-extract a b shift)
  ;(pretty-display `(vector-extract ,a ,b ,shift))
  (define len (vector-length a))
  (define pos (- len shift))
  (define vec (make-vector len))
  (for ([i (in-range pos)])
       ;(pretty-display `(first ,i ,(+ shift i)))
       (vector-set! vec i (vector-ref a (+ shift i))))
  (for ([i (in-range shift)])
       ;(pretty-display `(second ,(+ pos i) ,i))
       (vector-set! vec (+ pos i) (vector-ref b i)))
  ;(pretty-display `(vector-extract-ret ,vec))
  vec)

(define (smmul u v bit)
  (define byte2 (quotient bit 2))
  (define low-mask (sub1 (arithmetic-shift 1 byte2)))

  (define u0 (bitwise-and u low-mask))
  (define u1 (>> u byte2 bit))
  (define v0 (bitwise-and v low-mask))
  (define v1 (>> v byte2 bit))

  (define w0 (finitize (* u0 v0) bit))
  (define t (finitize (+ (* u1 v0) (>>> w0 byte2 bit)) bit))
  (define w1 (bitwise-and t low-mask))
  (define w2 (>> t byte2 bit))
  (set! w1 (finitize (+ (* u0 v1) w1) bit))
  (finitize (+ (* u1 v1) w2 (>> w1 byte2 bit)) bit))

(define (ummul u v bit)
  (define byte2 (quotient bit 2))
  (define low-mask (sub1 (arithmetic-shift 1 byte2)))

  (define u0 (bitwise-and u low-mask))
  (define u1 (bitwise-and (>> u byte2 bit) low-mask))
  (define v0 (bitwise-and v low-mask))
  (define v1 (bitwise-and (>> v byte2 bit) low-mask))

  (finitize
   (+ (* u1 v1) 
      (>>> (* u1 v0) byte2 bit) 
      (>>> (* u0 v1) byte2 bit) 
      (>>> (+ (bitwise-and (* u1 v0) low-mask)
                  (bitwise-and (* u0 v1) low-mask)
                  (>>> (* u0 v0) byte2 bit))
               byte2 bit))
   bit))

;; (define (smmul x y bit) 
;;   (define p (*h x y))
;;   (define t1 (bitwise-and (>> x (sub1 bit)) y))
;;   (define t2 (bitwise-and (>> y (sub1 bit)) x))
;;   (finitize (- p t1 t2) bit))

;; (define (ummul x y bit) 
;;   (*h x y))
