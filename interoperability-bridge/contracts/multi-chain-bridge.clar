;; Interoperability Bridge Contract
;; This contract enables cross-chain token transfers with robust security features

;; Error Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_OWNER_ONLY (err u100))
(define-constant ERR_INVALID_PARAMETERS (err u101))
(define-constant ERR_INSUFFICIENT_BALANCE (err u102))
(define-constant ERR_UNAUTHORIZED_ACCESS (err u103))
(define-constant ERR_INVALID_BRIDGE_STATUS (err u104))
(define-constant ERR_TRANSFER_NOT_FOUND (err u105))
(define-constant ERR_INVALID_CHAIN_ID (err u106))
(define-constant ERR_BELOW_MINIMUM_AMOUNT (err u107))
(define-constant ERR_DUPLICATE_CONFIRMATION (err u108))

;; Data Variables
(define-data-var bridge-minimum-transfer-amount uint u1000000)
(define-data-var bridge-operation-paused bool false)
(define-data-var required-relayer-confirmations uint u3)
(define-data-var total-transfer-count uint u0)

;; Data Maps
(define-map user-token-balances principal uint)
(define-map authorized-relayers principal bool)
(define-map processed-transfer-records
    {transaction-hash: (buff 32), source-chain-id: uint}
    {
        transfer-amount: uint,
        recipient-address: principal,
        transfer-status: (string-ascii 20),
        relayer-confirmation-count: uint
    }
)

(define-map active-transfer-requests
    uint
    {
        transfer-amount: uint,
        sender-address: principal,
        recipient-address: principal,
        origin-chain-id: uint,
        destination-chain-id: uint,
        transfer-status: (string-ascii 20)
    }
)

;; Private Functions
(define-private (is-contract-owner)
    (is-eq tx-sender CONTRACT_OWNER)
)

(define-private (is-authorized-relayer (relayer-address principal))
    (default-to false (map-get? authorized-relayers relayer-address))
)

(define-private (validate-transfer-parameters 
    (transfer-amount uint) 
    (recipient-address principal) 
    (destination-chain-id uint)
)
    (and
        (>= transfer-amount (var-get bridge-minimum-transfer-amount))
        (is-some (map-get? user-token-balances tx-sender))
        (>= (default-to u0 (map-get? user-token-balances tx-sender)) transfer-amount)
        (> destination-chain-id u0)
    )
)

;; Public Functions
(define-public (initialize-bridge)
    (begin
        (asserts! (is-contract-owner) ERR_OWNER_ONLY)
        (var-set bridge-operation-paused false)
        (var-set total-transfer-count u0)
        (ok true)
    )
)

(define-public (pause-bridge-operations)
    (begin
        (asserts! (is-contract-owner) ERR_OWNER_ONLY)
        (var-set bridge-operation-paused true)
        (ok true)
    )
)

(define-public (resume-bridge-operations)
    (begin
        (asserts! (is-contract-owner) ERR_OWNER_ONLY)
        (var-set bridge-operation-paused false)
        (ok true)
    )
)

(define-public (register-relayer (relayer-address principal))
    (begin
        (asserts! (is-contract-owner) ERR_OWNER_ONLY)
        (map-set authorized-relayers relayer-address true)
        (ok true)
    )
)

(define-public (remove-relayer-authorization (relayer-address principal))
    (begin
        (asserts! (is-contract-owner) ERR_OWNER_ONLY)
        (map-delete authorized-relayers relayer-address)
        (ok true)
    )
)

(define-public (initiate-cross-chain-transfer 
    (transfer-amount uint)
    (recipient-address principal)
    (destination-chain-id uint)
)
    (let (
        (sender-address tx-sender)
        (transfer-request-id (var-get total-transfer-count))
    )
        (asserts! (not (var-get bridge-operation-paused)) ERR_INVALID_BRIDGE_STATUS)
        (asserts! (validate-transfer-parameters transfer-amount recipient-address destination-chain-id) 
                 ERR_INVALID_PARAMETERS)
        
        ;; Update sender's balance
        (map-set user-token-balances 
            sender-address 
            (- (default-to u0 (map-get? user-token-balances sender-address)) transfer-amount)
        )
        
        ;; Record transfer request
        (map-set active-transfer-requests transfer-request-id {
            transfer-amount: transfer-amount,
            sender-address: sender-address,
            recipient-address: recipient-address,
            origin-chain-id: u1,  ;; Current chain ID
            destination-chain-id: destination-chain-id,
            transfer-status: "PENDING"
        })
        
        (var-set total-transfer-count (+ transfer-request-id u1))
        (ok transfer-request-id)
    )
)

