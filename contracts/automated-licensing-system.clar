;; Automated Licensing System Contract
;; Smart contract-based IP licensing with automated royalty distribution

;; Define constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u200))
(define-constant ERR_INVALID_INPUT (err u201))
(define-constant ERR_LICENSE_NOT_FOUND (err u202))
(define-constant ERR_LICENSE_EXPIRED (err u203))
(define-constant ERR_INSUFFICIENT_FUNDS (err u204))
(define-constant ERR_LICENSE_ALREADY_EXISTS (err u205))
(define-constant ERR_USAGE_LIMIT_EXCEEDED (err u206))
(define-constant ERR_INVALID_ROYALTY_RATE (err u207))

;; Define data variables
(define-data-var next-license-id uint u1)
(define-data-var platform-fee-rate uint u5) ;; 5% platform fee
(define-data-var total-royalties-distributed uint u0)

;; License types
(define-constant LICENSE_TYPE_EXCLUSIVE u1)
(define-constant LICENSE_TYPE_NON_EXCLUSIVE u2)
(define-constant LICENSE_TYPE_PERPETUAL u3)
(define-constant LICENSE_TYPE_LIMITED_TIME u4)
(define-constant LICENSE_TYPE_USAGE_BASED u5)

;; Define data structures
(define-map licenses
  { license-id: uint }
  {
    licensor: principal,
    licensee: principal,
    ip-identifier: (string-utf8 256),
    license-type: uint,
    royalty-rate: uint, ;; percentage * 100 (e.g., 500 = 5%)
    base-fee: uint,
    usage-limit: uint,
    current-usage: uint,
    start-date: uint,
    end-date: uint,
    is-active: bool,
    terms-hash: (buff 32),
    created-at: uint,
    last-payment: uint,
    total-royalties-paid: uint,
    payment-frequency: uint, ;; in blocks
    next-payment-due: uint,
    territory: (string-utf8 100),
    field-of-use: (string-utf8 256)
  }
)

(define-map license-templates
  { template-id: uint }
  {
    creator: principal,
    name: (string-utf8 100),
    description: (string-utf8 500),
    license-type: uint,
    default-royalty-rate: uint,
    default-base-fee: uint,
    default-duration: uint,
    terms-template: (string-utf8 2048),
    is-public: bool,
    usage-count: uint,
    created-at: uint
  }
)

(define-map ip-assets
  { asset-id: (string-utf8 256) }
  {
    owner: principal,
    title: (string-utf8 256),
    description: (string-utf8 1024),
    asset-type: (string-utf8 50),
    valuation: uint,
    is-available-for-licensing: bool,
    exclusive-license-granted: bool,
    total-licenses: uint,
    total-royalties-earned: uint,
    created-at: uint,
    last-licensed: uint
  }
)

(define-map royalty-payments
  { payment-id: uint }
  {
    license-id: uint,
    payer: principal,
    recipient: principal,
    amount: uint,
    platform-fee: uint,
    timestamp: uint,
    usage-reported: uint,
    payment-reason: (string-utf8 100)
  }
)

(define-map license-usage-reports
  { report-id: uint }
  {
    license-id: uint,
    reporter: principal,
    usage-amount: uint,
    usage-description: (string-utf8 512),
    timestamp: uint,
    verified: bool,
    royalty-calculated: uint
  }
)

(define-map licensor-earnings
  { licensor: principal }
  {
    total-earned: uint,
    pending-payments: uint,
    completed-payments: uint,
    active-licenses: uint
  }
)

;; Define data variables for counters
(define-data-var next-template-id uint u1)
(define-data-var next-payment-id uint u1)
(define-data-var next-report-id uint u1)

;; Public functions

;; Register an IP asset for licensing
(define-public (register-ip-asset
  (asset-id (string-utf8 256))
  (title (string-utf8 256))
  (description (string-utf8 1024))
  (asset-type (string-utf8 50))
  (valuation uint)
  )
  (let (
    (current-time burn-block-height)
  )
    ;; Validate input
    (asserts! (> (len asset-id) u0) ERR_INVALID_INPUT)
    (asserts! (> (len title) u0) ERR_INVALID_INPUT)
    (asserts! (> valuation u0) ERR_INVALID_INPUT)
    
    ;; Check if asset already exists
    (asserts! (is-none (map-get? ip-assets { asset-id: asset-id })) ERR_LICENSE_ALREADY_EXISTS)
    
    ;; Create IP asset record
    (map-set ip-assets
      { asset-id: asset-id }
      {
        owner: tx-sender,
        title: title,
        description: description,
        asset-type: asset-type,
        valuation: valuation,
        is-available-for-licensing: true,
        exclusive-license-granted: false,
        total-licenses: u0,
        total-royalties-earned: u0,
        created-at: current-time,
        last-licensed: u0
      }
    )
    
    (ok true)
  )
)

