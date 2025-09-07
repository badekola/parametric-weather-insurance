;; Weather Oracle Smart Contract
;; Manages weather data feeds, validation, and quality assurance for parametric insurance

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-OWNER-ONLY (err u400))
(define-constant ERR-UNAUTHORIZED-REPORTER (err u401))
(define-constant ERR-INVALID-DATA (err u402))
(define-constant ERR-DATA-ALREADY-EXISTS (err u403))
(define-constant ERR-NO-DATA-FOUND (err u404))
(define-constant ERR-STALE-DATA (err u405))
(define-constant ERR-INSUFFICIENT-CONFIRMATIONS (err u406))
(define-constant ERR-INVALID-LOCATION (err u407))
(define-constant ERR-REPORTER-ALREADY-EXISTS (err u408))
(define-constant ERR-REPORTER-NOT-FOUND (err u409))
(define-constant ERR-CONTRACT-INACTIVE (err u410))

;; Data Variables for system configuration and statistics
(define-data-var total-reporters uint u0)
(define-data-var total-data-points uint u0)
(define-data-var total-locations uint u0)
(define-data-var min-confirmations-required uint u2)
(define-data-var max-data-age uint u144) ;; Maximum blocks (approximately 24 hours)
(define-data-var contract-active bool true)
(define-data-var emergency-mode bool false)
(define-data-var data-submission-fee uint u100000) ;; Fee in microSTX

;; Data Maps for comprehensive weather data management

;; Authorized weather data reporters and their credentials
(define-map authorized-reporters 
    principal 
    {
        active: bool,
        reputation-score: uint,
        total-submissions: uint,
        successful-submissions: uint,
        last-submission: uint,
        reporter-type: (string-ascii 20),
        location-coverage: (list 10 uint)
    }
)

;; Weather data storage with comprehensive metadata
(define-map weather-data
    {location-id: uint, date: uint, parameter: (string-ascii 20)}
    {
        value: uint,
        reporter: principal,
        submission-time: uint,
        confirmations: uint,
        confidence-score: uint,
        data-quality: uint,
        validation-status: (string-ascii 15),
        source-type: (string-ascii 20)
    }
)

;; Location metadata and geographic information
(define-map location-registry
    uint
    {
        latitude: uint,
        longitude: uint,
        location-name: (string-ascii 50),
        active: bool,
        data-sources: uint,
        last-update: uint,
        coverage-radius: uint,
        elevation: uint
    }
)

;; Data confirmations from multiple sources for validation
(define-map data-confirmations
    {location-id: uint, date: uint, parameter: (string-ascii 20)}
    (list 5 {reporter: principal, value: uint, timestamp: uint, confidence: uint})
)

;; Weather parameter configuration and validation rules
(define-map parameter-config
    (string-ascii 20)
    {
        min-value: uint,
        max-value: uint,
        unit: (string-ascii 10),
        precision: uint,
        validation-threshold: uint,
        active: bool
    }
)

;; Reporter performance tracking and analytics
(define-map reporter-performance
    principal
    {
        accuracy-score: uint,
        timeliness-score: uint,
        consistency-score: uint,
        penalty-points: uint,
        reward-points: uint,
        last-evaluation: uint
    }
)

;; Daily aggregated statistics for system monitoring
(define-map daily-stats
    uint ;; date (block-height / 144)
    {
        total-submissions: uint,
        unique-reporters: uint,
        locations-covered: uint,
        average-confidence: uint,
        validation-failures: uint
    }
)

;; Initialize weather parameter configurations
(map-set parameter-config "temperature" {
    min-value: u0,
    max-value: u500, ;; -50 to 50 Celsius (* 10)
    unit: "celsius",
    precision: u1, ;; 1 decimal place
    validation-threshold: u50, ;; 5 degree variance
    active: true
})

(map-set parameter-config "rainfall" {
    min-value: u0,
    max-value: u5000, ;; 0 to 500mm
    unit: "mm",
    precision: u1,
    validation-threshold: u100, ;; 10mm variance
    active: true
})

(map-set parameter-config "wind-speed" {
    min-value: u0,
    max-value: u2000, ;; 0 to 200 km/h (* 10)
    unit: "kmh",
    precision: u1,
    validation-threshold: u150, ;; 15 km/h variance
    active: true
})

(map-set parameter-config "humidity" {
    min-value: u0,
    max-value: u1000, ;; 0 to 100% (* 10)
    unit: "percent",
    precision: u1,
    validation-threshold: u100, ;; 10% variance
    active: true
})

