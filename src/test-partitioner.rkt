#lang s-exp rosette

(require "header.rkt" 
         "parser.rkt" 
         "compiler.rkt"
         "partitioner.rkt" 
	 "partition-storage.rkt" 
	 rackunit)

(define testdir "../tests/")

(define (optimize-file file name cores capacity [max-msgs #f] #:mode [mode 'smt])
  (set-outdir file name)
  (define my-ast (parse file))
  (optimize-comm my-ast #:cores cores #:capacity capacity #:max-msgs max-msgs 
                 #:verbose #t #:mode mode))

;; Check with expected number of messages
(define (test-num-msgs name expected-msgs 
                       #:cores [cores 4] #:capacity [capacity 256] #:max-msgs [max-msgs 8]
                       [file (string-append testdir name ".cll")])
  (check-equal? 
   (result-msgs (optimize-file file name cores capacity max-msgs))
   expected-msgs
   name)
  )

;; Consistency Test
(define (test-consistent name
                         [cores 4] [capacity 256] [max-msgs 8]
                         [file1 (string-append testdir name "_concrete.cll")]
                         [file2 (string-append testdir name "_symbolic.cll")])
  (let ([res1 (optimize-file file1 (string-append name "_concrete") cores capacity max-msgs)]
        [res2 (optimize-file file2 (string-append name "_symbolic") cores capacity max-msgs)])
  (check-equal? (result-msgs res1) (result-msgs res2))
    (check-true (cores-equal? (result-cores res1) (result-cores res2)))))

;; No error test
(define (no-error name [cores 4] [capacity 256] [max-msgs #f]
                  [file (string-append testdir name ".cll")])
  (optimize-file file name cores capacity max-msgs))

;(test-num-msgs "for-array1"    0)
;(test-num-msgs "for-array2"    0)
;(test-num-msgs "for-array3"    0)
;(test-num-msgs "for-array4"    20 #:max-msgs 100 #:capacity 512)
;(test-num-msgs "for-array5"    0)
;(test-num-msgs "add"           100 #:cores 8 #:max-msgs 200 #:capacity 350)
;(test-num-msgs "add-pair"      100 #:cores 8 #:max-msgs 200 #:capacity 300)
;(test-num-msgs "function"      2 #:capacity 512)
;(test-num-msgs "function2"     4)
;(test-num-msgs "while"         300 #:max-msgs 800)

;(test-consistent "space")
;(test-consistent "if")

;(optimize-file "../tests/space.cll" "space" 4 256 #:mode 'smt)
(optimize-file "../examples/parallel/prefixsum-nopart.cll" "space" 144 256 #:mode 'mip)
;(optimize-file "../examples/parallel/ssd-nopart.cll" "space" 30 512 #:mode 'mip)
;(optimize-file "../examples/parallel/convolution-nopart.cll" "space" 144 256 #:mode 'mip)
;(optimize-file "../examples/rom/fir-par4-nopart.cll" "space" 144 512 #:mode 'mip)

