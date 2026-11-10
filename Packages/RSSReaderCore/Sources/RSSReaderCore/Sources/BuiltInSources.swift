import Foundation

// MARK: - Curated feed directory

public struct DirectorySource: Identifiable, Codable, Hashable, Sendable {
    public var id: String { url.absoluteString }
    public var name: String
    public var summary: String
    public var url: URL
    public var category: String
    public var tags: [String]
    public var symbol: String
    public var format: FeedFormat

    public init(
        name: String,
        summary: String,
        url: String,
        category: String,
        tags: [String],
        symbol: String,
        format: FeedFormat = .rss
    ) {
        self.name = name
        self.summary = summary
        self.url = URL(string: url) ?? URL(string: "https://example.com")!
        self.category = category
        self.tags = tags
        self.symbol = symbol
        self.format = format
    }

    /// Bare host, for display and favicon lookup.
    public var host: String {
        url.host() ?? url.absoluteString
    }
}

public enum DirectoryCategory: String, CaseIterable, Sendable {
    case apple = "Apple"
    case technology = "Technology"
    case development = "Development"
    case science = "Science"
    case space = "Space"
    case news = "World News"
    case design = "Design"
    case security = "Security"
    case business = "Business"
    case culture = "Culture"
    case comics = "Comics"
}