(map-set parameter-config "pressure" {
    min-value: u8000,
    max-value: u12000, ;; 800 to 1200 hPa (* 10)
    unit: "hpa",
    precision: u1,
    validation-threshold: u50, ;; 5 hPa variance
    active: true
})

;; Private Helper Functions

;; Calculate current date identifier from block height
(define-private (get-current-date)
    (/ block-height u144) ;; Approximately 1 day in blocks
)

;; Validate weather data value against parameter constraints
(define-private (is-valid-weather-value (parameter (string-ascii 20)) (value uint))
    (match (map-get? parameter-config parameter)
        config
        (and
            (get active config)
            (>= value (get min-value config))
            (<= value (get max-value config))
        )
        false
    )
)

;; Check if data is within acceptable age limits
(define-private (is-data-fresh (submission-time uint))
    (<= (- block-height submission-time) (var-get max-data-age))
)

;; Calculate confidence score based on reporter reputation and data quality
(define-private (calculate-confidence-score (reporter principal) (value uint) (parameter (string-ascii 20)))
    (match (map-get? authorized-reporters reporter)
        reporter-info
        (let 
            (
                (reputation (get reputation-score reporter-info))
                (success-rate (if (> (get total-submissions reporter-info) u0)
                                  (/ (* (get successful-submissions reporter-info) u100) 
                                     (get total-submissions reporter-info))
                                  u50))
            )
            (/ (+ reputation success-rate) u2)
        )
        u0
    )
)

;; Update reporter statistics after data submission
(define-private (update-reporter-stats (reporter principal) (successful bool))
    (match (map-get? authorized-reporters reporter)
        reporter-info
        (let 
            (
                (new-total (+ (get total-submissions reporter-info) u1))
                (new-successful (if successful 
                                    (+ (get successful-submissions reporter-info) u1)
                                    (get successful-submissions reporter-info)))
            )
            (map-set authorized-reporters reporter (merge reporter-info {
                total-submissions: new-total,
                successful-submissions: new-successful,
                last-submission: block-height
            }))
            true
        )
        false
    )
)

;; Add confirmation data for multi-source validation
(define-private (add-data-confirmation 
    (location-id uint) 
    (date uint) 
    (parameter (string-ascii 20)) 
    (reporter principal) 
    (value uint) 
    (confidence uint)
)
    (let 
        (
            (key {location-id: location-id, date: date, parameter: parameter})
            (current-confirmations (default-to (list) (map-get? data-confirmations key)))
            (new-confirmation {reporter: reporter, value: value, timestamp: block-height, confidence: confidence})
        )
        (if (< (len current-confirmations) u5)
            (map-set data-confirmations key 
                (unwrap-panic (as-max-len? (append current-confirmations new-confirmation) u5)))
            (map-set data-confirmations key 
                (unwrap-panic (as-max-len? (append (unwrap-panic (slice? current-confirmations u1 u5)) new-confirmation) u5)))
        )
    )
)

;; Public Functions for Weather Data Management

;; Submit weather data with comprehensive validation and metadata
(define-public (submit-weather-data 
    (location-id uint) 
    (parameter (string-ascii 20)) 
    (value uint) 
    (source-type (string-ascii 20))
)
    (let 
        (
            (current-date (get-current-date))
            (data-key {location-id: location-id, date: current-date, parameter: parameter})
            (reporter-info (unwrap! (map-get? authorized-reporters tx-sender) ERR-UNAUTHORIZED-REPORTER))
            (confidence-score (calculate-confidence-score tx-sender value parameter))
        )
        ;; Comprehensive validation checks
        (asserts! (var-get contract-active) ERR-CONTRACT-INACTIVE)
        (asserts! (get active reporter-info) ERR-UNAUTHORIZED-REPORTER)
        (asserts! (is-valid-weather-value parameter value) ERR-INVALID-DATA)
        (asserts! (is-some (map-get? location-registry location-id)) ERR-INVALID-LOCATION)
        (asserts! (is-none (map-get? weather-data data-key)) ERR-DATA-ALREADY-EXISTS)

        ;; Store weather data with comprehensive metadata
        (map-set weather-data data-key {
            value: value,
            reporter: tx-sender,
            submission-time: block-height,
            confirmations: u1,
            confidence-score: confidence-score,
            data-quality: u100, ;; Initial quality score
            validation-status: "pending",
            source-type: source-type
        })

        ;; Add confirmation entry for validation
        (add-data-confirmation location-id current-date parameter tx-sender value confidence-score)

        ;; Update reporter statistics and performance metrics
        (update-reporter-stats tx-sender true)
        (var-set total-data-points (+ (var-get total-data-points) u1))

        ;; Update daily statistics
        (match (map-get? daily-stats current-date)
            stats
            (map-set daily-stats current-date (merge stats {
                total-submissions: (+ (get total-submissions stats) u1)
            }))
            (map-set daily-stats current-date {
                total-submissions: u1,
                unique-reporters: u1,
                locations-covered: u1,
                average-confidence: confidence-score,
                validation-failures: u0
            })
        )

        (ok true)
    )
)

