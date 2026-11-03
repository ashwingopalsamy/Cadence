// CadenceApp: the menu-bar app (macOS only). An accessory app with one running instance.
import AppKit
import CadenceCore
import CadenceUI
import ServiceManagement
import SwiftUI

// `make uninstall` runs this; it needs no running app and takes no lock.
if CommandLine.arguments.contains("--unregister") {
    let id = Bundle.main.bundleIdentifier ?? ""
    let services = [SMAppService.mainApp, SMAppService.agent(plistName: "\(id).agent.plist")]
    var failed = false
    // A service never registered reports notFound, and unregistering it throws.
    for service in services {
        if service.status == .enabled || service.status == .requiresApproval {
            do {
                try service.unregister()
            } catch {
                FileHandle.standardError.write(Data("unregister: \(error.localizedDescription)\n".utf8))
                failed = true
            }
        }
        print("unregister: status \(service.status.rawValue)")
    }
    exit(failed ? 1 : 0)
}

// flock guards the inode, so the file sits in Application Support, which nothing purges, not in tmp.
// The kernel drops the lock when the process ends, however it ends, so a crash cannot strand it.
// The descriptor stays open for the life of the process. Only a held lock stops a launch; any other
// failure runs without one, because a missing lock is better than a menu-bar app that will not start.
let lockDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
try? FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
let lockDescriptor = open(lockDirectory.appendingPathComponent("cadence.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
if lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) != 0, errno == EWOULDBLOCK {
    if let id = Bundle.main.bundleIdentifier {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
        others.first { $0 != .current }?.activate()
    }
    FileHandle.standardError.write(Data("Cadence is already running; quit it first.\n".utf8))
    exit(1)
}

if let resources = Bundle.main.resourceURL {
    CadenceType.registerFonts(in: resources.appendingPathComponent("Fonts"))
}

// The store the app reads. Inside the sandbox `NSHomeDirectory()` is the container, so the real home comes from
// the password database (docs/SPEC.md section 8.3). `CADENCE_HOME`, when set, is the store: a folder the sandbox
// denies shows the error state, and nothing falls back to the real store.
let storeLocation = StoreLocation.resolve(
    environment: ProcessInfo.processInfo.environment, realHome: StoreLocation.realHome())
let dayModel = DayModel(loader: DayStoreLoader(location: storeLocation, clock: SystemClock()))

// The observer's first check is the initial load, and each write after it reloads the day: a store-changed
// notification wakes it, with `PRAGMA data_version` polling as the fallback (docs/SPEC.md sections 8.2 and 8.7).
// The Pocket tells it when it is on screen with `setVisible`, which moves the poll from 30 s to 2 s.
let storeChanges = StoreChanges()
storeChanges.add { dayModel.reload() }
let storeObserver: StoreObserver?
if let databasePath = storeLocation.databasePath {
    storeObserver = StoreObserver(
        source: StoreVersionProbe(path: databasePath), clock: SystemClock(),
        onChange: { Task { @MainActor in storeChanges.changed() } })
    storeObserver?.start()
} else {
    // No place to watch; the one read shows why.
    storeObserver = nil
    dayModel.reload()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// MARK: T3.7 panel and status item (docs/SPEC.md sections 4.1 and 4.2)
// One shared model for every surface, the warm panel, and the status item that toggles it and owns the right-click
// menu. The closures that open other surfaces are wired when those surfaces land; until then they do nothing.
let appWriter = AppWriter(location: storeLocation, clock: SystemClock())
let appState = AppState(model: dayModel, writer: appWriter, clock: SystemClock())
let capturePause = CapturePause(app: appState)
let surfaces = Surfaces()
let panelActions = PanelActions(
    openWindow: { surfaces.openWindow($0) },
    openPlanSheet: { surfaces.openPlanSheet() },
    openWrapUp: { surfaces.openWrapUp() },
    openRecap: { surfaces.openRecap() },
    openSettings: { surfaces.openSettings($0) },
    sealAsEmpty: { Task { _ = await appState.seal(standup: false) } },
    openCapture: { surfaces.openCapture() }
)
/// Tempo for the day, composed from what the store and the app know (docs/SPEC.md section 5.3).
@MainActor func tempo(for story: DayStory, size: CGFloat) -> AnyView {
    let input = appState.context?.storyInput(at: appState.now) ?? DayStory.Input(date: appState.today)
    let hour = Calendar.current.component(.hour, from: appState.now)
    return AnyView(TempoView(TempoSpec.compose(state: story.state, input: input, hour: hour), size: size))
}
let panelController = PanelController(
    app: appState, pause: capturePause, actions: panelActions, tempo: { tempo(for: $0, size: CadenceSize.panelTempo) })
let statusItem = StatusItemController(app: appState, pause: capturePause, panel: panelController, actions: panelActions)
panelController.onVisibilityChange = { open in
    statusItem.panelVisibilityChanged(open)
    storeObserver?.setVisible(open)
}
// MARK: end T3.7

// MARK: - The window (T4.1)
// One window for Today, Log, Insights, Recap, Proof, Inbox and Settings, read and acted on through `AppState`.
// The panel and notifications call `openWindow(section:)`. The sheets and recaps are built in other tasks, so their
// closures do nothing until the planner wires them; failure actions other than Try again and Quit wait for T3.33.
let windowSections = WindowSections(
    recaps: RecapModel(loader: RecapStoreLoader(location: storeLocation, clock: SystemClock())),
    proof: ProofModel(reader: ProofReader(location: storeLocation, clock: SystemClock())),
    log: LogModel(location: storeLocation, clock: SystemClock()),
    inbox: InboxModel(location: storeLocation, clock: SystemClock()),
    insights: InsightsModel(loader: InsightsStoreLoader(location: storeLocation, clock: SystemClock())),
    milestones: MilestoneTracker(store: DefaultsMilestoneStore(), play: { sounds.play($0) }))
storeChanges.add {
    windowSections.log?.reload()
    windowSections.inbox?.reload()
    windowSections.insights?.refresh()
}
let windowController = WindowController(
    app: appState,
    actions: WindowActions(
        openPlan: { surfaces.openPlanSheet() }, openWrapUp: { surfaces.openWrapUp() },
        wrapUpYesterday: { surfaces.wrapUpPrevious() }, openRecap: { surfaces.openRecap() },
        failure: { action in
            FailureActions.perform(action, app: appState, location: storeLocation) { pane in
                windowController.open(section: .settings)
                windowController.navigation.openSettings(pane: pane)
            }
        }),
    sections: windowSections,
    navigation: WindowNavigation(days: DayBrowser(reader: StoreReader(location: storeLocation, clock: SystemClock()))))
surfaces.openRecap = { windowController.open(section: .recap) }
surfaces.openWindow = { section in
    windowController.open(section: section == .insights ? .insights : .today)
}
surfaces.openSettings = { pane in
    windowController.open(section: .settings)
    windowController.navigation.openSettings(pane: pane == .sources ? "Sources" : "General")
}

/// Opens the window at a section and brings Cadence forward.
@MainActor func openWindow(section: WindowSection) {
    windowController.open(section: section)
}
// MARK: - End of the window block

// --- Sheets: the morning plan and the wrap-up (T3.9, T3.10), opened from the panel, the window and notifications ---
let sounds = CadenceSoundPlayer()
appState.onLogged = { sounds.play(.captureSaved) }
let soundCues = SoundCues(model: dayModel, sounds: sounds)
let sheetsController = SheetWindowController(
    app: appState, location: storeLocation, sound: sounds,
    tempo: { pose, size in
        guard let name = TempoPose.Name(rawValue: pose) else { return AnyView(EmptyView()) }
        return AnyView(TempoView(TempoSpec(pose: name), size: size))
    })
surfaces.openPlanSheet = { sheetsController.showPlan() }
surfaces.openWrapUp = {
    // Yesterday still open in its grace window is wrapped up first; otherwise today.
    if appState.story?.state == .yesterdayOpen, let previous = appState.context?.previous, previous.graceOpen {
        sheetsController.showWrapUp(previous: previous.date)
    } else {
        sheetsController.showWrapUp()
    }
}
surfaces.wrapUpPrevious = {
    // "Wrap up Wednesday" opens Wednesday's wrap-up, whatever today's state is.
    guard let previous = appState.context?.previous, previous.graceOpen else { return }
    sheetsController.showWrapUp(previous: previous.date)
}
// --- end sheets ---

// The login item and the collector agent (docs/SPEC.md sections 8.1 and 8.3). Only a service that is not registered is
// registered, so an enabled one is never touched again. `loginItems.report` is what Settings and the failure table
// read: enabled, requires approval (also after an update, when macOS asks again), not found or failed.
let loginItems = LoginItemController.forThisApp()
loginItems.ensureRegistered()

// Notifications (docs/SPEC.md section 4.7), nil outside an app bundle. The day clock tells it about the boundary, a wake
// and the plan prompt, and the model about each read; it keeps the next 7 workdays of wrap-up reminders in the system.
// `onRoute` is where a tap or a button lands: T3.7 to T3.10 open the panel, the plan sheet or the wrap-up sheet here.
let notifications = Notifications(
    clock: SystemClock(), location: storeLocation,
    onRoute: { route in
        switch route {
        case .plan: surfaces.openPlanSheet()
        case .wrapUp: surfaces.openWrapUp()
        case .sources: surfaces.openSettings(.sources)
        case .inbox: windowController.open(section: .inbox)
        }
    })
notifications?.follow(dayModel)
Task { @MainActor in
    // Asked once, if the system has not been asked. The answer stays in `notifications.access`, which the
    // "Notifications are off" screen reads later.
    appState.notificationsOff = await notifications?.authorize() == .denied
    notifications?.refresh(state: dayModel.state)
}
// Coming back from System Settings, the answer may have changed.
let notificationsAccessObserver = NotificationCenter.default.addObserver(
    forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
) { _ in
    Task { @MainActor in appState.notificationsOff = await notifications?.authorize() == .denied }
}

// The day clock keeps one timer on the next moment the surfaces change at: the 04:00 boundary, today's reminders, the
// plan prompt and a grace window closing. Nothing writes at those moments, so it rereads the day when each comes, and
// on wake and on time zone and clock changes (docs/SPEC.md section 3). It replaces a 5 minute refresh timer and a
// separate wake observer.
let dayClock = DayClock(
    clock: SystemClock(),
    inputs: { DayClockInput(location: storeLocation, state: dayModel.state) },
    onEvent: { event in
        dayModel.reload()
        notifications?.clockEvent(event, state: dayModel.state)
    })
dayClock.follow(dayModel)
dayClock.start()

// --- T3.32 presence: the app's one writer and the presence adapter (docs/SPEC.md section 8.4) ---
// `appWriter` is the only write connection in the app; other blocks that write must share it, not open another.
// `presenceAdapter.setPaused(until:)` is "Capture paused", and `isPaused` is what `AppSignals.paused` reads.
let presenceAdapter = PresenceAdapter(writer: appWriter, clock: SystemClock())
presenceAdapter.start()
// Closes the open span at the moment of quitting; a crash is closed from the saved state at its last input instead.
let presenceTerminationObserver = NotificationCenter.default.addObserver(
    forName: NSApplication.willTerminateNotification, object: nil, queue: nil
) { _ in
    // A tick still waiting for Undo is written however the app quits (menu, logout, restart), waiting at most a second.
    if let task = MainActor.assumeIsolated({ appState.takePendingTick() }) {
        let written = DispatchSemaphore(value: 0)
        Task.detached {
            _ = await appWriter.perform(.resolve(task: task, status: .done, reason: nil))
            written.signal()
        }
        _ = written.wait(timeout: .now() + 1)
    }
    presenceAdapter.stop()
}
// --- end T3.32 ---

// --- T3.18 housekeeping: spool drain, daily backup, agent status and source health, all through `appWriter` ---
// `housekeeping.status.behind` is what `AppSignals.behind` reads, and `status` is what Settings and doctor show.
// `housekeeping.onChange` fires after every run, for whoever keeps the app's signals.
let housekeeping = Housekeeping(work: appWriter, agent: SMAppServiceAgentStatus(), clock: SystemClock())
housekeeping.start()
// --- end T3.18 ---

// --- Integration: what only the app knows reaches the one story (docs/SPEC.md section 5.2) ---
capturePause.onChange = { end in
    presenceAdapter.setPaused(until: end)
    // The collector agent reads the same pause, so collectors stop too, and a relaunch keeps it.
    if case .found(let roots) = storeLocation { try? CapturePauseFile.write(end, roots: roots) }
}
if case .found(let roots) = storeLocation {
    capturePause.restore(until: CapturePauseFile.pausedUntil(roots: roots, now: Date()))
}
// A backfill of more than a week is the first sync: the agent writes its progress after each chunk, so each store
// change reads it again, and while one runs a check every 5 s sees the end, which may land after the last change.
var backfillCheck: Task<Void, Never>?
@MainActor func readBackfill() {
    guard case .found(let roots) = storeLocation else { return }
    let progress = BackfillProgressFile.read(roots: roots, now: Date())
    let importing = progress.map { DayStory.Import(label: $0.label, done: $0.done, total: $0.total) }
    if importing != appState.signals.importing { appState.signals.importing = importing }
    backfillCheck?.cancel()
    backfillCheck = importing == nil ? nil : Task { @MainActor in
        try? await Task.sleep(for: .seconds(5))
        guard !Task.isCancelled else { return }
        readBackfill()
    }
}
storeChanges.add { readBackfill() }
readBackfill()
housekeeping.onChange = { status in
    Task { @MainActor in
        appState.signals.behind = status.behind
        // A failing source that feeds the count gets one notice after 3 hours, and it is taken back on recovery.
        for source in status.sources where source.feedsCount {
            if source.isFailing, let since = source.lastGoodRun {
                notifications?.sourceBehind(source.title, since: since)
            } else if !source.isFailing {
                notifications?.sourceRecovered(source.title)
            }
        }
    }
}
// --- end integration ---

// MARK: T3.8 capture bar and global hotkeys (docs/SPEC.md sections 4.3 and 4.8)
// The bar saves through the one app writer and state above. ⌃⌥L opens the bar, ⌃⌥N opens it as a note, ⌃⌥D turns
// discreet mode on or off.
// `hotkeyClashes` is what Settings will show ("⌃⌥L is already used by another app. ..."). `icon` takes the app
// icon view (TempoAppIcon, T3.6) at its 26-point size.
let capture = CaptureController(state: appState, location: storeLocation, clock: SystemClock(), icon: { AnyView(TempoAppIcon(size: 26)) })
let hotkeys = Hotkeys { action in
    switch action {
    case .capture: capture.open(.capture)
    case .quickNote: capture.open(.note)
    case .discreet:
        appState.discreet.toggle()
        statusItem.discreet = appState.discreet
        notifications?.discreet = appState.discreet
    }
}
let hotkeyClashes = hotkeys.apply(.standard)
surfaces.openCapture = { capture.open(.capture) }
// MARK: end T3.8

// --- Settings and first run (T3.16, T4.12), made last because they control the services above ---
let settingsAndFirstRun = SettingsWiring.make(
    SettingsWiring.Services(
        app: appState, writer: appWriter, location: storeLocation, loginItems: loginItems, notifications: notifications,
        sounds: sounds, applyHotkeys: { hotkeys.apply($0) }, clashes: hotkeyClashes, sections: windowSections))
windowSections.settings = settingsAndFirstRun.settings
windowSections.firstRun = settingsAndFirstRun.firstRun
// --- end settings and first run ---

app.run()