public enum BuiltInSources {
    public static let all: [DirectorySource] = [
        // Apple
        DirectorySource(name: "Apple Newsroom", summary: "Official Apple press releases and product announcements.",
                        url: "https://www.apple.com/newsroom/rss-feed.rss", category: "Apple",
                        tags: ["apple", "products", "official"], symbol: "apple.logo"),
        DirectorySource(name: "MacRumors", summary: "Apple news, rumours and buying guides.",
                        url: "https://feeds.macrumors.com/MacRumors-All", category: "Apple",
                        tags: ["apple", "mac", "iphone"], symbol: "laptopcomputer"),
        DirectorySource(name: "9to5Mac", summary: "Daily Apple news and analysis.",
                        url: "https://9to5mac.com/feed/", category: "Apple",
                        tags: ["apple", "mac", "ios"], symbol: "macbook"),
        DirectorySource(name: "MacStories", summary: "In-depth Apple coverage, reviews and app culture.",
                        url: "https://www.macstories.net/feed/", category: "Apple",
                        tags: ["apple", "apps", "reviews"], symbol: "text.book.closed"),
        DirectorySource(name: "Daring Fireball", summary: "John Gruber on Apple, design and the web.",
                        url: "https://daringfireball.net/feeds/main", category: "Apple",
                        tags: ["apple", "design", "commentary"], symbol: "nose"),
        DirectorySource(name: "Six Colors", summary: "Jason Snell's Apple reporting and commentary.",
                        url: "https://sixcolors.com/feed/", category: "Apple",
                        tags: ["apple", "analysis"], symbol: "paintpalette"),
        DirectorySource(name: "AppleInsider", summary: "Apple news, rumours and financial coverage.",
                        url: "https://appleinsider.com/rss/news/", category: "Apple",
                        tags: ["apple", "news"], symbol: "newspaper"),
        DirectorySource(name: "512 Pixels", summary: "Stephen Hackett on Apple history and the Mac.",
                        url: "https://512pixels.net/feed/", category: "Apple",
                        tags: ["apple", "history", "mac"], symbol: "desktopcomputer"),
        DirectorySource(name: "The Loop", summary: "Jim Dalrymple's Apple news and reviews.",
                        url: "https://www.loopinsight.com/feed/", category: "Apple",
                        tags: ["apple", "reviews"], symbol: "repeat"),
        DirectorySource(name: "Cult of Mac", summary: "Apple culture, tips and news.",
                        url: "https://www.cultofmac.com/feed/", category: "Apple",
                        tags: ["apple", "culture"], symbol: "sparkles"),

        // Development
        DirectorySource(name: "Swift Blog", summary: "Official Swift language announcements from Apple.",
                        url: "https://www.swift.org/atom.xml", category: "Development",
                        tags: ["swift", "apple", "language"], symbol: "swift", format: .atom),
        DirectorySource(name: "Swift by Sundell", summary: "Articles and podcasts about Swift development.",
                        url: "https://swiftbysundell.com/rss", category: "Development",
                        tags: ["swift", "ios", "architecture"], symbol: "chevron.left.forwardslash.chevron.right"),
        DirectorySource(name: "Hacking with Swift", summary: "Paul Hudson's Swift tutorials and articles.",
                        url: "https://www.hackingwithswift.com/articles/rss", category: "Development",
                        tags: ["swift", "tutorials"], symbol: "hammer"),
        DirectorySource(name: "Point-Free", summary: "Functional Swift and architecture from Brandon and Stephen.",
                        url: "https://www.pointfree.co/blog/feed/atom.xml", category: "Development",
                        tags: ["swift", "functional", "video"], symbol: "function"),
        DirectorySource(name: "iOS Dev Weekly", summary: "Dave Verwer's weekly iOS development roundup.",
                        url: "https://iosdevweekly.com/issues.rss", category: "Development",
                        tags: ["ios", "newsletter"], symbol: "envelope"),
        DirectorySource(name: "GitHub Blog", summary: "Product news and engineering stories from GitHub.",
                        url: "https://github.blog/feed/", category: "Development",
                        tags: ["github", "engineering", "open source"], symbol: "chevron.left.slash.chevron.right"),
        DirectorySource(name: "Simon Willison", summary: "Datasette, LLMs and practical engineering.",
                        url: "https://simonwillison.net/atom/everything/", category: "Development",
                        tags: ["python", "ai", "data"], symbol: "terminal", format: .atom),
        DirectorySource(name: "Julia Evans", summary: "Debugging, networking and systems zines.",
                        url: "https://jvns.ca/atom.xml", category: "Development",
                        tags: ["systems", "debugging"], symbol: "wrench.and.screwdriver", format: .atom),
        DirectorySource(name: "Dan Luu", summary: "Deep dives on software, hardware and performance.",
                        url: "https://danluu.com/atom.xml", category: "Development",
                        tags: ["performance", "engineering"], symbol: "speedometer", format: .atom),
        DirectorySource(name: "Lobsters", summary: "Computing news, curated by the community.",
                        url: "https://lobste.rs/rss", category: "Development",
                        tags: ["programming", "community"], symbol: "text.bubble"),
        DirectorySource(name: "Hacker News", summary: "The front page of Hacker News.",
                        url: "https://hnrss.org/frontpage", category: "Development",
                        tags: ["startups", "programming"], symbol: "flame"),
        DirectorySource(name: "Hacker News: Show HN", summary: "New projects launched by the community.",
                        url: "https://hnrss.org/show", category: "Development",
                        tags: ["show hn", "projects"], symbol: "megaphone"),
        DirectorySource(name: "InfoQ", summary: "Software architecture, AI and engineering trends.",
                        url: "https://feed.infoq.com/", category: "Development",
                        tags: ["architecture", "engineering"], symbol: "building.columns"),
        DirectorySource(name: "CSS-Tricks", summary: "Front-end development techniques and CSS.",
                        url: "https://css-tricks.com/feed/", category: "Development",
                        tags: ["css", "frontend"], symbol: "paintbrush"),
        DirectorySource(name: "Smashing Magazine", summary: "Design and front-end development articles.",
                        url: "https://www.smashingmagazine.com/feed/", category: "Design",
                        tags: ["design", "frontend", "ux"], symbol: "square.grid.3x3"),
        DirectorySource(name: "A List Apart", summary: "Standards-based web design and development.",
                        url: "https://alistapart.com/main/feed/", category: "Design",
                        tags: ["web", "design", "standards"], symbol: "list.bullet.rectangle"),

        // Technology
        DirectorySource(name: "Ars Technica", summary: "Technology news, reviews and analysis.",
                        url: "https://feeds.arstechnica.com/arstechnica/index", category: "Technology",
                        tags: ["tech", "science", "policy"], symbol: "cpu"),
        DirectorySource(name: "The Verge", summary: "Technology, science and culture.",
                        url: "https://www.theverge.com/rss/index.xml", category: "Technology",
                        tags: ["tech", "gadgets"], symbol: "bolt.horizontal", format: .atom),
        DirectorySource(name: "Wired", summary: "The way technology shapes culture and the future.",
                        url: "https://www.wired.com/feed/rss", category: "Technology",
                        tags: ["tech", "culture", "science"], symbol: "antenna.radiowaves.left.and.right"),
        DirectorySource(name: "TechCrunch", summary: "Startup and technology industry news.",
                        url: "https://techcrunch.com/feed/", category: "Technology",
                        tags: ["startups", "venture"], symbol: "chart.line.uptrend.xyaxis"),
        DirectorySource(name: "Engadget", summary: "Consumer electronics and gadget reviews.",
                        url: "https://www.engadget.com/rss.xml", category: "Technology",
                        tags: ["gadgets", "reviews"], symbol: "iphone.gen3"),
        DirectorySource(name: "The Register", summary: "Irreverent enterprise technology news.",
                        url: "https://www.theregister.com/headlines.atom", category: "Technology",
                        tags: ["enterprise", "security"], symbol: "server.rack", format: .atom),
        DirectorySource(name: "9to5Google", summary: "Google, Android and Chrome news.",
                        url: "https://9to5google.com/feed/", category: "Technology",
                        tags: ["google", "android"], symbol: "globe"),
        DirectorySource(name: "Android Police", summary: "Android news, reviews and tips.",
                        url: "https://www.androidpolice.com/feed/", category: "Technology",
                        tags: ["android", "google"], symbol: "apps.iphone"),
        DirectorySource(name: "Phoronix", summary: "Linux hardware and open-source performance news.",
                        url: "https://www.phoronix.com/rss.php", category: "Technology",
                        tags: ["linux", "hardware"], symbol: "terminal"),
        DirectorySource(name: "Product Hunt", summary: "New products launched every day.",
                        url: "https://www.producthunt.com/feed", category: "Technology",
                        tags: ["products", "startups"], symbol: "rocket"),

        // Science
        DirectorySource(name: "Quanta Magazine", summary: "Mathematics, physics, biology and computer science.",
                        url: "https://www.quantamagazine.org/feed/", category: "Science",
                        tags: ["science", "math", "physics"], symbol: "atom"),
        DirectorySource(name: "Nature", summary: "Research highlights from Nature.",
                        url: "https://www.nature.com/nature.rss", category: "Science",
                        tags: ["research", "biology"], symbol: "leaf"),
        DirectorySource(name: "ScienceDaily", summary: "Breaking research news across the sciences.",
                        url: "https://www.sciencedaily.com/rss/all.xml", category: "Science",
                        tags: ["research", "science"], symbol: "flask"),
        DirectorySource(name: "Phys.org", summary: "Physics, technology and science news.",
                        url: "https://phys.org/rss-feed/", category: "Science",
                        tags: ["physics", "research"], symbol: "waveform.path"),
        DirectorySource(name: "NASA Breaking News", summary: "Official NASA mission updates.",
                        url: "https://www.nasa.gov/rss/dyn/breaking_news.rss", category: "Space",
                        tags: ["nasa", "space"], symbol: "moon.stars"),
        DirectorySource(name: "NASA Image of the Day", summary: "A daily image from NASA's archive.",
                        url: "https://www.nasa.gov/rss/dyn/lg_image_of_the_day.rss", category: "Space",
                        tags: ["nasa", "images"], symbol: "photo"),
        DirectorySource(name: "Space.com", summary: "Space exploration, astronomy and skywatching.",
                        url: "https://www.space.com/feeds/all", category: "Space",
                        tags: ["space", "astronomy"], symbol: "sparkles"),
        DirectorySource(name: "Universe Today", summary: "Space and astronomy news.",
                        url: "https://www.universetoday.com/feed/", category: "Space",
                        tags: ["space", "astronomy"], symbol: "circle.dotted"),

        // News
        DirectorySource(name: "BBC News", summary: "Top stories from the BBC.",
                        url: "https://feeds.bbci.co.uk/news/rss.xml", category: "World News",
                        tags: ["world", "news"], symbol: "newspaper"),
        DirectorySource(name: "BBC Technology", summary: "Technology coverage from BBC News.",
                        url: "https://feeds.bbci.co.uk/news/technology/rss.xml", category: "World News",
                        tags: ["tech", "news"], symbol: "antenna.radiowaves.left.and.right"),
        DirectorySource(name: "The New York Times", summary: "Front page stories from the NYT.",
                        url: "https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml", category: "World News",
                        tags: ["news", "world"], symbol: "newspaper"),
        DirectorySource(name: "The Guardian", summary: "World news from The Guardian.",
                        url: "https://www.theguardian.com/world/rss", category: "World News",
                        tags: ["world", "news"], symbol: "globe"),
        DirectorySource(name: "The Guardian: Technology", summary: "Technology coverage from The Guardian.",
                        url: "https://www.theguardian.com/uk/technology/rss", category: "World News",
                        tags: ["tech", "news"], symbol: "globe"),
        DirectorySource(name: "NPR News", summary: "US and world news from NPR.",
                        url: "https://feeds.npr.org/1001/rss.xml", category: "World News",
                        tags: ["news", "radio"], symbol: "radio"),
        DirectorySource(name: "Al Jazeera", summary: "International news from Al Jazeera.",
                        url: "https://www.aljazeera.com/xml/rss/all.xml", category: "World News",
                        tags: ["world", "news"], symbol: "globe"),

        // Security
        DirectorySource(name: "Krebs on Security", summary: "Investigative reporting on cybercrime.",
                        url: "https://krebsonsecurity.com/feed/", category: "Security",
                        tags: ["security", "cybercrime"], symbol: "lock.shield"),
        DirectorySource(name: "BleepingComputer", summary: "Security news and malware analysis.",
                        url: "https://www.bleepingcomputer.com/feed/", category: "Security",
                        tags: ["security", "malware"], symbol: "shield.lefthalf.filled"),
        DirectorySource(name: "The Hacker News", summary: "Cybersecurity news and vulnerability coverage.",
                        url: "https://feeds.feedburner.com/TheHackersNews", category: "Security",
                        tags: ["security", "vulnerabilities"], symbol: "exclamationmark.shield"),

        // Business / Culture
        DirectorySource(name: "Stratechery", summary: "Ben Thompson on technology strategy.",
                        url: "https://stratechery.com/feed/", category: "Business",
                        tags: ["strategy", "business"], symbol: "chart.bar"),
        DirectorySource(name: "Benedict Evans", summary: "Technology, media and venture capital essays.",
                        url: "https://www.ben-evans.com/benedictevans?format=rss", category: "Business",
                        tags: ["analysis", "venture"], symbol: "chart.pie"),
        DirectorySource(name: "Kottke.org", summary: "Jason Kottke's curated culture and curiosity.",
                        url: "https://kottke.org/index.xml", category: "Culture",
                        tags: ["culture", "links"], symbol: "link"),
        DirectorySource(name: "The Onion", summary: "America's finest news source.",
                        url: "https://www.theonion.com/rss", category: "Culture",
                        tags: ["satire", "humour"], symbol: "face.smiling"),
        DirectorySource(name: "XKCD", summary: "A webcomic of romance, sarcasm, math and language.",
                        url: "https://xkcd.com/rss.xml", category: "Comics",
                        tags: ["comics", "geek"], symbol: "text.bubble"),
        DirectorySource(name: "Penny Arcade", summary: "Games, culture and the Penny Arcade comic.",
                        url: "https://www.penny-arcade.com/feed", category: "Comics",
                        tags: ["comics", "gaming"], symbol: "gamecontroller")
    ]