(define-public (confirm-cross-chain-transfer 
    (transfer-request-id uint)
    (transaction-hash (buff 32))
)
    (let (
        (transfer-request (unwrap! (map-get? active-transfer-requests transfer-request-id) 
                                 ERR_TRANSFER_NOT_FOUND))
        (current-confirmation-count (default-to u0 
            (get relayer-confirmation-count 
                (map-get? processed-transfer-records 
                    {
                        transaction-hash: transaction-hash,
                        source-chain-id: (get destination-chain-id transfer-request)
                    }
                )
            ))
        )
    )
        (asserts! (is-authorized-relayer tx-sender) ERR_UNAUTHORIZED_ACCESS)
        (asserts! (not (var-get bridge-operation-paused)) ERR_INVALID_BRIDGE_STATUS)
        
        ;; Update transfer records
        (map-set processed-transfer-records 
            {
                transaction-hash: transaction-hash,
                source-chain-id: (get destination-chain-id transfer-request)
            }
            {
                transfer-amount: (get transfer-amount transfer-request),
                recipient-address: (get recipient-address transfer-request),
                transfer-status: "CONFIRMED",
                relayer-confirmation-count: (+ current-confirmation-count u1)
            }
        )
        
        ;; Check if enough confirmations received
        (if (>= (+ current-confirmation-count u1) (var-get required-relayer-confirmations))
            (begin
                (map-set active-transfer-requests transfer-request-id 
                    (merge transfer-request {transfer-status: "COMPLETED"})
                )
                (ok true)
            )
            (ok false)
        )
    )
)

(define-public (deposit-tokens)
    (begin
        (asserts! (> (stx-get-balance tx-sender) u0) ERR_INSUFFICIENT_BALANCE)
        (map-set user-token-balances
            tx-sender
            (+ (default-to u0 (map-get? user-token-balances tx-sender)) (stx-get-balance tx-sender))
        )
        (ok true)
    )
)

(define-public (withdraw-tokens (withdrawal-amount uint))
    (let (
        (current-token-balance (default-to u0 (map-get? user-token-balances tx-sender)))
    )
        (asserts! (>= current-token-balance withdrawal-amount) ERR_INSUFFICIENT_BALANCE)
        (asserts! (not (var-get bridge-operation-paused)) ERR_INVALID_BRIDGE_STATUS)
        
        ;; Update balance
        (map-set user-token-balances
            tx-sender
            (- current-token-balance withdrawal-amount)
        )
        
        ;; Transfer STX
        (try! (stx-transfer? withdrawal-amount tx-sender tx-sender))
        (ok true)
    )
)

;; Read-only Functions
(define-read-only (get-user-balance (user-address principal))
    (ok (default-to u0 (map-get? user-token-balances user-address)))
)

(define-read-only (get-transfer-request-details (transfer-request-id uint))
    (ok (map-get? active-transfer-requests transfer-request-id))
)

(define-read-only (get-transfer-confirmation-count 
    (transaction-hash (buff 32))
    (chain-id uint)
)
    (ok (get relayer-confirmation-count 
        (default-to 
            {
                transfer-amount: u0,
                recipient-address: CONTRACT_OWNER,
                transfer-status: "NONE",
                relayer-confirmation-count: u0
            }
            (map-get? processed-transfer-records 
                {transaction-hash: transaction-hash, source-chain-id: chain-id}
            )
        )
    ))
)

(define-read-only (is-bridge-paused)
    (ok (var-get bridge-operation-paused))
)