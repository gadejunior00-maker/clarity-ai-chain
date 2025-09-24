;; Clarity AI Chain - Decentralized AI Model Verification and Execution Platform
;; A smart contract for AI model registration, verification, and trustless execution

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_NOT_FOUND (err u101))
(define-constant ERR_INVALID_INPUT (err u102))
(define-constant ERR_INSUFFICIENT_BALANCE (err u103))
(define-constant ERR_MODEL_NOT_VERIFIED (err u104))
(define-constant ERR_EXECUTION_FAILED (err u105))
(define-constant ERR_ALREADY_EXISTS (err u106))
(define-constant ERR_INVALID_STATE (err u107))
(define-constant ERR_VERIFICATION_PENDING (err u108))

;; Data Variables
(define-data-var next-model-id uint u1)
(define-data-var next-execution-id uint u1)
(define-data-var verification-fee uint u1000) ;; Fee for model verification
(define-data-var execution-fee uint u500) ;; Base fee for AI execution
(define-data-var total-fees-collected uint u0)
(define-data-var min-verification-stake uint u5000)

;; Data Maps
(define-map ai-models
    uint
    {
        owner: principal,
        name: (string-ascii 50),
        description: (string-ascii 200),
        model-hash: (string-ascii 64),
        algorithm-type: (string-ascii 30),
        input-format: (string-ascii 100),
        output-format: (string-ascii 100),
        verification-status: (string-ascii 20), ;; "pending", "verified", "rejected"
        verification-stake: uint,
        execution-count: uint,
        accuracy-score: uint,
        is-active: bool,
        created-at: uint,
        verified-at: (optional uint)
    }
)

(define-map ai-executions
    uint
    {
        requester: principal,
        model-id: uint,
        input-data-hash: (string-ascii 64),
        output-data-hash: (optional (string-ascii 64)),
        execution-cost: uint,
        status: (string-ascii 20), ;; "pending", "processing", "completed", "failed"
        confidence-score: (optional uint),
        execution-time: (optional uint),
        created-at: uint,
        completed-at: (optional uint)
    }
)

(define-map model-verifiers
    uint
    (list 10 principal) ;; List of verifiers for each model
)

(define-map verifier-stakes
    { verifier: principal, model-id: uint }
    uint
)

(define-map user-balances principal uint)
(define-map user-execution-history principal (list 50 uint))
(define-map model-execution-queue uint (list 100 uint)) ;; Queue of pending executions per model

;; Read-only functions
(define-read-only (get-ai-model (model-id uint))
    (map-get? ai-models model-id)
)

(define-read-only (get-execution (execution-id uint))
    (map-get? ai-executions execution-id)
)

(define-read-only (get-user-balance (user principal))
    (default-to u0 (map-get? user-balances user))
)

(define-read-only (get-user-execution-history (user principal))
    (default-to (list) (map-get? user-execution-history user))
)

(define-read-only (get-model-verifiers (model-id uint))
    (default-to (list) (map-get? model-verifiers model-id))
)

(define-read-only (get-verifier-stake (verifier principal) (model-id uint))
    (default-to u0 (map-get? verifier-stakes { verifier: verifier, model-id: model-id }))
)

(define-read-only (get-next-model-id)
    (var-get next-model-id)
)

(define-read-only (get-next-execution-id)
    (var-get next-execution-id)
)

(define-read-only (get-verification-fee)
    (var-get verification-fee)
)

(define-read-only (get-execution-fee)
    (var-get execution-fee)
)

(define-read-only (get-total-fees-collected)
    (var-get total-fees-collected)
)

(define-read-only (get-model-execution-queue (model-id uint))
    (default-to (list) (map-get? model-execution-queue model-id))
)

;; Private functions
(define-private (calculate-execution-cost (model-id uint) (complexity-factor uint))
    (let ((base-fee (var-get execution-fee))
          (model-info (unwrap-panic (get-ai-model model-id))))
        (* base-fee (+ u1 complexity-factor))
    )
)

(define-private (update-user-execution-history (user principal) (execution-id uint))
    (let ((current-history (get-user-execution-history user)))
        (map-set user-execution-history user 
            (unwrap-panic (as-max-len? (append current-history execution-id) u50)))
    )
)

(define-private (add-to-execution-queue (model-id uint) (execution-id uint))
    (let ((current-queue (get-model-execution-queue model-id)))
        (map-set model-execution-queue model-id
            (unwrap-panic (as-max-len? (append current-queue execution-id) u100)))
    )
)