    /// Feeds selected on first launch for a useful out-of-the-box experience.
    public static let starterNames: [String] = [
        "Ars Technica", "The Verge", "Daring Fireball", "MacRumors",
        "Hacker News", "Swift Blog", "NASA Breaking News", "Quanta Magazine"
    ]

    public static var starters: [DirectorySource] {
        all.filter { starterNames.contains($0.name) }
    }

    public static func sources(in category: String) -> [DirectorySource] {
        all.filter { $0.category == category }
    }

    public static let categories: [String] = {
        var seen = Set<String>()
        return all.compactMap { source in
            seen.insert(source.category).inserted ? source.category : nil
        }
    }()
}

// MARK: - Usenet presets

public struct UsenetServerPreset: Identifiable, Hashable, Sendable {
    public var id: String { host }
    public var name: String
    public var host: String
    public var port: Int
    public var useTLS: Bool
    public var summary: String
    public var requiresAccount: Bool

    public init(
        name: String,
        host: String,
        port: Int = 563,
        useTLS: Bool = true,
        summary: String,
        requiresAccount: Bool
    ) {
        self.name = name
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.summary = summary
        self.requiresAccount = requiresAccount
    }
}

public enum BuiltInUsenet {
    public static let servers: [UsenetServerPreset] = [
        UsenetServerPreset(name: "Neodome (free plain)", host: "news.neodome.net", port: 119, useTLS: false, summary: "Free, anonymous, full group list. No account.", requiresAccount: false),
        UsenetServerPreset(name: "Usenet.ovh (free plain)", host: "usenet.ovh", port: 119, useTLS: false, summary: "Free, anonymous, read-only.", requiresAccount: false),
        UsenetServerPreset(name: "Chmurka (free plain)", host: "news.chmurka.net", port: 119, useTLS: false, summary: "Free, anonymous, active groups.", requiresAccount: false),
        UsenetServerPreset(name: "Netfront (free plain)", host: "freenews.netfront.net", port: 119, useTLS: false, summary: "Free, anonymous, large comp.* and alt.* groups. No account.", requiresAccount: false),
        UsenetServerPreset(name: "Gmane (mailing lists)", host: "news.gmane.io", port: 119, useTLS: false, summary: "Free, anonymous, mailing-list archives (browse gmane.*).", requiresAccount: false),
        UsenetServerPreset(name: "Mixmin (free TLS)", host: "news.mixmin.net", port: 563, useTLS: true, summary: "Free TLS; some groups have zero articles.", requiresAccount: false),
        UsenetServerPreset(name: "Eternal September", host: "news.eternal-september.org", port: 563, useTLS: true, summary: "Free with simple registration (READ DENIED for anonymous).", requiresAccount: true),
        UsenetServerPreset(
            name: "Giganews",
            host: "news.giganews.com",
            summary: "Premium Usenet provider with long retention.",
            requiresAccount: true
        ),
        UsenetServerPreset(
            name: "UsenetServer",
            host: "news.usenetserver.com",
            summary: "High-retention Usenet access.",
            requiresAccount: true
        ),
        UsenetServerPreset(
            name: "Newshosting",
            host: "news.newshosting.com",
            summary: "Popular unlimited Usenet provider.",
            requiresAccount: true
        ),
        UsenetServerPreset(
            name: "Easynews",
            host: "news.easynews.com",
            summary: "Usenet with a web search interface.",
            requiresAccount: true
        ),
        UsenetServerPreset(
            name: "Astraweb",
            host: "news.astraweb.com",
            summary: "Long-running independent Usenet provider.",
            requiresAccount: true
        ),
        UsenetServerPreset(
            name: "NewsDemon",
            host: "news.newsdemon.com",
            summary: "Unlimited Usenet plans with block options.",
            requiresAccount: true
        ),
        UsenetServerPreset(
            name: "Frugal Usenet",
            host: "news.frugalusenet.com",
            summary: "Budget-friendly Usenet with tiered retention.",
            requiresAccount: true
        )
    ]

