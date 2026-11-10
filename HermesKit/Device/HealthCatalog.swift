// [health-all-types] Every kind of Health data a bot may read, grouped as the Health app groups them (tester,
// 2026-11-08: "toggle whatever the Health app allows to be read"). Pure Foundation so it builds on the Mac (no Health
// there) and is unit-testable: each type is named by its HealthKit identifier's raw value, which is also its switch's
// key and its name on the wire. App/DeviceAccess/HealthLookup.swift turns a key back into an HKObjectType and reads it.
//
// Not here, on purpose: clinical records and CDA documents (the entitlement asks for no clinical access), vision
// prescriptions and medications (HealthKit asks about those one object at a time, a different flow), workout routes
// (where the person went) and raw heartbeat series, and the blood pressure and food correlations (their parts are here:
// systolic, diastolic and every nutrient).
//
// The four switches before this (steps, sleep, workouts, heart) are `legacy`: saved settings turn into their types, and
// the add-on still hears them, since an add-on before 0.9.46 knows only those four.

import Foundation

nonisolated enum HealthCatalog {
    /// The Health app's own groups, in its order.
    enum Category: String, CaseIterable, Sendable {
        case activity, bodyMeasurements, cycleTracking, hearing, heart, mentalWellbeing, mobility, nutrition, respiratory,
             sleep, symptoms, vitals, other

        var title: String {
            switch self {
            case .activity: "Activity"
            case .bodyMeasurements: "Body Measurements"
            case .cycleTracking: "Cycle Tracking"
            case .hearing: "Hearing"
            case .heart: "Heart"
            case .mentalWellbeing: "Mental Wellbeing"
            case .mobility: "Mobility"
            case .nutrition: "Nutrition"
            case .respiratory: "Respiratory"
            case .sleep: "Sleep"
            case .symptoms: "Symptoms"
            case .vitals: "Vitals"
            case .other: "Other Data"
            }
        }

        var systemImage: String {
            switch self {
            case .activity: "flame"
            case .bodyMeasurements: "figure"
            case .cycleTracking: "drop"
            case .hearing: "ear"
            case .heart: "heart"
            case .mentalWellbeing: "brain.head.profile"
            case .mobility: "figure.stairs"
            case .nutrition: "carrot"
            case .respiratory: "lungs"
            case .sleep: "bed.double"
            case .symptoms: "list.bullet.clipboard"
            case .vitals: "waveform.path.ecg.rectangle"
            case .other: "plus.square"
            }
        }
    }

    /// How a type is read, and so what its summary looks like (the wire's `kind`).
    enum Shape: String, Sendable {
        /// Added up: a total and one per day (steps, energy, water).
        case cumulative
        /// Measured now and then: average, lowest, highest, the latest (heart rate, weight).
        case discrete
        /// Events or states logged over time: how many, for how long, which values (symptoms, stand hours).
        case category
        case sleep, workout, activitySummary, characteristic, electrocardiogram, audiogram, stateOfMind, assessment
    }

    /// The values a category type's samples take, by raw value (HKCategoryValues.h), as the bot reads them.
    enum Values: String, Sendable {
        case severity, presence, appetite, bleeding, cervicalMucus, ovulation, testResult, contraceptive, standHour,
             walkingSteadiness, menopause, sleep

        var names: [Int: String] {
            switch self {
            case .severity: [0: "unspecified", 1: "not present", 2: "mild", 3: "moderate", 4: "severe"]
            case .presence: [0: "present", 1: "not present"]
            case .appetite: [0: "unspecified", 1: "no change", 2: "decreased", 3: "increased"]
            case .bleeding: [1: "unspecified", 2: "light", 3: "medium", 4: "heavy", 5: "none"]
            case .cervicalMucus: [1: "dry", 2: "sticky", 3: "creamy", 4: "watery", 5: "egg white"]
            case .ovulation: [1: "negative", 2: "luteinizing hormone surge", 3: "indeterminate", 4: "estrogen surge"]
            case .testResult: [1: "negative", 2: "positive", 3: "indeterminate"]
            case .contraceptive: [1: "unspecified", 2: "implant", 3: "injection", 4: "intrauterine device",
                                  5: "intravaginal ring", 6: "oral", 7: "patch"]
            case .standHour: [0: "stood", 1: "idle"]
            case .walkingSteadiness: [1: "initial low", 2: "initial very low", 3: "repeat low", 4: "repeat very low"]
            case .menopause: [1: "menopause", 2: "perimenopause", 3: "none"]
            case .sleep: [0: "in bed", 1: "asleep", 2: "awake", 3: "core", 4: "deep", 5: "rem"]
            }
        }

        func name(_ raw: Int) -> String { names[raw] ?? "\(raw)" }
    }

    struct Item: Sendable, Hashable {
        /// The HealthKit identifier's raw value ("HKQuantityTypeIdentifierHeartRate"): the switch's key and the wire's.
        let key: String
        /// As the Health app says it.
        let name: String
        let category: Category
        let shape: Shape
        /// A quantity's unit as HKUnit spells it ("count/min", "km", "%"); nil for the rest.
        let unit: String?
        /// A category type's named values; nil where a sample is just "it happened".
        let values: Values?
        /// The first iOS that has it, as major * 100 + minor (1800 = iOS 18.0).
        let since: Int
    }

    // MARK: The catalog

    private static let quantity = "HKQuantityTypeIdentifier", categoryPrefix = "HKCategoryTypeIdentifier",
                       characteristic = "HKCharacteristicTypeIdentifier"

    private static func sum(_ id: String, _ name: String, _ category: Category, _ unit: String, since: Int = 800) -> Item {
        Item(key: quantity + id, name: name, category: category, shape: .cumulative, unit: unit, values: nil, since: since)
    }

    private static func measured(_ id: String, _ name: String, _ category: Category, _ unit: String, since: Int = 800) -> Item {
        Item(key: quantity + id, name: name, category: category, shape: .discrete, unit: unit, values: nil, since: since)
    }

    private static func logged(_ id: String, _ name: String, _ category: Category, _ values: Values? = nil, since: Int = 800) -> Item {
        Item(key: categoryPrefix + id, name: name, category: category, shape: .category, unit: nil, values: values, since: since)
    }

    private static func symptom(_ id: String, _ name: String, _ values: Values = .severity, since: Int = 1306) -> Item {
        logged(id, name, .symptoms, values, since: since)
    }

    private static func trait(_ id: String, _ name: String, since: Int = 800) -> Item {
        Item(key: characteristic + id, name: name, category: .other, shape: .characteristic, unit: nil, values: nil, since: since)
    }

    private static func special(_ key: String, _ name: String, _ category: Category, _ shape: Shape, since: Int) -> Item {
        Item(key: key, name: name, category: category, shape: shape, unit: nil, values: nil, since: since)
    }

    static let workoutKey = "HKWorkoutTypeIdentifier"
    static let sleepKey = "HKCategoryTypeIdentifierSleepAnalysis"

    /// Every type, in no particular order (the page sorts each group by name).
    static let all: [Item] = [
        // Activity
        sum("StepCount", "Steps", .activity, "count"),
        sum("DistanceWalkingRunning", "Walking + Running Distance", .activity, "km"),
        sum("FlightsClimbed", "Flights Climbed", .activity, "count"),
        sum("ActiveEnergyBurned", "Active Energy", .activity, "kcal"),
        sum("BasalEnergyBurned", "Resting Energy", .activity, "kcal"),
        sum("AppleExerciseTime", "Exercise Minutes", .activity, "min", since: 903),
        sum("AppleStandTime", "Stand Minutes", .activity, "min", since: 1300),
        sum("AppleMoveTime", "Move Minutes", .activity, "min", since: 1405),
        logged("AppleStandHour", "Stand Hours", .activity, .standHour, since: 900),
        special("HKActivitySummaryTypeIdentifier", "Activity Rings", .activity, .activitySummary, since: 903),
        special(workoutKey, "Workouts", .activity, .workout, since: 800),
        sum("DistanceCycling", "Cycling Distance", .activity, "km"),
        measured("CyclingSpeed", "Cycling Speed", .activity, "km/hr", since: 1700),
        measured("CyclingPower", "Cycling Power", .activity, "W", since: 1700),
        measured("CyclingCadence", "Cycling Cadence", .activity, "count/min", since: 1700),
        measured("CyclingFunctionalThresholdPower", "Cycling Functional Threshold Power", .activity, "W", since: 1700),
        sum("DistanceSwimming", "Swimming Distance", .activity, "m", since: 1000),
        sum("SwimmingStrokeCount", "Swimming Strokes", .activity, "count", since: 1000),
        sum("DistanceWheelchair", "Wheelchair Distance", .activity, "km", since: 1000),
        sum("PushCount", "Pushes", .activity, "count", since: 1000),
        sum("DistanceDownhillSnowSports", "Downhill Snow Sports Distance", .activity, "km", since: 1102),
        sum("DistanceCrossCountrySkiing", "Cross-Country Skiing Distance", .activity, "km", since: 1800),
        measured("CrossCountrySkiingSpeed", "Cross-Country Skiing Speed", .activity, "km/hr", since: 1800),
        sum("DistancePaddleSports", "Paddle Sports Distance", .activity, "km", since: 1800),
        measured("PaddleSportsSpeed", "Paddle Sports Speed", .activity, "km/hr", since: 1800),
        sum("DistanceRowing", "Rowing Distance", .activity, "km", since: 1800),
        measured("RowingSpeed", "Rowing Speed", .activity, "km/hr", since: 1800),
        sum("DistanceSkatingSports", "Skating Sports Distance", .activity, "km", since: 1800),
        measured("RunningSpeed", "Running Speed", .activity, "km/hr", since: 1600),
        measured("RunningPower", "Running Power", .activity, "W", since: 1600),
        measured("RunningStrideLength", "Running Stride Length", .activity, "m", since: 1600),
        measured("RunningVerticalOscillation", "Vertical Oscillation", .activity, "cm", since: 1600),
        measured("RunningGroundContactTime", "Ground Contact Time", .activity, "ms", since: 1600),
        measured("PhysicalEffort", "Physical Effort", .activity, "kcal/(kg*hr)", since: 1700),
        measured("WorkoutEffortScore", "Workout Effort", .activity, "appleEffortScore", since: 1800),
        measured("EstimatedWorkoutEffortScore", "Estimated Workout Effort", .activity, "appleEffortScore", since: 1800),
        sum("NikeFuel", "NikeFuel", .activity, "count"),

        // Body Measurements
        measured("Height", "Height", .bodyMeasurements, "cm"),
        measured("BodyMass", "Weight", .bodyMeasurements, "kg"),
        measured("BodyMassIndex", "Body Mass Index", .bodyMeasurements, "count"),
        measured("BodyFatPercentage", "Body Fat Percentage", .bodyMeasurements, "%"),
        measured("LeanBodyMass", "Lean Body Mass", .bodyMeasurements, "kg"),
        measured("WaistCircumference", "Waist Circumference", .bodyMeasurements, "cm", since: 1100),
        measured("AppleSleepingWristTemperature", "Wrist Temperature", .bodyMeasurements, "degC", since: 1600),

        // Cycle Tracking
        logged("MenstrualFlow", "Period", .cycleTracking, .bleeding, since: 900),
        logged("IntermenstrualBleeding", "Spotting", .cycleTracking, since: 900),
        logged("InfrequentMenstrualCycles", "Infrequent Periods", .cycleTracking, since: 1600),
        logged("IrregularMenstrualCycles", "Irregular Cycles", .cycleTracking, since: 1600),
        logged("PersistentIntermenstrualBleeding", "Persistent Spotting", .cycleTracking, since: 1600),
        logged("ProlongedMenstrualPeriods", "Prolonged Periods", .cycleTracking, since: 1600),
        measured("BasalBodyTemperature", "Basal Body Temperature", .cycleTracking, "degC", since: 900),
        logged("CervicalMucusQuality", "Cervical Mucus Quality", .cycleTracking, .cervicalMucus, since: 900),
        logged("OvulationTestResult", "Ovulation Test Result", .cycleTracking, .ovulation, since: 900),
        logged("PregnancyTestResult", "Pregnancy Test Result", .cycleTracking, .testResult, since: 1500),
        logged("ProgesteroneTestResult", "Progesterone Test Result", .cycleTracking, .testResult, since: 1500),
        logged("SexualActivity", "Sexual Activity", .cycleTracking, since: 900),
        logged("Contraceptive", "Contraceptives", .cycleTracking, .contraceptive, since: 1403),
        logged("Pregnancy", "Pregnancy", .cycleTracking, since: 1403),
        logged("Lactation", "Lactation", .cycleTracking, since: 1403),
        logged("BleedingDuringPregnancy", "Bleeding During Pregnancy", .cycleTracking, .bleeding, since: 1800),
        logged("BleedingAfterPregnancy", "Bleeding After Pregnancy", .cycleTracking, .bleeding, since: 1800),
        logged("BleedingAfterMenopause", "Bleeding After Menopause", .cycleTracking, .bleeding, since: 2700),
        logged("MenopausalState", "Menopause", .cycleTracking, .menopause, since: 2700),

        // Hearing
        measured("EnvironmentalAudioExposure", "Environmental Sound Levels", .hearing, "dBASPL", since: 1300),
        measured("HeadphoneAudioExposure", "Headphone Audio Levels", .hearing, "dBASPL", since: 1300),
        measured("EnvironmentalSoundReduction", "Environmental Sound Reduction", .hearing, "dBASPL", since: 1600),
        // HealthKit's .environmentalAudioExposureEvent keeps the raw value of the identifier it replaced.
        logged("AudioExposureEvent", "Noise Notifications", .hearing, since: 1400),
        logged("HeadphoneAudioExposureEvent", "Headphone Notifications", .hearing, since: 1402),
        special("HKDataTypeIdentifierAudiogram", "Hearing Test Results", .hearing, .audiogram, since: 1300),

        // Heart
        measured("HeartRate", "Heart Rate", .heart, "count/min"),
        measured("RestingHeartRate", "Resting Heart Rate", .heart, "count/min", since: 1100),
        measured("WalkingHeartRateAverage", "Walking Heart Rate Average", .heart, "count/min", since: 1100),
        measured("HeartRateVariabilitySDNN", "Heart Rate Variability", .heart, "ms", since: 1100),
        measured("HeartRateVariabilityRMSSD", "Heart Rate Variability (RMSSD)", .heart, "ms", since: 2700),
        measured("HeartRateRecoveryOneMinute", "Cardio Recovery", .heart, "count/min", since: 1600),
        measured("VO2Max", "Cardio Fitness", .heart, "ml/(kg*min)", since: 1100),
        measured("AtrialFibrillationBurden", "AFib History", .heart, "%", since: 1600),
        logged("HighHeartRateEvent", "High Heart Rate Notifications", .heart, since: 1202),
        logged("LowHeartRateEvent", "Low Heart Rate Notifications", .heart, since: 1202),
        logged("IrregularHeartRhythmEvent", "Irregular Rhythm Notifications", .heart, since: 1202),
        logged("LowCardioFitnessEvent", "Low Cardio Fitness Notifications", .heart, since: 1403),
        logged("HypertensionEvent", "Hypertension Notifications", .heart, since: 2602),
        special("HKDataTypeIdentifierElectrocardiogram", "ECG", .heart, .electrocardiogram, since: 1400),

        // Mental Wellbeing
        logged("MindfulSession", "Mindful Minutes", .mentalWellbeing, since: 1000),
        special("HKDataTypeStateOfMind", "State of Mind", .mentalWellbeing, .stateOfMind, since: 1800),
        special("HKScoredAssessmentTypeIdentifierGAD7", "Anxiety Risk (GAD-7)", .mentalWellbeing, .assessment, since: 1800),
        special("HKScoredAssessmentTypeIdentifierPHQ9", "Depression Risk (PHQ-9)", .mentalWellbeing, .assessment, since: 1800),

        // Mobility
        measured("AppleWalkingSteadiness", "Walking Steadiness", .mobility, "%", since: 1500),
        logged("AppleWalkingSteadinessEvent", "Walking Steadiness Notifications", .mobility, .walkingSteadiness, since: 1500),
        measured("WalkingSpeed", "Walking Speed", .mobility, "km/hr", since: 1400),
        measured("WalkingStepLength", "Walking Step Length", .mobility, "cm", since: 1400),
        measured("WalkingAsymmetryPercentage", "Walking Asymmetry", .mobility, "%", since: 1400),
        measured("WalkingDoubleSupportPercentage", "Double Support Time", .mobility, "%", since: 1400),
        measured("StairAscentSpeed", "Stair Speed: Up", .mobility, "m/s", since: 1400),
        measured("StairDescentSpeed", "Stair Speed: Down", .mobility, "m/s", since: 1400),
        measured("SixMinuteWalkTestDistance", "Six-Minute Walk", .mobility, "m", since: 1400),

        // Nutrition
        sum("DietaryEnergyConsumed", "Dietary Energy", .nutrition, "kcal"),
        sum("DietaryProtein", "Protein", .nutrition, "g"),
        sum("DietaryCarbohydrates", "Carbohydrates", .nutrition, "g"),
        sum("DietaryFatTotal", "Total Fat", .nutrition, "g"),
        sum("DietaryFatSaturated", "Saturated Fat", .nutrition, "g"),
        sum("DietaryFatMonounsaturated", "Monounsaturated Fat", .nutrition, "g"),
        sum("DietaryFatPolyunsaturated", "Polyunsaturated Fat", .nutrition, "g"),
        sum("DietaryCholesterol", "Cholesterol", .nutrition, "mg"),
        sum("DietarySugar", "Dietary Sugar", .nutrition, "g"),
        sum("DietaryFiber", "Fiber", .nutrition, "g"),
        sum("DietaryWater", "Water", .nutrition, "mL", since: 900),
        sum("DietaryCaffeine", "Caffeine", .nutrition, "mg"),
        sum("DietarySodium", "Sodium", .nutrition, "mg"),
        sum("DietaryPotassium", "Potassium", .nutrition, "mg"),
        sum("DietaryCalcium", "Calcium", .nutrition, "mg"),
        sum("DietaryIron", "Iron", .nutrition, "mg"),
        sum("DietaryMagnesium", "Magnesium", .nutrition, "mg"),
        sum("DietaryZinc", "Zinc", .nutrition, "mg"),
        sum("DietaryPhosphorus", "Phosphorus", .nutrition, "mg"),
        sum("DietaryManganese", "Manganese", .nutrition, "mg"),
        sum("DietaryCopper", "Copper", .nutrition, "mg"),
        sum("DietarySelenium", "Selenium", .nutrition, "mcg"),
        sum("DietaryChromium", "Chromium", .nutrition, "mcg"),
        sum("DietaryMolybdenum", "Molybdenum", .nutrition, "mcg"),
        sum("DietaryChloride", "Chloride", .nutrition, "mg"),
        sum("DietaryIodine", "Iodine", .nutrition, "mcg"),
        sum("DietaryVitaminA", "Vitamin A", .nutrition, "mcg"),
        sum("DietaryThiamin", "Thiamin", .nutrition, "mg"),
        sum("DietaryRiboflavin", "Riboflavin", .nutrition, "mg"),
        sum("DietaryNiacin", "Niacin", .nutrition, "mg"),
        sum("DietaryPantothenicAcid", "Pantothenic Acid", .nutrition, "mg"),
        sum("DietaryVitaminB6", "Vitamin B6", .nutrition, "mg"),
        sum("DietaryBiotin", "Biotin", .nutrition, "mcg"),
        sum("DietaryFolate", "Folate", .nutrition, "mcg"),
        sum("DietaryVitaminB12", "Vitamin B12", .nutrition, "mcg"),
        sum("DietaryVitaminC", "Vitamin C", .nutrition, "mg"),
        sum("DietaryVitaminD", "Vitamin D", .nutrition, "mcg"),
        sum("DietaryVitaminE", "Vitamin E", .nutrition, "mg"),
        sum("DietaryVitaminK", "Vitamin K", .nutrition, "mcg"),

        // Respiratory
        measured("RespiratoryRate", "Respiratory Rate", .respiratory, "count/min"),
        measured("OxygenSaturation", "Blood Oxygen", .respiratory, "%"),
        measured("ForcedExpiratoryVolume1", "Forced Expiratory Volume, 1 sec", .respiratory, "L"),
        measured("ForcedVitalCapacity", "Forced Vital Capacity", .respiratory, "L"),
        measured("PeakExpiratoryFlowRate", "Peak Expiratory Flow Rate", .respiratory, "L/min"),
        sum("InhalerUsage", "Inhaler Usage", .respiratory, "count"),
        measured("AppleSleepingBreathingDisturbances", "Breathing Disturbances", .respiratory, "count", since: 1800),
        logged("SleepApneaEvent", "Sleep Apnea Notifications", .respiratory, since: 1800),

        // Sleep
        Item(key: sleepKey, name: "Sleep", category: .sleep, shape: .sleep, unit: nil, values: .sleep, since: 800),

        // Symptoms
        symptom("AbdominalCramps", "Abdominal Cramps"),
        symptom("Acne", "Acne"),
        symptom("AppetiteChanges", "Appetite Changes", .appetite),
        symptom("BladderIncontinence", "Bladder Incontinence", since: 1400),
        symptom("Bloating", "Bloating"),
        symptom("BreastPain", "Breast Pain"),
        symptom("ChestTightnessOrPain", "Chest Tightness or Pain"),
        symptom("Chills", "Chills"),
        symptom("Constipation", "Constipation"),
        symptom("Coughing", "Coughing"),
        symptom("Diarrhea", "Diarrhea"),
        symptom("Dizziness", "Dizziness"),
        symptom("DrySkin", "Dry Skin", since: 1400),
        symptom("Fainting", "Fainting"),
        symptom("Fatigue", "Fatigue"),
        symptom("Fever", "Fever"),
        symptom("GeneralizedBodyAche", "Body and Muscle Ache"),
        symptom("HairLoss", "Hair Loss", since: 1400),
        symptom("Headache", "Headache"),
        symptom("Heartburn", "Heartburn"),
        symptom("HotFlashes", "Hot Flashes"),
        symptom("LossOfSmell", "Loss of Smell"),
        symptom("LossOfTaste", "Loss of Taste"),
        symptom("LowerBackPain", "Lower Back Pain"),
        symptom("MemoryLapse", "Memory Lapse", since: 1400),
        symptom("MoodChanges", "Mood Changes", .presence),
        symptom("Nausea", "Nausea"),
        symptom("NightSweats", "Night Sweats", since: 1400),
        symptom("PelvicPain", "Pelvic Pain"),
        symptom("RapidPoundingOrFlutteringHeartbeat", "Rapid, Pounding or Fluttering Heartbeat"),
        symptom("RunnyNose", "Runny Nose"),
        symptom("ShortnessOfBreath", "Shortness of Breath"),
        symptom("SinusCongestion", "Sinus Congestion"),
        symptom("SkippedHeartbeat", "Skipped Heartbeat"),
        symptom("SleepChanges", "Sleep Changes", .presence),
        symptom("SoreThroat", "Sore Throat"),
        symptom("VaginalDryness", "Vaginal Dryness", since: 1400),
        symptom("Vomiting", "Vomiting"),
        symptom("Wheezing", "Wheezing"),

        // Vitals
        measured("BloodPressureSystolic", "Blood Pressure (Systolic)", .vitals, "mmHg"),
        measured("BloodPressureDiastolic", "Blood Pressure (Diastolic)", .vitals, "mmHg"),
        measured("BloodGlucose", "Blood Glucose", .vitals, "mg/dL"),
        measured("BodyTemperature", "Body Temperature", .vitals, "degC"),
        measured("PeripheralPerfusionIndex", "Peripheral Perfusion Index", .vitals, "%"),

        // Other Data
        measured("BloodAlcoholContent", "Blood Alcohol Content", .other, "%"),
        sum("NumberOfAlcoholicBeverages", "Alcoholic Beverages", .other, "count", since: 1500),
        sum("NumberOfTimesFallen", "Number of Times Fallen", .other, "count"),
        sum("InsulinDelivery", "Insulin Delivery", .other, "IU", since: 1100),
        logged("ToothbrushingEvent", "Toothbrushing", .other, since: 1300),
        logged("HandwashingEvent", "Handwashing", .other, since: 1400),
        measured("UVExposure", "UV Index", .other, "count", since: 900),
        sum("TimeInDaylight", "Time in Daylight", .other, "min", since: 1700),
        measured("WaterTemperature", "Water Temperature", .other, "degC", since: 1600),
        measured("UnderwaterDepth", "Underwater Depth", .other, "m", since: 1600),
        measured("ElectrodermalActivity", "Electrodermal Activity", .other, "mcS"),
        trait("DateOfBirth", "Date of Birth"),
        trait("BiologicalSex", "Sex"),
        trait("BloodType", "Blood Type"),
        trait("FitzpatrickSkinType", "Skin Type", since: 900),
        trait("WheelchairUse", "Wheelchair Use", since: 1000),
        trait("ActivityMoveMode", "Move Ring Mode", since: 1400),
    ]

    static let byKey: [String: Item] = Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })

    /// The types this iOS has, in the page's order: by group, then by name.
    static func available(osVersion: Int = currentOS) -> [Item] {
        all.filter { $0.since <= osVersion }.sorted { ($0.category.order, $0.name) < ($1.category.order, $1.name) }
    }

    static func items(in category: Category, osVersion: Int = currentOS) -> [Item] {
        available(osVersion: osVersion).filter { $0.category == category }
    }

    /// This device's iOS as major * 100 + minor.
    static var currentOS: Int {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.majorVersion * 100 + min(version.minorVersion, 99)
    }

    // MARK: The four switches before 0.9.46

    /// The old switch keys, in their old order, and the types each one stood for.
    static let legacy: KeyValuePairs<String, [String]> = [
        "steps": [quantity + "StepCount", quantity + "DistanceWalkingRunning", quantity + "FlightsClimbed"],
        "sleep": [sleepKey],
        "workouts": [workoutKey],
        "heart": [quantity + "HeartRate", quantity + "RestingHeartRate"],
    ]

    static let legacyKeys: [String] = legacy.map(\.key)
    static let legacyNames = ["steps": "Steps & Distance", "sleep": "Sleep", "workouts": "Workouts", "heart": "Heart Rate"]

    static func legacyTypes(_ key: String) -> [String] { legacy.first { $0.key == key }?.value ?? [] }

    /// Old keys turned into their types; any other key is kept as it is.
    static func expandingLegacy(_ keys: Set<String>) -> Set<String> {
        Set(keys.flatMap { key in legacyKeys.contains(key) ? legacyTypes(key) : [key] })
    }

    /// The old switches an older add-on hears as on: each one whose types include one that is on.
    static func legacyOn(_ types: Set<String>) -> Set<String> {
        Set(legacy.filter { !types.isDisjoint(with: $0.value) }.map(\.key))
    }

    // MARK: Words

    /// A type's name for the bot or the page, from the catalog or, for a key it doesn't have, made from the key itself.
    static func name(_ key: String) -> String {
        byKey[key]?.name ?? legacyNames[key] ?? key
    }

    /// A workout's activity, by HKWorkoutActivityType raw value (HKWorkoutActivityType.h), as the bot reads it.
    static let workoutNames: [UInt: String] = [
        1: "american football", 2: "archery", 3: "australian football", 4: "badminton", 5: "baseball", 6: "basketball",
        7: "bowling", 8: "boxing", 9: "climbing", 10: "cricket", 11: "cross training", 12: "curling", 13: "cycling",
        14: "dance", 15: "dance inspired training", 16: "elliptical", 17: "equestrian sports", 18: "fencing",
        19: "fishing", 20: "functional strength training", 21: "golf", 22: "gymnastics", 23: "handball", 24: "hiking",
        25: "hockey", 26: "hunting", 27: "lacrosse", 28: "martial arts", 29: "mind and body",
        30: "mixed metabolic cardio training", 31: "paddle sports", 32: "play", 33: "preparation and recovery",
        34: "racquetball", 35: "rowing", 36: "rugby", 37: "running", 38: "sailing", 39: "skating sports",
        40: "snow sports", 41: "soccer", 42: "softball", 43: "squash", 44: "stair climbing", 45: "surfing sports",
        46: "swimming", 47: "table tennis", 48: "tennis", 49: "track and field", 50: "traditional strength training",
        51: "volleyball", 52: "walking", 53: "water fitness", 54: "water polo", 55: "water sports", 56: "wrestling",
        57: "yoga", 58: "barre", 59: "core training", 60: "cross country skiing", 61: "downhill skiing",
        62: "flexibility", 63: "high intensity interval training", 64: "jump rope", 65: "kickboxing", 66: "pilates",
        67: "snowboarding", 68: "stairs", 69: "step training", 70: "wheelchair walk pace", 71: "wheelchair run pace",
        72: "tai chi", 73: "mixed cardio", 74: "hand cycling", 75: "disc sports", 76: "fitness gaming",
        77: "cardio dance", 78: "social dance", 79: "pickleball", 80: "cooldown", 82: "swim bike run",
        83: "transition", 84: "underwater diving", 3000: "other",
    ]

    static func workoutName(_ raw: UInt) -> String { workoutNames[raw] ?? "other" }
}

nonisolated extension HealthCatalog.Category {
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}
