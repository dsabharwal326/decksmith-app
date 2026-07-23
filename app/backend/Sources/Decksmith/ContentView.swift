import SwiftUI

struct ContentView: View {
    @Bindable var appModel: AppModel
    @State private var sidebarSelection: SidebarItem = .upload

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $sidebarSelection, appModel: appModel)
        } detail: {
            Group {
                switch appModel.phase {
                case .idle:
                    switch sidebarSelection {
                    case .upload:    UploadView(appModel: appModel)
                    case .topic:     TopicView(appModel: appModel)
                    case .history:   HistoryView(appModel: appModel)
                    case .settings:  SettingsView(appModel: appModel)
                    }
                case .processing:
                    ProcessingView(appModel: appModel)
                case .results:
                    ResultsView(appModel: appModel)
                case .exporting:
                    ExportView(appModel: appModel)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 560)
    }
}
