;; Payout Calculator Smart Contract
;; Handles parametric weather insurance policy registration and payout calculations

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-OWNER-ONLY (err u300))
(define-constant ERR-INVALID-POLICY (err u301))
(define-constant ERR-POLICY-NOT-FOUND (err u302))
(define-constant ERR-POLICY-EXPIRED (err u303))
(define-constant ERR-PAYOUT-ALREADY-CLAIMED (err u304))
(define-constant ERR-INSUFFICIENT-FUNDS (err u305))
(define-constant ERR-INVALID-WEATHER-DATA (err u306))
(define-constant ERR-UNAUTHORIZED (err u307))
(define-constant ERR-INVALID-PARAMETERS (err u308))
(define-constant ERR-POLICY-NOT-ACTIVE (err u309))
(define-constant ERR-THRESHOLD-NOT-MET (err u310))

;; Data Variables
(define-data-var next-policy-id uint u1)
(define-data-var total-policies uint u0)
(define-data-var total-payouts-processed uint u0)
(define-data-var total-premiums-collected uint u0)
(define-data-var contract-balance uint u0)
(define-data-var oracle-address (optional principal) none)
(define-data-var minimum-premium uint u1000000) ;; 1 STX in microSTX
(define-data-var maximum-payout uint u100000000) ;; 100 STX in microSTX
(define-data-var contract-active bool true)

;; Data Maps for comprehensive policy management
(define-map policies
    uint
    {
        policy-holder: principal,
        premium-amount: uint,
        coverage-amount: uint,
        policy-type: (string-ascii 20),
        weather-parameter: (string-ascii 20),
        threshold-value: uint,
        threshold-direction: (string-ascii 10),
        location-lat: uint,
        location-lon: uint,
        start-date: uint,
        end-date: uint,
        status: (string-ascii 15),
        payout-claimed: bool,
        creation-time: uint
    }
)

;; Payout tracking and calculation results
(define-map payouts
    uint
    {
        policy-id: uint,
        weather-value: uint,
        payout-amount: uint,
        calculation-method: (string-ascii 20),
        processing-time: uint,
        claim-time: (optional uint)
    }
)

;; Weather parameter thresholds and calculation methods
(define-map weather-thresholds
    (string-ascii 20)
    {
        min-threshold: uint,
        max-threshold: uint,
        payout-multiplier: uint,
        calculation-type: (string-ascii 15)
    }
)

;; User policy tracking for efficient lookups
(define-map user-policies principal (list 20 uint))

;; Policy activity history for audit trails and compliance
(define-map policy-history 
    uint 
    (list 10 {action: (string-ascii 30), timestamp: uint, actor: principal})
)

;; Weather data validation and quality metrics
(define-map weather-data-quality
    (string-ascii 20)
    {
        last-update: uint,
        data-points: uint,
        reliability-score: uint,
        active-sources: uint
    }
)

;; Initialize default weather threshold configurations for common parameters
(map-set weather-thresholds "rainfall" {
    min-threshold: u0,
    max-threshold: u1000, ;; mm
    payout-multiplier: u100,
    calculation-type: "linear"
})

(map-set weather-thresholds "temperature" {
    min-threshold: u0,
    max-threshold: u400, ;; Celsius * 10
    payout-multiplier: u150,
    calculation-type: "step"
})

(map-set weather-thresholds "wind-speed" {
    min-threshold: u0,
    max-threshold: u1500, ;; km/h * 10
    payout-multiplier: u200,
    calculation-type: "exponential"
})

(map-set weather-thresholds "humidity" {
    min-threshold: u0,
    max-threshold: u1000, ;; percentage * 10
    payout-multiplier: u80,
    calculation-type: "linear"
})

;; Initialize weather data quality tracking
(map-set weather-data-quality "rainfall" {
    last-update: u0,
    data-points: u0,
    reliability-score: u100,
    active-sources: u3
})

;; Private Helper Functions