;; Public functions

;; Register a new AI model
(define-public (register-ai-model
    (name (string-ascii 50))
    (description (string-ascii 200))
    (model-hash (string-ascii 64))
    (algorithm-type (string-ascii 30))
    (input-format (string-ascii 100))
    (output-format (string-ascii 100)))
    (let ((model-id (var-get next-model-id))
          (user-balance (get-user-balance tx-sender))
          (verification-cost (var-get verification-fee)))
        
        (asserts! (> (len name) u0) ERR_INVALID_INPUT)
        (asserts! (> (len model-hash) u0) ERR_INVALID_INPUT)
        (asserts! (>= user-balance verification-cost) ERR_INSUFFICIENT_BALANCE)
        
        ;; Deduct verification fee
        (map-set user-balances tx-sender (- user-balance verification-cost))
        
        ;; Create model entry
        (map-set ai-models model-id {
            owner: tx-sender,
            name: name,
            description: description,
            model-hash: model-hash,
            algorithm-type: algorithm-type,
            input-format: input-format,
            output-format: output-format,
            verification-status: "pending",
            verification-stake: verification-cost,
            execution-count: u0,
            accuracy-score: u0,
            is-active: false,
            created-at: stacks-block-height,
            verified-at: none
        })
        
        ;; Update fees collected
        (var-set total-fees-collected (+ (var-get total-fees-collected) verification-cost))
        
        ;; Increment model ID counter
        (var-set next-model-id (+ model-id u1))
        
        (ok model-id)
    )
)

;; Verify an AI model (can be called by multiple verifiers)
(define-public (verify-ai-model (model-id uint) (accuracy-score uint) (stake-amount uint))
    (let ((model-info (unwrap! (get-ai-model model-id) ERR_NOT_FOUND))
          (user-balance (get-user-balance tx-sender))
          (min-stake (var-get min-verification-stake)))
        
        (asserts! (not (is-eq tx-sender (get owner model-info))) ERR_UNAUTHORIZED)
        (asserts! (is-eq (get verification-status model-info) "pending") ERR_INVALID_STATE)
        (asserts! (>= stake-amount min-stake) ERR_INSUFFICIENT_BALANCE)
        (asserts! (>= user-balance stake-amount) ERR_INSUFFICIENT_BALANCE)
        (asserts! (<= accuracy-score u100) ERR_INVALID_INPUT)
        
        ;; Deduct stake amount
        (map-set user-balances tx-sender (- user-balance stake-amount))
        
        ;; Add verifier to model
        (let ((current-verifiers (get-model-verifiers model-id)))
            (map-set model-verifiers model-id 
                (unwrap-panic (as-max-len? (append current-verifiers tx-sender) u10)))
        )
        
        ;; Record verifier stake
        (map-set verifier-stakes { verifier: tx-sender, model-id: model-id } stake-amount)
        
        ;; Update model with verification info (simplified - in reality would need consensus)
        (map-set ai-models model-id (merge model-info {
            verification-status: "verified",
            accuracy-score: accuracy-score,
            is-active: true,
            verified-at: (some stacks-block-height)
        }))
        
        (ok true)
    )
)

;; Submit AI execution request
(define-public (request-ai-execution
    (model-id uint)
    (input-data-hash (string-ascii 64))
    (complexity-factor uint))
    (let ((execution-id (var-get next-execution-id))
          (model-info (unwrap! (get-ai-model model-id) ERR_NOT_FOUND))
          (execution-cost (calculate-execution-cost model-id complexity-factor))
          (user-balance (get-user-balance tx-sender)))
        
        (asserts! (is-eq (get verification-status model-info) "verified") ERR_MODEL_NOT_VERIFIED)
        (asserts! (get is-active model-info) ERR_INVALID_STATE)
        (asserts! (>= user-balance execution-cost) ERR_INSUFFICIENT_BALANCE)
        (asserts! (> (len input-data-hash) u0) ERR_INVALID_INPUT)
        
        ;; Deduct execution cost
        (map-set user-balances tx-sender (- user-balance execution-cost))
        
        ;; Create execution entry
        (map-set ai-executions execution-id {
            requester: tx-sender,
            model-id: model-id,
            input-data-hash: input-data-hash,
            output-data-hash: none,
            execution-cost: execution-cost,
            status: "pending",
            confidence-score: none,
            execution-time: none,
            created-at: stacks-block-height,
            completed-at: none
        })
        
        ;; Add to execution queue
        (add-to-execution-queue model-id execution-id)
        
        ;; Update user execution history
        (update-user-execution-history tx-sender execution-id)
        
        ;; Update model execution count
        (map-set ai-models model-id (merge model-info {
            execution-count: (+ (get execution-count model-info) u1)
        }))
        
        ;; Increment execution ID counter
        (var-set next-execution-id (+ execution-id u1))
        
        (ok execution-id)
    )
)

