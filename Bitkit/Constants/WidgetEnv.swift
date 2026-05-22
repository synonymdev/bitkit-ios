import Foundation

/// Lightweight constants shared between the main app and the WidgetKit extension.
///
/// Kept free of BitkitCore / LDKNode imports so it can be a member of both targets via
/// `PBXFileSystemSynchronizedBuildFileExceptionSet`. `Env.swift` cannot fill this role
/// because it depends on framework types that aren't linked into the widget extension.
enum WidgetEnv {
    static let priceFeedBaseUrl = "https://feeds.synonym.to/price-feed/api"
    static let newsFeedBaseUrl = "https://feeds.synonym.to/news-feed/api"
    static let newsFeedArticlesUrl = "\(newsFeedBaseUrl)/articles"
}
