import SwiftUI
import AppKit
import Combine

// MARK: - People list

final class PeopleModel: ObservableObject {
    @Published private(set) var people: [PersonSummary] = []
    @Published private(set) var loaded = false
    @Published var search = ""

    func reload() {
        Task { @MainActor [weak self] in
            let list = await Task.detached(priority: .userInitiated) { Library.persons() }.value
            self?.people = list
            self?.loaded = true
        }
    }

    private var query: String { search.trimmingCharacters(in: .whitespaces).lowercased() }

    var named: [PersonSummary] {
        let q = query
        return people.filter { p in
            guard let name = p.name else { return false }
            return q.isEmpty || name.lowercased().contains(q)
        }
    }

    var unnamed: [PersonSummary] {
        query.isEmpty ? people.filter { $0.name == nil } : []
    }
}

struct PeopleView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var indexer: Indexer
    @StateObject var model = PeopleModel()
    @State var selected: Int64?

    let columns = [GridItem(.adaptive(minimum: 132, maximum: 160), spacing: 22)]

    var body: some View {
        Group {
            if let pid = selected {
                PersonDetailView(personId: pid,
                                 onBack: { selected = nil; model.reload() },
                                 onOpen: { selected = $0 })
                    .id(pid)
            } else {
                list
            }
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.09))
        .onAppear { model.reload() }
        .onReceive(indexer.$libraryVersion.dropFirst()) { _ in
            if selected == nil { model.reload() }
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Люди").font(.system(size: 34, weight: .bold))
                        Text("Подпишите лица — и PhotoShuffle узнает этих людей на остальных фото.")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    SearchField(prompt: "Найти по имени", text: $model.search)
                        .frame(width: 230)
                }

                if !model.loaded {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 80)
                } else if model.people.isEmpty {
                    emptyState
                } else {
                    if !model.named.isEmpty {
                        section(title: "Подписанные", subtitle: nil, people: model.named)
                    }
                    if !model.unnamed.isEmpty {
                        section(title: "Кто это?", subtitle: "Нажмите на лицо и введите имя — похожие лица подтянутся сами",
                                people: model.unnamed)
                    }
                    if model.named.isEmpty && model.unnamed.isEmpty {
                        Text("Никого не нашлось").foregroundColor(.secondary)
                    }
                }
            }
            .padding(30)
        }
    }

    private func section(title: String, subtitle: String?, people: [PersonSummary]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.weight(.semibold))
                if let subtitle = subtitle {
                    Text(subtitle).font(.callout).foregroundColor(.secondary)
                }
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                ForEach(people) { person in
                    Button {
                        selected = person.id
                    } label: {
                        PersonCard(person: person)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Слайд-шоу с этим человеком") { app.showSlideshow(personId: person.id) }
                        Button("Скрыть из списка") {
                            let id = person.id
                            Task { @MainActor in
                                await Task.detached { Library.setPersonHidden(id) }.value
                                model.reload()
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 56, weight: .light))
                .foregroundColor(.secondary)
            Text("Лица появятся по мере анализа фото").font(.title3.weight(.semibold))
            Text(indexer.phase.isWorking ? indexer.phase.title : "Проверьте, что выбрана правильная папка с фото")
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

struct PersonCard: View {
    let person: PersonSummary
    @State var hover = false

    var body: some View {
        VStack(spacing: 8) {
            FaceAvatar(face: person.coverFace, size: 116)
                .overlay(Circle().stroke(Color.white.opacity(hover ? 0.85 : 0.1), lineWidth: hover ? 3 : 1))
                .shadow(color: .black.opacity(0.4), radius: hover ? 12 : 4, y: 3)
                .scaleEffect(hover ? 1.04 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover)
            Text(person.name ?? "Добавить имя")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(person.name == nil ? .accentColor : .primary)
                .lineLimit(1)
            Text("\(Fmt.number(person.count)) фото")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(width: 136)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

// MARK: - One person

final class PersonDetailModel: ObservableObject {
    let personId: Int64
    @Published private(set) var person: PersonSummary?
    @Published private(set) var photos: [PersonPhoto] = []
    @Published private(set) var suggestions: [PersonSummary] = []
    @Published private(set) var loading = true

    init(personId: Int64) {
        self.personId = personId
    }

    func load() {
        let pid = personId
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> (PersonSummary?, [PersonPhoto], [PersonSummary]) in
                (Library.person(pid), Library.photos(ofPerson: pid), Library.suggestions(for: pid))
            }.value
            guard let self = self else { return }
            self.person = result.0
            self.photos = result.1
            self.suggestions = result.2
            self.loading = false
        }
    }

    func rename(_ name: String) {
        let pid = personId
        Task { @MainActor [weak self] in
            await Task.detached { FaceClusterer.shared.rename(pid, to: name) }.value
            self?.load()
        }
    }

    /// Merges `other` with this person. Returns (via completion) the id that survived.
    func accept(_ other: PersonSummary, completion: @escaping (Int64) -> Void) {
        let me = personId
        let target: Int64
        let source: Int64
        if person?.name == nil && other.name != nil {
            target = other.id
            source = me
        } else {
            target = me
            source = other.id
        }
        suggestions.removeAll { $0.id == other.id }
        Task { @MainActor [weak self] in
            await Task.detached { FaceClusterer.shared.merge(source, into: target) }.value
            if target == me { self?.load() } else { completion(target) }
        }
    }

    func acceptAll() {
        let me = personId
        let others = suggestions.filter { $0.name == nil }.map { $0.id }
        suggestions.removeAll()
        Task { @MainActor [weak self] in
            await Task.detached {
                for id in others { FaceClusterer.shared.merge(id, into: me) }
            }.value
            self?.load()
        }
    }

    func reject(_ other: PersonSummary) {
        let me = personId
        suggestions.removeAll { $0.id == other.id }
        DispatchQueue.global(qos: .utility).async { Library.rejectPair(me, other.id) }
    }

    func removeFace(_ photo: PersonPhoto) {
        photos.removeAll { $0.id == photo.id }
        let faceId = photo.face.id
        Task { @MainActor [weak self] in
            await Task.detached { FaceClusterer.shared.removeFace(faceId) }.value
            self?.load()
        }
    }

    func mergeInto(_ target: Int64, completion: @escaping () -> Void) {
        let me = personId
        Task { @MainActor in
            await Task.detached { FaceClusterer.shared.merge(me, into: target) }.value
            completion()
        }
    }

    func hide(completion: @escaping () -> Void) {
        let me = personId
        Task { @MainActor in
            await Task.detached { Library.setPersonHidden(me) }.value
            completion()
        }
    }
}

struct PersonDetailView: View {
    let personId: Int64
    let onBack: () -> Void
    let onOpen: (Int64) -> Void

    @EnvironmentObject var app: AppState
    @StateObject var model: PersonDetailModel
    @State var name = ""
    @State var viewerIndex: Int?
    @State var showMerge = false
    @State var mergeCandidate: PersonSummary?
    @FocusState var nameFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 6)]

    init(personId: Int64, onBack: @escaping () -> Void, onOpen: @escaping (Int64) -> Void) {
        self.personId = personId
        self.onBack = onBack
        self.onOpen = onOpen
        _model = StateObject(wrappedValue: PersonDetailModel(personId: personId))
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    topBar
                    header
                    if !model.suggestions.isEmpty { suggestionsView }
                    grid
                }
                .padding(28)
            }

            if let index = viewerIndex, !model.photos.isEmpty {
                PhotoViewer(items: model.photos.map { $0.item }, index: min(index, model.photos.count - 1)) {
                    withAnimation(.easeInOut(duration: 0.2)) { viewerIndex = nil }
                }
                .transition(.opacity)
            }
        }
        .onAppear {
            model.load()
        }
        .onReceive(model.$person) { person in
            guard let person = person, !nameFocused else { return }
            name = person.name ?? ""
            if person.name == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { nameFocused = true }
            }
        }
        .onChange(of: nameFocused) { focused in
            if !focused { saveName() }
        }
        .sheet(isPresented: $showMerge) {
            MergePicker(excluding: personId, onPick: { target in
                showMerge = false
                model.mergeInto(target) { onOpen(target) }
            }, onCancel: { showMerge = false })
        }
        .alert("Это один и тот же человек?",
               isPresented: Binding(get: { mergeCandidate != nil }, set: { if !$0 { mergeCandidate = nil } })) {
            Button("Объединить") {
                if let target = mergeCandidate {
                    model.mergeInto(target.id) { onOpen(target.id) }
                }
                mergeCandidate = nil
            }
            Button("Отмена", role: .cancel) {
                name = model.person?.name ?? ""
                mergeCandidate = nil
            }
        } message: {
            Text("Человек с именем «\(mergeCandidate?.name ?? "")» уже есть. Объединить их фото?")
        }
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (model.person?.name ?? "") else { return }
        if !trimmed.isEmpty, let existing = Library.namedPerson(matching: trimmed, excluding: personId) {
            mergeCandidate = existing
            return
        }
        model.rename(trimmed)
    }

    // MARK: Parts

    private var topBar: some View {
        HStack {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Люди")
                }
                .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
            .keyboardShortcut("[", modifiers: .command)

            Spacer()

            Menu {
                Button("Объединить с другим человеком…") { showMerge = true }
                Button("Скрыть этого человека") { model.hide { onBack() } }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 18))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var header: some View {
        HStack(spacing: 22) {
            FaceAvatar(face: model.person?.coverFace, size: 108)
                .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
            VStack(alignment: .leading, spacing: 6) {
                TextField("Кто это? Введите имя", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 30, weight: .bold))
                    .focused($nameFocused)
                    .onSubmit { nameFocused = false; saveName() }
                Text(model.loading ? " " : "\(Fmt.number(model.photos.count)) фото · нажмите Enter, чтобы сохранить имя")
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                saveName()
                app.showSlideshow(personId: personId)
            } label: {
                Label("Слайд-шоу", systemImage: "play.fill")
            }
            .buttonStyle(CapsuleButtonStyle())
            .disabled(model.photos.isEmpty)
        }
    }

    private var suggestionsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.person?.name.map { "Это тоже \($0)?" } ?? "Похоже на этого же человека")
                    .font(.headline)
                Spacer()
                if model.person?.name != nil && model.suggestions.contains(where: { $0.name == nil }) {
                    Button("Да, это всё он(а)") { model.acceptAll() }
                        .buttonStyle(CapsuleButtonStyle(prominent: false))
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(model.suggestions) { suggestion in
                        VStack(spacing: 6) {
                            FaceAvatar(face: suggestion.coverFace, size: 78)
                            Text(suggestion.name ?? "\(Fmt.number(suggestion.count)) фото")
                                .font(.caption)
                                .lineLimit(1)
                            HStack(spacing: 8) {
                                Button {
                                    model.accept(suggestion) { target in onOpen(target) }
                                } label: {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .frame(width: 28, height: 28)
                                        .background(Circle().fill(Color.green.opacity(0.85)))
                                        .foregroundColor(.white)
                                }
                                .buttonStyle(.plain)
                                .help("Да, это он(а)")
                                Button {
                                    model.reject(suggestion)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .frame(width: 28, height: 28)
                                        .background(Circle().fill(Color.white.opacity(0.15)))
                                        .foregroundColor(.white)
                                }
                                .buttonStyle(.plain)
                                .help("Нет, это другой человек")
                            }
                        }
                        .frame(width: 96)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.05)))
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.photos.isEmpty {
                Text("Правый клик по фото → «Это не \(model.person?.name ?? "этот человек")», если попал кто-то другой")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(model.photos.enumerated()), id: \.element.id) { index, photo in
                    PersonPhotoCell(photo: photo,
                                    onOpen: { withAnimation(.easeInOut(duration: 0.2)) { viewerIndex = index } },
                                    onRemove: { model.removeFace(photo) })
                        .contextMenu {
                            Button("Это не \(model.person?.name ?? "этот человек")") { model.removeFace(photo) }
                            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([photo.item.url]) }
                        }
                }
            }
        }
    }
}

