;; Patent Timestamp Registry Contract
;; Immutable timestamps for inventions, designs, and creative works to establish prior art

;; Define constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_INVALID_INPUT (err u101))
(define-constant ERR_PATENT_NOT_FOUND (err u102))
(define-constant ERR_PATENT_ALREADY_EXISTS (err u103))
(define-constant ERR_INSUFFICIENT_FUNDS (err u104))

;; Define data variables
(define-data-var next-patent-id uint u1)
(define-data-var registration-fee uint u1000000) ;; 1 STX in microSTX
(define-data-var contract-balance uint u0)

;; Define data structures
(define-map patents
  { patent-id: uint }
  {
    inventor: principal,
    title: (string-utf8 256),
    description: (string-utf8 1024),
    technical-specs: (string-utf8 2048),
    patent-hash: (buff 32),
    timestamp: uint,
    block-height: uint,
    status: (string-utf8 20),
    category: (string-utf8 50),
    keywords: (list 10 (string-utf8 50)),
    prior-art-references: (list 20 (string-utf8 256)),
    registration-fee-paid: uint,
    is-public: bool,
    renewal-deadline: uint
  }
)

(define-map patent-hashes
  { hash: (buff 32) }
  { patent-id: uint, exists: bool }
)

(define-map inventor-patents
  { inventor: principal }
  { patent-ids: (list 100 uint), count: uint }
)

(define-map category-patents
  { category: (string-utf8 50) }
  { patent-ids: (list 1000 uint), count: uint }
)

(define-map patent-disputes
  { patent-id: uint }
  {
    disputing-party: principal,
    dispute-reason: (string-utf8 512),
    dispute-timestamp: uint,
    is-resolved: bool,
    resolution: (string-utf8 1024)
  }
)

;; Public functions

;; Register a new patent with immutable timestamp
(define-public (register-patent
  (title (string-utf8 256))
  (description (string-utf8 1024))
  (technical-specs (string-utf8 2048))
  (category (string-utf8 50))
  (keywords (list 10 (string-utf8 50)))
  (prior-art-refs (list 20 (string-utf8 256)))
  (is-public bool)
  )
  (let (
    (patent-id (var-get next-patent-id))
    (patent-hash (sha256 (unwrap-panic (to-consensus-buff? (concat (concat title description) technical-specs)))))
    (current-time burn-block-height)
    (fee (var-get registration-fee))
  )
    ;; Check if patent hash already exists
    (asserts! (is-none (map-get? patent-hashes { hash: patent-hash })) ERR_PATENT_ALREADY_EXISTS)
    
    ;; Check payment
    (asserts! (>= (stx-get-balance tx-sender) fee) ERR_INSUFFICIENT_FUNDS)
    
    ;; Validate input
    (asserts! (> (len title) u0) ERR_INVALID_INPUT)
    (asserts! (> (len description) u0) ERR_INVALID_INPUT)
    (asserts! (> (len technical-specs) u0) ERR_INVALID_INPUT)
    
    ;; Transfer registration fee
    (try! (stx-transfer? fee tx-sender (as-contract tx-sender)))
    (var-set contract-balance (+ (var-get contract-balance) fee))
    
    ;; Create patent record
    (map-set patents
      { patent-id: patent-id }
      {
        inventor: tx-sender,
        title: title,
        description: description,
        technical-specs: technical-specs,
        patent-hash: patent-hash,
        timestamp: current-time,
        block-height: burn-block-height,
        status: u"active",
        category: category,
        keywords: keywords,
        prior-art-references: prior-art-refs,
        registration-fee-paid: fee,
        is-public: is-public,
        renewal-deadline: (+ current-time u31536000) ;; 1 year from now
      }
    )
    
    ;; Update hash mapping
    (map-set patent-hashes
      { hash: patent-hash }
      { patent-id: patent-id, exists: true }
    )
    
    ;; Update inventor patents
    (let (
      (inventor-data (default-to { patent-ids: (list), count: u0 }
                                   (map-get? inventor-patents { inventor: tx-sender })))
    )
      (map-set inventor-patents
        { inventor: tx-sender }
        {
          patent-ids: (unwrap-panic (as-max-len? (append (get patent-ids inventor-data) patent-id) u100)),
          count: (+ (get count inventor-data) u1)
        }
      )
    )
    
    ;; Update category patents
    (let (
      (category-data (default-to { patent-ids: (list), count: u0 }
                                  (map-get? category-patents { category: category })))
    )
      (map-set category-patents
        { category: category }
        {
          patent-ids: (unwrap-panic (as-max-len? (append (get patent-ids category-data) patent-id) u1000)),
          count: (+ (get count category-data) u1)
        }
      )
    )
    
    ;; Increment next patent ID
    (var-set next-patent-id (+ patent-id u1))
    
    (ok patent-id)
  )
)

