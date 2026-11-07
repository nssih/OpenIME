import OpenIMECore
import SwiftUI

// MARK: - 主 App 根视图

@main
struct OpenIMEApp: App {
    @ObservedObject private var runtime = IMERuntime.shared

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(runtime)
                .task {
                    await IMERuntime.shared.start()
                }
        }
    }
}

struct MainTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var runtime: IMERuntime

    var body: some View {
        TabView {
            SchemeManagerView()
                .tabItem {
                    Label("方案", systemImage: "square.stack.3d.up")
                }

            KeyboardSettingsView()
                .tabItem {
                    Label("键盘", systemImage: "keyboard")
                }

            MixInputSettingsView()
                .tabItem {
                    Label("混合", systemImage: "arrow.triangle.merge")
                }

            UserWordsView()
                .tabItem {
                    Label("词典", systemImage: "text.book.closed")
                }

            AboutView()
                .tabItem {
                    Label("关于", systemImage: "info.circle")
                }
        }
        // 主 App 打开 / 回前台时抓取一次剪贴板（与键盘共享同一 lastChangeCount，不会重复入库）
        .onAppear {
            ClipboardCapture.captureIfNeeded()
            // 注册跨进程设置监听：键盘扩展是独立进程，App 在前台、键盘同屏时切方案
            // 不会触发 scenePhase 变化，只能靠 Darwin 通知实时收到（幂等，多次 onAppear 只注册一次）
            runtime.observeSettingsChangesIfNeeded()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                ClipboardCapture.captureIfNeeded()
                // 回前台时从磁盘重载设置：键盘扩展是独立进程，它那边激活方案 / 改开关只写盘，
                // 主 App 不重载就会一直停在启动时的旧值（混合页主方案不跟随即由此而来）
                runtime.reloadSettings()
            }
        }
    }
}