;; Confirm weather data from additional sources for validation
(define-public (confirm-weather-data 
    (location-id uint) 
    (date uint) 
    (parameter (string-ascii 20)) 
    (value uint)
)
    (let 
        (
            (data-key {location-id: location-id, date: date, parameter: parameter})
            (existing-data (unwrap! (map-get? weather-data data-key) ERR-NO-DATA-FOUND))
            (reporter-info (unwrap! (map-get? authorized-reporters tx-sender) ERR-UNAUTHORIZED-REPORTER))
            (confidence-score (calculate-confidence-score tx-sender value parameter))
        )
        ;; Validation checks for confirmation
        (asserts! (var-get contract-active) ERR-CONTRACT-INACTIVE)
        (asserts! (get active reporter-info) ERR-UNAUTHORIZED-REPORTER)
        (asserts! (is-valid-weather-value parameter value) ERR-INVALID-DATA)
        (asserts! (not (is-eq (get reporter existing-data) tx-sender)) ERR-INVALID-DATA) ;; Can't confirm own data

        ;; Add confirmation data
        (add-data-confirmation location-id date parameter tx-sender value confidence-score)

        ;; Update existing data with confirmation count
        (map-set weather-data data-key (merge existing-data {
            confirmations: (+ (get confirmations existing-data) u1),
            validation-status: "confirmed"
        }))

        ;; Update reporter statistics
        (update-reporter-stats tx-sender true)

        (ok true)
    )
)

;; Get weather data with validation status
(define-public (get-weather-data (location-id uint) (date uint) (parameter (string-ascii 20)))
    (let 
        (
            (data-key {location-id: location-id, date: date, parameter: parameter})
            (data (unwrap! (map-get? weather-data data-key) ERR-NO-DATA-FOUND))
        )
        ;; Check data freshness and confirmation requirements
        (asserts! (is-data-fresh (get submission-time data)) ERR-STALE-DATA)
        (asserts! (>= (get confirmations data) (var-get min-confirmations-required)) ERR-INSUFFICIENT-CONFIRMATIONS)

        (ok data)
    )
)

;; Administrative Functions (Contract Owner Only)

;; Add authorized weather data reporter with comprehensive profile
(define-public (add-reporter 
    (reporter principal) 
    (reporter-type (string-ascii 20)) 
    (initial-reputation uint)
    (location-coverage (list 10 uint))
)
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
        (asserts! (is-none (map-get? authorized-reporters reporter)) ERR-REPORTER-ALREADY-EXISTS)
        (asserts! (<= initial-reputation u100) ERR-INVALID-DATA)

        ;; Add comprehensive reporter profile
        (map-set authorized-reporters reporter {
            active: true,
            reputation-score: initial-reputation,
            total-submissions: u0,
            successful-submissions: u0,
            last-submission: u0,
            reporter-type: reporter-type,
            location-coverage: location-coverage
        })

        ;; Initialize performance tracking
        (map-set reporter-performance reporter {
            accuracy-score: u100,
            timeliness-score: u100,
            consistency-score: u100,
            penalty-points: u0,
            reward-points: u0,
            last-evaluation: block-height
        })

        (var-set total-reporters (+ (var-get total-reporters) u1))
        (ok true)
    )
)

;; Remove or deactivate weather data reporter
(define-public (remove-reporter (reporter principal))
    (let ((reporter-info (unwrap! (map-get? authorized-reporters reporter) ERR-REPORTER-NOT-FOUND)))
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)

        (map-set authorized-reporters reporter (merge reporter-info {active: false}))
        (ok true)
    )
)

