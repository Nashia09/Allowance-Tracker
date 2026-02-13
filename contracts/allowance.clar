(define-constant ERR-UNAUTHORIZED (err u401))
(define-constant ERR-INSUFFICIENT-ALLOWANCE (err u402))
(define-constant ERR-NOT-FOUND (err u404))
(define-constant ERR-ALREADY-AUTHORIZED (err u409))
(define-constant ERR-INVALID-AMOUNT (err u400))
(define-constant ERR-INVALID-INTERVAL (err u403))
(define-constant ERR-JAR-ALREADY-EXISTS (err u410))
(define-constant ERR-JAR-NOT-FOUND (err u411))
(define-constant ERR-JAR-LOCKED (err u412))
(define-constant ERR-BOUNTY-NOT-FOUND (err u413))
(define-constant ERR-BOUNTY-LOCKED (err u414))
(define-constant ERR-BOUNTY-WRONG-STATE (err u415))
(define-constant ERR-INVALID-OWNERS (err u416))
(define-constant ERR-INVALID-THRESHOLD (err u417))
(define-constant ERR-ALREADY-APPROVED (err u418))
(define-constant ERR-PROPOSAL-NOT-FOUND (err u419))
(define-constant ERR-PROPOSAL-CLOSED (err u420))

;; Maps parent-child pairs to allowance data (amount, spent, active status)
(define-map allowance-data
  {
    parent: principal,
    child: principal,
  }
  {
    amount: uint,
    spent: uint,
    active: bool,
  }
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

;; Feature 2: Targeted Savings Jars
(define-map savings-jars
  {
    owner: principal,
    name: (string-ascii 32),
  }
  {
    target: uint,
    balance: uint,
  }
)

;; Feature 3: Task-Based Bounties
(define-data-var bounty-nonce uint u0)

(define-map bounties
  { id: uint }
  {
    parent: principal,
    amount: uint,
    status: (string-ascii 10), ;; "OPEN", "DONE", "PAID"
    description: (string-ascii 64),
  }
)

;; Feature 4: Multi-Sig Joint Accounts
(define-data-var account-nonce uint u0)
(define-data-var proposal-nonce uint u0)

(define-map joint-accounts
  { id: uint }
  {
    owners: (list 5 principal),
    balance: uint,
    threshold: uint,
    name: (string-ascii 32),
  }
)

(define-map proposals
  { id: uint }
  {
    account-id: uint,
    to: principal,
    amount: uint,
    approver-count: uint,
    approvers: (list 5 principal), ;; Track who has approved
    active: bool,
  }
)

;; Maps parents to their list of authorized children
(define-map parent-children
  { parent: principal }
  { children: (list 100 principal) }
)

(define-read-only (get-allowance
    (parent principal)
    (child principal)
  )
  (map-get? allowance-data {
    parent: parent,
    child: child,
  })
)

(define-read-only (get-authorization
    (parent principal)
    (child principal)
  )
  (map-get? authorizations {
    parent: parent,
    child: child,
  })
)

(define-read-only (get-children (parent principal))
  (default-to { children: (list) } (map-get? parent-children { parent: parent }))
)

;; Get remaining allowance for a child
(define-read-only (get-remaining
    (parent principal)
    (child principal)
  )
  (let ((allowance (unwrap! (get-allowance parent child) ERR-NOT-FOUND)))
    (ok (- (get amount allowance) (get spent allowance)))
  )
)

;; Set or update allowance amount for an authorized child
(define-public (set-allowance
    (child principal)
    (amount uint)
  )
  (let (
      (parent tx-sender)
      (existing (get-allowance parent child))
    )
    (asserts! (is-some (get-authorization parent child)) ERR-UNAUTHORIZED)
    (ok (map-set allowance-data {
      parent: parent,
      child: child,
    } {
      amount: amount,
      spent: (if (is-none existing)
        u0
        (get spent (unwrap! existing ERR-NOT-FOUND))
      ),
      active: true,
    }))
  )
)

;; Set automatic allowance renewal interval
(define-public (set-renewal
    (child principal)
    (interval uint)
  )
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
    (map-set authorizations {
      parent: parent,
      child: child,
    } {
      created-at: stacks-block-height,
      created-by: parent,
    })
    (let (
        (parent-record (default-to { children: (list) }
          (map-get? parent-children { parent: parent })
        ))
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
  (let ((parent tx-sender))
    (asserts! (is-some (get-authorization parent child)) ERR-NOT-FOUND)
    (map-delete authorizations {
      parent: parent,
      child: child,
    })
    (map-delete allowance-renewal {
      parent: parent,
      child: child,
    })
    (map-set allowance-data {
      parent: parent,
      child: child,
    } {
      amount: u0,
      spent: u0,
      active: false,
    })
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
(define-public (spend-allowance
    (parent principal)
    (amount uint)
  )
  (let (
      (child tx-sender)
      (allowance (unwrap! (get-allowance parent child) ERR-NOT-FOUND))
      (renewal (map-get? allowance-renewal {
        parent: parent,
        child: child,
      }))
      (current-height stacks-block-height)
      (should-renew (match renewal
        r (>= current-height (+ (get last-renewal r) (get interval r)))
        false
      ))
      (current-spent (if should-renew
        u0
        (get spent allowance)
      ))
      (remaining (- (get amount allowance) current-spent))
    )
    (asserts! (get active allowance) ERR-UNAUTHORIZED)
    (asserts! (>= remaining amount) ERR-INSUFFICIENT-ALLOWANCE)

    ;; Ensure parent has enough funds in vault
    (let ((parent-balance (default-to u0 (get balance (map-get? vault-balances { parent: parent })))))
      (asserts! (>= parent-balance amount) ERR-INSUFFICIENT-ALLOWANCE)

      ;; 1. Update renewal (if needed)
      (if should-renew
        (map-set allowance-renewal {
          parent: parent,
          child: child,
        } {
          interval: (unwrap-panic (get interval renewal)),
          last-renewal: current-height,
        })
        false
      )

      ;; 2. Transfer STX
      (try! (as-contract (stx-transfer? amount tx-sender child)))

      ;; 3. Deduct from parent's vault balance
      (map-set vault-balances { parent: parent } { balance: (- parent-balance amount) })

      ;; 4. Update allowance record
      (ok (map-set allowance-data {
        parent: parent,
        child: child,
      } {
        amount: (get amount allowance),
        spent: (+ current-spent amount),
        active: true,
      }))
    )
  )
)

;; Reset a child's spending back to zero (e.g., monthly reset)
(define-public (reset-spending (child principal))
  (let (
      (parent tx-sender)
      (allowance (unwrap! (get-allowance parent child) ERR-NOT-FOUND))
    )
    (ok (map-set allowance-data {
      parent: parent,
      child: child,
    } {
      amount: (get amount allowance),
      spent: u0,
      active: (get active allowance),
    }))
  )
)

(define-read-only (is-authorized
    (parent principal)
    (child principal)
  )
  (is-some (get-authorization parent child))
)

(define-read-only (is-allowance-active
    (parent principal)
    (child principal)
  )
  (match (get-allowance parent child)
    allowance (get active allowance)
    false
  )
)

(define-read-only (get-allowance-summary
    (parent principal)
    (child principal)
  )
  (match (get-allowance parent child)
    allowance (ok {
      total: (get amount allowance),
      spent: (get spent allowance),
      remaining: (- (get amount allowance) (get spent allowance)),
      active: (get active allowance),
    })
    ERR-NOT-FOUND
  )
)

(define-read-only (get-vault-balance (parent principal))
  (default-to u0 (get balance (map-get? vault-balances { parent: parent })))
)

;; --------------------------------------------------------------------------
;; Feature 2: Targeted Savings Jars Implementation
;; --------------------------------------------------------------------------

(define-public (create-jar
    (name (string-ascii 32))
    (target uint)
  )
  (let ((child tx-sender))
    (asserts!
      (is-none (map-get? savings-jars {
        owner: child,
        name: name,
      }))
      ERR-JAR-ALREADY-EXISTS
    )
    (asserts! (> target u0) ERR-INVALID-AMOUNT)
    (ok (map-set savings-jars {
      owner: child,
      name: name,
    } {
      target: target,
      balance: u0,
    }))
  )
)

(define-public (add-to-jar
    (parent principal)
    (name (string-ascii 32))
    (amount uint)
  )
  (let (
      (child tx-sender)
      (allowance (unwrap! (get-allowance parent child) ERR-NOT-FOUND))
      (jar (unwrap!
        (map-get? savings-jars {
          owner: child,
          name: name,
        })
        ERR-JAR-NOT-FOUND
      ))
      (current-limit (- (get amount allowance) (get spent allowance)))
      (parent-balance (default-to u0 (get balance (map-get? vault-balances { parent: parent }))))
    )
    ;; 1. Validate Allowance & Solvency
    (asserts! (get active allowance) ERR-UNAUTHORIZED)
    (asserts! (>= current-limit amount) ERR-INSUFFICIENT-ALLOWANCE)
    (asserts! (>= parent-balance amount) ERR-INSUFFICIENT-ALLOWANCE)

    ;; 2. Deduct from Parent Vault (Movement of funds to Jar custody)
    (map-set vault-balances { parent: parent } { balance: (- parent-balance amount) })

    ;; 3. Update Allowance (Mark as spent)
    (map-set allowance-data {
      parent: parent,
      child: child,
    } {
      amount: (get amount allowance),
      spent: (+ (get spent allowance) amount),
      active: true,
    })

    ;; 4. Credit Jar
    (ok (map-set savings-jars {
      owner: child,
      name: name,
    } {
      target: (get target jar),
      balance: (+ (get balance jar) amount),
    }))
  )
)

(define-public (withdraw-jar (name (string-ascii 32)))
  (let (
      (child tx-sender)
      (jar (unwrap!
        (map-get? savings-jars {
          owner: child,
          name: name,
        })
        ERR-JAR-NOT-FOUND
      ))
    )
    ;; Assert target reached
    (asserts! (>= (get balance jar) (get target jar)) ERR-JAR-LOCKED)

    ;; Transfer to child
    (try! (as-contract (stx-transfer? (get balance jar) tx-sender child)))

    ;; Close jar
    (ok (map-delete savings-jars {
      owner: child,
      name: name,
    }))
  )
)

(define-read-only (get-jar
    (owner principal)
    (name (string-ascii 32))
  )
  (map-get? savings-jars {
    owner: owner,
    name: name,
  })
)

;; --------------------------------------------------------------------------
;; Feature 3: Task-Based Bounties Implementation
;; --------------------------------------------------------------------------

(define-public (post-bounty
    (amount uint)
    (description (string-ascii 64))
  )
  (let (
      (parent tx-sender)
      (new-id (+ (var-get bounty-nonce) u1))
      (parent-balance (default-to u0 (get balance (map-get? vault-balances { parent: parent }))))
    )
    ;; 1. Lock funds from vault
    (asserts! (>= parent-balance amount) ERR-INSUFFICIENT-ALLOWANCE)
    (map-set vault-balances { parent: parent } { balance: (- parent-balance amount) })

    ;; 2. Create Bounty
    (map-set bounties { id: new-id } {
      parent: parent,
      amount: amount,
      status: "OPEN",
      description: description,
    })
    (var-set bounty-nonce new-id)
    (ok new-id)
  )
)

(define-public (complete-bounty (id uint))
  (let (
      (child tx-sender)
      (bounty (unwrap! (map-get? bounties { id: id }) ERR-BOUNTY-NOT-FOUND))
    )
    ;; Only "OPEN" bounties can be completed
    (asserts! (is-eq (get status bounty) "OPEN") ERR-BOUNTY-WRONG-STATE)

    ;; Must be an authorized child of the parent
    (asserts! (is-some (get-authorization (get parent bounty) child))
      ERR-UNAUTHORIZED
    )

    ;; Update status to DONE
    (ok (map-set bounties { id: id } (merge bounty { status: "DONE" })))
  )
)

(define-public (approve-bounty
    (id uint)
    (child principal)
  )
  (let (
      (parent tx-sender)
      (bounty (unwrap! (map-get? bounties { id: id }) ERR-BOUNTY-NOT-FOUND))
    )
    ;; 1. Verify ownership and state
    (asserts! (is-eq (get parent bounty) parent) ERR-UNAUTHORIZED)
    (asserts! (is-eq (get status bounty) "DONE") ERR-BOUNTY-WRONG-STATE)

    ;; 2. Pay Out (Trustless transfer from contract)
    (try! (as-contract (stx-transfer? (get amount bounty) tx-sender child)))

    ;; 3. Update status to PAID. History preserved.
    (ok (map-set bounties { id: id } (merge bounty { status: "PAID" })))
  )
)

(define-public (cancel-bounty (id uint))
  (let (
      (parent tx-sender)
      (bounty (unwrap! (map-get? bounties { id: id }) ERR-BOUNTY-NOT-FOUND))
      (current-balance (default-to u0 (get balance (map-get? vault-balances { parent: parent }))))
    )
    ;; Only owner can cancel
    (asserts! (is-eq (get parent bounty) parent) ERR-UNAUTHORIZED)
    ;; Cannot cancel if already PAID
    (asserts! (not (is-eq (get status bounty) "PAID")) ERR-BOUNTY-WRONG-STATE)

    ;; Refund to Vault
    (map-set vault-balances { parent: parent } { balance: (+ current-balance (get amount bounty)) })

    ;; Delete the bounty to clean up state
    (ok (map-delete bounties { id: id }))
  )
)

(define-read-only (get-bounty (id uint))
  (map-get? bounties { id: id })
)

;; --------------------------------------------------------------------------
;; Feature 4: Multi-Sig Joint Accounts Implementation
;; --------------------------------------------------------------------------

(define-public (create-joint-account
    (name (string-ascii 32))
    (owners (list 5 principal))
    (threshold uint)
  )
  (let ((new-id (+ (var-get account-nonce) u1)))
    (asserts! (>= (len owners) u2) ERR-INVALID-OWNERS)
    ;; At least 2 owners
    (asserts! (and (> threshold u0) (<= threshold (len owners)))
      ERR-INVALID-THRESHOLD
    )

    (map-set joint-accounts { id: new-id } {
      name: name,
      owners: owners,
      balance: u0,
      threshold: threshold,
    })
    (var-set account-nonce new-id)
    (ok new-id)
  )
)

(define-public (fund-joint-account
    (id uint)
    (amount uint)
  )
  (let ((account (unwrap! (map-get? joint-accounts { id: id }) ERR-NOT-FOUND)))
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    (ok (map-set joint-accounts { id: id }
      (merge account { balance: (+ (get balance account) amount) })
    ))
  )
)

(define-public (request-withdrawal
    (account-id uint)
    (amount uint)
  )
  (let (
      (account (unwrap! (map-get? joint-accounts { id: account-id }) ERR-NOT-FOUND))
      (new-proposal-id (+ (var-get proposal-nonce) u1))
      (sender tx-sender)
    )
    (asserts! (is-some (index-of? (get owners account) sender)) ERR-UNAUTHORIZED)
    (asserts! (>= (get balance account) amount) ERR-INSUFFICIENT-ALLOWANCE)

    (map-set proposals { id: new-proposal-id } {
      account-id: account-id,
      to: sender,
      amount: amount,
      approver-count: u1,
      approvers: (list sender),
      active: true,
    })
    (var-set proposal-nonce new-proposal-id)
    (ok new-proposal-id)
  )
)

(define-public (approve-withdrawal (proposal-id uint))
  (let (
      (proposal (unwrap! (map-get? proposals { id: proposal-id }) ERR-PROPOSAL-NOT-FOUND))
      (account (unwrap! (map-get? joint-accounts { id: (get account-id proposal) })
        ERR-NOT-FOUND
      ))
      (sender tx-sender)
    )
    (asserts! (get active proposal) ERR-PROPOSAL-CLOSED)
    (asserts! (is-some (index-of? (get owners account) sender)) ERR-UNAUTHORIZED)
    (asserts! (is-none (index-of? (get approvers proposal) sender))
      ERR-ALREADY-APPROVED
    )

    (let (
        (new-count (+ (get approver-count proposal) u1))
        (new-approvers (unwrap! (as-max-len? (append (get approvers proposal) sender) u5)
          (err u500)
        ))
      )
      ;; Check if threshold met
      (if (>= new-count (get threshold account))
        (begin
          ;; Execute Transfer
          (try! (as-contract (stx-transfer? (get amount proposal) tx-sender (get to proposal))))

          ;; Deduct Balance
          (map-set joint-accounts { id: (get account-id proposal) }
            (merge account { balance: (- (get balance account) (get amount proposal)) })
          )

          ;; Close Proposal
          (ok (map-set proposals { id: proposal-id }
            (merge proposal {
              active: false,
              approver-count: new-count,
              approvers: new-approvers,
            })
          ))
        )
        ;; Else just update count
        (ok (map-set proposals { id: proposal-id }
          (merge proposal {
            approver-count: new-count,
            approvers: new-approvers,
          })
        ))
      )
    )
  )
)

(define-read-only (get-joint-account (id uint))
  (map-get? joint-accounts { id: id })
)

(define-read-only (get-proposal (id uint))
  (map-get? proposals { id: id })
)