;; Create a licensing agreement
(define-public (create-license
  (ip-identifier (string-utf8 256))
  (licensee principal)
  (license-type uint)
  (royalty-rate uint)
  (base-fee uint)
  (usage-limit uint)
  (duration uint)
  (territory (string-utf8 100))
  (field-of-use (string-utf8 256))
  )
  (let (
    (license-id (var-get next-license-id))
    (current-time burn-block-height)
    (end-time (if (is-eq license-type LICENSE_TYPE_PERPETUAL) u0 (+ current-time duration)))
    (asset-data (unwrap! (map-get? ip-assets { asset-id: ip-identifier }) ERR_LICENSE_NOT_FOUND))
    (terms-hash (sha256 (unwrap-panic (to-consensus-buff? (concat (concat ip-identifier territory) field-of-use)))))
  )
    ;; Validate inputs
    (asserts! (is-eq tx-sender (get owner asset-data)) ERR_UNAUTHORIZED)
    (asserts! (not (is-eq tx-sender licensee)) ERR_INVALID_INPUT)
    (asserts! (<= royalty-rate u10000) ERR_INVALID_ROYALTY_RATE) ;; Max 100%
    (asserts! (get is-available-for-licensing asset-data) ERR_LICENSE_NOT_FOUND)
    
    ;; Check if exclusive license already granted
    (if (is-eq license-type LICENSE_TYPE_EXCLUSIVE)
      (asserts! (not (get exclusive-license-granted asset-data)) ERR_LICENSE_ALREADY_EXISTS)
      true
    )
    
    ;; Payment for base fee
    (if (> base-fee u0)
      (begin
        (asserts! (>= (stx-get-balance licensee) base-fee) ERR_INSUFFICIENT_FUNDS)
        (try! (stx-transfer? base-fee licensee tx-sender))
      )
      true
    )
    
    ;; Create license record
    (map-set licenses
      { license-id: license-id }
      {
        licensor: tx-sender,
        licensee: licensee,
        ip-identifier: ip-identifier,
        license-type: license-type,
        royalty-rate: royalty-rate,
        base-fee: base-fee,
        usage-limit: usage-limit,
        current-usage: u0,
        start-date: current-time,
        end-date: end-time,
        is-active: true,
        terms-hash: terms-hash,
        created-at: current-time,
        last-payment: current-time,
        total-royalties-paid: u0,
        payment-frequency: u1440, ;; Daily payments (assuming ~10 min blocks)
        next-payment-due: (+ current-time u14400), ;; Next payment due in ~1 day
        territory: territory,
        field-of-use: field-of-use
      }
    )
    
    ;; Update IP asset
    (map-set ip-assets
      { asset-id: ip-identifier }
      (merge asset-data {
        total-licenses: (+ (get total-licenses asset-data) u1),
        last-licensed: current-time,
        exclusive-license-granted: (if (is-eq license-type LICENSE_TYPE_EXCLUSIVE) true (get exclusive-license-granted asset-data))
      })
    )
    
    ;; Update licensor earnings
    (let (
      (earnings-data (default-to { total-earned: u0, pending-payments: u0, completed-payments: u0, active-licenses: u0 }
                                  (map-get? licensor-earnings { licensor: tx-sender })))
    )
      (map-set licensor-earnings
        { licensor: tx-sender }
        (merge earnings-data {
          active-licenses: (+ (get active-licenses earnings-data) u1),
          total-earned: (+ (get total-earned earnings-data) base-fee)
        })
      )
    )
    
    ;; Increment next license ID
    (var-set next-license-id (+ license-id u1))
    
    (ok license-id)
  )
)