;; Complete AI execution (called by model owner or authorized processor)
(define-public (complete-ai-execution
    (execution-id uint)
    (output-data-hash (string-ascii 64))
    (confidence-score uint)
    (execution-time uint))
    (let ((execution-info (unwrap! (get-execution execution-id) ERR_NOT_FOUND))
          (model-info (unwrap! (get-ai-model (get model-id execution-info)) ERR_NOT_FOUND)))
        
        (asserts! (is-eq tx-sender (get owner model-info)) ERR_UNAUTHORIZED)
        (asserts! (is-eq (get status execution-info) "pending") ERR_INVALID_STATE)
        (asserts! (> (len output-data-hash) u0) ERR_INVALID_INPUT)
        (asserts! (<= confidence-score u100) ERR_INVALID_INPUT)
        
        ;; Update execution with results
        (map-set ai-executions execution-id (merge execution-info {
            output-data-hash: (some output-data-hash),
            status: "completed",
            confidence-score: (some confidence-score),
            execution-time: (some execution-time),
            completed-at: (some stacks-block-height)
        }))
        
        ;; Pay model owner (minus platform fee)
        (let ((execution-cost (get execution-cost execution-info))
              (platform-fee (/ execution-cost u10)) ;; 10% platform fee
              (owner-payment (- execution-cost platform-fee))
              (owner-balance (get-user-balance tx-sender)))
            
            (map-set user-balances tx-sender (+ owner-balance owner-payment))
            (var-set total-fees-collected (+ (var-get total-fees-collected) platform-fee))
        )
        
        (ok true)
    )
)

;; Deposit funds to user balance
(define-public (deposit-funds (amount uint))
    (let ((current-balance (get-user-balance tx-sender)))
        (asserts! (> amount u0) ERR_INVALID_INPUT)
        
        ;; In a real implementation, this would involve STX transfer
        (map-set user-balances tx-sender (+ current-balance amount))
        
        (ok true)
    )
)

;; Withdraw funds from user balance
(define-public (withdraw-funds (amount uint))
    (let ((current-balance (get-user-balance tx-sender)))
        (asserts! (>= current-balance amount) ERR_INSUFFICIENT_BALANCE)
        (asserts! (> amount u0) ERR_INVALID_INPUT)
        
        (map-set user-balances tx-sender (- current-balance amount))
        
        ;; In a real implementation, this would involve STX transfer
        (ok true)
    )
)

;; Update model status (activate/deactivate)
(define-public (update-model-status (model-id uint) (is-active bool))
    (let ((model-info (unwrap! (get-ai-model model-id) ERR_NOT_FOUND)))
        (asserts! (is-eq tx-sender (get owner model-info)) ERR_UNAUTHORIZED)
        (asserts! (is-eq (get verification-status model-info) "verified") ERR_MODEL_NOT_VERIFIED)
        
        (map-set ai-models model-id (merge model-info {
            is-active: is-active
        }))
        
        (ok true)
    )
)

;; Admin function to update fees (only contract owner)
(define-public (update-fees (new-verification-fee uint) (new-execution-fee uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        (asserts! (> new-verification-fee u0) ERR_INVALID_INPUT)
        (asserts! (> new-execution-fee u0) ERR_INVALID_INPUT)
        
        (var-set verification-fee new-verification-fee)
        (var-set execution-fee new-execution-fee)
        (ok true)
    )
)

;; Admin function to withdraw collected fees (only contract owner)
(define-public (withdraw-platform-fees)
    (let ((total-fees (var-get total-fees-collected)))
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        (asserts! (> total-fees u0) ERR_INSUFFICIENT_BALANCE)
        
        (var-set total-fees-collected u0)
        ;; In a real implementation, this would transfer STX to contract owner
        (ok total-fees)
    )
)