;; Get minimum of two values (Clarity doesn't have built-in min)
(define-private (get-min (a uint) (b uint))
    (if (< a b) a b)
)

;; Get maximum of two values (Clarity doesn't have built-in max)
(define-private (get-max (a uint) (b uint))
    (if (> a b) a b)
)

;; Comprehensive policy parameter validation
(define-private (is-valid-policy-params (premium uint) (coverage uint) (start uint) (end uint))
    (and
        (>= premium (var-get minimum-premium))
        (<= coverage (var-get maximum-payout))
        (> coverage premium)
        (< start end)
        (> end block-height)
        (<= (- end start) u52560000) ;; Maximum 1 year coverage period
        (> start block-height) ;; Start date must be in future
    )
)

;; Linear payout calculation for gradual weather impact scenarios
(define-private (calculate-linear-payout (weather-value uint) (threshold uint) (coverage uint) (multiplier uint))
    (if (> weather-value threshold)
        (let ((excess (- weather-value threshold))
              (calculated-amount (/ (* excess coverage multiplier) u10000)))
            (get-min calculated-amount coverage)
        )
        u0
    )
)

;; Step function payout for binary weather conditions (all or nothing)
(define-private (calculate-step-payout (weather-value uint) (threshold uint) (coverage uint))
    (if (> weather-value threshold) coverage u0)
)

;; Exponential payout calculation for severe weather events
(define-private (calculate-exponential-payout (weather-value uint) (threshold uint) (coverage uint) (multiplier uint))
    (if (> weather-value threshold)
        (let 
            (
                (excess (- weather-value threshold))
                (base-payout (/ (* excess coverage) u100))
                (exponential-factor (/ (* excess multiplier) u1000))
                (total-calculated (+ base-payout exponential-factor))
            )
            (get-min total-calculated coverage)
        )
        u0
    )
)

;; Update user's policy list for efficient retrieval and management
(define-private (update-user-policies (user principal) (policy-id uint))
    (let ((current-policies (default-to (list) (map-get? user-policies user))))
        (if (< (len current-policies) u20)
            (map-set user-policies user (unwrap-panic (as-max-len? (append current-policies policy-id) u20)))
            (map-set user-policies user (unwrap-panic (as-max-len? (append (unwrap-panic (slice? current-policies u1 u20)) policy-id) u20)))
        )
    )
)

;; Add entry to policy history for comprehensive audit trail
(define-private (add-policy-history (policy-id uint) (action (string-ascii 30)) (actor principal))
    (let ((current-history (default-to (list) (map-get? policy-history policy-id))))
        (if (< (len current-history) u10)
            (map-set policy-history policy-id 
                (unwrap-panic (as-max-len? 
                    (append current-history {action: action, timestamp: block-height, actor: actor}) 
                    u10)))
            (map-set policy-history policy-id 
                (unwrap-panic (as-max-len? 
                    (append (unwrap-panic (slice? current-history u1 u10)) 
                        {action: action, timestamp: block-height, actor: actor}) 
                    u10)))
        )
    )
)

;; Public Functions for Policy Management

;; Register new parametric insurance policy with comprehensive parameters
(define-public (register-policy
    (premium-amount uint)
    (coverage-amount uint)
    (policy-type (string-ascii 20))
    (weather-parameter (string-ascii 20))
    (threshold-value uint)
    (threshold-direction (string-ascii 10))
    (location-lat uint)
    (location-lon uint)
    (start-date uint)
    (end-date uint)
)
    (let 
        (
            (policy-id (var-get next-policy-id))
            (current-time block-height)
        )
        (asserts! (var-get contract-active) ERR-UNAUTHORIZED)
        (asserts! (is-valid-policy-params premium-amount coverage-amount start-date end-date) ERR-INVALID-PARAMETERS)
        (asserts! (is-some (map-get? weather-thresholds weather-parameter)) ERR-INVALID-WEATHER-DATA)
        (asserts! (or (is-eq threshold-direction "above") (is-eq threshold-direction "below")) ERR-INVALID-PARAMETERS)

        ;; Store comprehensive policy information
        (map-set policies policy-id {
            policy-holder: tx-sender,
            premium-amount: premium-amount,
            coverage-amount: coverage-amount,
            policy-type: policy-type,
            weather-parameter: weather-parameter,
            threshold-value: threshold-value,
            threshold-direction: threshold-direction,
            location-lat: location-lat,
            location-lon: location-lon,
            start-date: start-date,
            end-date: end-date,
            status: "active",
            payout-claimed: false,
            creation-time: current-time
        })

        ;; Update tracking and statistics
        (update-user-policies tx-sender policy-id)
        (add-policy-history policy-id "policy-created" tx-sender)
        (var-set next-policy-id (+ policy-id u1))
        (var-set total-policies (+ (var-get total-policies) u1))
        (var-set total-premiums-collected (+ (var-get total-premiums-collected) premium-amount))
        (var-set contract-balance (+ (var-get contract-balance) premium-amount))

        (ok policy-id)
    )
)

;; Calculate payout amount based on weather data and policy parameters
(define-public (calculate-payout (policy-id uint) (weather-value uint))
    (let 
        (
            (policy (unwrap! (map-get? policies policy-id) ERR-POLICY-NOT-FOUND))
            (threshold-info (unwrap! (map-get? weather-thresholds (get weather-parameter policy)) ERR-INVALID-WEATHER-DATA))
        )
        ;; Comprehensive policy eligibility validation
        (asserts! (var-get contract-active) ERR-UNAUTHORIZED)
        (asserts! (is-eq (get status policy) "active") ERR-POLICY-NOT-ACTIVE)
        (asserts! (>= block-height (get start-date policy)) ERR-INVALID-POLICY)
        (asserts! (<= block-height (get end-date policy)) ERR-POLICY-EXPIRED)
        (asserts! (not (get payout-claimed policy)) ERR-PAYOUT-ALREADY-CLAIMED)

        ;; Calculate payout based on weather parameters and thresholds
        (let 
            (
                (threshold (get threshold-value policy))
                (coverage (get coverage-amount policy))
                (calculation-type (get calculation-type threshold-info))
                (multiplier (get payout-multiplier threshold-info))
                (threshold-direction (get threshold-direction policy))
                (trigger-met 
                    (if (is-eq threshold-direction "above")
                        (> weather-value threshold)
                        (< weather-value threshold)))
                (payout-amount
                    (if trigger-met
                        (if (is-eq calculation-type "linear")
                            (calculate-linear-payout weather-value threshold coverage multiplier)
                            (if (is-eq calculation-type "step")
                                (calculate-step-payout weather-value threshold coverage)
                                (calculate-exponential-payout weather-value threshold coverage multiplier)))
                        u0))
            )

            ;; Process payout calculation results
            (if (> payout-amount u0)
                (begin
                    ;; Store payout calculation results for claiming
                    (map-set payouts policy-id {
                        policy-id: policy-id,
                        weather-value: weather-value,
                        payout-amount: payout-amount,
                        calculation-method: calculation-type,
                        processing-time: block-height,
                        claim-time: none
                    })
                    ;; Add history entry for audit trail
                    (add-policy-history policy-id "payout-calculated" tx-sender)
                    (ok payout-amount)
                )
                (err ERR-THRESHOLD-NOT-MET)
            )
        )
    )
)

;; Claim calculated payout for eligible policies
(define-public (claim-payout (policy-id uint))
    (let 
        (
            (policy (unwrap! (map-get? policies policy-id) ERR-POLICY-NOT-FOUND))
            (payout-info (unwrap! (map-get? payouts policy-id) ERR-POLICY-NOT-FOUND))
        )
        ;; Comprehensive verification of claim eligibility
        (asserts! (var-get contract-active) ERR-UNAUTHORIZED)
        (asserts! (is-eq (get policy-holder policy) tx-sender) ERR-UNAUTHORIZED)
        (asserts! (not (get payout-claimed policy)) ERR-PAYOUT-ALREADY-CLAIMED)
        (asserts! (>= (var-get contract-balance) (get payout-amount payout-info)) ERR-INSUFFICIENT-FUNDS)

        ;; Update policy status to completed
        (map-set policies policy-id (merge policy {
            payout-claimed: true,
            status: "completed"
        }))

        ;; Record claim timestamp
        (map-set payouts policy-id (merge payout-info {
            claim-time: (some block-height)
        }))

        ;; Update contract accounting and statistics
        (var-set contract-balance (- (var-get contract-balance) (get payout-amount payout-info)))
        (var-set total-payouts-processed (+ (var-get total-payouts-processed) u1))
        
        ;; Record transaction in audit history
        (add-policy-history policy-id "payout-claimed" tx-sender)

        ;; Return payout amount (STX transfer would occur in real implementation)
        (ok (get payout-amount payout-info))
    )
)

;; Cancel active policy before payout calculation
(define-public (cancel-policy (policy-id uint))
    (let ((policy (unwrap! (map-get? policies policy-id) ERR-POLICY-NOT-FOUND)))
        (asserts! (var-get contract-active) ERR-UNAUTHORIZED)
        (asserts! (is-eq (get policy-holder policy) tx-sender) ERR-UNAUTHORIZED)
        (asserts! (is-eq (get status policy) "active") ERR-POLICY-NOT-ACTIVE)
        (asserts! (not (get payout-claimed policy)) ERR-PAYOUT-ALREADY-CLAIMED)

        ;; Update policy status and record cancellation
        (map-set policies policy-id (merge policy {status: "cancelled"}))
        (add-policy-history policy-id "policy-cancelled" tx-sender)

        (ok true)
    )
)

;; Administrative Functions (Contract Owner Only)

;; Update weather threshold parameters and calculation methods
(define-public (update-weather-threshold 
    (parameter (string-ascii 20)) 
    (min-threshold uint) 
    (max-threshold uint) 
    (multiplier uint) 
    (calc-type (string-ascii 15))
)
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
        (asserts! (< min-threshold max-threshold) ERR-INVALID-PARAMETERS)
        (asserts! (> multiplier u0) ERR-INVALID-PARAMETERS)
        
        (map-set weather-thresholds parameter {
            min-threshold: min-threshold,
            max-threshold: max-threshold,
            payout-multiplier: multiplier,
            calculation-type: calc-type
        })
        (ok true)
    )
)

;; Configure oracle address for weather data validation and integration
(define-public (set-oracle-address (oracle principal))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
        (var-set oracle-address (some oracle))
        (ok true)
    )
)

