(define-constant ERR-UNAUTHORIZED (err u401))  
(define-constant ERR-INSUFFICIENT-ALLOWANCE (err u402))
(define-constant ERR-NOT-FOUND (err u404))
(define-constant ERR-ALREADY-AUTHORIZED (err u409))
(define-constant ERR-INVALID-AMOUNT (err u400))

;; Maps parent-child pairs to allowance data (amount, spent, active status)
(define-map allowance-data
  { parent: principal, child: principal }
  { amount: uint, spent: uint, active: bool }
)

;; Maps parent-child pairs to authorization metadata
(define-map authorizations
  { parent: principal, child: principal }
  { created-at: uint, created-by: principal }
)

;; Maps parents to their list of authorized children
(define-map parent-children
  { parent: principal }
  { children: (list 100 principal) }
)

(define-read-only (get-allowance (parent principal) (child principal))
  (map-get? allowance-data { parent: parent, child: child })
)

(define-read-only (get-authorization (parent principal) (child principal))
  (map-get? authorizations { parent: parent, child: child })
)

(define-read-only (get-children (parent principal))
  (default-to
    { children: (list) }
    (map-get? parent-children { parent: parent })
  )
)

;; Get remaining allowance for a child
(define-read-only (get-remaining (parent principal) (child principal))
  (let (
    (allowance (unwrap! (get-allowance parent child) ERR-NOT-FOUND))
  )
    (ok (- (get amount allowance) (get spent allowance)))
  )
)

;; Set or update allowance amount for an authorized child
(define-public (set-allowance (child principal) (amount uint))
  (let (
    (parent tx-sender)
    (existing (get-allowance parent child))
  )
    (asserts! (is-some (get-authorization parent child)) ERR-UNAUTHORIZED)
    (ok (map-set allowance-data
      { parent: parent, child: child }
      { amount: amount, spent: (if (is-none existing) u0 (get spent (unwrap! existing ERR-NOT-FOUND))), active: true }
    ))
  )
)

;; Authorize a child to receive allowance from the parent
(define-public (authorize-child (child principal))
  (let (
    (parent tx-sender)
    (existing (get-authorization parent child))
  )
    (asserts! (is-none existing) ERR-ALREADY-AUTHORIZED)
    (map-set authorizations
      { parent: parent, child: child }
      { created-at: stacks-block-height, created-by: parent }
    )
    (let (
      (parent-record (default-to { children: (list) } (map-get? parent-children { parent: parent })))
      (current-children (get children parent-record))
      (updated-children (if (is-some (index-of? current-children child))
        current-children
        (unwrap! (as-max-len? (append current-children child) u100) (err u500))
      ))
    )
      (map-set parent-children { parent: parent } { children: updated-children })
      (ok true)
    )
  )
)

;; Revoke a child's authorization and reset their allowance
(define-public (revoke-child (child principal))
  (let (
    (parent tx-sender)
  )
    (asserts! (is-some (get-authorization parent child)) ERR-NOT-FOUND)
    (map-delete authorizations { parent: parent, child: child })
    (map-set allowance-data
      { parent: parent, child: child }
      { amount: u0, spent: u0, active: false }
    )
    (ok true)
  )
)

;; Child spends from their allowance
(define-public (spend-allowance (parent principal) (amount uint))
  (let (
    (child tx-sender)
    (allowance (unwrap! (get-allowance parent child) ERR-NOT-FOUND))
    (remaining (- (get amount allowance) (get spent allowance)))
  )
    (asserts! (get active allowance) ERR-UNAUTHORIZED)
    (asserts! (>= remaining amount) ERR-INSUFFICIENT-ALLOWANCE)
    (ok (map-set allowance-data
      { parent: parent, child: child }
      { 
        amount: (get amount allowance),
        spent: (+ (get spent allowance) amount),
        active: true
      }
    ))
  )
)

;; Reset a child's spending back to zero (e.g., monthly reset)
(define-public (reset-spending (child principal))
  (let (
    (parent tx-sender)
    (allowance (unwrap! (get-allowance parent child) ERR-NOT-FOUND))
  )
    (ok (map-set allowance-data
      { parent: parent, child: child }
      { 
        amount: (get amount allowance),
        spent: u0,
        active: (get active allowance)
      }
    ))
  )
)

(define-read-only (is-authorized (parent principal) (child principal))
  (is-some (get-authorization parent child))
)

(define-read-only (is-allowance-active (parent principal) (child principal))
  (match (get-allowance parent child)
    allowance (get active allowance)
    false
  )
)

(define-read-only (get-allowance-summary (parent principal) (child principal))
  (match (get-allowance parent child)
    allowance (ok {
      total: (get amount allowance),
      spent: (get spent allowance),
      remaining: (- (get amount allowance) (get spent allowance)),
      active: (get active allowance)
    })
    ERR-NOT-FOUND
  )
)