;; Report usage and calculate royalty payment
(define-public (report-usage
  (license-id uint)
  (usage-amount uint)
  (usage-description (string-utf8 512))
  )
  (let (
    (license-data (unwrap! (map-get? licenses { license-id: license-id }) ERR_LICENSE_NOT_FOUND))
    (report-id (var-get next-report-id))
    (current-time burn-block-height)
    (royalty-amount (/ (* usage-amount (get royalty-rate license-data)) u10000))
    (platform-fee (/ (* royalty-amount (var-get platform-fee-rate)) u100))
    (net-royalty (- royalty-amount platform-fee))
  )
    ;; Validate license is active and not expired
    (asserts! (get is-active license-data) ERR_LICENSE_EXPIRED)
    (asserts! (or (is-eq (get end-date license-data) u0) (<= current-time (get end-date license-data))) ERR_LICENSE_EXPIRED)
    
    ;; Check usage limits
    (asserts! (or (is-eq (get usage-limit license-data) u0) 
                  (<= (+ (get current-usage license-data) usage-amount) (get usage-limit license-data))) 
              ERR_USAGE_LIMIT_EXCEEDED)
    
    ;; Only licensee can report usage
    (asserts! (is-eq tx-sender (get licensee license-data)) ERR_UNAUTHORIZED)
    
    ;; Check if licensee has sufficient funds for royalty payment
    (asserts! (>= (stx-get-balance tx-sender) royalty-amount) ERR_INSUFFICIENT_FUNDS)
    
    ;; Create usage report
    (map-set license-usage-reports
      { report-id: report-id }
      {
        license-id: license-id,
        reporter: tx-sender,
        usage-amount: usage-amount,
        usage-description: usage-description,
        timestamp: current-time,
        verified: true,
        royalty-calculated: royalty-amount
      }
    )
    
    ;; Process royalty payment
    (try! (stx-transfer? net-royalty tx-sender (get licensor license-data)))
    (if (> platform-fee u0)
      (try! (stx-transfer? platform-fee tx-sender (as-contract tx-sender)))
      true
    )
    
    ;; Record payment
    (let (
      (payment-id (var-get next-payment-id))
    )
      (map-set royalty-payments
        { payment-id: payment-id }
        {
          license-id: license-id,
          payer: tx-sender,
          recipient: (get licensor license-data),
          amount: net-royalty,
          platform-fee: platform-fee,
          timestamp: current-time,
          usage-reported: usage-amount,
          payment-reason: u"Usage-based royalty payment"
        }
      )
      (var-set next-payment-id (+ payment-id u1))
    )
    
    ;; Update license with new usage and payment info
    (map-set licenses
      { license-id: license-id }
      (merge license-data {
        current-usage: (+ (get current-usage license-data) usage-amount),
        last-payment: current-time,
        total-royalties-paid: (+ (get total-royalties-paid license-data) royalty-amount),
        next-payment-due: (+ current-time (get payment-frequency license-data))
      })
    )
    
    ;; Update total royalties distributed
    (var-set total-royalties-distributed (+ (var-get total-royalties-distributed) net-royalty))
    
    ;; Update licensor earnings
    (let (
      (earnings-data (default-to { total-earned: u0, pending-payments: u0, completed-payments: u0, active-licenses: u0 }
                                  (map-get? licensor-earnings { licensor: (get licensor license-data) })))
    )
      (map-set licensor-earnings
        { licensor: (get licensor license-data) }
        (merge earnings-data {
          total-earned: (+ (get total-earned earnings-data) net-royalty),
          completed-payments: (+ (get completed-payments earnings-data) u1)
        })
      )
    )
    
    ;; Increment report ID
    (var-set next-report-id (+ report-id u1))
    
    (ok {
      report-id: report-id,
      royalty-paid: net-royalty,
      platform-fee: platform-fee,
      remaining-usage-limit: (if (is-eq (get usage-limit license-data) u0) u0 
                                 (- (get usage-limit license-data) (+ (get current-usage license-data) usage-amount)))
    })
  )
)

;; Terminate a license
(define-public (terminate-license (license-id uint))
  (let (
    (license-data (unwrap! (map-get? licenses { license-id: license-id }) ERR_LICENSE_NOT_FOUND))
  )
    ;; Only licensor can terminate
    (asserts! (is-eq tx-sender (get licensor license-data)) ERR_UNAUTHORIZED)
    
    ;; Update license status
    (map-set licenses
      { license-id: license-id }
      (merge license-data {
        is-active: false,
        end-date: burn-block-height
      })
    )
    
    ;; Update licensor earnings
    (let (
      (earnings-data (default-to { total-earned: u0, pending-payments: u0, completed-payments: u0, active-licenses: u0 }
                                  (map-get? licensor-earnings { licensor: tx-sender })))
    )
      (map-set licensor-earnings
        { licensor: tx-sender }
        (merge earnings-data {
          active-licenses: (if (> (get active-licenses earnings-data) u0) 
                              (- (get active-licenses earnings-data) u1) 
                              u0)
        })
      )
    )
    
    (ok true)
  )
)

;; Read-only functions

;; Get license details
(define-read-only (get-license (license-id uint))
  (map-get? licenses { license-id: license-id })
)

;; Get IP asset details
(define-read-only (get-ip-asset (asset-id (string-utf8 256)))
  (map-get? ip-assets { asset-id: asset-id })
)

;; Get licensor earnings
(define-read-only (get-licensor-earnings (licensor principal))
  (map-get? licensor-earnings { licensor: licensor })
)

;; Get usage report
(define-read-only (get-usage-report (report-id uint))
  (map-get? license-usage-reports { report-id: report-id })
)

;; Get payment details
(define-read-only (get-payment (payment-id uint))
  (map-get? royalty-payments { payment-id: payment-id })
)

;; Get contract statistics
(define-read-only (get-contract-stats)
  {
    total-licenses: (- (var-get next-license-id) u1),
    total-royalties-distributed: (var-get total-royalties-distributed),
    platform-fee-rate: (var-get platform-fee-rate)
  }
)

;; Administrative functions

;; Update platform fee rate (owner only)
(define-public (set-platform-fee-rate (new-rate uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (<= new-rate u50) ERR_INVALID_INPUT) ;; Max 50% platform fee
    (var-set platform-fee-rate new-rate)
    (ok true)
  )
)

;; title: automated-licensing-system
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