    public struct GroupPreset: Identifiable, Hashable, Sendable {
        public var id: String { name }
        public var name: String
        public var summary: String
        public var symbol: String

        public init(name: String, summary: String, symbol: String) {
            self.name = name
            self.summary = summary
            self.symbol = symbol
        }
    }

    public static let groups: [GroupPreset] = [
        .init(name: "comp.lang.python", summary: "Python programming.", symbol: "chevron.left.forwardslash.chevron.right"),
        .init(name: "comp.lang.c", summary: "The C programming language.", symbol: "c.circle"),
        .init(name: "comp.lang.c++", summary: "C++ discussion.", symbol: "c.square"),
        .init(name: "comp.lang.objective-c", summary: "Objective-C and Cocoa.", symbol: "macwindow"),
        .init(name: "comp.sys.mac.apps", summary: "macOS application discussion.", symbol: "macwindow"),
        .init(name: "comp.sys.mac.system", summary: "macOS system administration.", symbol: "gearshape.2"),
        .init(name: "comp.os.linux.misc", summary: "Linux discussion.", symbol: "terminal"),
        .init(name: "comp.infosystems.www.authoring.html", summary: "Web authoring (HTML/CSS).", symbol: "globe"),
        .init(name: "comp.arch", summary: "Computer architecture.", symbol: "cpu"),
        .init(name: "sci.astro", summary: "Astronomy.", symbol: "sparkles"),
        .init(name: "sci.physics", summary: "Physics.", symbol: "atom"),
        .init(name: "sci.electronics.design", summary: "Electronics design.", symbol: "bolt"),
        .init(name: "rec.arts.sf.written", summary: "Science fiction writing.", symbol: "book.closed"),
        .init(name: "rec.photo.digital", summary: "Digital photography.", symbol: "camera"),
        .init(name: "rec.food.cooking", summary: "Cooking.", symbol: "fork.knife"),
        .init(name: "news.software.readers", summary: "Newsreader clients.", symbol: "newspaper")
    ]
}
