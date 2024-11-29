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
(define-constant ERR_INVALID_SOURCE_CHAIN (err u106))
(define-constant ERR_BELOW_MINIMUM_AMOUNT (err u107))
(define-constant ERR_DUPLICATE_CONFIRMATION (err u108))
(define-constant ERR_INVALID_RELAYER (err u109))

;; Data Variables
(define-data-var bridge-minimum-transfer-amount uint u1000000)
(define-data-var bridge-operation-paused bool false)
(define-data-var required-relayer-confirmations uint u3)
(define-data-var total-transfer-count uint u0)

;; Data Maps
(define-map user-token-balances principal uint)
(define-map authorized-relayers principal bool)
(define-map processed-transfer-records
    {tx-hash: (buff 32), origin-chain: uint}
    {
        amount: uint,
        recipient: principal,
        status: (string-ascii 20),
        confirmations: uint
    }
)

(define-map active-transfer-requests
    uint
    {
        amount: uint,
        sender: principal,
        recipient: principal,
        source-chain: uint,
        target-chain: uint,
        status: (string-ascii 20)
    }
)

;; Private Functions
(define-private (is-contract-owner)
    (is-eq tx-sender CONTRACT_OWNER)
)

(define-private (validate-relayer (relayer principal))
    (let ((is-authorized (default-to false (map-get? authorized-relayers relayer))))
        (asserts! is-authorized ERR_INVALID_RELAYER)
        (ok true)
    )
)

(define-private (validate-transfer-params 
    (amount uint) 
    (recipient principal) 
    (target-chain uint)
)
    (begin
        (asserts! (>= amount (var-get bridge-minimum-transfer-amount)) 
                 ERR_BELOW_MINIMUM_AMOUNT)
        (asserts! (is-some (map-get? user-token-balances tx-sender))
                 ERR_INSUFFICIENT_BALANCE)
        (asserts! (>= (default-to u0 (map-get? user-token-balances tx-sender)) amount)
                 ERR_INSUFFICIENT_BALANCE)
        (asserts! (> target-chain u0) ERR_INVALID_SOURCE_CHAIN)
        (ok true)
    )
)

;; Public Functions
(define-public (register-relayer (relayer principal))
    (begin
        (asserts! (is-contract-owner) ERR_OWNER_ONLY)
        (try! (validate-relayer-address relayer))
        (map-set authorized-relayers relayer true)
        (ok true)
    )
)

(define-public (remove-relayer (relayer principal))
    (begin
        (asserts! (is-contract-owner) ERR_OWNER_ONLY)
        (try! (validate-relayer-address relayer))
        (map-delete authorized-relayers relayer)
        (ok true)
    )
)

(define-private (validate-relayer-address (relayer principal))
    (begin
        (asserts! (not (is-eq relayer CONTRACT_OWNER)) ERR_INVALID_PARAMETERS)
        (ok true)
    )
)

(define-public (initiate-transfer 
    (amount uint)
    (recipient principal)
    (target-chain uint)
)
    (let (
        (transfer-id (var-get total-transfer-count))
    )
        (asserts! (not (var-get bridge-operation-paused)) 
                 ERR_INVALID_BRIDGE_STATUS)
        (try! (validate-transfer-params amount recipient target-chain))
        
        ;; Update sender balance
        (map-set user-token-balances 
            tx-sender 
            (- (default-to u0 (map-get? user-token-balances tx-sender)) amount)
        )
        
        ;; Record transfer
        (map-set active-transfer-requests transfer-id {
            amount: amount,
            sender: tx-sender,
            recipient: recipient,
            source-chain: u1,
            target-chain: target-chain,
            status: "PENDING"
        })
        
        (var-set total-transfer-count (+ transfer-id u1))
        (ok transfer-id)
    )
)

(define-public (confirm-transfer 
    (transfer-id uint)
    (tx-hash (buff 32))
)
    (let (
        (transfer-data (unwrap! (map-get? active-transfer-requests transfer-id) 
                               ERR_TRANSFER_NOT_FOUND))
        (current-confirmations (default-to u0 
            (get confirmations 
                (map-get? processed-transfer-records 
                    {
                        tx-hash: tx-hash,
                        origin-chain: (get target-chain transfer-data)
                    }
                )
            ))
        )
    )
        (try! (validate-relayer tx-sender))
        (asserts! (not (var-get bridge-operation-paused)) 
                 ERR_INVALID_BRIDGE_STATUS)
        
        ;; Update records
        (map-set processed-transfer-records 
            {
                tx-hash: tx-hash,
                origin-chain: (get target-chain transfer-data)
            }
            {
                amount: (get amount transfer-data),
                recipient: (get recipient transfer-data),
                status: "CONFIRMED",
                confirmations: (+ current-confirmations u1)
            }
        )
        
        ;; Check confirmation threshold
        (if (>= (+ current-confirmations u1) (var-get required-relayer-confirmations))
            (begin
                (map-set active-transfer-requests transfer-id 
                    (merge transfer-data {status: "COMPLETED"})
                )
                (ok true)
            )
            (ok false)
        )
    )
)