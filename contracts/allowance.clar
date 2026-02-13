(define-constant ERR-UNAUTHORIZED (err u401)) 
(define-constant ERR-INSUFFICIENT-ALLOWANCE (err u402))
(define-constant ERR-NOT-FOUND (err u404))
(define-constant ERR-ALREADY-AUTHORIZED (err u409))
(define-constant ERR-INVALID-AMOUNT (err u400))
(define-constant ERR-INVALID-INTERVAL (err u403))

;; Maps parent-child pairs to allowance data (amount, spent, active status)
(define-map allowance-data
  { parent: principal, child: principal }
  { amount: uint, spent: uint, active: bool }
)

;; Maps parent-child pairs to authorization metadata
(define-map authorizations
  {
    parent: principal,
    child: principal,
  }
  {
    created-at: uint,
    created-by: principal,
  }
)

;; Maps parent-child pairs to renewal settings
(define-map allowance-renewal
  {
    parent: principal,
    child: principal,
  }
  {
    interval: uint,
    last-renewal: uint,
  }
)

;; Maps parent to their deposited balance in the vault
(define-map vault-balances
  { parent: principal }
  { balance: uint }
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

;; Set automatic allowance renewal interval
(define-public (set-renewal (child principal) (interval uint))
  (let ((parent tx-sender))
    (asserts! (is-some (get-authorization parent child)) ERR-UNAUTHORIZED)
    (asserts! (> interval u0) ERR-INVALID-INTERVAL)
    (ok (map-set allowance-renewal {
      parent: parent,
      child: child,
    } {
      interval: interval,
      last-renewal: stacks-block-height,
    }))
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
    (map-delete allowance-renewal { parent: parent, child: child })
    (map-set allowance-data
      { parent: parent, child: child }
      { amount: u0, spent: u0, active: false }
    )
    (ok true)
  )
)

;; Deposit funds into the contract vault
(define-public (deposit (amount uint))
  (let (
      (parent tx-sender)
      (current-balance (default-to u0 (get balance (map-get? vault-balances { parent: parent }))))
    )
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    (ok (map-set vault-balances { parent: parent } { balance: (+ current-balance amount) }))
  )
)

;; Withdraw unused funds from the vault
(define-public (withdraw-funds (amount uint))
  (let (
      (parent tx-sender)
      (current-balance (default-to u0 (get balance (map-get? vault-balances { parent: parent }))))
    )
    (asserts! (>= current-balance amount) ERR-INSUFFICIENT-ALLOWANCE)
    (try! (as-contract (stx-transfer? amount tx-sender parent)))
    (ok (map-set vault-balances { parent: parent } { balance: (- current-balance amount) }))
  )
)

;; Child spends from their allowance
(define-public (spend-allowance (parent principal) (amount uint))
  (let (
    (child tx-sender)
    (allowance (unwrap! (get-allowance parent child) ERR-NOT-FOUND))
    (renewal (map-get? allowance-renewal { parent: parent, child: child }))
    (current-height stacks-block-height)
    (should-renew (match renewal
      r (>= current-height (+ (get last-renewal r) (get interval r)))
      false
    ))
    (current-spent (if should-renew u0 (get spent allowance)))
    (remaining (- (get amount allowance) current-spent))
  )
    (asserts! (get active allowance) ERR-UNAUTHORIZED)
    (asserts! (>= remaining amount) ERR-INSUFFICIENT-ALLOWANCE)

    ;; Ensure parent has enough funds in vault
    (let ((parent-balance (default-to u0 (get balance (map-get? vault-balances { parent: parent })))))
      (asserts! (>= parent-balance amount) ERR-INSUFFICIENT-ALLOWANCE)

      ;; 1. Update renewal (if needed)
      (if should-renew
        (map-set allowance-renewal
          { parent: parent, child: child }
          {
            interval: (unwrap-panic (get interval renewal)),
            last-renewal: current-height,
          }
        )
        false
      )

      ;; 2. Transfer STX
      (try! (as-contract (stx-transfer? amount tx-sender child)))

      ;; 3. Deduct from parent's vault balance
      (map-set vault-balances { parent: parent } { balance: (- parent-balance amount) })

      ;; 4. Update allowance record
      (ok (map-set allowance-data
        { parent: parent, child: child }
        {
          amount: (get amount allowance),
          spent: (+ current-spent amount),
          active: true,
        }
      ))
    )
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

(define-read-only (get-vault-balance (parent principal))
  (default-to u0 (get balance (map-get? vault-balances { parent: parent })))
)
