import Foundation
import CoreGraphics
import AppKit

// MARK: - Settings keys

enum Keys {
    static let root = "rootPath"
    static let slideSeconds = "slideSeconds"
    static let kenBurns = "kenBurns"
    static let includeVideos = "includeVideos"
    static let videoSound = "videoSound"
    static let faceSimilarity = "faceSimilarity"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            slideSeconds: 6.0,
            kenBurns: true,
            includeVideos: true,
            videoSound: false,
            faceSimilarity: 0.62
        ])
    }
}

// MARK: - Paths

enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoShuffle", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static let faceCache: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoShuffle", isDirectory: true)
            .appendingPathComponent("faces", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static func resetFaceCache() {
        try? FileManager.default.removeItem(at: faceCache)
        try? FileManager.default.createDirectory(at: faceCache, withIntermediateDirectories: true)
    }
}

// MARK: - Media types

enum MediaTypes {
    static let photo: Set<String> = ["jpg", "jpeg", "jpe", "heic", "heif", "png", "tif", "tiff", "gif", "bmp", "webp"]
    static let raw: Set<String> = ["dng", "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf", "srw", "pef"]
    static let video: Set<String> = ["mov", "mp4", "m4v", "3gp"]
    static let all: Set<String> = photo.union(raw).union(video)
    static let skippedFolders: Set<String> = ["$recycle.bin", "system volume information", ".trashes", ".spotlight-v100", ".fseventsd", "@eadir"]
}

// MARK: - Library models

struct MediaItem: Identifiable, Hashable {
    let id: Int64
    let path: String
    let livePath: String?
    let kind: Int          // 0 = photo, 1 = video
    let taken: Double?
    var favorite: Bool

    var url: URL { URL(fileURLWithPath: path) }
    var isVideo: Bool { kind == 1 }
    var date: Date? { taken.map { Date(timeIntervalSince1970: $0) } }
    var folderName: String { url.deletingLastPathComponent().lastPathComponent }
}

/// Face position in normalized coordinates with the origin at the top-left corner.
struct FaceRef: Hashable {
    let id: Int64
    let photoId: Int64
    let path: String
    let kind: Int
    let x: Double
    let y: Double
    let w: Double
    let h: Double

    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

struct PersonSummary: Identifiable, Hashable {
    let id: Int64
    var name: String?
    var count: Int
    var coverFace: FaceRef?
}

struct PersonPhoto: Identifiable, Hashable {
    let face: FaceRef
    let item: MediaItem
    var id: Int64 { face.id }
}

struct LabelCount: Identifiable, Hashable {
    let id: String
    let count: Int
}

struct YearCount: Identifiable, Hashable {
    let year: Int
    let count: Int
    var id: Int { year }
}

struct LibraryStats {
    var total = 0
    var analyzed = 0
    var faces = 0
    var people = 0
    var named = 0
    var hidden = 0
}

struct SlideFilter: Equatable {
    var categoryId = "all"
    var personId: Int64?
    var label: String?
    var year: Int?
    var onThisDay = false
    var favoritesOnly = false

    func isCategory(_ id: String) -> Bool { personId == nil && label == nil && categoryId == id }
    var isDefault: Bool { self == SlideFilter() }
}

struct SlidePayload {
    let image: NSImage?
    let backdrop: NSImage?
    let names: [String]
}

// MARK: - Categories

struct MediaCategory: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    let bit: Int64
    let tokens: Set<String>

    func matches(_ identifier: String) -> Bool {
        let lower = identifier.lowercased()
        if tokens.contains(lower) { return true }
        for part in lower.split(whereSeparator: { $0 == "_" || $0 == " " || $0 == "-" }) where tokens.contains(String(part)) {
            return true
        }
        return false
    }

    static let all = MediaCategory(id: "all", title: "Все", icon: "photo.on.rectangle", bit: 0, tokens: [])

    static let people = MediaCategory(
        id: "people", title: "Люди", icon: "person.2.fill", bit: 1,
        tokens: ["people", "person", "adult", "child", "baby", "crowd", "portrait", "selfie", "teen", "toddler", "kid", "kids", "infant", "groom", "bride"])

    static let vehicles = MediaCategory(
        id: "vehicles", title: "Авто", icon: "car.fill", bit: 2,
        tokens: ["car", "cars", "automobile", "vehicle", "truck", "bus", "motorcycle", "motorbike", "van", "suv", "jeep", "taxi",
                 "limousine", "convertible", "minivan", "sportscar", "tractor", "wheel", "tire", "racecar", "supercar"])

