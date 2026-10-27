import SwiftUI
import AppKit

@main
struct PhotoShuffleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject var app = AppState()

    var body: some Scene {
        WindowGroup("PhotoShuffle") {
            ContentView()
                .environmentObject(app)
                .environmentObject(Indexer.shared)
                .frame(minWidth: 960, minHeight: 640)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        Settings {
            SettingsView()
                .environmentObject(app)
                .environmentObject(Indexer.shared)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: nil, queue: .main) { note in
            (note.object as? NSWindow)?.toolbar?.isVisible = false
        })
        observers.append(center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main) { note in
            (note.object as? NSWindow)?.toolbar?.isVisible = true
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification,
                                                                          object: nil, queue: .main) { _ in
            Indexer.shared.start()
        })
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        FaceClusterer.shared.flush()
    }
}

final class AppState: ObservableObject {
    enum Tab: Hashable {
        case slideshow, people
    }

    @Published var tab: Tab = .slideshow
    @Published private(set) var rootPath: String?
    let slideshow = SlideshowModel()

    init() {
        Keys.registerDefaults()
        rootPath = UserDefaults.standard.string(forKey: Keys.root)
        FaceClusterer.shared.load()
        if rootPath != nil { Indexer.shared.start() }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Выбрать"
        panel.message = "Выберите папку с фотографиями — можно весь внешний диск"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setRoot(url.path)
    }

    func setRoot(_ path: String) {
        let old = rootPath
        UserDefaults.standard.set(path, forKey: Keys.root)
        rootPath = path
        if let old = old, old != path {
            Indexer.shared.restart(clearLibrary: true)
        } else {
            Indexer.shared.start()
        }
        slideshow.restart()
    }

    func showSlideshow(personId: Int64) {
        var f = SlideFilter()
        f.categoryId = MediaCategory.people.id
        f.personId = personId
        slideshow.filter = f
        tab = .slideshow
    }
}

func openSettingsWindow() {
    if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
        _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }
}

func toggleFullScreen() {
    (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
}

func exitFullScreenIfNeeded() {
    if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.styleMask.contains(.fullScreen) {
        window.toggleFullScreen(nil)
    }
}
