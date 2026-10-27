import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var indexer: Indexer

    @AppStorage(Keys.slideSeconds) var slideSeconds = 6.0
    @AppStorage(Keys.kenBurns) var kenBurns = true
    @AppStorage(Keys.includeVideos) var includeVideos = true
    @AppStorage(Keys.videoSound) var videoSound = false
    @AppStorage(Keys.faceSimilarity) var faceSimilarity = 0.62

    @State var stats = LibraryStats()
    @State var regrouping = false
    @State var regroupProgress = 0.0
    @State var confirmFolderChange = false

    var body: some View {
        TabView {
            general
                .tabItem { Label("Основные", systemImage: "gearshape") }
            faces
                .tabItem { Label("Лица", systemImage: "person.crop.circle") }
            library
                .tabItem { Label("Медиатека", systemImage: "photo.on.rectangle") }
        }
        .frame(width: 560, height: 380)
        .onAppear(perform: reloadStats)
        .onReceive(indexer.$libraryVersion) { _ in reloadStats() }
    }

    // MARK: Tabs

    private var general: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: "folder.fill").foregroundColor(.accentColor)
                    Text(app.rootPath ?? "Не выбрана")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Изменить…") { confirmFolderChange = true }
                }
            } header: {
                Text("Папка с фото")
            }

            Section {
                HStack {
                    Text("Каждое фото")
                    Slider(value: $slideSeconds, in: 3...30, step: 1)
                    Text("\(Int(slideSeconds)) сек").monospacedDigit().frame(width: 52, alignment: .trailing)
                }
                Toggle("Плавный наезд камеры (эффект Кена Бёрнса)", isOn: $kenBurns)
                Toggle("Показывать видео и Live Photo", isOn: $includeVideos)
                Toggle("Звук у видео", isOn: $videoSound)
            } header: {
                Text("Слайд-шоу")
            }
        }
        .padding(20)
        .alert("Сменить папку?", isPresented: $confirmFolderChange) {
            Button("Выбрать другую папку") { app.chooseFolder() }
            Button("Отмена", role: .cancel) { }
        } message: {
            Text("Медиатека будет собрана заново. Имена подписанных людей сохранятся — приложение узнает их и на новых фото.")
        }
    }

    private var faces: some View {
        Form {
            Section {
                Text("Найдено лиц: \(Fmt.number(stats.faces)) · людей: \(Fmt.number(stats.people)) · подписано: \(Fmt.number(stats.named))")
                    .foregroundColor(.secondary)
            }

            Section {
                HStack {
                    Text("Мягче").font(.caption).foregroundColor(.secondary)
                    Slider(value: $faceSimilarity, in: 0.45...0.85)
                    Text("Строже").font(.caption).foregroundColor(.secondary)
                }
                Text("Если в одной группе оказались разные люди — сдвиньте вправо. Если один человек разбит на много групп — влево. Затем нажмите «Перегруппировать».")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Перегруппировать лица", action: regroup)
                        .disabled(regrouping)
                    if regrouping {
                        ProgressView(value: regroupProgress)
                            .frame(width: 160)
                    }
                }
                Text("Подписанные люди и ваши исправления сохранятся.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Группировка лиц")
            }
        }
        .padding(20)
    }

    private var library: some View {
        Form {
            Section {
                Text("Всего: \(Fmt.number(stats.total)) · проанализировано: \(Fmt.number(stats.analyzed))")
                if stats.total > 0 {
                    ProgressView(value: Double(stats.analyzed), total: Double(max(stats.total, 1)))
                }
                Text(indexer.isPaused ? "Анализ на паузе" : (indexer.phase.title.isEmpty ? " " : indexer.phase.title))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            } header: {
                Text("Медиатека")
            }

            Section {
                HStack {
                    Button(indexer.isPaused ? "Продолжить анализ" : "Приостановить анализ") { indexer.togglePause() }
                    Button("Проверить папку на новые фото") { indexer.restart() }
                }
                Button("Вернуть скрытые фото (\(Fmt.number(stats.hidden)))") {
                    let indexerRef = indexer
                    DispatchQueue.global(qos: .userInitiated).async {
                        Library.unhideAll()
                        indexerRef.notifyLibraryChanged()
                    }
                }
                .disabled(stats.hidden == 0)
            } header: {
                Text("Действия")
            }

            Text("Всё распознавание выполняется на этом Mac. Фото никуда не отправляются.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(20)
    }

    // MARK: Actions

    private func reloadStats() {
        Task { @MainActor in
            stats = await Task.detached(priority: .utility) { Library.stats() }.value
        }
    }

    private func regroup() {
        regrouping = true
        regroupProgress = 0
        let indexerRef = indexer
        DispatchQueue.global(qos: .userInitiated).async {
            FaceClusterer.shared.recluster { done, total in
                DispatchQueue.main.async {
                    regroupProgress = total > 0 ? Double(done) / Double(total) : 1
                }
            }
            DispatchQueue.main.async {
                regrouping = false
                indexerRef.notifyLibraryChanged()
            }
        }
    }
}