    static let animals = MediaCategory(
        id: "animals", title: "Животные", icon: "pawprint.fill", bit: 4,
        tokens: ["animal", "animals", "dog", "cat", "bird", "horse", "pet", "mammal", "canine", "feline", "puppy", "kitten", "cow",
                 "sheep", "goat", "rabbit", "squirrel", "duck", "insect", "butterfly", "reptile", "hamster", "parrot", "pigeon",
                 "chicken", "deer", "bear", "monkey", "elephant", "giraffe", "zebra", "lion", "tiger", "fox", "wolf", "owl", "swan"])

    static let nature = MediaCategory(
        id: "nature", title: "Природа", icon: "leaf.fill", bit: 8,
        tokens: ["nature", "mountain", "mountains", "forest", "tree", "trees", "flower", "flowers", "plant", "landscape", "field",
                 "grass", "sunset", "sunrise", "snow", "hill", "garden", "park", "foliage", "meadow", "autumn", "leaf", "jungle",
                 "desert", "canyon", "countryside", "blossom", "woodland", "valley", "rainbow", "sky", "clouds", "cloudy"])

    static let water = MediaCategory(
        id: "water", title: "Море", icon: "drop.fill", bit: 16,
        tokens: ["beach", "sea", "ocean", "lake", "river", "water", "pool", "waterfall", "shore", "coast", "boat", "sailboat",
                 "swimming", "waves", "wave", "harbor", "island", "yacht", "seashore", "lagoon", "pier"])

    static let food = MediaCategory(
        id: "food", title: "Еда", icon: "fork.knife", bit: 32,
        tokens: ["food", "dish", "meal", "dessert", "cake", "fruit", "vegetable", "vegetables", "drink", "pizza", "bread", "salad",
                 "coffee", "sushi", "burger", "pasta", "soup", "breakfast", "baked", "barbecue", "wine", "beer", "cocktail",
                 "meat", "seafood", "cookie", "pastry", "sandwich", "juice", "tea", "dinner", "lunch", "icecream", "chocolate"])

    static let city = MediaCategory(
        id: "city", title: "Город", icon: "building.2.fill", bit: 64,
        tokens: ["building", "buildings", "city", "street", "architecture", "house", "bridge", "skyscraper", "tower", "church",
                 "cityscape", "road", "urban", "downtown", "monument", "castle", "cathedral", "temple", "plaza", "skyline"])

    static let documents = MediaCategory(
        id: "documents", title: "Документы", icon: "doc.text.fill", bit: 128,
        tokens: ["document", "text", "screenshot", "paper", "receipt", "handwriting", "whiteboard", "printed_page", "diagram",
                 "chart", "map", "book", "letter", "screen", "computer_screen"])

    static let chips: [MediaCategory] = [all, people, vehicles, animals, nature, water, food, city]
    static let extra: [MediaCategory] = [documents]
    static let analyzed: [MediaCategory] = [people, vehicles, animals, nature, water, food, city, documents]

    static func byId(_ id: String) -> MediaCategory? {
        (chips + extra).first { $0.id == id }
    }

    static func bits(for labels: [(String, Float)]) -> Int64 {
        var bits: Int64 = 0
        for (label, conf) in labels where conf >= 0.3 {
            for category in analyzed where category.matches(label) {
                bits |= category.bit
            }
        }
        return bits
    }
}

// MARK: - Russian titles for Vision labels

