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
(define-constant ERR_INVALID_RECIPIENT (err u110))
(define-constant ERR_INVALID_TX_HASH (err u111))
(define-constant ERR_INVALID_CHAIN_ID (err u112))

;; Data Variables
(define-data-var bridge-minimum-transfer-amount uint u1000000)
(define-data-var bridge-operation-paused bool false)
(define-data-var required-relayer-confirmations uint u3)
(define-data-var total-transfer-count uint u0)
(define-data-var max-chain-id uint u100)

;; Data Maps
(define-map user-token-balances principal uint)
(define-map authorized-relayers principal bool)
(define-map processed-transfer-records
    {transaction-hash: (buff 32), source-chain-identifier: uint}
    {
        transfer-amount: uint,
        recipient-address: principal,
        transfer-status: (string-ascii 20),
        confirmation-count: uint
    }
)

(define-map active-transfer-requests
    uint
    {
        transfer-amount: uint,
        sender-address: principal,
        recipient-address: principal,
        source-chain-identifier: uint,
        target-chain-identifier: uint,
        transfer-status: (string-ascii 20)
    }
)

;; Private Functions
(define-private (is-contract-owner)
    (is-eq tx-sender CONTRACT_OWNER)
)

(define-private (validate-relayer (relayer-address principal))
    (begin
        (asserts! (not (is-eq relayer-address CONTRACT_OWNER)) ERR_INVALID_RELAYER)
        (ok (asserts! (default-to false (map-get? authorized-relayers relayer-address)) ERR_INVALID_RELAYER))
    )
)

(define-private (validate-chain-identifier (chain-identifier uint))
    (ok (asserts! (and (> chain-identifier u0) (<= chain-identifier (var-get max-chain-id))) ERR_INVALID_CHAIN_ID))
)

(define-private (validate-recipient-address (recipient-address principal))
    (ok (asserts! (and 
        (not (is-eq recipient-address CONTRACT_OWNER)) 
        (not (is-eq recipient-address tx-sender)))
        ERR_INVALID_RECIPIENT))
)

(define-private (validate-transaction-hash (transaction-hash (buff 32)))
    (ok (asserts! (and 
        (is-eq (len transaction-hash) u32)
        (not (is-eq transaction-hash 0x0000000000000000000000000000000000000000000000000000000000000000)))
        ERR_INVALID_TX_HASH))
)

(define-private (validate-transfer-parameters 
    (transfer-amount uint) 
    (recipient-address principal) 
    (target-chain-identifier uint)
)
    (begin
        (asserts! (>= transfer-amount (var-get bridge-minimum-transfer-amount)) ERR_BELOW_MINIMUM_AMOUNT)
        (asserts! (is-some (map-get? user-token-balances tx-sender)) ERR_INSUFFICIENT_BALANCE)
        (asserts! (>= (default-to u0 (map-get? user-token-balances tx-sender)) transfer-amount) ERR_INSUFFICIENT_BALANCE)
        (try! (validate-recipient-address recipient-address))
        (try! (validate-chain-identifier target-chain-identifier))
        (ok true)
    )
)

;; Public Functions
(define-public (register-relayer (relayer-address principal))
    (begin
        (asserts! (is-contract-owner) ERR_OWNER_ONLY)
        (asserts! (not (is-eq relayer-address CONTRACT_OWNER)) ERR_INVALID_PARAMETERS)
        (map-set authorized-relayers relayer-address true)
        (ok true)
    )
)

(define-public (remove-relayer (relayer-address principal))
    (begin
        (asserts! (is-contract-owner) ERR_OWNER_ONLY)
        (asserts! (not (is-eq relayer-address CONTRACT_OWNER)) ERR_INVALID_PARAMETERS)
        (asserts! (default-to false (map-get? authorized-relayers relayer-address)) ERR_INVALID_RELAYER)
        (map-delete authorized-relayers relayer-address)
        (ok true)
    )
)

(define-public (initiate-transfer 
    (transfer-amount uint)
    (recipient-address principal)
    (target-chain-identifier uint)
)
    (let (
        (transfer-id (var-get total-transfer-count))
        (sender-balance (default-to u0 (map-get? user-token-balances tx-sender)))
    )
        (asserts! (not (var-get bridge-operation-paused)) ERR_INVALID_BRIDGE_STATUS)
        (try! (validate-transfer-parameters transfer-amount recipient-address target-chain-identifier))
        
        ;; Update sender balance with checked arithmetic
        (asserts! (>= sender-balance transfer-amount) ERR_INSUFFICIENT_BALANCE)
        (map-set user-token-balances 
            tx-sender 
            (- sender-balance transfer-amount)
        )
        
        ;; Record transfer with validated parameters
        (map-set active-transfer-requests transfer-id {
            transfer-amount: transfer-amount,
            sender-address: tx-sender,
            recipient-address: recipient-address,
            source-chain-identifier: u1,
            target-chain-identifier: target-chain-identifier,
            transfer-status: "PENDING"
        })
        
        (var-set total-transfer-count (+ transfer-id u1))
        (ok transfer-id)
    )
)

(define-public (confirm-transfer 
    (transfer-id uint)
    (transaction-hash (buff 32))
)
    (let (
        (transfer-data (unwrap! (map-get? active-transfer-requests transfer-id) ERR_TRANSFER_NOT_FOUND))
        (transfer-record {
            transaction-hash: transaction-hash,
            source-chain-identifier: (get target-chain-identifier transfer-data)
        })
        (processed-record (default-to 
            {
                transfer-amount: u0,
                recipient-address: CONTRACT_OWNER,
                transfer-status: "PENDING",
                confirmation-count: u0
            } 
            (map-get? processed-transfer-records transfer-record)))
    )
        (try! (validate-relayer tx-sender))
        (try! (validate-transaction-hash transaction-hash))
        (asserts! (not (var-get bridge-operation-paused)) ERR_INVALID_BRIDGE_STATUS)
        (asserts! (< (get confirmation-count processed-record) (var-get required-relayer-confirmations)) ERR_DUPLICATE_CONFIRMATION)
        
        ;; Update records with validated data
        (map-set processed-transfer-records 
            transfer-record
            {
                transfer-amount: (get transfer-amount transfer-data),
                recipient-address: (get recipient-address transfer-data),
                transfer-status: "CONFIRMED",
                confirmation-count: (+ (get confirmation-count processed-record) u1)
            }
        )
        
        ;; Check confirmation threshold
        (if (>= (+ (get confirmation-count processed-record) u1) (var-get required-relayer-confirmations))
            (begin
                (try! (validate-chain-identifier (get target-chain-identifier transfer-data)))
                (map-set active-transfer-requests transfer-id 
                    (merge transfer-data {transfer-status: "COMPLETED"}))
                (ok true)
            )
            (ok false)
        )
    )
)

;; Getter Functions
(define-read-only (get-transfer-status (transfer-id uint))
    (map-get? active-transfer-requests transfer-id)
)

(define-read-only (get-relayer-status (relayer-address principal))
    (default-to false (map-get? authorized-relayers relayer-address))
)

(define-read-only (get-bridge-parameters)
    {
        minimum-amount: (var-get bridge-minimum-transfer-amount),
        required-confirmations: (var-get required-relayer-confirmations),
        is-paused: (var-get bridge-operation-paused),
        max-chain-id: (var-get max-chain-id)
    }
)