;; Verify patent ownership and authenticity
(define-public (verify-patent (patent-id uint))
  (match (map-get? patents { patent-id: patent-id })
    patent-data (ok {
      patent-id: patent-id,
      inventor: (get inventor patent-data),
      timestamp: (get timestamp patent-data),
      block-height: (get block-height patent-data),
      patent-hash: (get patent-hash patent-data),
      status: (get status patent-data)
    })
    ERR_PATENT_NOT_FOUND
  )
)

;; Check for prior art by comparing patent hashes
(define-public (check-prior-art (content-hash (buff 32)))
  (match (map-get? patent-hashes { hash: content-hash })
    hash-data (ok {
      exists: (get exists hash-data),
      patent-id: (get patent-id hash-data),
      message: u"Prior art found - patent already exists"
    })
    (ok {
      exists: false,
      patent-id: u0,
      message: u"No prior art found - content appears to be original"
    })
  )
)

;; Renew patent registration
(define-public (renew-patent (patent-id uint))
  (let (
    (patent-data (unwrap! (map-get? patents { patent-id: patent-id }) ERR_PATENT_NOT_FOUND))
    (renewal-fee (/ (var-get registration-fee) u2)) ;; 50% of original fee
    (current-time burn-block-height)
  )
    ;; Check ownership
    (asserts! (is-eq tx-sender (get inventor patent-data)) ERR_UNAUTHORIZED)
    
    ;; Check payment
    (asserts! (>= (stx-get-balance tx-sender) renewal-fee) ERR_INSUFFICIENT_FUNDS)
    
    ;; Transfer renewal fee
    (try! (stx-transfer? renewal-fee tx-sender (as-contract tx-sender)))
    (var-set contract-balance (+ (var-get contract-balance) renewal-fee))
    
    ;; Update patent with new renewal deadline
    (map-set patents
      { patent-id: patent-id }
      (merge patent-data {
        renewal-deadline: (+ current-time u31536000),
        status: u"renewed"
      })
    )
    
    (ok true)
  )
)

;; File a dispute against a patent
(define-public (file-dispute
  (patent-id uint)
  (dispute-reason (string-utf8 512))
  )
  (let (
    (patent-data (unwrap! (map-get? patents { patent-id: patent-id }) ERR_PATENT_NOT_FOUND))
    (current-time burn-block-height)
  )
    ;; Ensure disputer is not the patent owner
    (asserts! (not (is-eq tx-sender (get inventor patent-data))) ERR_UNAUTHORIZED)
    
    ;; Create dispute record
    (map-set patent-disputes
      { patent-id: patent-id }
      {
        disputing-party: tx-sender,
        dispute-reason: dispute-reason,
        dispute-timestamp: current-time,
        is-resolved: false,
        resolution: u""
      }
    )
    
    (ok true)
  )
)

;; Read-only functions

;; Get patent information
(define-read-only (get-patent (patent-id uint))
  (map-get? patents { patent-id: patent-id })
)

;; Get patents by inventor
(define-read-only (get-inventor-patents (inventor principal))
  (map-get? inventor-patents { inventor: inventor })
)

;; Get patents by category
(define-read-only (get-category-patents (category (string-utf8 50)))
  (map-get? category-patents { category: category })
)

;; Get patent dispute information
(define-read-only (get-patent-dispute (patent-id uint))
  (map-get? patent-disputes { patent-id: patent-id })
)

;; Get contract statistics
(define-read-only (get-contract-stats)
  {
    total-patents: (- (var-get next-patent-id) u1),
    registration-fee: (var-get registration-fee),
    contract-balance: (var-get contract-balance)
  }
)

;; Administrative functions (owner only)

;; Update registration fee
(define-public (set-registration-fee (new-fee uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (var-set registration-fee new-fee)
    (ok true)
  )
)

;; Withdraw contract balance
(define-public (withdraw-balance (amount uint) (recipient principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (<= amount (var-get contract-balance)) ERR_INSUFFICIENT_FUNDS)
    
    (try! (as-contract (stx-transfer? amount tx-sender recipient)))
    (var-set contract-balance (- (var-get contract-balance) amount))
    
    (ok true)
  )
)

;; title: patent-timestamp-registry
;; version:
;; summary:
;; description:

;; traits
;;

;; token definitions
;;

;; constants
;;

;; data vars
;;

;; data maps
;;

;; public functions
;;

;; read only functions
;;

;; private functions
;;