;; Update contract operational limits and parameters
(define-public (update-contract-limits (min-premium uint) (max-payout uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
        (asserts! (< min-premium max-payout) ERR-INVALID-PARAMETERS)
        (var-set minimum-premium min-premium)
        (var-set maximum-payout max-payout)
        (ok true)
    )
)

;; Add funds to contract balance for payout reserves
(define-public (add-contract-funds (amount uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
        (asserts! (> amount u0) ERR-INVALID-PARAMETERS)
        (var-set contract-balance (+ (var-get contract-balance) amount))
        (ok true)
    )
)

;; Toggle contract active status for maintenance or emergencies
(define-public (toggle-contract-status)
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
        (var-set contract-active (not (var-get contract-active)))
        (ok (var-get contract-active))
    )
)

;; Read-only Functions for Data Retrieval and Analysis

;; Get comprehensive policy details
(define-read-only (get-policy (policy-id uint))
    (map-get? policies policy-id)
)

;; Get payout calculation information and results
(define-read-only (get-payout-info (policy-id uint))
    (map-get? payouts policy-id)
)

;; Get all policies for a specific user
(define-read-only (get-user-policies (user principal))
    (default-to (list) (map-get? user-policies user))
)

;; Get comprehensive policy activity history
(define-read-only (get-policy-history (policy-id uint))
    (default-to (list) (map-get? policy-history policy-id))
)

;; Get weather threshold configuration
(define-read-only (get-weather-threshold (parameter (string-ascii 20)))
    (map-get? weather-thresholds parameter)
)

;; Get weather data quality metrics
(define-read-only (get-weather-data-quality (parameter (string-ascii 20)))
    (map-get? weather-data-quality parameter)
)

;; Project payout amount without processing transaction (simulation)
(define-read-only (project-payout (policy-id uint) (weather-value uint))
    (match (map-get? policies policy-id)
        policy 
        (match (map-get? weather-thresholds (get weather-parameter policy))
            threshold-info
            (let 
                (
                    (threshold (get threshold-value policy))
                    (coverage (get coverage-amount policy))
                    (calculation-type (get calculation-type threshold-info))
                    (multiplier (get payout-multiplier threshold-info))
                    (threshold-direction (get threshold-direction policy))
                    (trigger-met 
                        (if (is-eq threshold-direction "above")
                            (> weather-value threshold)
                            (< weather-value threshold)))
                )
                (if trigger-met
                    (if (is-eq calculation-type "linear")
                        (some (calculate-linear-payout weather-value threshold coverage multiplier))
                        (if (is-eq calculation-type "step")
                            (some (calculate-step-payout weather-value threshold coverage))
                            (some (calculate-exponential-payout weather-value threshold coverage multiplier))))
                    (some u0))
            )
            none
        )
        none
    )
)

;; Get comprehensive contract statistics and metrics
(define-read-only (get-contract-stats)
    {
        total-policies: (var-get total-policies),
        total-payouts-processed: (var-get total-payouts-processed),
        total-premiums-collected: (var-get total-premiums-collected),
        contract-balance: (var-get contract-balance),
        next-policy-id: (var-get next-policy-id),
        oracle-address: (var-get oracle-address),
        contract-active: (var-get contract-active)
    }
)

;; Check comprehensive eligibility for payout calculation
(define-read-only (check-payout-eligibility (policy-id uint))
    (match (map-get? policies policy-id)
        policy 
        {
            eligible: (and 
                (is-eq (get status policy) "active")
                (>= block-height (get start-date policy))
                (<= block-height (get end-date policy))
                (not (get payout-claimed policy))
            ),
            policy-active: (is-eq (get status policy) "active"),
            in-coverage-period: (and 
                (>= block-height (get start-date policy)) 
                (<= block-height (get end-date policy))
            ),
            not-claimed: (not (get payout-claimed policy))
        }
        {
            eligible: false, 
            policy-active: false, 
            in-coverage-period: false, 
            not-claimed: false
        }
    )
)

;; Get contract owner address
(define-read-only (get-contract-owner)
    CONTRACT-OWNER
)

;; Get current contract operational limits
(define-read-only (get-contract-limits)
    {
        minimum-premium: (var-get minimum-premium),
        maximum-payout: (var-get maximum-payout)
    }
)
