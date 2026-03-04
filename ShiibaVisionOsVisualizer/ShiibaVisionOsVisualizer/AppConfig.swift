//
//  AppConfig.swift
//  ShiibaVisionOsVisualizer
//
//  Centralized configuration with Settings.bundle support.
//  Values are read once at init time (no runtime hot-reload).
//

import Foundation

enum AppConfig {

    /// Register all default values with UserDefaults.
    /// Must be called before AppModel() is created.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            // Auto Start (existing)
            "auto_start_enabled": false,
            // A: Network/OSC
            OSC.receivePortKey: OSC.receivePortDefault,
            OSC.sendPortKey: OSC.sendPortDefault,
            OSC.sendHostKey: OSC.sendHostDefault,
            // B: Rendering
            Rendering.pointPhysicalSizeKey: String(Rendering.pointPhysicalSizeDefault),
            Rendering.floorNoiseThresholdKey: String(Rendering.floorNoiseThresholdDefault),
            Rendering.overlayAlphaKey: String(Rendering.overlayAlphaDefault),
            Rendering.titleDisplayDurationKey: String(Rendering.titleDisplayDurationDefault),
            Rendering.titleQuadWidthKey: String(Rendering.titleQuadWidthDefault),
            Rendering.axisLengthKey: String(Rendering.axisLengthDefault),
            Rendering.axisThicknessKey: String(Rendering.axisThicknessDefault),
            Rendering.sceneYRotationKey: String(Rendering.sceneYRotationDefault),
            // C: Playback
            Playback.frameRateKey: String(Playback.frameRateDefault),
            Playback.animationSleepMsKey: Playback.animationSleepMsDefault,
            Playback.pauseSleepMsKey: Playback.pauseSleepMsDefault,
            // D: Spatial Detection
            Spatial.floorDetectionIntervalKey: String(Spatial.floorDetectionIntervalDefault),
            Spatial.floorYOffsetMinKey: String(Spatial.floorYOffsetMinDefault),
            Spatial.floorYOffsetMaxKey: String(Spatial.floorYOffsetMaxDefault),
            // E: Spatial Audio
            Audio.rolloffFactorKey: String(Audio.rolloffFactorDefault),
            Audio.referenceDistanceKey: String(Audio.referenceDistanceDefault),
            Audio.maxDistanceKey: String(Audio.maxDistanceDefault),
            // F: iCloud/Retry
            ICloud.sampleSizeKey: ICloud.sampleSizeDefault,
            ICloud.pollIntervalKey: ICloud.pollIntervalDefault,
            ICloud.checkIntervalKey: ICloud.checkIntervalDefault,
            WorldTracking.retryCountKey: WorldTracking.retryCountDefault,
            WorldTracking.retryIntervalMsKey: WorldTracking.retryIntervalMsDefault,
        ])
    }

    // MARK: - Type-safe accessors

    private static func floatValue(forKey key: String, default defaultValue: Float) -> Float {
        guard let val = UserDefaults.standard.object(forKey: key) else { return defaultValue }
        if let f = val as? Float { return f }
        if let d = val as? Double { return Float(d) }
        if let n = val as? NSNumber { return n.floatValue }
        if let s = val as? String, let f = Float(s) { return f }
        return defaultValue
    }

    private static func intValue(forKey key: String, default defaultValue: Int) -> Int {
        guard let val = UserDefaults.standard.object(forKey: key) else { return defaultValue }
        if let i = val as? Int { return i }
        if let n = val as? NSNumber { return n.intValue }
        if let s = val as? String, let i = Int(s) { return i }
        return defaultValue
    }

    private static func stringValue(forKey key: String, default defaultValue: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? defaultValue
    }

    // MARK: - A: Network/OSC

    enum OSC {
        static let receivePortKey = "osc_receive_port"
        static let sendPortKey = "osc_send_port"
        static let sendHostKey = "osc_send_host"

        static let receivePortDefault = 9999
        static let sendPortDefault = 9998
        static let sendHostDefault = "192.168.0.7"

        static var receivePort: Int { intValue(forKey: receivePortKey, default: receivePortDefault) }
        static var sendPort: Int { intValue(forKey: sendPortKey, default: sendPortDefault) }
        static var sendHost: String { stringValue(forKey: sendHostKey, default: sendHostDefault) }
    }

    // MARK: - B: Rendering

    enum Rendering {
        static let pointPhysicalSizeKey = "point_physical_size"
        static let floorNoiseThresholdKey = "floor_noise_threshold"
        static let overlayAlphaKey = "overlay_alpha"
        static let titleDisplayDurationKey = "title_display_duration"
        static let titleQuadWidthKey = "title_quad_width"
        static let axisLengthKey = "axis_length"
        static let axisThicknessKey = "axis_thickness"
        static let sceneYRotationKey = "scene_y_rotation"

        static let pointPhysicalSizeDefault: Float = 0.001
        static let floorNoiseThresholdDefault: Float = 0.02
        static let overlayAlphaDefault: Float = 0.2
        static let titleDisplayDurationDefault: Float = 5.0
        static let titleQuadWidthDefault: Float = 0.5
        static let axisLengthDefault: Float = 0.5
        static let axisThicknessDefault: Float = 0.01
        static let sceneYRotationDefault: Float = 0.0

        static var pointPhysicalSize: Float { floatValue(forKey: pointPhysicalSizeKey, default: pointPhysicalSizeDefault) }
        static var floorNoiseThreshold: Float { floatValue(forKey: floorNoiseThresholdKey, default: floorNoiseThresholdDefault) }
        static var overlayAlpha: Float { floatValue(forKey: overlayAlphaKey, default: overlayAlphaDefault) }
        static var titleDisplayDuration: Float { floatValue(forKey: titleDisplayDurationKey, default: titleDisplayDurationDefault) }
        static var titleQuadWidth: Float { floatValue(forKey: titleQuadWidthKey, default: titleQuadWidthDefault) }
        static var axisLength: Float { floatValue(forKey: axisLengthKey, default: axisLengthDefault) }
        static var axisThickness: Float { floatValue(forKey: axisThicknessKey, default: axisThicknessDefault) }
        static var sceneYRotation: Float { floatValue(forKey: sceneYRotationKey, default: sceneYRotationDefault) }
    }

    // MARK: - C: Playback

    enum Playback {
        static let frameRateKey = "playback_frame_rate"
        static let animationSleepMsKey = "animation_sleep_ms"
        static let pauseSleepMsKey = "pause_sleep_ms"

        static let frameRateDefault: Float = 30.0
        static let animationSleepMsDefault = 5
        static let pauseSleepMsDefault = 50

        static var frameRate: Float { floatValue(forKey: frameRateKey, default: frameRateDefault) }
        static var animationSleepMs: Int { intValue(forKey: animationSleepMsKey, default: animationSleepMsDefault) }
        static var pauseSleepMs: Int { intValue(forKey: pauseSleepMsKey, default: pauseSleepMsDefault) }
    }

    // MARK: - D: Spatial Detection

    enum Spatial {
        static let floorDetectionIntervalKey = "floor_detection_interval"
        static let floorYOffsetMinKey = "floor_y_offset_min"
        static let floorYOffsetMaxKey = "floor_y_offset_max"

        static let floorDetectionIntervalDefault: Float = 0.5
        static let floorYOffsetMinDefault: Float = -1.8
        static let floorYOffsetMaxDefault: Float = -1.5

        static var floorDetectionInterval: Float { floatValue(forKey: floorDetectionIntervalKey, default: floorDetectionIntervalDefault) }
        static var floorYOffsetMin: Float { floatValue(forKey: floorYOffsetMinKey, default: floorYOffsetMinDefault) }
        static var floorYOffsetMax: Float { floatValue(forKey: floorYOffsetMaxKey, default: floorYOffsetMaxDefault) }
    }

    // MARK: - E: Spatial Audio

    enum Audio {
        static let rolloffFactorKey = "audio_rolloff_factor"
        static let referenceDistanceKey = "audio_reference_distance"
        static let maxDistanceKey = "audio_max_distance"

        static let rolloffFactorDefault: Float = 2.0
        static let referenceDistanceDefault: Float = 1.0
        static let maxDistanceDefault: Float = 50.0

        static var rolloffFactor: Float { floatValue(forKey: rolloffFactorKey, default: rolloffFactorDefault) }
        static var referenceDistance: Float { floatValue(forKey: referenceDistanceKey, default: referenceDistanceDefault) }
        static var maxDistance: Float { floatValue(forKey: maxDistanceKey, default: maxDistanceDefault) }
    }

    // MARK: - F: iCloud/Retry

    enum ICloud {
        static let sampleSizeKey = "icloud_sample_size"
        static let pollIntervalKey = "icloud_poll_interval"
        static let checkIntervalKey = "icloud_check_interval"

        static let sampleSizeDefault = 20
        static let pollIntervalDefault = 10
        static let checkIntervalDefault = 5

        static var sampleSize: Int { intValue(forKey: sampleSizeKey, default: sampleSizeDefault) }
        static var pollInterval: Int { intValue(forKey: pollIntervalKey, default: pollIntervalDefault) }
        static var checkInterval: Int { intValue(forKey: checkIntervalKey, default: checkIntervalDefault) }
    }

    enum WorldTracking {
        static let retryCountKey = "world_tracking_retry_count"
        static let retryIntervalMsKey = "world_tracking_retry_interval_ms"

        static let retryCountDefault = 15
        static let retryIntervalMsDefault = 200

        static var retryCount: Int { intValue(forKey: retryCountKey, default: retryCountDefault) }
        static var retryIntervalMs: Int { intValue(forKey: retryIntervalMsKey, default: retryIntervalMsDefault) }
    }
}