;; Register new weather monitoring location
(define-public (register-location 
    (location-id uint) 
    (latitude uint) 
    (longitude uint) 
    (location-name (string-ascii 50)) 
    (coverage-radius uint) 
    (elevation uint)
)
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
        (asserts! (is-none (map-get? location-registry location-id)) ERR-INVALID-LOCATION)

        (map-set location-registry location-id {
            latitude: latitude,
            longitude: longitude,
            location-name: location-name,
            active: true,
            data-sources: u0,
            last-update: u0,
            coverage-radius: coverage-radius,
            elevation: elevation
        })

        (var-set total-locations (+ (var-get total-locations) u1))
        (ok true)
    )
)

;; Update weather parameter configuration
(define-public (update-parameter-config 
    (parameter (string-ascii 20)) 
    (min-value uint) 
    (max-value uint) 
    (unit (string-ascii 10)) 
    (precision uint) 
    (validation-threshold uint)
)
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
        (asserts! (< min-value max-value) ERR-INVALID-DATA)

        (map-set parameter-config parameter {
            min-value: min-value,
            max-value: max-value,
            unit: unit,
            precision: precision,
            validation-threshold: validation-threshold,
            active: true
        })
        (ok true)
    )
)

;; Update system configuration parameters
(define-public (update-system-config 
    (min-confirmations uint) 
    (max-age uint) 
    (submission-fee uint)
)
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
        (asserts! (and (> min-confirmations u0) (<= min-confirmations u5)) ERR-INVALID-DATA)
        (asserts! (> max-age u0) ERR-INVALID-DATA)

        (var-set min-confirmations-required min-confirmations)
        (var-set max-data-age max-age)
        (var-set data-submission-fee submission-fee)
        (ok true)
    )
)

;; Toggle contract active status for maintenance
(define-public (toggle-contract-status)
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
        (var-set contract-active (not (var-get contract-active)))
        (ok (var-get contract-active))
    )
)

;; Activate emergency mode for critical situations
(define-public (toggle-emergency-mode)
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
        (var-set emergency-mode (not (var-get emergency-mode)))
        (ok (var-get emergency-mode))
    )
)

;; Read-only Functions for Data Retrieval and Analysis

;; Get weather data without validation requirements (for internal use)
(define-read-only (get-raw-weather-data (location-id uint) (date uint) (parameter (string-ascii 20)))
    (map-get? weather-data {location-id: location-id, date: date, parameter: parameter})
)

;; Get reporter information and performance metrics
(define-read-only (get-reporter-info (reporter principal))
    (map-get? authorized-reporters reporter)
)

;; Get reporter performance metrics
(define-read-only (get-reporter-performance (reporter principal))
    (map-get? reporter-performance reporter)
)

;; Get location registry information
(define-read-only (get-location-info (location-id uint))
    (map-get? location-registry location-id)
)

;; Get weather parameter configuration
(define-read-only (get-parameter-config (parameter (string-ascii 20)))
    (map-get? parameter-config parameter)
)

;; Get data confirmations for validation analysis
(define-read-only (get-data-confirmations (location-id uint) (date uint) (parameter (string-ascii 20)))
    (map-get? data-confirmations {location-id: location-id, date: date, parameter: parameter})
)

;; Get daily statistics for system monitoring
(define-read-only (get-daily-stats (date uint))
    (map-get? daily-stats date)
)

;; Get comprehensive system statistics
(define-read-only (get-system-stats)
    {
        total-reporters: (var-get total-reporters),
        total-data-points: (var-get total-data-points),
        total-locations: (var-get total-locations),
        min-confirmations-required: (var-get min-confirmations-required),
        max-data-age: (var-get max-data-age),
        contract-active: (var-get contract-active),
        emergency-mode: (var-get emergency-mode),
        submission-fee: (var-get data-submission-fee)
    }
)

;; Check if reporter is authorized and active
(define-read-only (is-authorized-reporter (reporter principal))
    (match (map-get? authorized-reporters reporter)
        reporter-info (get active reporter-info)
        false
    )
)

;; Get current system date identifier
(define-read-only (get-system-date)
    (get-current-date)
)

;; Get contract owner address
(define-read-only (get-contract-owner)
    CONTRACT-OWNER
)

;; Validate weather data value for parameter
(define-read-only (validate-weather-value (parameter (string-ascii 20)) (value uint))
    (is-valid-weather-value parameter value)
)

;; Check data freshness
(define-read-only (is-fresh-data (submission-time uint))
    (is-data-fresh submission-time)
)
