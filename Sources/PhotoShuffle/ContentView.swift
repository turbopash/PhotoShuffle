import SwiftUI

struct ContentView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Group {
            if app.rootPath == nil {
                OnboardingView()
            } else {
                switch app.tab {
                case .slideshow:
                    SlideshowView(model: app.slideshow)
                case .people:
                    PeopleView()
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                IndexingStatusView()
            }
            ToolbarItem(placement: .principal) {
                if app.rootPath != nil {
                    Picker("Раздел", selection: $app.tab) {
                        Text("Слайд-шоу").tag(AppState.Tab.slideshow)
                        Text("Люди").tag(AppState.Tab.people)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 230)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openSettingsWindow()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Настройки")
            }
        }
    }
}

struct IndexingStatusView: View {
    @EnvironmentObject var indexer: Indexer

    var body: some View {
        HStack(spacing: 8) {
            if indexer.phase.isWorking && !indexer.isPaused {
                ProgressView()
                    .controlSize(.small)
            }
            if indexer.isPaused || !indexer.phase.title.isEmpty {
                Text(indexer.isPaused ? "Анализ на паузе" : indexer.phase.title)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            if indexer.phase.isWorking || indexer.isPaused {
                Button {
                    indexer.togglePause()
                } label: {
                    Image(systemName: indexer.isPaused ? "play.circle" : "pause.circle")
                }
                .buttonStyle(.borderless)
                .help(indexer.isPaused ? "Продолжить анализ" : "Приостановить анализ")
            }
        }
        .padding(.horizontal, 4)
    }
}

struct OnboardingView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.13, green: 0.10, blue: 0.24), Color(red: 0.02, green: 0.02, blue: 0.05)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 22) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 76, weight: .light))
                    .foregroundStyle(LinearGradient(colors: [.orange, .pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text("PhotoShuffle")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                Text("Ваши фотографии в случайном порядке — с людьми, машинами, природой и всем, что вы выберете.")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: 480)
                Button {
                    app.chooseFolder()
                } label: {
                    Label("Выбрать папку с фото", systemImage: "folder.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .padding(.horizontal, 26)
                        .padding(.vertical, 13)
                        .foregroundColor(.white)
                        .background(Capsule().fill(LinearGradient(colors: [.orange, .pink], startPoint: .leading, endPoint: .trailing)))
                }
                .buttonStyle(.plain)
                Text("Можно выбрать весь внешний диск — вложенные папки тоже попадут в показ.\nВсё распознавание идёт на этом Mac, фото никуда не отправляются.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
            }
            .padding(40)
        }
    }
}

// MARK: - Shared small views

struct CapsuleButtonStyle: ButtonStyle {
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundColor(prominent ? .white : .primary)
            .background(Capsule().fill(prominent ? Color.accentColor : Color.white.opacity(0.1)))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct FaceAvatar: View {
    let face: FaceRef?
    let size: CGFloat
    @State var image: NSImage?

    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.08))
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42))
                    .foregroundColor(.white.opacity(0.22))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: face?.id) {
            if let face = face {
                image = await ImageStore.shared.face(face)
            } else {
                image = nil
            }
        }
    }
}

struct ThumbView: View {
    let item: MediaItem
    var maxPixel = 420
    @State var image: NSImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Color.white.opacity(0.05))
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if item.isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.white)
                    .shadow(radius: 3)
                    .padding(6)
            } else if item.livePath != nil {
                Image(systemName: "livephoto")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .shadow(radius: 3)
                    .padding(6)
            }
        }
        .task(id: item.id) {
            image = await ImageStore.shared.thumb(item, maxPixel: maxPixel)
        }
    }
}

struct SearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.08)))
    }
}