struct PersonPhotoCell: View {
    let photo: PersonPhoto
    let onOpen: () -> Void
    let onRemove: () -> Void
    @State var hover = false

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay(ThumbView(item: photo.item))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if hover {
                    Button(action: onRemove) {
                        Image(systemName: "person.crop.circle.badge.xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(6)
                            .background(Circle().fill(Color.black.opacity(0.6)))
                    }
                    .buttonStyle(.plain)
                    .help("Это не он(а)")
                    .padding(6)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            .onHover { hover = $0 }
    }
}

// MARK: - Full-size viewer

struct PhotoViewer: View {
    let items: [MediaItem]
    let onClose: () -> Void
    @State var index: Int
    @State var image: NSImage?

    init(items: [MediaItem], index: Int, onClose: @escaping () -> Void) {
        self.items = items
        self.onClose = onClose
        _index = State(initialValue: index)
    }

    var body: some View {
        let item = items[index]
        ZStack {
            Color.black.opacity(0.95)
            if item.isVideo {
                VideoPlayerView(url: item.url, muted: false, onEnd: {})
                    .id(item.id)
                    .padding(30)
            } else if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(30)
            } else {
                ProgressView()
            }

            HStack {
                navButton("chevron.left") { step(-1) }.opacity(index > 0 ? 1 : 0.2)
                Spacer()
                navButton("chevron.right") { step(1) }.opacity(index < items.count - 1 ? 1 : 0.2)
            }
            .padding(.horizontal, 16)

            VStack {
                HStack {
                    if let date = item.date {
                        Text(Fmt.date(date)).font(.headline)
                    }
                    Text(item.folderName).foregroundColor(.secondary)
                    Spacer()
                    navButton("xmark", action: onClose)
                }
                .padding(18)
                Spacer()
            }

            ZStack {
                Button("") { step(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { step(1) }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("") { onClose() }.keyboardShortcut(.escape, modifiers: [])
            }
            .buttonStyle(.plain)
            .opacity(0)
            .frame(width: 0, height: 0)
        }
        .foregroundColor(.white)
        .task(id: index) {
            image = nil
            image = await ImageStore.shared.display(items[index])
        }
    }

    private func step(_ delta: Int) {
        let next = index + delta
        guard next >= 0, next < items.count else { return }
        index = next
    }

    private func navButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 42, height: 42)
                .background(Circle().fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Merge picker

struct MergePicker: View {
    let excluding: Int64
    let onPick: (Int64) -> Void
    let onCancel: () -> Void
    @State var people: [PersonSummary] = []
    @State var query = ""

    private var filtered: [PersonSummary] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return people }
        return people.filter { ($0.name ?? "").lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Объединить с…").font(.title2.bold())
            Text("Выберите, кто это на самом деле. Все фото перейдут к выбранному человеку.")
                .foregroundColor(.secondary)
            SearchField(prompt: "Поиск по имени", text: $query)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered) { person in
                        Button {
                            onPick(person.id)
                        } label: {
                            HStack(spacing: 10) {
                                FaceAvatar(face: person.coverFace, size: 36)
                                Text(person.name ?? "Без имени")
                                    .foregroundColor(person.name == nil ? .secondary : .primary)
                                Spacer()
                                Text("\(Fmt.number(person.count)) фото").font(.caption).foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 340)
            HStack {
                Spacer()
                Button("Отмена", action: onCancel).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task {
            let all = await Task.detached(priority: .userInitiated) { Library.persons() }.value
            people = all.filter { $0.id != excluding }
        }
    }
}
