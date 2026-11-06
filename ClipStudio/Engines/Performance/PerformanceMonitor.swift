//
//  PerformanceMonitor.swift
//  ClipStudio — Engines/Performance (Part 6)
//
//  Watches the device so heavy work adapts instead of overheating or being
//  killed for memory:
//  • thermal state and Low Power Mode → the Studio preview resolution is capped
//    (serious: 540p, critical: 360p), proxy generation pauses, the animated
//    background stops;
//  • memory warnings → in-memory caches are purged (thumbnails, generated text
//    layers, waveforms, color cubes) and the event is counted;
//  • the app's memory footprint is sampled for the diagnostics screen.
//

import Foundation
import UIKit
import os

@MainActor
@Observable
final class PerformanceMonitor {
    static let shared = PerformanceMonitor()

    private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    private(set) var isLowPower: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
    private(set) var memoryWarnings = 0
    private(set) var lastWarning: Date?
    private(set) var footprintMB: Double = 0
    private(set) var peakFootprintMB: Double = 0

    /// User switch: adapt the preview to heat / Low Power Mode (on by default).
    var adaptsToHeat: Bool {
        didSet { UserDefaults.standard.set(adaptsToHeat, forKey: "performance.adaptive") }
    }

    private var observers: [NSObjectProtocol] = []
    private var sampler: Task<Void, Never>?

    private init() {
        adaptsToHeat = UserDefaults.standard.object(forKey: "performance.adaptive") as? Bool ?? true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PerformanceMonitor.shared.refreshState() }
        })
        observers.append(center.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PerformanceMonitor.shared.refreshState() }
        })
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PerformanceMonitor.shared.handleMemoryWarning() }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PerformanceMonitor.shared.startSampling() }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PerformanceMonitor.shared.stopSampling() }
        })
        startSampling()
    }

    func refreshState() {
        thermalState = ProcessInfo.processInfo.thermalState
        isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    // MARK: Policy

    /// Maximum preview short side for the current conditions (nil = no cap).
    var previewCap: CGFloat? {
        adaptsToHeat ? Self.previewCap(thermal: thermalState, lowPower: isLowPower) : nil
    }

    nonisolated static func previewCap(thermal: ProcessInfo.ThermalState, lowPower: Bool) -> CGFloat? {
        switch thermal {
        case .critical: return 360
        case .serious: return 540
        default: return lowPower ? 540 : nil
        }
    }

    /// Background work (proxies, batch analyses) should wait.
    var shouldPauseBackgroundWork: Bool {
        thermalState == .serious || thermalState == .critical
    }

    /// Decorative animation should stop (heat, Low Power Mode).
    var reducesEffects: Bool { isLowPower || thermalState == .serious || thermalState == .critical }

    var thermalTitle: String { Self.title(thermalState) }

    nonisolated static func title(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "طبيعية"
        case .fair: "دافئ قليلًا"
        case .serious: "حار — خُفّضت جودة المعاينة"
        case .critical: "حار جدًا — أوقف الأعمال الثقيلة"
        @unknown default: "غير معروفة"
        }
    }

    // MARK: Memory

    func handleMemoryWarning() {
        memoryWarnings += 1
        lastWarning = Date()
        Self.purgeCaches()
        sampleFootprint()
    }

    static func purgeCaches() {
        ThumbnailService.shared.clearMemory()
        GeneratedContentRenderer.shared.clear()
        Task { await WaveformService.shared.clearMemory() }
        URLCache.shared.removeAllCachedResponses()
    }

    func sampleFootprint() {
        let value = Self.currentFootprintMB()
        footprintMB = value
        peakFootprintMB = max(peakFootprintMB, value)
    }

    private func startSampling() {
        refreshState()
        guard sampler == nil else { return }
        sampler = Task { [weak self] in
            while !Task.isCancelled {
                self?.sampleFootprint()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func stopSampling() {
        sampler?.cancel()
        sampler = nil
    }

    /// Physical footprint (what iOS counts against the app's memory limit), in MB.
    nonisolated static func currentFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }

    /// Available memory before iOS terminates the app (iOS 13+), in MB.
    nonisolated static func availableMB() -> Double {
        Double(os_proc_available_memory()) / 1_048_576
    }
}