enum LabelNames {
    static let ru: [String: String] = [
        "people": "Люди", "adult": "Взрослые", "child": "Дети", "baby": "Малыши", "crowd": "Толпа", "portrait": "Портрет",
        "selfie": "Селфи", "teen": "Подростки", "toddler": "Малыши",
        "car": "Машины", "automobile": "Автомобили", "vehicle": "Транспорт", "truck": "Грузовики", "bus": "Автобусы",
        "motorcycle": "Мотоциклы", "bicycle": "Велосипеды", "train": "Поезда", "airplane": "Самолёты", "aircraft": "Самолёты",
        "boat": "Лодки", "ship": "Корабли", "scooter": "Самокаты", "wheel": "Колёса",
        "animal": "Животные", "dog": "Собаки", "cat": "Кошки", "bird": "Птицы", "horse": "Лошади", "pet": "Питомцы",
        "fish": "Рыбы", "insect": "Насекомые", "butterfly": "Бабочки", "cow": "Коровы", "duck": "Утки",
        "sky": "Небо", "blue_sky": "Голубое небо", "cloudy": "Облака", "clouds": "Облака", "sunset_sunrise": "Закаты и рассветы",
        "sunset": "Закат", "sunrise": "Рассвет", "night_sky": "Ночное небо", "outdoor": "На улице", "indoor": "В помещении",
        "mountain": "Горы", "forest": "Лес", "tree": "Деревья", "flower": "Цветы", "plant": "Растения", "grass": "Трава",
        "landscape": "Пейзаж", "field": "Поле", "snow": "Снег", "winter": "Зима", "autumn": "Осень", "garden": "Сад",
        "park": "Парк", "hill": "Холмы", "desert": "Пустыня", "foliage": "Листва", "land": "Природа", "rocks": "Камни",
        "water": "Вода", "body_of_water": "Водоёмы", "sea": "Море", "ocean": "Океан", "beach": "Пляж", "sand": "Песок",
        "lake": "Озеро", "river": "Река", "pool": "Бассейн", "swimming_pool": "Бассейн", "waterfall": "Водопад", "waves": "Волны",
        "food": "Еда", "dessert": "Десерты", "cake": "Торты", "fruit": "Фрукты", "vegetable": "Овощи", "drink": "Напитки",
        "pizza": "Пицца", "bread": "Хлеб", "salad": "Салаты", "coffee": "Кофе", "sushi": "Суши", "burger": "Бургеры",
        "pasta": "Паста", "soup": "Супы", "breakfast": "Завтраки", "meat": "Мясо", "wine": "Вино", "beer": "Пиво",
        "baked_goods": "Выпечка", "barbecue": "Шашлыки", "tea": "Чай", "ice_cream": "Мороженое", "chocolate": "Шоколад",
        "structure": "Сооружения", "building": "Здания", "architecture": "Архитектура", "city": "Город", "street": "Улицы",
        "house": "Дома", "bridge": "Мосты", "skyscraper": "Небоскрёбы", "tower": "Башни", "church": "Церкви", "road": "Дороги",
        "castle": "Замки", "monument": "Памятники", "interior_room": "Интерьер", "room": "Комнаты", "kitchen": "Кухня",
        "document": "Документы", "text": "Текст", "screenshot": "Скриншоты", "paper": "Бумаги", "receipt": "Чеки",
        "handwriting": "Записи от руки", "book": "Книги", "map": "Карты",
        "toy": "Игрушки", "ball": "Мячи", "sport": "Спорт", "sports": "Спорт", "dance": "Танцы", "dancing": "Танцы",
        "music": "Музыка", "musical_instrument": "Инструменты", "guitar": "Гитары", "piano": "Пианино", "party": "Праздники",
        "birthday": "Дни рождения", "christmas_tree": "Ёлки", "fireworks": "Фейерверки", "candle": "Свечи", "balloon": "Шарики",
        "wedding": "Свадьбы", "clothing": "Одежда", "shoes": "Обувь", "hat": "Шляпы", "glasses": "Очки", "jewelry": "Украшения",
        "furniture": "Мебель", "sofa": "Диваны", "bed": "Кровати", "computer": "Компьютеры", "phone": "Телефоны",
        "television": "Телевизоры", "camera": "Фотоаппараты", "playground": "Детские площадки", "stage": "Сцена",
        "night": "Ночь", "fire": "Огонь", "campfire": "Костёр", "tent": "Палатки", "camping": "Кемпинг", "skiing": "Лыжи",
        "bicycle_wheel": "Велосипеды", "art": "Искусство", "painting": "Картины", "sculpture": "Скульптуры", "statue": "Статуи"
    ]

    static func title(_ id: String) -> String {
        if let ru = ru[id] { return ru }
        let pretty = id.replacingOccurrences(of: "_", with: " ")
        return pretty.prefix(1).uppercased() + pretty.dropFirst()
    }
}

// MARK: - Formatting

enum Fmt {
    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "ru_RU")
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM yyyy"
        return f
    }()

    static func number(_ n: Int) -> String {
        numberFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func date(_ d: Date) -> String {
        dateFormatter.string(from: d)
    }

    static func percent(_ done: Int, _ total: Int) -> String {
        guard total > 0 else { return "0%" }
        return "\(min(100, done * 100 / total))%"
    }
}

// MARK: - Helpers

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

extension Data {
    func floats() -> [Float] {
        let n = count / MemoryLayout<Float>.size
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        _ = out.withUnsafeMutableBufferPointer { copyBytes(to: $0) }
        return out
    }

    func doubles() -> [Double] {
        let n = count / MemoryLayout<Double>.size
        guard n > 0 else { return [] }
        var out = [Double](repeating: 0, count: n)
        _ = out.withUnsafeMutableBufferPointer { copyBytes(to: $0) }
        return out
    }
}

extension Array where Element == Float {
    var data: Data { withUnsafeBufferPointer { Data(buffer: $0) } }
}
